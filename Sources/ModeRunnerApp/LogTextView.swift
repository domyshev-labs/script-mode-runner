import AppKit
import SwiftUI

struct LogTextView: NSViewRepresentable {
    let text: String
    var boldFirstLine = false

    func makeNSView(context: Context) -> NSScrollView {
        makeLogScrollView()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        updateLogScrollView(scroll, text: text, boldFirstLine: boldFirstLine)
    }
}

@MainActor
func makeLogScrollView() -> NSScrollView {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false

    let contentSize = scroll.contentSize
    let view = LogDocumentView(frame: NSRect(origin: .zero, size: contentSize))
    view.delegate = view
    view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                               .cursor: NSCursor.pointingHand]
    view.isEditable = false
    view.isSelectable = true
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.minSize = NSSize(width: 0, height: contentSize.height)
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    view.textColor = .textColor
    view.backgroundColor = .textBackgroundColor
    view.drawsBackground = true
    view.textContainerInset = NSSize(width: 8, height: 8)
    view.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.widthTracksTextView = true
    scroll.documentView = view
    return scroll
}

@MainActor
func updateLogScrollView(_ scroll: NSScrollView, text: String, boldFirstLine: Bool = false) {
    let displayText = stripTerminalEscapes(text)
    guard let view = scroll.documentView as? NSTextView else { return }
    if view.string == displayText {
        applyLogHeading(to: view.textStorage, bold: boldFirstLine)
        return
    }
    let wasAtBottom = view.visibleRect.maxY >= view.bounds.maxY - 24
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.textColor,
    ]
    if let storage = view.textStorage, !view.string.isEmpty, displayText.hasPrefix(view.string) {
        let oldLength = storage.length
        let appended = (displayText as NSString).substring(from: oldLength)
        storage.beginEditing()
        storage.append(NSAttributedString(string: appended, attributes: attributes))
        // Revisit the last token so URLs split between output chunks remain clickable.
        let string = storage.string as NSString
        var start = oldLength
        while start > 0 {
            if let scalar = UnicodeScalar(string.character(at: start - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            start -= 1
        }
        let range = NSRange(location: start, length: storage.length - start)
        storage.removeAttribute(.link, range: range)
        storage.removeAttribute(.cursor, range: range)
        addLogLinks(to: storage, range: range)
        storage.endEditing()
    } else {
        let attributed = NSMutableAttributedString(string: displayText, attributes: attributes)
        addLogLinks(to: attributed)
        view.textStorage?.setAttributedString(attributed)
    }
    applyLogHeading(to: view.textStorage, bold: boldFirstLine)
    if wasAtBottom { view.scrollToEndOfDocument(nil) }
    view.window?.invalidateCursorRects(for: view)
}

@MainActor
private func applyLogHeading(to storage: NSTextStorage?, bold: Bool) {
    guard let storage, storage.length > 0 else { return }
    let firstLine = (storage.string as NSString).lineRange(for: NSRange(location: 0, length: 0))
    storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular),
                         range: firstLine)
    guard bold else { return }
    let text = storage.string as NSString
    var offset = NSMaxRange(firstLine)
    for _ in 0..<4 where offset < text.length {
        let range = text.lineRange(for: NSRange(location: offset, length: 0))
        let line = text.substring(with: range).trimmingCharacters(in: .newlines)
        for prefix in ["Configuration match: ", "Port: "] where line.hasPrefix(prefix) {
            let prefixLength = (prefix as NSString).length
            let valueRange = NSRange(location: offset + prefixLength,
                                     length: (line as NSString).length - prefixLength)
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                                 range: valueRange)
        }
        offset = NSMaxRange(range)
    }
}

@MainActor
private final class LogDocumentView: NSTextView, NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return true }
        NSWorkspace.shared.open(url)
        return true
    }
}

func stripTerminalEscapes(_ text: String) -> String {
    let pattern = #"\x1B\[[0-?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
}

@MainActor
func addLogLinks(to text: NSMutableAttributedString, range: NSRange? = nil) {
    for link in detectedLogLinks(in: text.string, range: range) {
        text.addAttributes([.link: link.url, .cursor: NSCursor.pointingHand], range: link.range)
    }
}

func detectedLogLinks(in text: String, range: NSRange? = nil) -> [(url: URL, range: NSRange)] {
    guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>\"\x1B]+"#, options: .caseInsensitive) else { return [] }
    let string = text as NSString
    var links: [(url: URL, range: NSRange)] = []
    for match in regex.matches(in: text, range: range ?? NSRange(location: 0, length: string.length)) {
        var value = string.substring(with: match.range)
        while let last = value.last {
            if ".,;:!?".contains(last) { value.removeLast(); continue }
            let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
            if let open = pairs[last], value.filter({ $0 == last }).count > value.filter({ $0 == open }).count {
                value.removeLast(); continue
            }
            break
        }
        guard let url = URL(string: value), url.host != nil else { continue }
        links.append((url, NSRange(location: match.range.location, length: value.utf16.count)))
    }
    return links
}

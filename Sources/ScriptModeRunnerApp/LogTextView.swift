import AppKit
import SwiftUI

struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        makeLogScrollView()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        updateLogScrollView(scroll, text: text)
    }
}

@MainActor
func makeLogScrollView() -> NSScrollView {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false

    let contentSize = scroll.contentSize
    let view = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
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
func updateLogScrollView(_ scroll: NSScrollView, text: String) {
    guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
    let wasAtBottom = view.visibleRect.maxY >= view.bounds.maxY - 24
    view.textStorage?.setAttributedString(NSAttributedString(
        string: text,
        attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
    ))
    if wasAtBottom { view.scrollToEndOfDocument(nil) }
}

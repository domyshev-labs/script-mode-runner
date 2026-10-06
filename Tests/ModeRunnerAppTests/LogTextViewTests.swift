import AppKit
import Testing
@testable import ModeRunnerApp

@MainActor
@Test func logTextViewHasVisibleDocumentAndRendersText() throws {
    let scroll = makeLogScrollView()
    let expected = "yarn run v1.22.22\nApplication #1\nAddress: http://127.0.0.1:3010\n"
    updateLogScrollView(scroll, text: expected)
    scroll.layoutSubtreeIfNeeded()

    let view = try #require(scroll.documentView as? NSTextView)
    #expect(view.frame.width > 0)
    #expect(view.frame.height > 0)
    #expect(view.string == expected)
    #expect(view.textStorage?.length == expected.utf16.count)
    #expect(view.textColor == .textColor)
    let layoutManager = try #require(view.layoutManager)
    let textContainer = try #require(view.textContainer)
    layoutManager.ensureLayout(for: textContainer)
    #expect(layoutManager.numberOfGlyphs > 0)
    #expect(layoutManager.usedRect(for: textContainer).height > 0)
}

@MainActor
@Test func logLinksHandleTerminalColorsAndPunctuation() throws {
    let scroll = makeLogScrollView()
    updateLogScrollView(scroll, text: "\u{001B}[32mVisit (http://localhost:3000/path?q=1).\u{001B}[0m\nhttps://example.com/a_(b)!")
    let view = try #require(scroll.documentView as? NSTextView)
    #expect(!view.string.contains("\u{001B}"))
    let storage = try #require(view.textStorage)
    let first = (view.string as NSString).range(of: "http://")
    #expect((storage.attribute(.link, at: first.location, effectiveRange: nil) as? URL)?.absoluteString == "http://localhost:3000/path?q=1")
    let second = (view.string as NSString).range(of: "https://")
    #expect((storage.attribute(.link, at: second.location, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com/a_(b)")
    #expect(view.isEditable == false)
    #expect(view.isSelectable)
}

@MainActor
@Test func logLinkUpdatesAfterSplitOutput() throws {
    let scroll = makeLogScrollView()
    updateLogScrollView(scroll, text: "http://localhost:")
    updateLogScrollView(scroll, text: "http://localhost:3000")
    let view = try #require(scroll.documentView as? NSTextView)
    #expect((view.textStorage?.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.absoluteString == "http://localhost:3000")
}

@MainActor
@Test func appendingOutputPreservesExistingLinksAndUpdatesTail() throws {
    let scroll = makeLogScrollView()
    updateLogScrollView(scroll, text: "http://localhost:3000\nLog\nhttp://example")
    updateLogScrollView(scroll, text: "http://localhost:3000\nLog\nhttp://example.com/path\n")
    let view = try #require(scroll.documentView as? NSTextView)
    let first = view.textStorage?.attribute(.link, at: 0, effectiveRange: nil) as? URL
    let secondRange = (view.string as NSString).range(of: "http://example")
    let second = view.textStorage?.attribute(.link, at: secondRange.location, effectiveRange: nil) as? URL
    #expect(first?.absoluteString == "http://localhost:3000")
    #expect(second?.absoluteString == "http://example.com/path")
}

@MainActor
@Test func linkFormattingHandlesMaximumSizeLog() throws {
    let padding = String(repeating: "A log line without links.\n", count: 200_000)
    let text = NSMutableAttributedString(string: padding + "http://localhost:3000/ready\n")
    let start = ContinuousClock.now
    addLogLinks(to: text)
    let elapsed = start.duration(to: .now)
    let location = (text.string as NSString).range(of: "http://localhost").location
    #expect((text.attribute(.link, at: location, effectiveRange: nil) as? URL)?.absoluteString == "http://localhost:3000/ready")
    print("Formatted a 5 MB log in \(elapsed)")
}

@MainActor
@Test func linkCursorTracksURLsWithoutAffectingPlainText() throws {
    let scroll = makeLogScrollView()
    updateLogScrollView(scroll, text: "Visit http://localhost:")
    updateLogScrollView(scroll, text: "Visit http://localhost:3000\nPlain text")
    let view = try #require(scroll.documentView as? NSTextView)
    let storage = try #require(view.textStorage)
    let urlRange = (view.string as NSString).range(of: "http://")
    #expect(storage.attribute(.cursor, at: urlRange.location, effectiveRange: nil) as? NSCursor == .pointingHand)
    #expect(storage.attribute(.cursor, at: 0, effectiveRange: nil) == nil)
    let plainRange = (view.string as NSString).range(of: "Plain text")
    #expect(storage.attribute(.cursor, at: plainRange.location, effectiveRange: nil) == nil)
    updateLogScrollView(scroll, text: "No links")
    #expect(view.textStorage?.attribute(.cursor, at: 0, effectiveRange: nil) == nil)
}

@Test func latestLinkIsShownOnlyForRunningLogsAndTracksNewOutput() {
    var log = ScriptLog(status: .running(pid: 123))
    log.buffer.append(Data("\u{001B}[32mhttp://localhost:3000\u{001B}[0m\nOpen (https://example.com/a_(b)).\n".utf8))
    #expect(log.latestRunningLink?.absoluteString == "https://example.com/a_(b)")
    log.buffer.append(Data("Next: http://localhost:".utf8))
    log.buffer.append(Data("3010/ready\nMore output without URLs\n".utf8))
    #expect(log.latestRunningLink?.absoluteString == "http://localhost:3010/ready")
    log.status = .stopping
    #expect(log.latestRunningLink == nil)
    log.status = .exited(code: 0)
    #expect(log.latestRunningLink == nil)
    log.status = .running(pid: 456)
    #expect(log.latestRunningLink?.absoluteString == "http://localhost:3010/ready")
    log.buffer.removeAll()
    #expect(log.latestRunningLink == nil)
}

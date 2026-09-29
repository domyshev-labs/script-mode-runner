import AppKit
import Testing
@testable import ScriptModeRunnerApp

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

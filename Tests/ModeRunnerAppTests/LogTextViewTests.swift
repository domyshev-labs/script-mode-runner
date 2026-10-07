import AppKit
import ModeRunnerCore
import Testing
@testable import ModeRunnerApp

@Test func processTabsNormalizeOnlyTrailingPortAnnotations() {
    #expect(processTabTitle("yarn mock · :3015") == "yarn mock : 3015")
    #expect(processTabTitle("yarn mock :3015") == "yarn mock : 3015")
    #expect(processTabTitle("yarn mock : 3015") == "yarn mock : 3015")
    #expect(processTabTitle("yarn dev:mock · :3015") == "yarn dev:mock : 3015")
    #expect(processTabTitle("yarn dev:mock") == "yarn dev:mock")
}
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

@Test func adoptedProcessLinkUsesConfiguredPortAndYieldsToCapturedOutput() {
    let script = RunnerScript(id: "mock", title: "Mock · :3015", command: "yarn mock")
    var log = ScriptLog(status: .running(pid: 123), configuredRunningLink: configuredLocalURL(for: script))
    #expect(log.latestRunningLink?.absoluteString == "http://localhost:3015/")
    log.buffer.append(Data("Listening at https://localhost:3015/api\n".utf8))
    #expect(log.latestRunningLink?.absoluteString == "https://localhost:3015/api")
    log.buffer.removeAll()
    #expect(log.latestRunningLink?.absoluteString == "http://localhost:3015/")
    log.status = .unobservedExit
    #expect(log.latestRunningLink == nil)
    #expect(configuredLocalURL(for: RunnerScript(id: "none", title: "Task 3015", command: "sleep 30")) == nil)
    #expect(configuredLocalURL(for: RunnerScript(id: "invalid", title: "Mock · :65536", command: "yarn mock")) == nil)
    #expect(configuredLocalURL(for: RunnerScript(id: "flag", title: "Dev", command: "vite --port=3020"))?.port == 3020)
    #expect(configuredLocalURL(for: RunnerScript(id: "env", title: "Dev", command: "yarn dev", environment: ["PORT": "3025"]))?.port == 3025)
}

@Test func adoptedProcessMessageIncludesLocationCommandPortAndTimestamp() {
    let script = RunnerScript(id: "mock", title: "Mock · :3015", command: "yarn mock")
    let message = existingProcessMessage(script: script, location: "/Volumes/code/event-search-ui",
                                         detectedAt: Date(timeIntervalSince1970: 0),
                                         timeZone: TimeZone(secondsFromGMT: 7200)!)
    let lines = message.components(separatedBy: "\n")
    #expect(lines[0] == "Detected an existing process:")
    #expect(lines[1] == "Location: /Volumes/code/event-search-ui")
    #expect(lines[2] == "Configuration match: yarn mock")
    #expect(lines[3] == "Port: 3015")
    #expect(lines[4] == "Detected at: 1970-01-01 02:00:00 +02:00")
    #expect(lines[5] == "Live output and earlier logs are unavailable because this instance does not own its stdout/stderr.")
}

@MainActor
@Test func detectionHeadingIsBoldAndSurvivesLogUpdates() throws {
    let scroll = makeLogScrollView()
    let text = "Detected an existing process:\nLocation: /Volumes/code/event-search-ui\nConfiguration match: yarn dev:mock\nPort: 3015\n"
    updateLogScrollView(scroll, text: text, boldFirstLine: true)
    let storage = try #require((scroll.documentView as? NSTextView)?.textStorage)
    let headingFont = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(NSFontManager.shared.traits(of: headingFont).contains(.boldFontMask))
    let bodyOffset = (text as NSString).range(of: "Location:").location
    let bodyFont = try #require(storage.attribute(.font, at: bodyOffset, effectiveRange: nil) as? NSFont)
    #expect(!NSFontManager.shared.traits(of: bodyFont).contains(.boldFontMask))
    for value in ["yarn dev:mock", "3015"] {
        let offset = (text as NSString).range(of: value).location
        let font = try #require(storage.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }
    for label in ["Configuration match:", "Port:"] {
        let offset = (text as NSString).range(of: label).location
        let font = try #require(storage.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
        #expect(!NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }
    updateLogScrollView(scroll, text: text + "Detected at: 2026-10-06 15:34:58 +02:00\n", boldFirstLine: true)
    let updatedFont = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(NSFontManager.shared.traits(of: updatedFont).contains(.boldFontMask))
    updateLogScrollView(scroll, text: "Normal output\n")
    let normalFont = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(!NSFontManager.shared.traits(of: normalFont).contains(.boldFontMask))
}

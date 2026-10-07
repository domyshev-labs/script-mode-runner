import AppKit
import Testing
@testable import ModeRunnerApp

@MainActor
@Test func closingInformationWindowsRestoresPopoverBehaviorOnlyAfterTheLastClose() async throws {
    let popover = NSPopover()
    popover.behavior = .transient
    let windows = RunnerInformationWindows()
    windows.mainPopover = popover
    let about = windows.makeAboutWindow()
    let documentation = try windows.makeDocumentationWindow()
    windows.beginPresentation(about)
    windows.beginPresentation(documentation)
    #expect(popover.behavior == .applicationDefined)
    about.close()
    try await Task.sleep(for: .milliseconds(30))
    #expect(popover.behavior == .applicationDefined)
    documentation.close()
    // The popover stays protected throughout the closing event.
    #expect(popover.behavior == .applicationDefined)
    try await Task.sleep(for: .milliseconds(30))
    #expect(popover.behavior == .transient)
}

@MainActor
@Test func documentationCentersOnScreenInsteadOfTheOffCenterPopover() throws {
    let screen = try #require(NSScreen.main)
    let visible = screen.visibleFrame
    let parent = NSWindow(contentRect: NSRect(x: visible.midX, y: visible.midY,
                                              width: 200, height: 100),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    parent.isReleasedWhenClosed = false
    parent.level = .popUpMenu
    defer { parent.close() }
    let windows = RunnerInformationWindows()
    let documentation = try windows.makeDocumentationWindow()
    defer { documentation.close() }
    windows.prepareForPresentation(documentation, relativeTo: parent, centeredOnScreen: true)
    #expect(abs(documentation.frame.midX - visible.midX) < 1)
    #expect(abs(documentation.frame.midY - visible.midY) < 1)
    #expect(abs(documentation.frame.midX - parent.frame.midX) > 1)
    #expect(documentation.level.rawValue > parent.level.rawValue)
}

@MainActor
@Test func informationWindowsOpenAboveThePopoverOnItsScreen() throws {
    let screen = try #require(NSScreen.main)
    let parent = NSWindow(contentRect: screen.visibleFrame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    parent.isReleasedWhenClosed = false
    parent.level = .popUpMenu
    defer { parent.close() }
    let windows = RunnerInformationWindows()
    for window in [windows.makeAboutWindow(), try windows.makeDocumentationWindow()] {
        defer { window.close() }
        windows.prepareForPresentation(window, relativeTo: parent)
        #expect(window.level.rawValue > parent.level.rawValue)
        #expect(abs(window.frame.midX - parent.frame.midX) < 1)
        #expect(abs(window.frame.midY - parent.frame.midY) < 1)
        #expect(window.hidesOnDeactivate)
        windows.prepareForPresentation(window, relativeTo: nil)
        #expect(window.level == .normal)
    }
}

@MainActor
@Test func aboutWindowKeepsItsFullContentSizeAfterHostingLayout() throws {
    let windows = RunnerInformationWindows()
    let window = windows.makeAboutWindow()
    defer { window.close() }
    let content = try #require(window.contentView)
    content.layoutSubtreeIfNeeded()
    #expect(content.bounds.size == NSSize(width: 480, height: 320))
    #expect(!window.styleMask.contains(.resizable))
    #expect(window.contentMinSize == window.contentMaxSize)
}

@MainActor
@Test func documentationWindowStartsReadableAndSupportsResizing() throws {
    let windows = RunnerInformationWindows()
    let window = try windows.makeDocumentationWindow()
    defer { window.close() }
    let content = try #require(window.contentView)
    content.layoutSubtreeIfNeeded()
    #expect(content.bounds.size == NSSize(width: 720, height: 620))
    #expect(window.styleMask.contains(.resizable))
    window.setContentSize(NSSize(width: 860, height: 700))
    content.layoutSubtreeIfNeeded()
    #expect(content.bounds.size == NSSize(width: 860, height: 700))
    #expect(window.contentMinSize == NSSize(width: 520, height: 400))
}

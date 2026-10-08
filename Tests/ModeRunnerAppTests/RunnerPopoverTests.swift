import AppKit
import SwiftUI
import Testing
@testable import ModeRunnerApp

@MainActor
@Test func popoverKeepsRightInsetOnDisplaysWithDifferentOrigins() {
    for screenX: CGFloat in [0, -1440, 1920] {
        let visibleFrame = NSRect(x: screenX, y: 30, width: 1440, height: 870)
        let frame = NSRect(x: visibleFrame.maxX - 710, y: 200, width: 710, height: 510)
        let origin = RunnerPopover.insetOrigin(for: frame, visibleFrame: visibleFrame)
        #expect(visibleFrame.maxX - (origin.x + frame.width) == 20)
        #expect(origin.y == frame.minY)

        let centered = NSRect(x: screenX + 200, y: 200, width: 710, height: 510)
        #expect(RunnerPopover.insetOrigin(for: centered, visibleFrame: visibleFrame) == centered.origin)
    }
}

@MainActor
@Test func hiddenPopoverRebuildsAfterDisplayConfigurationChanges() throws {
    let runner = RunnerPopover()
    let original = runner.prepare { Text("Content") }
    let originalController = try #require(original.contentViewController)
    #expect(!original.isShown)

    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification,
                                    object: NSApplication.shared)
    let replacement = runner.prepare { Text("Content") }
    #expect(replacement !== original)
    #expect(replacement.contentViewController !== originalController)
    #expect(replacement.contentSize == RunnerPopover.contentSize)
    #expect(replacement.contentViewController?.view.frame.size == RunnerPopover.contentSize)
    #expect(replacement.behavior == .transient)
}

@MainActor
@Test func unchangedDisplaysPreservePopoverAndHostedView() {
    let runner = RunnerPopover()
    let original = runner.prepare { Text("Content") }
    let next = runner.prepare { Text("Unused") }
    #expect(next === original)
}

@MainActor
@Test func displayChangePreservesInformationWindowPopoverProtection() {
    let runner = RunnerPopover()
    let original = runner.prepare { Text("Content") }
    original.behavior = .applicationDefined
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification,
                                    object: NSApplication.shared)
    let replacement = runner.prepare { Text("Content") }
    #expect(replacement.behavior == .applicationDefined)
}

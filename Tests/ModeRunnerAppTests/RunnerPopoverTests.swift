import AppKit
import SwiftUI
import Testing
@testable import ModeRunnerApp

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

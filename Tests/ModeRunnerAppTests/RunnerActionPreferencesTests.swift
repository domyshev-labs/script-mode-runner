import AppKit
import Foundation
import Testing
@testable import ModeRunnerApp

@MainActor
@Test func rememberedExitChoicePersistsAndAppliesToBothActions() throws {
    let suite = "RunnerActionPreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = RunnerActionPreferences(defaults: defaults)
    #expect(preferences.showConfirmation)
    #expect(!preferences.savedTerminateProcesses)
    var performed: [(RunnerAction, Bool)] = []
    preferences.request(.restart) { performed.append(($0, $1)) }
    #expect(preferences.pendingAction == .restart)
    preferences.terminateProcesses = true
    preferences.rememberChoice = true
    preferences.confirm(.restart)
    #expect(performed.isEmpty)
    preferences.finishConfirmation { performed.append(($0, $1)) }
    #expect(performed.count == 1)
    #expect(performed[0].0 == .restart && performed[0].1)
    let restored = RunnerActionPreferences(defaults: defaults)
    #expect(!restored.showConfirmation)
    #expect(restored.savedTerminateProcesses)
    for action in [RunnerAction.poweroff, .restart] {
        restored.request(action) { performed.append(($0, $1)) }
        #expect(restored.pendingAction == nil)
        #expect(performed.last?.0 == action)
        #expect(performed.last?.1 == true)
    }
    restored.showConfirmation = true
    restored.savedTerminateProcesses = false
    restored.request(.poweroff) { performed.append(($0, $1)) }
    #expect(restored.pendingAction == .poweroff)
    #expect(!restored.terminateProcesses)
    #expect(performed.count == 3)
}

@MainActor
@Test func cancellingDoesNotRememberExitChoice() throws {
    let suite = "RunnerActionPreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = RunnerActionPreferences(defaults: defaults)
    var performed = false
    preferences.request(.poweroff) { _, _ in performed = true }
    preferences.terminateProcesses = true
    preferences.rememberChoice = true
    preferences.pendingAction = nil
    preferences.finishConfirmation { _, _ in performed = true }
    #expect(!performed)
    let restored = RunnerActionPreferences(defaults: defaults)
    #expect(restored.showConfirmation)
    #expect(!restored.savedTerminateProcesses)
    preferences.request(.restart) { _, _ in performed = true }
    #expect(!preferences.rememberChoice)
    #expect(!preferences.terminateProcesses)
    preferences.confirm(.restart)
    preferences.finishConfirmation { _, _ in performed = true }
    #expect(performed)
    #expect(preferences.showConfirmation)
}

@MainActor
@Test func actionsMenuPlacesSettingsBelowReloadAndAboveSeparator() throws {
    let coordinator = RunnerActionsMenu.Coordinator()
    let menu = coordinator.makeMenu(appearance: try #require(NSAppearance(named: .aqua)))
    #expect(menu.items[0].title == "Reload configuration")
    #expect(menu.items[1].title == "Settings...")
    #expect(menu.items[2].isSeparatorItem)
    #expect(menu.items.suffix(2).map(\.title) == [RunnerAction.restart.title, RunnerAction.poweroff.title])
}

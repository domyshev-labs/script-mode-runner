import Combine
import Foundation
import Testing
import ScriptModeRunnerCore
@testable import ScriptModeRunnerApp

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "AppStateTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for state"])
}

@MainActor
@Test func runningButtonTurnsGreenAndClearsAfterStop() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "".write(to: dir.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
    let yaml = """
    tabs:
      - id: test
        title: Test
        buttons:
          - id: server
            title: Server
            on_deactivate:
              sigkill: true
            scripts:
              - id: server
                title: Server
                executable: /bin/sleep
                arguments: [30]
          - id: scripts
            title: Scripts
            environment:
              ZDOTDIR: \(dir.path)
            runner: [/bin/echo]
            source:
              type: package_scripts
    """
    let config = dir.appending(path: "config.yaml")
    try yaml.write(to: config, atomically: true, encoding: .utf8)
    try #"{"scripts":{"build":"echo build"}}"#.write(to: dir.appending(path: "package.json"), atomically: true, encoding: .utf8)
    let state = AppState(configURL: config)
    defer { Task { await state.shutdown() } }
    let tab = try #require(state.selectedTab)
    let server = tab.buttons[0]
    state.toggle(server, in: tab)
    try await waitUntil { state.activity(server, in: tab) == .running }
    let firstID = try #require(state.runs.first?.id)
    state.launch(MenuItem(id: "build", title: "build", arguments: ["build"]), button: tab.buttons[1], tab: tab)
    try await waitUntil { state.runs.count == 2 && state.logs[state.runs[1].id]?.status == .exited(code: 0) }
    #expect(state.activity(server, in: tab) == .running)
    #expect(state.visibleScripts.count == 2)
    state.reload()
    #expect(state.visibleScripts.count == 2)
    #expect(state.activity(server, in: tab) == .running)
    await state.stop(firstID)
    try await waitUntil { state.logs[firstID]?.status?.isRunning == false }
    #expect(state.activity(server, in: tab) == .idle)
    #expect(state.activeModes[tab.id] == nil)
    state.close(firstID)
    #expect(state.runs.count == 1)
    await state.shutdown()
}

@MainActor
@Test func modeTransitionMovesLoaderAndLocksButtonsUntilCompletion() async throws {
    let config = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: config) }
    try """
    tabs:
      - id: test
        title: Test
        buttons:
          - id: primary
            title: Primary
            on_deactivate: {sigint: true, sigkill: true, timeout: 0.2s}
            scripts:
              - {id: server, title: Server, executable: /bin/sleep, arguments: [30]}
          - id: secondary
            title: Secondary
            on_deactivate: {sigkill: true}
            scripts:
              - {id: server, title: Server, executable: /bin/sleep, arguments: [30]}
    """.write(to: config, atomically: true, encoding: .utf8)
    let state = AppState(configURL: config)
    defer { Task { await state.shutdown() } }
    let tab = try #require(state.selectedTab)
    let primary = tab.buttons[0]
    let secondary = tab.buttons[1]
    state.toggle(primary, in: tab)
    #expect(state.activity(primary, in: tab) == .transitioning)
    #expect(state.busyTabs.contains(tab.id))
    try await waitUntil { state.activity(primary, in: tab) == .running && state.busyTabs.isEmpty }

    var phases: [Set<String>] = []
    var phasesWereBusy = true
    let subscription = state.$transitioningModes.dropFirst().sink { modes in
        if let phase = modes[tab.id] {
            phases.append(phase)
            phasesWereBusy = phasesWereBusy && state.busyTabs.contains(tab.id)
        }
    }
    defer { subscription.cancel() }
    state.toggle(secondary, in: tab)
    #expect(state.activity(primary, in: tab) == .transitioning)
    #expect(state.activity(secondary, in: tab) == .idle)
    #expect(state.busyTabs.contains(tab.id))
    state.toggle(primary, in: tab)
    state.toggle(secondary, in: tab)
    try await waitUntil { state.activity(secondary, in: tab) == .running && state.busyTabs.isEmpty }
    #expect(phases == [[primary.id], [secondary.id]])
    #expect(phasesWereBusy)
    #expect(state.transitioningModes.isEmpty)
    #expect(state.activity(primary, in: tab) == .idle)
    #expect(state.runs.count == 2)

    state.toggle(secondary, in: tab)
    #expect(state.activity(secondary, in: tab) == .transitioning)
    #expect(state.busyTabs.contains(tab.id))
    try await waitUntil { state.activity(secondary, in: tab) == .idle && state.busyTabs.isEmpty }
    #expect(state.transitioningModes.isEmpty)
    #expect(state.logs.values.allSatisfy { $0.status?.isRunning == false })
    await state.shutdown()
}

@MainActor
@Test func modeSelectionSurvivesStopAndRestartReplacesAllProcesses() async throws {
    let config = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: config) }
    try """
    tabs:
      - id: test
        title: Test
        buttons:
          - id: primary
            title: Primary
            on_deactivate: {sigkill: true}
            scripts:
              - {id: one, title: One, executable: /bin/sleep, arguments: [30]}
              - {id: two, title: Two, executable: /bin/sleep, arguments: [30]}
          - id: secondary
            title: Secondary
            on_deactivate: {sigkill: true}
            scripts:
              - {id: one, title: One, executable: /bin/sleep, arguments: [30]}
    """.write(to: config, atomically: true, encoding: .utf8)
    let state = AppState(configURL: config)
    defer { Task { await state.shutdown() } }
    let tab = try #require(state.selectedTab)
    let primary = tab.buttons[0]
    let secondary = tab.buttons[1]
    #expect(state.selectedMode(in: tab)?.id == primary.id)
    state.startMode(primary, in: tab)
    try await waitUntil { state.activity(primary, in: tab) == .running && state.busyTabs.isEmpty }
    let original = state.runs.map(\.id)
    state.startMode(primary, in: tab)
    #expect(state.runs.count == 2)
    state.restartMode(primary, in: tab)
    try await waitUntil { state.runs.count == 4 && state.activity(primary, in: tab) == .running && state.busyTabs.isEmpty }
    #expect(original.allSatisfy { state.logs[$0]?.status?.isRunning == false })
    state.startMode(secondary, in: tab)
    try await waitUntil { state.runningMode(in: tab)?.id == secondary.id && state.busyTabs.isEmpty }
    #expect(state.selectedMode(in: tab)?.id == secondary.id)
    #expect(state.runs.filter { state.logs[$0.id]?.status?.isRunning == true }.count == 1)
    state.stopMode(secondary, in: tab)
    try await waitUntil { state.runningMode(in: tab) == nil && state.busyTabs.isEmpty }
    #expect(state.selectedMode(in: tab)?.id == secondary.id)
    state.startMode(secondary, in: tab)
    try await waitUntil { state.runningMode(in: tab)?.id == secondary.id && state.busyTabs.isEmpty }
    await state.shutdown()
}

@MainActor
@Test func failedModeIsRedAndCanBeRestarted() async throws {
    let config = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: config) }
    let yaml = """
    tabs:
      - id: test
        title: Test
        buttons:
          - id: fail
            title: Fail
            scripts:
              - id: fail
                title: Fail
                executable: /bin/sh
                arguments: [-c, 'exit 7']
    """
    try yaml.write(to: config, atomically: true, encoding: .utf8)
    let state = AppState(configURL: config)
    defer { Task { await state.shutdown() } }
    let tab = try #require(state.selectedTab)
    let button = tab.buttons[0]
    state.toggle(button, in: tab)
    try await waitUntil { state.activity(button, in: tab) == .failed && !state.busyTabs.contains(tab.id) }
    #expect(state.transitioningModes.isEmpty)
    state.toggle(button, in: tab)
    try await waitUntil { state.runs.count == 2 && state.logs[state.runs[1].id]?.status == .exited(code: 7) }
    #expect(state.runs[0].id != state.runs[1].id)
    #expect(state.visibleScripts.count == 1)
    #expect(state.visibleScripts.first?.id == state.runs.last?.id)
    await state.shutdown()
}

@MainActor
@Test func seedRunsAreSerializedAndCompletedHistoryIsBounded() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "".write(to: dir.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
    try "[]".write(to: dir.appending(path: "seeds.json"), atomically: true, encoding: .utf8)
    let yaml = """
    tabs:
      - id: test
        title: Test
        buttons:
          - id: seeds
            title: Seeds
            runner: [/bin/sleep]
            environment:
              ZDOTDIR: \(dir.path)
            source: {type: json_file, path: seeds.json}
            on_deactivate: {sigkill: true}
    """
    let config = dir.appending(path: "config.yaml")
    try yaml.write(to: config, atomically: true, encoding: .utf8)
    let state = AppState(configURL: config)
    defer { Task { await state.shutdown() } }
    let tab = try #require(state.selectedTab)
    let button = tab.buttons[0]
    let slow = MenuItem(id: "slow", title: "Slow", arguments: ["30"])
    state.launch(slow, button: button, tab: tab)
    state.launch(slow, button: button, tab: tab)
    #expect(state.runs.count == 1)
    try await waitUntil { state.activity(button, in: tab) == .running }
    let id = try #require(state.selectedOutputID)
    state.close(id)
    #expect(state.runs.count == 1)
    await state.stop(id)
    try await waitUntil { !state.seedIsRunning(button) }
    let fast = MenuItem(id: "fast", title: "Fast", arguments: ["0"])
    for _ in 0..<23 {
        state.launch(fast, button: button, tab: tab)
        try await waitUntil { !state.seedIsRunning(button) }
    }
    #expect(state.runs.count <= 21)
    #expect(state.logs.count == state.runs.count)
    await state.shutdown()
}

@MainActor
@Test func groupFailureIsNotHiddenByAnotherSuccessfulCommand() async throws {
    let config = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: config) }
    let yaml = """
    tabs:
      - id: group
        title: Group
        buttons:
          - id: pair
            title: Pair
            scripts:
              - id: fail
                title: Fail
                executable: /bin/sh
                arguments: [-c, 'exit 7']
              - id: success
                title: Success
                executable: /bin/sleep
                arguments: [0]
    """
    try yaml.write(to: config, atomically: true, encoding: .utf8)
    let state = AppState(configURL: config)
    defer { Task { await state.shutdown() } }
    let tab = try #require(state.selectedTab)
    let button = tab.buttons[0]
    state.toggle(button, in: tab)
    try await waitUntil { state.runs.count == 2 && state.logs.values.allSatisfy { $0.status?.isRunning == false } }
    #expect(state.activity(button, in: tab) == .failed)
    await state.shutdown()
}

@MainActor
@Test func switchingModesScopesLogsAndRestartShowsOnlyLatestConfiguredScripts() async throws {
    let config = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: config) }
    try """
    tabs:
      - id: test
        title: Test
        buttons:
          - id: lab
            title: Lab
            on_deactivate: {sigkill: true}
            scripts:
              - {id: dev, title: Dev, executable: /bin/sleep, arguments: [30]}
          - id: mock
            title: Mock
            on_deactivate: {sigkill: true}
            scripts:
              - {id: dev, title: Dev, executable: /bin/sleep, arguments: [30]}
              - {id: backend, title: Backend, executable: /bin/sleep, arguments: [30]}
    """.write(to: config, atomically: true, encoding: .utf8)
    let state = AppState(configURL: config)
    defer { Task { await state.shutdown() } }
    let tab = try #require(state.selectedTab)
    state.toggle(tab.buttons[0], in: tab)
    try await waitUntil { state.activity(tab.buttons[0], in: tab) == .running && state.busyTabs.isEmpty }
    let firstLabID = try #require(state.selectedOutputID)
    state.toggle(tab.buttons[1], in: tab)
    try await waitUntil { state.activity(tab.buttons[1], in: tab) == .running && state.busyTabs.isEmpty }
    #expect(state.visibleScripts.count == 2)
    #expect(state.visibleScripts.allSatisfy { $0.buttonID == "mock" })
    #expect(state.selectedOutputID == state.visibleScripts.first?.id)
    #expect(state.selectedRun?.script.id == "dev")
    state.toggle(tab.buttons[0], in: tab)
    try await waitUntil { state.activity(tab.buttons[0], in: tab) == .running && state.busyTabs.isEmpty }
    #expect(state.visibleScripts.count == 1)
    #expect(state.visibleScripts.first?.buttonID == "lab")
    #expect(state.visibleScripts.first?.id != firstLabID)
    state.toggle(tab.buttons[0], in: tab)
    try await waitUntil { state.activity(tab.buttons[0], in: tab) == .idle && state.busyTabs.isEmpty }
    #expect(state.visibleScripts.count == 1)
    state.reload()
    #expect(state.visibleScripts.count == 1)
    await state.shutdown()
}

@MainActor
@Test func reloadSelectedRestartsOnlySelectedProcessAndRejectsRepeatedClicks() async throws {
    let config = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: config) }
    try """
    tabs:
      - id: test
        title: Test
        buttons:
          - id: pair
            title: Pair
            on_deactivate: {sigkill: true}
            scripts:
              - {id: frontend, title: Frontend, executable: /bin/sh, arguments: [-c, 'echo ready; exec sleep 30']}
              - {id: backend, title: Backend, executable: /bin/sleep, arguments: [30]}
    """.write(to: config, atomically: true, encoding: .utf8)
    let state = AppState(configURL: config)
    defer { Task { await state.shutdown() } }
    let tab = try #require(state.selectedTab)
    let button = tab.buttons[0]
    state.toggle(button, in: tab)
    try await waitUntil { state.activity(button, in: tab) == .running && state.busyTabs.isEmpty }
    let frontend = try #require(state.runs.first)
    let backend = try #require(state.runs.last)
    let frontendStatus = state.logs[frontend.id]?.status
    let backendStatus = state.logs[backend.id]?.status
    state.selectedOutputID = frontend.id
    state.reloadSelected()
    state.reloadSelected()
    try await waitUntil {
        state.restartingRuns.isEmpty && state.logs[frontend.id]?.status != frontendStatus &&
        state.activity(button, in: tab) == .running && state.logs[frontend.id]?.buffer.string == "ready\n"
    }
    #expect(state.runs.count == 2)
    #expect(state.visibleScripts.count == 2)
    #expect(state.logs[backend.id]?.status == backendStatus)
    #expect(state.selectedOutputID == frontend.id)
    #expect(state.activeModes[tab.id] == button.id)
    #expect(state.runs.first?.requestedStop == false)
    await state.shutdown()
}

@MainActor
@Test func reloadSelectedPreservesMenuCommandAndContext() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "".write(to: dir.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
    try "[]".write(to: dir.appending(path: "seeds.json"), atomically: true, encoding: .utf8)
    let config = dir.appending(path: "config.yaml")
    try """
    tabs:
      - id: test
        title: Test
        buttons:
          - id: seeds
            title: Seeds
            runner: [/bin/sleep]
            environment:
              ZDOTDIR: \(dir.path)
            source: {type: json_file, path: seeds.json}
            on_deactivate: {sigkill: true}
    """.write(to: config, atomically: true, encoding: .utf8)
    let state = AppState(configURL: config)
    defer { Task { await state.shutdown() } }
    let tab = try #require(state.selectedTab)
    let button = tab.buttons[0]
    state.launch(MenuItem(id: "slow", title: "Slow", arguments: ["30"]), button: button, tab: tab)
    try await waitUntil { state.activity(button, in: tab) == .running }
    let original = try #require(state.selectedRun)
    let status = state.logs[original.id]?.status
    state.reloadSelected()
    try await waitUntil {
        state.restartingRuns.isEmpty && state.logs[original.id]?.status != status &&
        state.activity(button, in: tab) == .running
    }
    #expect(state.runs.count == 1)
    #expect(state.selectedRun?.script == original.script)
    #expect(state.selectedRun?.contextModeID == original.contextModeID)
    #expect(state.seedIsRunning(button))
    await state.shutdown()
}

@MainActor
@Test func selectingModeDoesNotStartStopOrRestartProcesses() async throws {
    let config = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: config) }
    try """
    tabs:
      - id: test
        title: Test
        buttons:
          - id: primary
            title: Primary
            on_deactivate: {sigkill: true}
            scripts:
              - {id: server, title: Server, executable: /bin/sleep, arguments: [30]}
          - id: secondary
            title: Secondary
            on_deactivate: {sigkill: true}
            scripts:
              - {id: server, title: Server, executable: /bin/sleep, arguments: [30]}
    """.write(to: config, atomically: true, encoding: .utf8)
    let state = AppState(configURL: config)
    defer { Task { await state.shutdown() } }
    let tab = try #require(state.selectedTab)
    let primary = tab.buttons[0]
    let secondary = tab.buttons[1]
    state.selectMode(secondary, in: tab)
    #expect(state.selectedMode(in: tab)?.id == secondary.id)
    #expect(state.runs.isEmpty)
    #expect(state.busyTabs.isEmpty)
    state.startMode(primary, in: tab)
    try await waitUntil { state.runningMode(in: tab)?.id == primary.id && state.busyTabs.isEmpty }
    let run = try #require(state.runs.first)
    let originalStatus = state.logs[run.id]?.status
    state.selectMode(secondary, in: tab)
    #expect(state.runningMode(in: tab)?.id == primary.id)
    #expect(state.activeModes[tab.id] == primary.id)
    #expect(state.logs[run.id]?.status == originalStatus)
    #expect(state.runs.count == 1)
    #expect(state.visibleScripts.isEmpty)
    #expect(state.selectedOutputID == nil)
    state.selectMode(primary, in: tab)
    #expect(state.selectedOutputID == run.id)
    #expect(state.logs[run.id]?.status == originalStatus)
    state.selectMode(secondary, in: tab)
    state.stopMode(primary, in: tab)
    try await waitUntil { state.runningMode(in: tab) == nil && state.busyTabs.isEmpty }
    #expect(state.selectedMode(in: tab)?.id == secondary.id)
    await state.shutdown()
}

@MainActor
@Test func projectOrderPersistsAcrossRelaunchAndConfigurationChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appending(path: "config.yaml")
    let suite = "ScriptModeRunnerTests/" + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    func writeTabs(_ ids: [String], to url: URL) throws {
        let tabs = ids.map { "  - {id: \($0), title: \($0), buttons: []}" }.joined(separator: "\n")
        try ("tabs:\n" + tabs).write(to: url, atomically: true, encoding: .utf8)
    }
    try writeTabs(["one", "two", "three"], to: config)
    let state = AppState(configURL: config, preferences: preferences)
    state.selectedTabID = "two"
    #expect(state.moveTab("one", to: "three"))
    #expect(state.configuration?.tabs.map(\.id) == ["two", "three", "one"])
    #expect(state.selectedTabID == "two")
    #expect(!state.moveTab("missing", to: "two"))
    #expect(!state.moveTab("two", to: "two"))
    #expect(state.moveTab("one", to: "two"))
    #expect(state.configuration?.tabs.map(\.id) == ["one", "two", "three"])
    #expect(state.moveTab("three", to: "one"))
    state.reload()
    #expect(state.configuration?.tabs.map(\.id) == ["three", "one", "two"])
    let relaunched = AppState(configURL: config, preferences: preferences)
    #expect(relaunched.configuration?.tabs.map(\.id) == ["three", "one", "two"])
    try writeTabs(["two", "four", "three"], to: config)
    relaunched.reload()
    #expect(relaunched.configuration?.tabs.map(\.id) == ["three", "two", "four"])
    let otherConfig = directory.appending(path: "other.yaml")
    try writeTabs(["two", "three"], to: otherConfig)
    let independent = AppState(configURL: otherConfig, preferences: preferences)
    #expect(independent.configuration?.tabs.map(\.id) == ["two", "three"])
}

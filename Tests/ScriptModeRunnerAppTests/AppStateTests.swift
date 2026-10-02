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
    #expect(state.visibleScripts.contains { $0.id == state.selectedOutputID })
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

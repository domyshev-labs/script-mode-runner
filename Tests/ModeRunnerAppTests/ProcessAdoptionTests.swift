import Darwin
import Foundation
import ModeRunnerCore
import Testing
@testable import ModeRunnerApp

@MainActor
@Test func startupAdoptsManualModeWithoutStartingDuplicatesAndSupportsRestart() async throws {
    let directory = try adoptionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = try adoptionConfiguration(in: directory)
    let first = try externalSleeper(seconds: "30", cwd: directory)
    let second = try externalSleeper(seconds: "31", cwd: directory)
    defer { cleanup(first); cleanup(second) }
    let state = AppState(configURL: configuration)
    defer { Task { await state.shutdown() } }
    let tab = try #require(state.selectedTab)
    let mock = tab.buttons[1]
    // A Start request racing initial discovery must adopt, not duplicate, this mode.
    state.startMode(mock, in: tab)
    try await waitForAdoption { !state.discoveringProcesses && state.busyTabs.isEmpty && state.activity(mock, in: tab) == .running }
    #expect(state.selectedMode(in: tab)?.id == mock.id)
    #expect(state.runningMode(in: tab)?.id == mock.id)
    #expect(state.activeModes[tab.id] == mock.id)
    #expect(state.runs.count == 2)
    let pids = Set(state.logs.values.compactMap { log -> Int32? in
        if case let .running(pid) = log.status { return pid }
        return nil
    })
    #expect(pids == [first.processIdentifier, second.processIdentifier])
    #expect(state.visibleScripts.count == 2)
    #expect(state.selectedRun?.script.id == "frontend")
    for run in state.runs {
        let log = try #require(state.logs[run.id])
        let lines = log.buffer.string.components(separatedBy: "\n")
        #expect(lines[0] == "Detected an existing process:")
        #expect(lines[1].hasPrefix("Location: "))
        #expect(lines[2] == "Configuration match: " + run.script.displayCommand)
        #expect(lines[3] == (run.script.id == "frontend" ? "Port: 3010" : "Port: 3015"))
        #expect(lines[4].hasPrefix("Detected at: "))
        #expect(log.hasDetectionMessage)
        #expect(log.latestRunningLink?.absoluteString == (run.script.id == "frontend"
            ? "http://localhost:3010/" : "http://localhost:3015/"))
    }
    state.selectMode(tab.buttons[0], in: tab)
    state.selectMode(mock, in: tab)
    #expect(state.selectedRun?.script.id == "frontend")
    state.selectedOutputID = try #require(state.runs.first { $0.script.id == "backend" }?.id)
    state.reload()
    try await waitForAdoption { !state.discoveringProcesses }
    #expect(state.runs.count == 2)
    #expect(state.selectedRun?.script.id == "backend")
    state.restartMode(mock, in: tab)
    try await waitForAdoption { state.runs.count == 4 && state.busyTabs.isEmpty && state.activity(mock, in: tab) == .running }
    #expect(!first.isRunning)
    #expect(!second.isRunning)
    #expect(state.visibleScripts.count == 2)
    state.stopMode(mock, in: tab)
    try await waitForAdoption { state.busyTabs.isEmpty && state.runningMode(in: tab) == nil }
    #expect(state.activity(mock, in: tab) == .idle)
    await state.shutdown()
}

@MainActor
@Test func startupAdoptsPriorSupervisorProcessAndTracksItsExit() async throws {
    let directory = try adoptionDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = try adoptionConfiguration(in: directory)
    let priorSupervisor = ProcessSupervisor { _ in }
    let pid = try await priorSupervisor.start(runID: "old-instance", spec: RunnerScript(
        id: "old", title: "Old", executable: "/bin/sleep", arguments: ["30"], cwd: directory.path
    ).launchSpec())
    defer { kill(pid, SIGKILL) }
    let state = AppState(configURL: configuration)
    defer { Task { await state.shutdown() } }
    let tab = try #require(state.selectedTab)
    let mock = tab.buttons[1]
    try await waitForAdoption { !state.discoveringProcesses && state.runningMode(in: tab)?.id == mock.id }
    #expect(state.activity(mock, in: tab) == .partial)
    let run = try #require(state.selectedRun)
    #expect(state.logs[run.id]?.status == .running(pid: pid))
    state.stopMode(mock, in: tab)
    try await waitForAdoption { state.busyTabs.isEmpty && state.runningMode(in: tab) == nil }
    #expect(state.logs[run.id]?.status == .unobservedExit)
    #expect(ProcessIdentity.read(pid: pid) == nil)
    #expect(state.activity(mock, in: tab) == .idle)
    await state.shutdown()
}

private func adoptionDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func adoptionConfiguration(in directory: URL) throws -> URL {
    let configuration = directory.appending(path: "config.yaml")
    try """
    tabs:
      - id: project
        title: Project
        buttons:
          - id: lab
            title: Lab
            on_deactivate: {sigkill: true}
            scripts:
              - {id: lab, title: Lab, executable: /bin/sleep, arguments: [29], cwd: '\(directory.path)'}
          - id: mock
            title: Mock
            on_deactivate: {sigkill: true}
            scripts:
              - {id: frontend, title: 'Frontend · :3010', executable: /bin/sleep, arguments: [30], cwd: '\(directory.path)'}
              - {id: backend, title: 'Backend · :3015', executable: /bin/sleep, arguments: [31], cwd: '\(directory.path)'}
    """.write(to: configuration, atomically: true, encoding: .utf8)
    return configuration
}

private func externalSleeper(seconds: String, cwd: URL) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = [seconds]
    process.currentDirectoryURL = cwd
    try process.run()
    return process
}

private func cleanup(_ process: Process) {
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}

@MainActor
private func waitForAdoption(_ condition: () -> Bool) async throws {
    for _ in 0..<250 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw AdoptionTimeout()
}

private struct AdoptionTimeout: Error {}

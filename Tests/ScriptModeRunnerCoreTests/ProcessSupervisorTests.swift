import Darwin
import Foundation
import Testing
@testable import ScriptModeRunnerCore

@Test func capturesOutputAndExitStatus() async throws {
    let events = EventCollector()
    let supervisor = ProcessSupervisor { events.append($0) }
    let spec = LaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "printf out; printf err >&2"],
        cwd: nil,
        environment: [:]
    )

    try await supervisor.start(runID: "output", spec: spec)
    let snapshot = try await waitForTerminalEvent(runID: "output", events: events)

    #expect(snapshot.contains { event in
        if case let .output(_, .stdout, data) = event { return String(decoding: data, as: UTF8.self).contains("out") }
        return false
    })
    #expect(snapshot.contains { event in
        if case let .output(_, .stderr, data) = event { return String(decoding: data, as: UTF8.self).contains("err") }
        return false
    })
    #expect(snapshot.contains { event in
        if case .status(_, .exited(code: 0)) = event { return true }
        return false
    })
}

@Test func escalatesFromInterruptToKill() async throws {
    let events = EventCollector()
    let supervisor = ProcessSupervisor { events.append($0) }
    let spec = LaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "trap '' INT; while :; do sleep 1; done"],
        cwd: nil,
        environment: [:]
    )

    try await supervisor.start(runID: "stubborn", spec: spec)
    try await Task.sleep(for: .milliseconds(100))
    await supervisor.stop(
        runID: "stubborn",
        policy: .init(sigint: true, sigkill: true, timeout: .seconds(0.1))
    )
    let snapshot = try await waitForTerminalEvent(runID: "stubborn", events: events)

    #expect(snapshot.contains { event in
        if case let .status(_, .signalled(signal)) = event { return signal == SIGKILL }
        return false
    })
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProcessEvent] = []

    func append(_ event: ProcessEvent) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [ProcessEvent] {
        lock.withLock { events }
    }
}

private func waitForTerminalEvent(runID: String, events: EventCollector) async throws -> [ProcessEvent] {
    for _ in 0..<100 {
        let snapshot = events.snapshot()
        if snapshot.contains(where: { event in
            guard case let .status(id, status) = event, id == runID else { return false }
            switch status {
            case .exited, .signalled, .failed: return true
            default: return false
            }
        }) {
            return snapshot
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw TestTimeout()
}

private struct TestTimeout: Error {}

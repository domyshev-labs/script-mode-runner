import Darwin
import Foundation
import Testing
@testable import ModeRunnerCore

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

@Test func streamsOutputBeforeLongRunningProcessExits() async throws {
    let events = EventCollector()
    let supervisor = ProcessSupervisor { events.append($0) }
    let spec = LaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "printf 'READY\\n'; sleep 30"],
        cwd: nil,
        environment: [:]
    )

    try await supervisor.start(runID: "streaming", spec: spec)
    var receivedBeforeStop = false
    for _ in 0..<50 {
        receivedBeforeStop = events.snapshot().contains { event in
            if case let .output("streaming", .stdout, data) = event {
                return String(decoding: data, as: UTF8.self).contains("READY")
            }
            return false
        }
        if receivedBeforeStop { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    await supervisor.stop(runID: "streaming", policy: .init(sigkill: true))
    _ = try await waitForTerminalEvent(runID: "streaming", events: events)

    #expect(receivedBeforeStop)
}

@Test func preservedProcessKeepsWritingAfterSupervisorIsReleased() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".build/debug/ModeRunner")
    let marker = directory.appending(path: "completed")
    var supervisor: ProcessSupervisor? = ProcessSupervisor { _ in }
    let pid = try await supervisor!.start(runID: "preserved", spec: LaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "sleep 0.3; dd if=/dev/zero bs=65536 count=16; dd if=/dev/zero bs=65536 count=16 >&2; touch completed"],
        cwd: directory.path, environment: [:]
    ))
    defer { killpg(pid, SIGKILL) }
    try await supervisor!.preserveOutput(executablePath: executable.path)
    supervisor = nil
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: marker.path) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test func failedOutputPreservationDoesNotStopProcess() async throws {
    let supervisor = ProcessSupervisor { _ in }
    let pid = try await supervisor.start(runID: "preserved", spec: LaunchSpec(
        executable: "/bin/sleep", arguments: ["30"], cwd: nil, environment: [:]
    ))
    do {
        try await supervisor.preserveOutput(executablePath: "/nonexistent/ModeRunner")
        Issue.record("Expected output preservation to fail")
    } catch {
        #expect(kill(pid, 0) == 0)
    }
    await supervisor.stopAll(policy: .init(sigkill: true))
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

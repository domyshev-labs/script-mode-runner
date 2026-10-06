import Darwin
import Foundation
import Testing
@testable import ModeRunnerApp

@Test func watchdogForcesHungAppToExit() throws {
    let child = try startExitFixture(duration: "2")
    let watchdog = try RunnerExitWatchdog.launch(pid: child.processIdentifier, action: .poweroff,
                                                executablePath: "/nonexistent", timeoutTicks: 2)
    child.waitUntilExit()
    watchdog.waitUntilExit()
    #expect(child.terminationReason == .uncaughtSignal)
    #expect(child.terminationStatus == SIGKILL)
    #expect(watchdog.terminationStatus == 0)
}

@Test func watchdogRestartsAfterForcedExit() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let replacement = directory.appending(path: "replacement")
    try "#!/bin/sh\ntouch \"$0.restarted\"\n".write(to: replacement, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacement.path)
    let child = try startExitFixture(duration: "2")
    let watchdog = try RunnerExitWatchdog.launch(pid: child.processIdentifier, action: .restart,
                                                executablePath: replacement.path, timeoutTicks: 2)
    child.waitUntilExit()
    watchdog.waitUntilExit()
    #expect(child.terminationStatus == SIGKILL)
    #expect(FileManager.default.fileExists(atPath: replacement.path + ".restarted"))
}

@Test func watchdogAllowsNormalExitWithoutKill() throws {
    let child = try startExitFixture(duration: "0.1")
    let watchdog = try RunnerExitWatchdog.launch(pid: child.processIdentifier, action: .poweroff,
                                                executablePath: "/nonexistent", timeoutTicks: 10)
    child.waitUntilExit()
    watchdog.waitUntilExit()
    #expect(child.terminationReason == .exit)
    #expect(child.terminationStatus == 0)
    #expect(watchdog.terminationStatus == 0)
}

private func startExitFixture(duration: String) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = [duration]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

import Darwin
import Foundation
import Testing
@testable import ModeRunnerCore

@Test func discoveryRequiresExactCommandAndWorkingDirectory() {
    let process = fixtureProcess(pid: 200, parent: 1, arguments: ["node", "/tools/yarn.js", "dev:mock"], cwd: "/tmp/project-a")
    #expect(ProcessDiscovery.matches(process, script: RunnerScript(id: "dev", title: "Dev", command: "yarn dev:mock", cwd: "/tmp/project-a")))
    #expect(!ProcessDiscovery.matches(process, script: RunnerScript(id: "dev", title: "Dev", command: "yarn dev:lab", cwd: "/tmp/project-a")))
    #expect(!ProcessDiscovery.matches(process, script: RunnerScript(id: "dev", title: "Dev", command: "yarn dev:mock", cwd: "/tmp/project-b")))
    #expect(!ProcessDiscovery.matches(process, script: RunnerScript(id: "dev", title: "Dev", command: "yarn dev:mock")))
    #expect(!ProcessDiscovery.matches(fixtureProcess(pid: 201, parent: 1, arguments: ["node", "/tools/yarn.js", "dev:mock", "--extra"], cwd: "/tmp/project-a"),
                                     script: RunnerScript(id: "dev", title: "Dev", command: "yarn dev:mock", cwd: "/tmp/project-a")))
}

@Test func discoveryHandlesQuotedArgumentsWithoutEvaluatingShell() {
    #expect(ProcessDiscovery.simpleCommandArguments("yarn 'dev:mock' --name \"two words\"") == ["yarn", "dev:mock", "--name", "two words"])
    #expect(ProcessDiscovery.simpleCommandArguments("yarn dev:mock && yarn mock") == nil)
    #expect(ProcessDiscovery.simpleCommandArguments("yarn $(echo mock)") == nil)
    #expect(ProcessDiscovery.simpleCommandArguments("yarn \"$SECRET\"") == nil)
    #expect(ProcessDiscovery.simpleCommandArguments("yarn 'unterminated") == nil)
}

@Test func discoveryCollapsesWrapperAndChildButKeepsAmbiguousRoots() {
    let script = RunnerScript(id: "dev", title: "Dev", command: "yarn dev:mock", cwd: "/tmp/project-a")
    let wrapper = fixtureProcess(pid: 100, parent: 1, arguments: ["/bin/zsh", "-ilc", "yarn dev:mock"], cwd: "/tmp/project-a")
    let child = fixtureProcess(pid: 101, parent: 100, arguments: ["node", "/tools/yarn.js", "dev:mock"], cwd: "/tmp/project-a")
    #expect(ProcessDiscovery.roots(matching: script, in: [wrapper, child]).map(\.identity.pid) == [100])
    let second = fixtureProcess(pid: 102, parent: 1, arguments: ["node", "/tools/yarn.js", "dev:mock"], cwd: "/tmp/project-a")
    #expect(ProcessDiscovery.roots(matching: script, in: [wrapper, child, second]).count == 2)
}

@Test func stoppingAdoptedProcessStopsDescendantsWithoutSignallingSibling() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = Process()
    root.executableURL = URL(fileURLWithPath: "/bin/sh")
    root.arguments = ["-c", "sleep 30 & echo $! > child.pid; wait"]
    root.currentDirectoryURL = directory
    try root.run()
    let sibling = Process()
    sibling.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sibling.arguments = ["30"]
    try sibling.run()
    defer {
        if root.isRunning { kill(root.processIdentifier, SIGKILL) }
        if sibling.isRunning { sibling.terminate() }
        root.waitUntilExit()
        sibling.waitUntilExit()
    }
    let childFile = directory.appending(path: "child.pid")
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: childFile.path) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let childPID = try #require(Int32(String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { if ProcessIdentity.read(pid: childPID) != nil { kill(childPID, SIGKILL) } }
    let childIdentity = try #require(ProcessIdentity.read(pid: childPID))
    let snapshot = DiscoveredProcess.snapshot()
    let process = try #require(snapshot.first { $0.identity.pid == root.processIdentifier })
    let supervisor = ProcessSupervisor { _ in }
    #expect(await supervisor.adopt(runID: "external", process: process))
    await supervisor.stop(runID: "external", policy: .init(sigkill: true))
    for _ in 0..<100 {
        if !process.identity.isAlive && !childIdentity.isAlive { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!process.identity.isAlive)
    #expect(!childIdentity.isAlive)
    #expect(sibling.isRunning)
    #expect(ProcessIdentity.read(pid: sibling.processIdentifier) != nil)
}

private func fixtureProcess(pid: Int32, parent: Int32, arguments: [String], cwd: String) -> DiscoveredProcess {
    DiscoveredProcess(identity: ProcessIdentity(pid: pid, startedSeconds: 1, startedMicroseconds: 0),
                      parentPID: parent, arguments: arguments, cwd: cwd)
}

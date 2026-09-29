import Foundation
import Testing
@testable import ScriptModeRunnerCore

@Test func testApplicationsConfigurationMatchesPackageScripts() throws {
    let root = repositoryRoot()
    let config = try ConfigurationLoader().load(from: root.appending(path: "Examples/test-apps.yaml"))
    let expectedPorts = [
        ["dev:lab": 3010, "dev:mock": 3010, "mock": 3015],
        ["dev:lab": 3020, "dev:mock": 3020, "mock": 3025],
        ["dev:lab": 3030, "dev:mock": 3030, "mock": 3035],
    ]

    #expect(config.tabs.count == 3)
    for (index, tab) in config.tabs.enumerated() {
        let applicationNumber = index + 1
        let applicationDirectory = root.appending(path: "TestApplications/application-\(applicationNumber)")
        let manifest = try loadPackageManifest(at: applicationDirectory.appending(path: "package.json"))

        #expect(tab.title == "Application #\(applicationNumber)")
        #expect(tab.buttons.count == 2)
        #expect(tab.buttons[0].scripts.count == 1)
        #expect(tab.buttons[1].scripts.count == 2)
        #expect(tab.buttons.allSatisfy { $0.onDeactivate.sigint && $0.onDeactivate.sigkill })

        let configuredCommands = tab.buttons.flatMap(\.scripts).compactMap(\.command)
        #expect(configuredCommands == ["yarn dev:lab", "yarn dev:mock", "yarn mock"])
        #expect(tab.buttons.flatMap(\.scripts).allSatisfy { $0.cwd == applicationDirectory.path })

        for (command, port) in expectedPorts[index] {
            let packageScript = try #require(manifest.scripts[command])
            #expect(packageScript.contains(" \(port)"))
            #expect(packageScript.contains("Application #\(applicationNumber)"))
        }
        #expect(manifest.scripts["dev:mock"]?.contains(" \(expectedPorts[index]["mock"]!)") == true)
    }
}

@Test func mockPairFetchesBackendDataAndLogsBothSides() async throws {
    let applicationDirectory = repositoryRoot().appending(path: "TestApplications/application-3")
    let backend = try launchNode(
        arguments: ["server.mjs", "Application #3", "mock", "3035"],
        directory: applicationDirectory
    )
    let frontend = try launchNode(
        arguments: ["server.mjs", "Application #3", "dev:mock", "3030", "3035"],
        directory: applicationDirectory
    )
    defer {
        if frontend.process.isRunning { frontend.process.terminate() }
        if backend.process.isRunning { backend.process.terminate() }
    }

    let responseData = try await fetchEventually(URL(string: "http://127.0.0.1:3030")!)

    frontend.process.interrupt()
    backend.process.interrupt()
    frontend.process.waitUntilExit()
    backend.process.waitUntilExit()
    let frontendConsole = String(decoding: frontend.output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let backendConsole = String(decoding: backend.output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let page = String(decoding: responseData, as: UTF8.self)

    #expect(page.contains("Application #3"))
    #expect(page.contains("Mock server #3"))
    #expect(page.contains("3035"))
    #expect(page.contains("mock-3-alpha"))
    #expect(frontendConsole.contains("[frontend] requesting http://127.0.0.1:3035/api/test-data"))
    #expect(frontendConsole.contains("[frontend] received"))
    #expect(frontendConsole.contains("Mock server #3"))
    #expect(backendConsole.contains("Mock server #3 is serving test data on port 3035"))
    #expect(backendConsole.contains("GET /api/test-data"))
    #expect(frontend.process.terminationStatus == 0)
    #expect(backend.process.terminationStatus == 0)
}

private struct RunningFixture {
    let process: Process
    let output: Pipe
}

private func launchNode(arguments: [String], directory: URL) throws -> RunningFixture {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = output
    process.standardError = output
    try process.run()
    return RunningFixture(process: process, output: output)
}

private func fetchEventually(_ url: URL) async throws -> Data {
    var lastError: Error?
    for _ in 0..<100 {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if (response as? HTTPURLResponse)?.statusCode == 200 { return data }
        } catch {
            lastError = error
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw lastError ?? FixtureTimeout()
}

private struct FixtureTimeout: Error {}

private struct PackageManifest: Decodable {
    let scripts: [String: String]
}

private func loadPackageManifest(at url: URL) throws -> PackageManifest {
    try JSONDecoder().decode(PackageManifest.self, from: Data(contentsOf: url))
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

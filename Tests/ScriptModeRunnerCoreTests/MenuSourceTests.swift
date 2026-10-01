import Foundation
import Testing
@testable import ScriptModeRunnerCore

private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try "".write(to: url.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
    return url
}

@Test func packageMenuReadsAllScriptsAndQuotesArguments() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let dangerous = "test';$(touch injected)"
    let data = try JSONSerialization.data(withJSONObject: ["scripts": ["build": "echo build", dangerous: "echo test"]])
    try data.write(to: dir.appending(path: "package.json"))
    let source = try JSONDecoder().decode(MenuSource.self, from: Data(#"{"type":"package_scripts"}"#.utf8))
    let button = RunnerMode(id: "scripts", title: "Scripts", scripts: [], source: source, cwd: dir.path, runner: ["/bin/echo"])
    let items = try await MenuLoader().load(button, relativeTo: dir)
    #expect(Set(items.map(\.id)) == ["build", dangerous])
    let item = try #require(items.first { $0.id == dangerous })
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", item.script(for: button).command!]
    process.currentDirectoryURL = dir
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(String(decoding: output, as: UTF8.self) == dangerous + "\n")
    #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "injected").path))
}

@Test func dropdownConfigurationResolvesPathsAndPreservesMargins() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let yaml = """
    tabs:
      - id: project
        title: Project
        buttons:
          - id: scripts
            title: Scripts
            margin_left: 2.5
            margin_right: 16
            source:
              type: package_scripts
    """
    let path = dir.appending(path: "config.yaml")
    try yaml.write(to: path, atomically: true, encoding: .utf8)
    let button = try ConfigurationLoader().load(from: path).tabs[0].buttons[0]
    #expect(button.cwd == dir.path)
    #expect(button.marginLeft == 2.5)
    #expect(button.marginRight == 16)
    #expect(button.runner == ["yarn", "run"])
    for replacement in ["margin_right: -1", "margin_right: .inf"] {
        try yaml.replacingOccurrences(of: "margin_right: 16", with: replacement).write(to: path, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try ConfigurationLoader().load(from: path) }
    }
}

@Test func commandCatalogCapturesFinalOutputAndParameters() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let json = #"[{"id":"component","title":"Component","arguments":["component"]}]"#
    let source = MenuSource(type: .command, path: nil, command: "printf %s " + shellQuote(json),
                            parameters: ["component": MenuParameter(prompt: "Component", defaultValue: "ADB")])
    let button = RunnerMode(id: "seeds", title: "Seeds", scripts: [], source: source, cwd: dir.path,
                            environment: ["ZDOTDIR": dir.path], runner: ["yarn", "mock:seed"])
    let items = try await MenuLoader().load(button, relativeTo: dir)
    #expect(items.count == 1)
    #expect(items[0].parameter?.defaultValue == "ADB")
    #expect(items[0].script(for: button, parameterValue: "O'Hare").command == "'yarn' 'mock:seed' 'component' 'O'\\''Hare'")
}

@Test func jsonCatalogRejectsDuplicateIDs() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let json = #"[{"id":"a","title":"A","arguments":[]},{"id":"a","title":"B","arguments":[]}]"#
    try json.write(to: dir.appending(path: "seeds.json"), atomically: true, encoding: .utf8)
    let source = MenuSource(type: .jsonFile, path: "seeds.json", command: nil, parameters: nil)
    let button = RunnerMode(id: "seeds", title: "Seeds", scripts: [], source: source, cwd: dir.path)
    await #expect(throws: MenuSourceError.self) { try await MenuLoader().load(button, relativeTo: dir) }
}

@Test func failedCatalogCommandReportsError() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = MenuSource(type: .command, path: nil, command: "printf 'catalog-failure' >&2; exit 7", parameters: nil)
    let button = RunnerMode(id: "seeds", title: "Seeds", scripts: [], source: source, cwd: dir.path, environment: ["ZDOTDIR": dir.path])
    do {
        _ = try await MenuLoader().load(button, relativeTo: dir)
        Issue.record("Expected catalog failure")
    } catch { #expect(error.localizedDescription.contains("catalog-failure")) }
}

@Test func seedModuleEnumeratesWithoutRunningSeedCLI() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "module.exports = {seedSetNames:['default','component']};".write(to: dir.appending(path: "sets.cjs"), atomically: true, encoding: .utf8)
    try "throw new Error('must not seed while listing');".write(to: dir.appending(path: "seed-cli.cjs"), atomically: true, encoding: .utf8)
    let source = MenuSource(type: .seedModule, path: "sets.cjs", command: nil,
                            parameters: ["component": MenuParameter(prompt: "Component", defaultValue: "ADB")])
    let button = RunnerMode(id: "seeds", title: "Seeds", scripts: [], source: source, cwd: dir.path,
                            environment: ["ZDOTDIR": dir.path], runner: ["yarn", "mock:seed"])
    let items = try await MenuLoader().load(button, relativeTo: dir)
    #expect(items.map(\.id) == ["default", "component"])
    #expect(items.last?.parameter?.defaultValue == "ADB")
}

@Test func cancellationStopsCatalogProcess() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = MenuSource(type: .command, path: nil, command: "exec /bin/sleep 30", parameters: nil)
    let button = RunnerMode(id: "seeds", title: "Seeds", scripts: [], source: source, cwd: dir.path,
                            environment: ["ZDOTDIR": dir.path])
    let task = Task { try await MenuLoader().load(button, relativeTo: dir) }
    try await Task.sleep(for: .milliseconds(200))
    task.cancel()
    do { _ = try await task.value; Issue.record("Expected cancellation") }
    catch { #expect(error is CancellationError) }
}

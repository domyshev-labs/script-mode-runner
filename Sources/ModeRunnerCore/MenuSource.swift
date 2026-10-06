import Foundation

public struct MenuSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case packageScripts = "package_scripts", seedModule = "seed_module", command, jsonFile = "json_file" }
    public let type: Kind
    public let path: String?
    public let command: String?
    public let parameters: [String: MenuParameter]?

    public func validate(id: String) throws {
        if type == .command {
            guard let command, !command.isEmpty else { throw ConfigurationError.invalidScript(id: id, reason: "command source requires command") }
        } else if type != .packageScripts {
            guard let path, !path.isEmpty else { throw ConfigurationError.invalidScript(id: id, reason: "source requires path") }
        }
    }
}

public struct MenuParameter: Codable, Equatable, Sendable {
    public let prompt: String
    public let defaultValue: String?
    enum CodingKeys: String, CodingKey { case prompt; case defaultValue = "default" }
}

public struct MenuItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let arguments: [String]
    public let parameter: MenuParameter?

    public init(id: String, title: String, arguments: [String], parameter: MenuParameter? = nil) {
        self.id = id; self.title = title; self.arguments = arguments; self.parameter = parameter
    }

    public func script(for button: RunnerMode, parameterValue: String? = nil) -> RunnerScript {
        let words = button.runner + arguments + (parameterValue.map { [$0] } ?? [])
        return RunnerScript(id: id, title: title, command: words.map(shellQuote).joined(separator: " "),
                            cwd: button.cwd, environment: button.environment)
    }
}

public enum MenuSourceError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

public struct MenuLoader: Sendable {
    public init() {}

    public func load(_ button: RunnerMode, relativeTo configDirectory: URL) async throws -> [MenuItem] {
        guard let source = button.source else { return [] }
        try source.validate(id: button.id)
        let base = button.cwd.map { URL(fileURLWithPath: resolvePath($0, relativeTo: configDirectory)) } ?? configDirectory
        let data: Data
        switch source.type {
        case .packageScripts:
            let url = URL(fileURLWithPath: resolvePath(source.path ?? "package.json", relativeTo: base))
            data = try await Task.detached { try Self.readFile(url) }.value
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let json else { throw MenuSourceError.invalid("package.json must contain an object") }
            guard let raw = json["scripts"] else { return [] }
            guard let scripts = raw as? [String: String] else { throw MenuSourceError.invalid("package.json scripts must contain string values") }
            return scripts.keys.sorted().map { MenuItem(id: $0, title: $0, arguments: [$0]) }
        case .jsonFile:
            data = try await Task.detached { try Self.readFile(URL(fileURLWithPath: resolvePath(source.path!, relativeTo: base))) }.value
        case .command, .seedModule:
            let command: String
            if source.type == .seedModule {
                let path = resolvePath(source.path!, relativeTo: base)
                let code = "const m = require(process.argv[1]); console.log(JSON.stringify(m.seedSetNames.map(n => ({id:n,title:n,arguments:[n]}))));"
                command = ["node", "-e", code, path].map(shellQuote).joined(separator: " ")
            } else { command = source.command! }
            data = try await capture(command: command, cwd: base.path, environment: button.environment)
        }
        let items = try JSONDecoder().decode([MenuItem].self, from: data)
        guard Set(items.map(\.id)).count == items.count, items.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty }) else {
            throw MenuSourceError.invalid("Menu items must have unique nonempty IDs and titles")
        }
        return items.map { MenuItem(id: $0.id, title: $0.title, arguments: $0.arguments,
                                   parameter: $0.parameter ?? source.parameters?[$0.id]) }
    }

    private static func readFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw MenuSourceError.invalid("Menu source exceeds 1 MB") }
        return data
    }

    private func capture(command: String, cwd: String, environment: [String: String]) async throws -> Data {
        let collector = CatalogOutput()
        let supervisor = ProcessSupervisor { collector.receive($0) }
        let spec = RunnerScript(id: "catalog", title: "Catalog", command: command, cwd: cwd, environment: environment).launchSpec()
        try await supervisor.start(runID: "catalog", spec: spec)
        do {
            for _ in 0..<200 {
                try Task.checkCancellation()
                let snapshot = collector.snapshot()
                if snapshot.overflow { throw MenuSourceError.invalid("Menu source exceeds 1 MB") }
                if let status = snapshot.status {
                    switch status {
                    case .exited(code: 0): return snapshot.data
                    case .exited, .signalled, .failed: throw MenuSourceError.invalid("Menu command failed: " + String(decoding: snapshot.error, as: UTF8.self))
                    default: break
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw MenuSourceError.invalid("Menu command timed out after 10 seconds")
        } catch {
            await supervisor.stopAll(policy: .init(sigkill: true))
            throw error
        }
    }
}

private final class CatalogOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var error = Data()
    private var status: ProcessStatus?
    private var overflow = false

    func receive(_ event: ProcessEvent) {
        lock.withLock {
            switch event {
            case let .output(_, stream, bytes):
                if data.count + error.count + bytes.count > 1_048_576 { overflow = true; return }
                if stream == .stdout { data.append(bytes) } else { error.append(bytes) }
            case let .status(_, value): status = value
            }
        }
    }

    func snapshot() -> (data: Data, error: Data, status: ProcessStatus?, overflow: Bool) {
        lock.withLock { (data, error, status, overflow) }
    }
}

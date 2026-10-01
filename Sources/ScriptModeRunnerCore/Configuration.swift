import Foundation

public struct RunnerConfiguration: Codable, Equatable, Sendable {
    public let tabs: [RunnerTab]

    public init(tabs: [RunnerTab]) {
        self.tabs = tabs
    }

    public func validated(fileManager: FileManager = .default) throws -> RunnerConfiguration {
        try validateUnique(tabs.map(\.id), kind: "tab")
        for tab in tabs {
            try validateUnique(tab.buttons.map(\.id), kind: "mode in tab '\(tab.id)'")
            for mode in tab.buttons {
                try validateUnique(mode.scripts.map(\.id), kind: "script in mode '\(mode.id)'")
                for script in mode.scripts {
                    try script.validate(fileManager: fileManager)
                }
            }
        }
        return self
    }

    public func resolvingRelativePaths(relativeTo baseDirectory: URL) -> RunnerConfiguration {
        RunnerConfiguration(tabs: tabs.map { tab in
            RunnerTab(id: tab.id, title: tab.title, buttons: tab.buttons.map { mode in
                RunnerMode(
                    id: mode.id,
                    title: mode.title,
                    onDeactivate: mode.onDeactivate,
                    scripts: mode.scripts.map { $0.resolvingRelativePath(relativeTo: baseDirectory) }
                )
            })
        })
    }
}

public struct RunnerTab: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let buttons: [RunnerMode]

    public init(id: String, title: String, buttons: [RunnerMode]) {
        self.id = id
        self.title = title
        self.buttons = buttons
    }
}

public struct RunnerMode: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let onDeactivate: DeactivationPolicy
    public let scripts: [RunnerScript]

    enum CodingKeys: String, CodingKey {
        case id, title, scripts
        case onDeactivate = "on_deactivate"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        scripts = try container.decode([RunnerScript].self, forKey: .scripts)
        onDeactivate = try container.decodeIfPresent(DeactivationPolicy.self, forKey: .onDeactivate) ?? .init()
    }

    public init(id: String, title: String, onDeactivate: DeactivationPolicy = .init(), scripts: [RunnerScript]) {
        self.id = id
        self.title = title
        self.onDeactivate = onDeactivate
        self.scripts = scripts
    }
}

public struct DeactivationPolicy: Codable, Equatable, Sendable {
    public let sigint: Bool
    public let sigkill: Bool
    public let timeout: DurationValue

    public init(sigint: Bool = false, sigkill: Bool = false, timeout: DurationValue = .seconds(5)) {
        self.sigint = sigint
        self.sigkill = sigkill
        self.timeout = timeout
    }

    enum CodingKeys: String, CodingKey { case sigint, sigkill, timeout }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sigint = try container.decodeIfPresent(Bool.self, forKey: .sigint) ?? false
        sigkill = try container.decodeIfPresent(Bool.self, forKey: .sigkill) ?? false
        timeout = try container.decodeIfPresent(DurationValue.self, forKey: .timeout) ?? .seconds(5)
    }
}

public struct DurationValue: Codable, Equatable, Sendable {
    public let seconds: Double

    public static func seconds(_ value: Double) -> DurationValue { .init(seconds: value) }

    public init(seconds: Double) {
        self.seconds = seconds
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Double.self) {
            seconds = number
            return
        }
        let text = try value.decode(String.self).trimmingCharacters(in: .whitespaces)
        let multiplier: Double
        let numeric: Substring
        if text.hasSuffix("ms") {
            multiplier = 0.001
            numeric = text.dropLast(2)
        } else if text.hasSuffix("s") {
            multiplier = 1
            numeric = text.dropLast()
        } else if text.hasSuffix("m") {
            multiplier = 60
            numeric = text.dropLast()
        } else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Duration must use ms, s, or m")
        }
        guard let parsed = Double(numeric), parsed >= 0 else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid duration: \(text)")
        }
        seconds = parsed * multiplier
    }
}

public struct RunnerScript: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let executable: String?
    public let arguments: [String]
    public let command: String?
    public let shell: String?
    public let cwd: String?
    public let environment: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, title, executable, arguments, command, shell, cwd, environment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        executable = try container.decodeIfPresent(String.self, forKey: .executable)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        command = try container.decodeIfPresent(String.self, forKey: .command)
        shell = try container.decodeIfPresent(String.self, forKey: .shell)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    }

    public init(
        id: String,
        title: String,
        executable: String? = nil,
        arguments: [String] = [],
        command: String? = nil,
        shell: String? = nil,
        cwd: String? = nil,
        environment: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.executable = executable
        self.arguments = arguments
        self.command = command
        self.shell = shell
        self.cwd = cwd
        self.environment = environment
    }

    public func launchSpec(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> LaunchSpec {
        let directory = cwd.map { expandTilde($0, homeDirectory: homeDirectory) }
        if let command {
            let commandShell = shell ?? "/bin/zsh"
            // Tools managed by NVM and similar managers are often initialized in .zshrc.
            // Finder does not provide the PATH inherited when launching from Terminal.
            let flags = URL(fileURLWithPath: commandShell).lastPathComponent == "zsh" ? "-ilc" : "-lc"
            return LaunchSpec(executable: commandShell, arguments: [flags, command], cwd: directory, environment: environment)
        }
        return LaunchSpec(executable: executable ?? "", arguments: arguments, cwd: directory, environment: environment)
    }

    fileprivate func validate(fileManager: FileManager) throws {
        let hasExecutable = !(executable?.isEmpty ?? true)
        let hasCommand = !(command?.isEmpty ?? true)
        guard hasExecutable != hasCommand else {
            throw ConfigurationError.invalidScript(id: id, reason: "specify exactly one of 'executable' or 'command'")
        }
        if let cwd {
            var isDirectory: ObjCBool = false
            let expanded = expandTilde(cwd, homeDirectory: fileManager.homeDirectoryForCurrentUser)
            guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ConfigurationError.invalidScript(id: id, reason: "working directory does not exist: \(expanded)")
            }
        }
        if let executable, executable.contains("/") {
            let expanded = expandTilde(executable, homeDirectory: fileManager.homeDirectoryForCurrentUser)
            guard fileManager.isExecutableFile(atPath: expanded) else {
                throw ConfigurationError.invalidScript(id: id, reason: "file is not executable: \(expanded)")
            }
        }
    }

    fileprivate func resolvingRelativePath(relativeTo baseDirectory: URL) -> RunnerScript {
        guard let cwd, !cwd.hasPrefix("/"), !cwd.hasPrefix("~") else { return self }
        return RunnerScript(
            id: id,
            title: title,
            executable: executable,
            arguments: arguments,
            command: command,
            shell: shell,
            cwd: baseDirectory.appending(path: cwd).standardizedFileURL.path,
            environment: environment
        )
    }
}

public struct LaunchSpec: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let cwd: String?
    public let environment: [String: String]
}

public enum ConfigurationError: LocalizedError, Equatable {
    case duplicateID(kind: String, id: String)
    case invalidScript(id: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .duplicateID(kind, id): "Duplicate \(kind) id: \(id)"
        case let .invalidScript(id, reason): "Invalid script '\(id)': \(reason)"
        }
    }
}

private func validateUnique(_ ids: [String], kind: String) throws {
    var seen = Set<String>()
    for id in ids where !seen.insert(id).inserted {
        throw ConfigurationError.duplicateID(kind: kind, id: id)
    }
}

private func expandTilde(_ path: String, homeDirectory: URL) -> String {
    if path == "~" { return homeDirectory.path }
    if path.hasPrefix("~/") { return homeDirectory.appending(path: String(path.dropFirst(2))).path }
    return path
}

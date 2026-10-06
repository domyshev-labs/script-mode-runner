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
                guard mode.marginLeft.isFinite, mode.marginRight.isFinite, mode.marginLeft >= 0, mode.marginRight >= 0 else {
                    throw ConfigurationError.invalidScript(id: mode.id, reason: "margins must be finite nonnegative numbers")
                }
                guard (mode.source != nil) != !mode.scripts.isEmpty else {
                    throw ConfigurationError.invalidScript(id: mode.id, reason: "specify either scripts or source")
                }
                if let source = mode.source {
                    try source.validate(id: mode.id)
                    guard !mode.runner.isEmpty, !mode.runner[0].isEmpty else {
                        throw ConfigurationError.invalidScript(id: mode.id, reason: "runner requires an executable")
                    }
                    if let cwd = mode.cwd {
                        var directory: ObjCBool = false
                        guard fileManager.fileExists(atPath: (cwd as NSString).expandingTildeInPath, isDirectory: &directory), directory.boolValue else {
                            throw ConfigurationError.invalidScript(id: mode.id, reason: "working directory does not exist: \(cwd)")
                        }
                    }
                }
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
                    scripts: mode.scripts.map { $0.resolvingRelativePath(relativeTo: baseDirectory) },
                    source: mode.source, cwd: mode.cwd.map { resolvePath($0, relativeTo: baseDirectory) } ?? (mode.source != nil ? baseDirectory.path : nil),
                    environment: mode.environment, runner: mode.runner,
                    marginLeft: mode.marginLeft, marginRight: mode.marginRight, align: mode.align
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

public enum ButtonAlignment: String, Codable, Sendable { case left, right }

public struct RunnerMode: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let onDeactivate: DeactivationPolicy
    public let scripts: [RunnerScript]
    public let source: MenuSource?
    public let cwd: String?
    public let environment: [String: String]
    public let runner: [String]
    public let marginLeft: Double
    public let marginRight: Double
    public let align: ButtonAlignment

    enum CodingKeys: String, CodingKey {
        case id, title, scripts, source, cwd, environment, runner, align
        case onDeactivate = "on_deactivate"
        case marginLeft = "margin_left"
        case marginRight = "margin_right"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        scripts = try c.decodeIfPresent([RunnerScript].self, forKey: .scripts) ?? []
        source = try c.decodeIfPresent(MenuSource.self, forKey: .source)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        runner = try c.decodeIfPresent([String].self, forKey: .runner) ?? ["yarn", "run"]
        marginLeft = try c.decodeIfPresent(Double.self, forKey: .marginLeft) ?? 0
        align = try c.decodeIfPresent(ButtonAlignment.self, forKey: .align) ?? .left
        marginRight = try c.decodeIfPresent(Double.self, forKey: .marginRight) ?? 0
        onDeactivate = try c.decodeIfPresent(DeactivationPolicy.self, forKey: .onDeactivate) ?? .init(sigint: true, sigkill: true)
    }

    public init(id: String, title: String, onDeactivate: DeactivationPolicy = .init(), scripts: [RunnerScript],
                source: MenuSource? = nil, cwd: String? = nil, environment: [String: String] = [:],
                runner: [String] = ["yarn", "run"], marginLeft: Double = 0, marginRight: Double = 0, align: ButtonAlignment = .left) {
        self.id = id
        self.title = title
        self.onDeactivate = onDeactivate
        self.scripts = scripts
        self.source = source
        self.cwd = cwd
        self.environment = environment
        self.runner = runner
        self.marginLeft = marginLeft
        self.marginRight = marginRight
        self.align = align
    }
}

public func resolvePath(_ path: String, relativeTo base: URL) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return expanded.hasPrefix("/") ? expanded : base.appending(path: expanded).standardizedFileURL.path
}

public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    public var displayCommand: String {
        command ?? ([executable ?? ""] + arguments).map(shellQuote).joined(separator: " ")
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

import Foundation
import Yams

public struct ConfigurationLoader: Sendable {
    public static var defaultURL: URL {
        defaultURL(environment: ProcessInfo.processInfo.environment,
                   homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    public static func defaultURL(environment: [String: String], homeDirectory: URL,
                                  fileManager: FileManager = .default) -> URL {
        for key in ["MODE_RUNNER_CONFIG", "SCRIPT_MODE_RUNNER_CONFIG"] {
            if let configured = environment[key], !configured.isEmpty {
                return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
            }
        }
        let current = homeDirectory.appending(path: ".config/mode-runner/config.yaml")
        let legacy = homeDirectory.appending(path: ".config/script-mode-runner/config.yaml")
        // Keep existing relative paths anchored to the original configuration directory.
        if !fileManager.fileExists(atPath: current.path), fileManager.fileExists(atPath: legacy.path) {
            return legacy
        }
        return current
    }

    public init() {}

    public func load(from url: URL = Self.defaultURL) throws -> RunnerConfiguration {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return try YAMLDecoder()
            .decode(RunnerConfiguration.self, from: text)
            .resolvingRelativePaths(relativeTo: url.deletingLastPathComponent())
            .validated()
    }
}

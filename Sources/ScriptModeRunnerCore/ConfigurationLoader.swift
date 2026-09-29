import Foundation
import Yams

public struct ConfigurationLoader: Sendable {
    public static var defaultURL: URL {
        if let configured = ProcessInfo.processInfo.environment["SCRIPT_MODE_RUNNER_CONFIG"], !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/script-mode-runner/config.yaml")
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

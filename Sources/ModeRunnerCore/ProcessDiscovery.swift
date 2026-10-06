import Darwin
import Foundation

public struct ProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public let pid: Int32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64

    public static func read(pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_uid == getuid(), info.pbi_status != SZOMB else { return nil }
        return ProcessIdentity(pid: pid, startedSeconds: info.pbi_start_tvsec,
                               startedMicroseconds: info.pbi_start_tvusec)
    }

    public var isAlive: Bool { Self.read(pid: pid) == self }
}

public struct DiscoveredProcess: Sendable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let arguments: [String]
    public let cwd: String

    public static func snapshot() -> [DiscoveredProcess] {
        let capacity = max(256, Int(proc_listallpids(nil, 0)) + 256)
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return pids.prefix(max(0, min(Int(count), capacity))).compactMap { pid in
            guard pid > 0, pid != getpid(), let identity = ProcessIdentity.read(pid: pid) else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
            var paths = proc_vnodepathinfo()
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, Int32(MemoryLayout.size(ofValue: paths))) == MemoryLayout.size(ofValue: paths) else { return nil }
            let cwd = withUnsafePointer(to: &paths.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard !cwd.isEmpty, let arguments = arguments(pid: pid), !arguments.isEmpty else { return nil }
            return DiscoveredProcess(identity: identity, parentPID: Int32(info.pbi_ppid), arguments: arguments, cwd: cwd)
        }
    }

    private static func arguments(pid: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var bytes = [UInt8](repeating: 0, count: 1_048_576)
        var size = bytes.count
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0, argc < 100_000 else { return nil }
        var offset = MemoryLayout<Int32>.size
        while offset < size && bytes[offset] != 0 { offset += 1 }
        while offset < size && bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            let start = offset
            while offset < size && bytes[offset] != 0 { offset += 1 }
            guard offset < size else { return nil }
            arguments.append(String(decoding: bytes[start..<offset], as: UTF8.self))
            offset += 1
        }
        return arguments
    }
}

public enum ProcessDiscovery {
    public static func matches(_ process: DiscoveredProcess, script: RunnerScript) -> Bool {
        // Working directory is mandatory: a command or occupied port alone is not ownership.
        guard let cwd = script.cwd,
              canonicalPath(cwd) == canonicalPath(process.cwd) else { return false }
        let spec = script.launchSpec()
        if equivalentArguments(process.arguments, [spec.executable] + spec.arguments) { return true }
        guard let command = script.command, let arguments = simpleCommandArguments(command) else { return false }
        return equivalentArguments(process.arguments, arguments)
    }

    public static func roots(matching script: RunnerScript, in processes: [DiscoveredProcess]) -> [DiscoveredProcess] {
        let candidates = processes.filter { matches($0, script: script) }
        let matchedPIDs = Set(candidates.map { $0.identity.pid })
        let parents = Dictionary(processes.map { ($0.identity.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
        return candidates.filter { process in
            var parent = process.parentPID
            var visited: Set<Int32> = []
            while parent > 1 && visited.insert(parent).inserted {
                if matchedPIDs.contains(parent) { return false }
                parent = parents[parent] ?? 0
            }
            return true
        }
    }

    static func simpleCommandArguments(_ command: String) -> [String]? {
        var arguments: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in command {
            if escaped { token.append(character); escaped = false; started = true; continue }
            if character == "\\", quote != "'" { escaped = true; started = true; continue }
            if let delimiter = quote {
                if character == delimiter { quote = nil }
                else {
                    if delimiter == "\"", "$`".contains(character) { return nil }
                    token.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" { quote = character; started = true }
            else if character.isWhitespace {
                if started { arguments.append(token); token = ""; started = false }
            } else if ";&|><$`()\n".contains(character) { return nil }
            else { token.append(character); started = true }
        }
        guard quote == nil, !escaped else { return nil }
        if started { arguments.append(token) }
        return arguments.isEmpty ? nil : arguments
    }

    private static func equivalentArguments(_ actual: [String], _ expected: [String]) -> Bool {
        guard !actual.isEmpty, !expected.isEmpty else { return false }
        var actual = actual
        // Yarn is commonly invoked through Node, including its absolute yarn.js path.
        if ["node", "nodejs"].contains(URL(fileURLWithPath: actual[0]).lastPathComponent), actual.count > 1,
           ["yarn", "yarn.js", "yarn.cjs"].contains(URL(fileURLWithPath: actual[1]).lastPathComponent) {
            actual.removeFirst()
        }
        let actualName = URL(fileURLWithPath: actual[0]).lastPathComponent
        let expectedName = URL(fileURLWithPath: expected[0]).lastPathComponent
        let sameExecutable = actualName == expectedName ||
            (expectedName == "yarn" && ["yarn.js", "yarn.cjs"].contains(actualName))
        guard sameExecutable, Array(actual.dropFirst()) == Array(expected.dropFirst()) else { return false }
        // Absolute executable paths must identify the same executable, except Yarn's Node wrapper.
        if expected[0].hasPrefix("/"), actualName == expectedName {
            return canonicalPath(actual[0]) == canonicalPath(expected[0])
        }
        return true
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

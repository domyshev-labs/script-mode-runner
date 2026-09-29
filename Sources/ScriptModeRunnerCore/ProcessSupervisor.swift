import Darwin
import Foundation

public enum OutputStream: Sendable { case stdout, stderr }

public enum ProcessStatus: Equatable, Sendable {
    case starting
    case running(pid: Int32)
    case stopping
    case exited(code: Int32)
    case signalled(signal: Int32)
    case failed(message: String)
}

public enum ProcessEvent: Sendable {
    case output(runID: String, stream: OutputStream, data: Data)
    case status(runID: String, status: ProcessStatus)
}

public enum ProcessSupervisorError: LocalizedError {
    case duplicateRun(String)
    case spawnFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case let .duplicateRun(id): "Process '\(id)' is already running"
        case let .spawnFailed(path, code): "Could not start \(path): \(String(cString: strerror(code)))"
        }
    }
}

public actor ProcessSupervisor {
    public typealias EventHandler = @Sendable (ProcessEvent) -> Void

    private struct RunningProcess {
        let pid: pid_t
        let stdout: FileHandle
        let stderr: FileHandle
    }

    private var processes: [String: RunningProcess] = [:]
    private let eventHandler: EventHandler

    public init(eventHandler: @escaping EventHandler) {
        self.eventHandler = eventHandler
    }

    @discardableResult
    public func start(runID: String, spec: LaunchSpec) throws -> pid_t {
        guard processes[runID] == nil else { throw ProcessSupervisorError.duplicateRun(runID) }
        eventHandler(.status(runID: runID, status: .starting))

        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw ProcessSupervisorError.spawnFailed(spec.executable, errno)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&actions, stderrPipe[0])
        if let cwd = spec.cwd {
            posix_spawn_file_actions_addchdir_np(&actions, cwd)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        let environment = ProcessInfo.processInfo.environment.merging(spec.environment) { _, configured in configured }
        let args = [spec.executable] + spec.arguments
        let result = withCStringArray(args) { argv in
            withCStringArray(environment.map { "\($0.key)=\($0.value)" }) { envp in
                posix_spawnp(&pid, spec.executable, &actions, &attributes, argv, envp)
            }
        }
        close(stdoutPipe[1])
        close(stderrPipe[1])

        guard result == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            eventHandler(.status(runID: runID, status: .failed(message: String(cString: strerror(result)))))
            throw ProcessSupervisorError.spawnFailed(spec.executable, result)
        }

        let stdout = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
        let stderr = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
        processes[runID] = RunningProcess(pid: pid, stdout: stdout, stderr: stderr)
        attach(stdout, runID: runID, stream: .stdout)
        attach(stderr, runID: runID, stream: .stderr)
        eventHandler(.status(runID: runID, status: .running(pid: pid)))
        waitForExit(runID: runID, pid: pid)
        return pid
    }

    public func stop(runID: String, policy: DeactivationPolicy) async {
        guard let process = processes[runID] else { return }
        eventHandler(.status(runID: runID, status: .stopping))
        if policy.sigint { killpg(process.pid, SIGINT) }
        if policy.sigkill {
            if policy.sigint {
                let nanos = UInt64(max(0, policy.timeout.seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
            if processes[runID] != nil { killpg(process.pid, SIGKILL) }
        }
    }

    public func stopAll(policy: DeactivationPolicy = .init(sigint: true, sigkill: true, timeout: .seconds(2))) async {
        let ids = Array(processes.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.stop(runID: id, policy: policy) } }
        }
    }

    private func attach(_ handle: FileHandle, runID: String, stream: OutputStream) {
        let handler = eventHandler
        handle.readabilityHandler = { file in
            let data = file.availableData
            if !data.isEmpty { handler(.output(runID: runID, stream: stream, data: data)) }
        }
    }

    private func waitForExit(runID: String, pid: pid_t) {
        Task.detached { [weak self] in
            var status: Int32 = 0
            let result = waitpid(pid, &status, 0)
            guard result > 0 else { return }
            await self?.didExit(runID: runID, rawStatus: status)
        }
    }

    private func didExit(runID: String, rawStatus: Int32) {
        guard let process = processes.removeValue(forKey: runID) else { return }
        process.stdout.readabilityHandler = nil
        process.stderr.readabilityHandler = nil
        let finalStatus: ProcessStatus
        let termination = rawStatus & 0x7f
        if termination == 0 {
            finalStatus = .exited(code: (rawStatus >> 8) & 0xff)
        } else {
            finalStatus = .signalled(signal: termination)
        }
        eventHandler(.status(runID: runID, status: finalStatus))
    }
}

private func withCStringArray<R>(_ strings: [String], body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    let pointers = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    return body(pointers + [nil])
}

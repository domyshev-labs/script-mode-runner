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
    case unobservedExit
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
        let stdoutReader: OutputReader
        let stderrReader: OutputReader
    }

    private var processes: [String: RunningProcess] = [:]
    private var adopted: [String: ProcessIdentity] = [:]
    private let eventHandler: EventHandler

    public init(eventHandler: @escaping EventHandler) {
        self.eventHandler = eventHandler
    }

    @discardableResult
    public func start(runID: String, spec: LaunchSpec) throws -> pid_t {
        guard processes[runID] == nil, adopted[runID] == nil else { throw ProcessSupervisorError.duplicateRun(runID) }
        eventHandler(.status(runID: runID, status: .starting))

        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw ProcessSupervisorError.spawnFailed(spec.executable, errno)
        }
        for descriptor in stdoutPipe + stderrPipe {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
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
        let stdoutReader = OutputReader(handle: stdout, runID: runID, stream: .stdout, handler: eventHandler)
        let stderrReader = OutputReader(handle: stderr, runID: runID, stream: .stderr, handler: eventHandler)
        processes[runID] = RunningProcess(pid: pid, stdout: stdout, stderr: stderr, stdoutReader: stdoutReader, stderrReader: stderrReader)
        stdout.readabilityHandler = { [weak stdoutReader] _ in stdoutReader?.drain() }
        stderr.readabilityHandler = { [weak stderrReader] _ in stderrReader?.drain() }
        eventHandler(.status(runID: runID, status: .running(pid: pid)))
        waitForExit(runID: runID, pid: pid)
        return pid
    }

    public func stop(runID: String, policy: DeactivationPolicy) async {
        if let identity = adopted[runID] {
            await stopAdopted(runID: runID, identity: identity, policy: policy)
            return
        }
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
        let ids = Array(processes.keys) + Array(adopted.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.stop(runID: id, policy: policy) } }
        }
    }

    public func adopt(runID: String, process: DiscoveredProcess) -> Bool {
        guard processes[runID] == nil, adopted[runID] == nil, process.identity.isAlive,
              !processes.values.contains(where: { $0.pid == process.identity.pid }),
              !adopted.values.contains(process.identity) else { return false }
        adopted[runID] = process.identity
        eventHandler(.status(runID: runID, status: .running(pid: process.identity.pid)))
        Task { [weak self] in
            while process.identity.isAlive {
                try? await Task.sleep(for: .milliseconds(200))
                guard await self?.isAdopted(runID: runID, identity: process.identity) == true else { return }
            }
            await self?.adoptedDidExit(runID: runID, identity: process.identity)
        }
        return true
    }

    private func isAdopted(runID: String, identity: ProcessIdentity) -> Bool { adopted[runID] == identity }

    private func adoptedDidExit(runID: String, identity: ProcessIdentity) {
        guard adopted[runID] == identity else { return }
        adopted[runID] = nil
        eventHandler(.status(runID: runID, status: .unobservedExit))
    }

    private func stopAdopted(runID: String, identity: ProcessIdentity, policy: DeactivationPolicy) async {
        guard identity.isAlive else { adoptedDidExit(runID: runID, identity: identity); return }
        let snapshot = await Task.detached { DiscoveredProcess.snapshot() }.value
        var targets = [identity]
        var parents: Set<Int32> = [identity.pid]
        var changed = true
        while changed {
            changed = false
            for process in snapshot where parents.contains(process.parentPID) && !parents.contains(process.identity.pid) {
                parents.insert(process.identity.pid)
                targets.append(process.identity)
                changed = true
            }
        }
        guard identity.isAlive, adopted[runID] == identity else {
            adoptedDidExit(runID: runID, identity: identity)
            return
        }
        eventHandler(.status(runID: runID, status: .stopping))
        // Never signal an external process group: it may include the user's terminal.
        if policy.sigint {
            for target in targets.reversed() where target.isAlive { kill(target.pid, SIGINT) }
        }
        if policy.sigkill {
            if policy.sigint { try? await Task.sleep(for: .seconds(max(0, policy.timeout.seconds))) }
            for target in targets.reversed() where target.isAlive { kill(target.pid, SIGKILL) }
        }
    }

    public func preserveOutput(executablePath: String) throws {
        // Keep both pipes readable after the UI exits so writers never receive SIGPIPE.
        for process in processes.values {
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_adddup2(&actions, process.stdout.fileDescriptor, 0)
            posix_spawn_file_actions_adddup2(&actions, process.stderr.fileDescriptor, 3)
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
            posix_spawnattr_setpgroup(&attributes, 0)
            var pid: pid_t = 0
            let result = withCStringArray([executablePath, "--drain-process-output"]) { argv in
                withCStringArray(ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }) { envp in
                    posix_spawn(&pid, executablePath, &actions, &attributes, argv, envp)
                }
            }
            guard result == 0 else { throw ProcessSupervisorError.spawnFailed(executablePath, result) }
        }
    }

    public nonisolated static func drainInheritedOutput() {
        var descriptors = [pollfd(fd: 0, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: 3, events: Int16(POLLIN), revents: 0)]
        var bytes = [UInt8](repeating: 0, count: 8192)
        while descriptors.contains(where: { $0.fd >= 0 }) {
            let result = poll(&descriptors, nfds_t(descriptors.count), -1)
            if result < 0 {
                if errno == EINTR { continue }
                break
            }
            for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                let count = read(descriptors[index].fd, &bytes, bytes.count)
                if count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN) {
                    close(descriptors[index].fd)
                    descriptors[index].fd = -1
                }
            }
        }
    }

    private func waitForExit(runID: String, pid: pid_t) {
        Task.detached { [weak self] in
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
            guard result > 0 else {
                let code = errno
                await self?.waitFailed(runID: runID, code: code)
                return
            }
            await self?.didExit(runID: runID, rawStatus: status)
        }
    }

    private func waitFailed(runID: String, code: Int32) {
        guard let process = processes.removeValue(forKey: runID) else { return }
        process.stdout.readabilityHandler = nil
        process.stderr.readabilityHandler = nil
        process.stdoutReader.drain()
        process.stderrReader.drain()
        eventHandler(.status(runID: runID, status: .failed(message: "Could not observe process exit: " + String(cString: strerror(code)))))
    }

    private func didExit(runID: String, rawStatus: Int32) {
        guard let process = processes.removeValue(forKey: runID) else { return }
        process.stdout.readabilityHandler = nil
        process.stderr.readabilityHandler = nil
        process.stdoutReader.drain()
        process.stderrReader.drain()
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

private final class OutputReader: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let runID: String
    private let stream: OutputStream
    private let handler: ProcessSupervisor.EventHandler

    init(handle: FileHandle, runID: String, stream: OutputStream, handler: @escaping ProcessSupervisor.EventHandler) {
        self.handle = handle; self.runID = runID; self.stream = stream; self.handler = handler
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    func drain() {
        lock.withLock {
            var bytes = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(handle.fileDescriptor, &bytes, bytes.count)
                if count > 0 { handler(.output(runID: runID, stream: stream, data: Data(bytes.prefix(count)))) }
                else if count < 0 && errno == EINTR { continue }
                else { break }
            }
        }
    }
}

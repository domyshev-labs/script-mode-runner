import AppKit
import Combine
import Foundation
import ScriptModeRunnerCore

struct ScriptLog {
    var buffer = ByteRingBuffer()
    var status: ProcessStatus?

    var latestRunningLink: URL? {
        guard case .running = status else { return nil }
        return detectedLogLinks(in: stripTerminalEscapes(buffer.string)).last?.url
    }
}

struct ScriptRun: Identifiable {
    let id: String
    let tabID: String
    let batchID: String
    let buttonID: String
    let script: RunnerScript
    let policy: DeactivationPolicy
    let isMenu: Bool
    let isSeed: Bool
    let contextModeID: String?
    var requestedStop = false
}

enum ButtonActivity { case idle, transitioning, running, partial, failed }

struct CatalogState {
    var items: [MenuItem] = []
    var loading = false
    var error: String?
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var configuration: RunnerConfiguration?
    @Published private(set) var errorMessage: String?
    @Published var selectedTabID: String? { didSet { selectVisibleOutput() } }
    @Published var selectedOutputID: String?
    @Published private(set) var viewedModes: [String: String] = [:]
    @Published private(set) var activeModes: [String: String] = [:]
    @Published private(set) var logs: [String: ScriptLog] = [:]
    @Published private(set) var runs: [ScriptRun] = []
    @Published private(set) var catalogs: [String: CatalogState] = [:]
    @Published private(set) var busyTabs: Set<String> = []
    @Published private(set) var restartingRuns: Set<String> = []

    let configURL: URL
    private let relay: EventRelay
    private let supervisor: ProcessSupervisor
    private var catalogTasks: [String: Task<Void, Never>] = [:]

    init(configURL: URL = ConfigurationLoader.defaultURL) {
        self.configURL = configURL
        let relay = EventRelay()
        self.relay = relay
        supervisor = ProcessSupervisor { event in relay.receive(event) }
        relay.owner = self
        reload()
    }

    var selectedTab: RunnerTab? { configuration?.tabs.first { $0.id == selectedTabID } }
    var visibleScripts: [ScriptRun] {
        let context = selectedTabID.flatMap { viewedModes[$0] }
        let candidates = runs.filter { $0.tabID == selectedTabID && $0.contextModeID == context }
        // A configured script owns one visible log; restarting replaces its displayed run.
        var seen = Set<String>()
        return candidates.reversed().filter { seen.insert($0.isMenu ? $0.id : "\($0.buttonID)/\($0.script.id)").inserted }.reversed()
    }
    var selectedRun: ScriptRun? { runs.first { $0.id == selectedOutputID } }

    func catalogKey(_ button: RunnerMode, tab: RunnerTab) -> String { "\(tab.id)/\(button.id)" }

    func reload() {
        do {
            let loaded = try ConfigurationLoader().load(from: configURL)
            // Keep removed tabs reachable while they still own logs or processes.
            let retained = configuration?.tabs.filter { old in
                !loaded.tabs.contains { $0.id == old.id } && runs.contains { $0.tabID == old.id }
            } ?? []
            configuration = RunnerConfiguration(tabs: loaded.tabs + retained)
            errorMessage = nil
            if !configuration!.tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = configuration?.tabs.first?.id }
            for task in catalogTasks.values { task.cancel() }
            catalogTasks = [:]
            catalogs = [:]
            for tab in configuration!.tabs {
                for button in tab.buttons where button.source != nil { refreshCatalog(button, in: tab) }
            }
            selectVisibleOutput()
        } catch { errorMessage = "\(configURL.path)\n\(error.localizedDescription)" }
    }

    func refreshCatalog(_ button: RunnerMode, in tab: RunnerTab) {
        let key = catalogKey(button, tab: tab)
        guard catalogTasks[key] == nil else { return }
        catalogs[key] = CatalogState(items: catalogs[key]?.items ?? [], loading: true)
        catalogTasks[key] = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { catalogTasks[key] = nil } }
            do {
                let items = try await MenuLoader().load(button, relativeTo: configURL.deletingLastPathComponent())
                guard !Task.isCancelled else { return }
                catalogs[key] = CatalogState(items: items)
            } catch {
                guard !Task.isCancelled else { return }
                catalogs[key] = CatalogState(error: error.localizedDescription)
            }
        }
    }

    func activity(_ button: RunnerMode, in tab: RunnerTab) -> ButtonActivity {
        let history = runs.filter { $0.tabID == tab.id && $0.buttonID == button.id }
        let relevant = button.source != nil ? history : history.filter { $0.batchID == history.last?.batchID }
        if relevant.contains(where: { isTransitioning(logs[$0.id]?.status) }) { return .transitioning }
        let running = relevant.filter { if case .running = logs[$0.id]?.status { return true }; return false }
        if !running.isEmpty {
            if button.source != nil { return .running }
            return running.count == button.scripts.count ? .running : .partial
        }
        let completed = button.source != nil ? Array(relevant.suffix(1)) : relevant
        if completed.contains(where: { run in
            guard !run.requestedStop else { return false }
            switch logs[run.id]?.status {
            case .failed, .signalled: return true
            case let .exited(code) where code != 0: return true
            default: return false
            }
        }) { return .failed }
        return .idle
    }

    func toggle(_ mode: RunnerMode, in tab: RunnerTab) {
        guard !busyTabs.contains(tab.id) else { return }
        busyTabs.insert(tab.id)
        Task {
            defer { busyTabs.remove(tab.id) }
            let live = runs.filter { $0.tabID == tab.id && !$0.isMenu && logs[$0.id]?.status?.isRunning == true }
            let same = live.filter { $0.buttonID == mode.id }
            if !same.isEmpty {
                for run in same { await stop(run.id) }
                activeModes[tab.id] = nil
            } else {
                for run in live { await stop(run.id) }
                for _ in 0..<100 where live.contains(where: { logs[$0.id]?.status?.isRunning == true }) {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                guard !live.contains(where: { logs[$0.id]?.status?.isRunning == true }) else {
                    errorMessage = "The previous mode is still stopping. Stop its processes before starting another mode."
                    return
                }
                viewedModes[tab.id] = mode.id
                selectVisibleOutput()
                activeModes[tab.id] = mode.id
                let batchID = UUID().uuidString
                for (index, script) in mode.scripts.enumerated() {
                    await start(script, button: mode, tab: tab, batchID: batchID, selectOutput: index == 0)
                }
            }
        }
    }

    func seedIsRunning(_ button: RunnerMode) -> Bool {
        guard button.source?.type != .packageScripts else { return false }
        return runs.contains { $0.isSeed && $0.script.cwd == button.cwd && logs[$0.id]?.status?.isRunning == true }
    }

    func launch(_ item: MenuItem, button: RunnerMode, tab: RunnerTab, parameterValue: String? = nil) {
        guard !seedIsRunning(button) else { return }
        // Reserve the run synchronously to prevent double-clicks from racing.
        let script = item.script(for: button, parameterValue: parameterValue)
        let id = reserve(script, button: button, tab: tab, isMenu: true)
        Task { await execute(id, script: script) }
    }

    private func reserve(_ script: RunnerScript, button: RunnerMode, tab: RunnerTab, isMenu: Bool, batchID: String? = nil, selectOutput: Bool = true) -> String {
        let id = UUID().uuidString
        runs.append(ScriptRun(id: id, tabID: tab.id, batchID: batchID ?? id, buttonID: button.id, script: script, policy: button.onDeactivate, isMenu: isMenu, isSeed: isMenu && button.source?.type != .packageScripts, contextModeID: isMenu ? viewedModes[tab.id] : button.id))
        logs[id] = ScriptLog(status: .starting)
        if selectOutput && selectedTabID == tab.id { selectedOutputID = id }
        pruneHistory()
        return id
    }

    private func start(_ script: RunnerScript, button: RunnerMode, tab: RunnerTab, batchID: String, selectOutput: Bool) async {
        let id = reserve(script, button: button, tab: tab, isMenu: false, batchID: batchID, selectOutput: selectOutput)
        await execute(id, script: script)
    }

    private func execute(_ id: String, script: RunnerScript) async {
        do { try await supervisor.start(runID: id, spec: script.launchSpec()) }
        catch { logs[id]?.status = .failed(message: error.localizedDescription) }
    }

    func stop(_ id: String) async {
        guard let index = runs.firstIndex(where: { $0.id == id }), logs[id]?.status?.isRunning == true else { return }
        runs[index].requestedStop = true
        let configured = runs[index].policy
        let policy = configured.sigint || configured.sigkill ? configured : .init(sigint: true, sigkill: true, timeout: .seconds(2))
        await supervisor.stop(runID: id, policy: policy)
    }

    func stopSelected() { if let id = selectedOutputID { Task { await stop(id) } } }

    func reloadSelected() {
        guard let run = selectedRun, case .running = logs[run.id]?.status,
              !busyTabs.contains(run.tabID), !restartingRuns.contains(run.id) else { return }
        restartingRuns.insert(run.id)
        busyTabs.insert(run.tabID)
        Task {
            defer {
                restartingRuns.remove(run.id)
                busyTabs.remove(run.tabID)
            }
            await stop(run.id)
            // Exit events arrive through the relay after the supervisor releases the process.
            for _ in 0..<100 where logs[run.id]?.status?.isRunning == true {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard logs[run.id]?.status?.isRunning == false,
                  let index = runs.firstIndex(where: { $0.id == run.id }) else {
                errorMessage = "The selected process is still stopping. Wait before reloading it."
                return
            }
            runs[index].requestedStop = false
            logs[run.id] = ScriptLog(status: .starting)
            if !run.isMenu { activeModes[run.tabID] = run.buttonID }
            await execute(run.id, script: run.script)
        }
    }

    func close(_ id: String) {
        guard logs[id]?.status?.isRunning != true, !restartingRuns.contains(id) else { return }
        runs.removeAll { $0.id == id }
        logs[id] = nil
        selectVisibleOutput()
    }

    func clearSelectedLog() {
        guard let id = selectedOutputID else { return }
        logs[id]?.buffer.removeAll()
    }

    func shutdown() async {
        for task in catalogTasks.values { task.cancel() }
        let tasks = Array(catalogTasks.values)
        for task in tasks { await task.value }
        await supervisor.stopAll()
    }

    private func selectVisibleOutput() {
        if !visibleScripts.contains(where: { $0.id == selectedOutputID }) { selectedOutputID = visibleScripts.last?.id }
    }

    private func pruneHistory() {
        for tabID in Set(runs.map(\.tabID)) {
            let finished = runs.filter { $0.tabID == tabID && logs[$0.id]?.status?.isRunning != true && $0.id != selectedOutputID }
            for run in finished.prefix(max(0, finished.count - 20)) { close(run.id) }
        }
        let budget = 100 * 1024 * 1024
        if logs.values.reduce(0, { $0 + $1.buffer.count }) > budget {
            let limit = budget / max(1, logs.count)
            for id in Array(logs.keys) { logs[id]?.buffer.trim(to: limit) }
        }
    }

    fileprivate func receive(_ event: ProcessEvent) {
        switch event {
        case let .output(id, stream, data):
            guard logs[id] != nil else { return }
            if stream == .stderr { logs[id]?.buffer.append(Data("[stderr] ".utf8)) }
            logs[id]?.buffer.append(data)
        case let .status(id, status):
            guard logs[id] != nil else { return }
            logs[id]?.status = status
            if !status.isRunning, let run = runs.first(where: { $0.id == id }), !run.isMenu,
               !runs.contains(where: { $0.tabID == run.tabID && !$0.isMenu && logs[$0.id]?.status?.isRunning == true }) {
                activeModes[run.tabID] = nil
            }
        }
        pruneHistory()
    }
}

// One stream preserves event ordering across output and exit notifications.
private final class EventRelay: @unchecked Sendable {
    weak var owner: AppState?
    private let continuation: AsyncStream<ProcessEvent>.Continuation
    init() {
        let pair = AsyncStream<ProcessEvent>.makeStream()
        continuation = pair.continuation
        Task { @MainActor [weak self] in
            for await event in pair.stream { self?.owner?.receive(event) }
        }
    }
    deinit { continuation.finish() }
    func receive(_ event: ProcessEvent) { continuation.yield(event) }
}

private func isTransitioning(_ status: ProcessStatus?) -> Bool {
    switch status { case .starting, .stopping: true; default: false }
}

extension ProcessStatus {
    var displayText: String {
        switch self {
        case .starting: "Starting"
        case let .running(pid): "Running · PID \(pid)"
        case .stopping: "Stopping"
        case let .exited(code): code == 0 ? "Finished" : "Error · code \(code)"
        case let .signalled(signal): "Stopped · signal \(signal)"
        case let .failed(message): "Not running · \(message)"
        }
    }
    var isRunning: Bool {
        switch self { case .starting, .running, .stopping: true; default: false }
    }
}

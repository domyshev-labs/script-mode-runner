import AppKit
import Combine
import Foundation
import ModeRunnerCore

struct ScriptLog {
    var buffer = ByteRingBuffer()
    var status: ProcessStatus?
    var configuredRunningLink: URL?
    var hasDetectionMessage = false

    var latestRunningLink: URL? {
        guard case .running = status else { return nil }
        return detectedLogLinks(in: stripTerminalEscapes(buffer.string)).last?.url ?? configuredRunningLink
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

enum LifecycleAction { case start, restart, stop }

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
    @Published private(set) var transitioningModes: [String: Set<String>] = [:]
    @Published private(set) var restartingRuns: Set<String> = []
    @Published private(set) var startingRuns: Set<String> = []
    @Published private(set) var stoppingRuns: Set<String> = []
    @Published private(set) var modeActions: [String: LifecycleAction] = [:]

    let configURL: URL
    private let relay: EventRelay
    private let supervisor: ProcessSupervisor
    private let preferences: UserDefaults
    private let legacyPreferences: UserDefaults?
    private var tabOrderKey: String { "projectTabOrder/\(configURL.standardizedFileURL.path)" }
    private var catalogTasks: [String: Task<Void, Never>] = [:]
    private var discoveryTask: Task<Void, Never>?
    @Published private(set) var discoveringProcesses = false

    init(configURL: URL = ConfigurationLoader.defaultURL, preferences: UserDefaults = .standard,
         legacyPreferences: UserDefaults? = UserDefaults(suiteName: "dev.domyshev.script-mode-runner")) {
        self.configURL = configURL
        self.preferences = preferences
        self.legacyPreferences = legacyPreferences
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
            let tabs = loaded.tabs + retained
            let savedOrder = preferences.stringArray(forKey: tabOrderKey)
                ?? legacyPreferences?.stringArray(forKey: tabOrderKey) ?? []
            if preferences.stringArray(forKey: tabOrderKey) == nil, !savedOrder.isEmpty {
                preferences.set(savedOrder, forKey: tabOrderKey)
            }
            let positions = Dictionary(savedOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            configuration = RunnerConfiguration(tabs: tabs.enumerated().sorted {
                let left = positions[$0.element.id] ?? savedOrder.count + $0.offset
                let right = positions[$1.element.id] ?? savedOrder.count + $1.offset
                return left < right
            }.map(\.element))
            errorMessage = nil
            if !configuration!.tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = configuration?.tabs.first?.id }
            for task in catalogTasks.values { task.cancel() }
            catalogTasks = [:]
            catalogs = [:]
            for tab in configuration!.tabs {
                let modes = tab.buttons.filter { $0.source == nil }
                if !modes.contains(where: { $0.id == viewedModes[tab.id] }) {
                    viewedModes[tab.id] = modes.first?.id
                }
                for button in tab.buttons where button.source != nil { refreshCatalog(button, in: tab) }
            }
            selectVisibleOutput()
            discoverExistingProcesses()
        } catch { errorMessage = "\(configURL.path)\n\(error.localizedDescription)" }
    }

    private func discoverExistingProcesses() {
        discoveryTask?.cancel()
        discoveringProcesses = true
        discoveryTask = Task { [weak self] in
            let snapshot = await Task.detached { DiscoveredProcess.snapshot() }.value
            guard !Task.isCancelled, let self, let configuration else { return }
            defer { discoveringProcesses = false }
            var adoptedTabs: Set<String> = []
            for tab in configuration.tabs {
                for mode in tab.buttons where mode.source == nil {
                    let batchID = runs.last(where: {
                        $0.tabID == tab.id && $0.buttonID == mode.id && !$0.isMenu &&
                        logs[$0.id]?.status?.isRunning == true
                    })?.batchID ?? UUID().uuidString
                    for script in mode.scripts {
                        guard !Task.isCancelled else { return }
                        guard !runs.contains(where: {
                            $0.tabID == tab.id && $0.buttonID == mode.id && $0.script.id == script.id &&
                            logs[$0.id]?.status?.isRunning == true
                        }) else { continue }
                        let candidates = ProcessDiscovery.roots(matching: script, in: snapshot)
                        // Ambiguous matches must not give Stop control over an arbitrary process.
                        guard candidates.count == 1, let process = candidates.first else { continue }
                        let id = reserve(script, button: mode, tab: tab, isMenu: false,
                                         batchID: batchID, selectOutput: false)
                        if await supervisor.adopt(runID: id, process: process) {
                            logs[id]?.status = .running(pid: process.identity.pid)
                            logs[id]?.configuredRunningLink = configuredLocalURL(for: script)
                            logs[id]?.hasDetectionMessage = true
                            logs[id]?.buffer.append(Data(existingProcessMessage(script: script, location: process.cwd).utf8))
                            adoptedTabs.insert(tab.id)
                        } else {
                            runs.removeAll { $0.id == id }
                            logs[id] = nil
                        }
                    }
                    // Restore stopped commands alongside any discovered processes in this mode.
                    if runs.contains(where: {
                        $0.tabID == tab.id && $0.buttonID == mode.id && !$0.isMenu &&
                        logs[$0.id]?.status?.isRunning == true
                    }) {
                        for script in mode.scripts where !runs.contains(where: {
                            $0.tabID == tab.id && $0.buttonID == mode.id && !$0.isMenu && $0.script.id == script.id
                        }) {
                            let id = reserve(script, button: mode, tab: tab, isMenu: false,
                                             batchID: batchID, selectOutput: false)
                            logs[id]?.status = .notRunning
                        }
                    }
                }
            }
            for tab in configuration.tabs where adoptedTabs.contains(tab.id) {
                if let mode = runningMode(in: tab) {
                    activeModes[tab.id] = mode.id
                    viewedModes[tab.id] = mode.id
                }
            }
            selectVisibleOutput()
        }
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
        if transitioningModes[tab.id]?.contains(button.id) == true { return .transitioning }
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

    func moveTab(_ sourceID: String, to targetID: String) -> Bool {
        guard var tabs = configuration?.tabs,
              let source = tabs.firstIndex(where: { $0.id == sourceID }),
              let target = tabs.firstIndex(where: { $0.id == targetID }), source != target else { return false }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: target)
        configuration = RunnerConfiguration(tabs: tabs)
        preferences.set(tabs.map(\.id), forKey: tabOrderKey)
        return true
    }

    func selectMode(_ mode: RunnerMode, in tab: RunnerTab) {
        guard mode.source == nil, tab.buttons.contains(where: { $0.id == mode.id }) else { return }
        viewedModes[tab.id] = mode.id
        selectVisibleOutput()
    }

    func selectedMode(in tab: RunnerTab) -> RunnerMode? {
        let modes = tab.buttons.filter { $0.source == nil }
        return modes.first { $0.id == viewedModes[tab.id] } ?? modes.first
    }

    func runningMode(in tab: RunnerTab) -> RunnerMode? {
        tab.buttons.first { mode in
            mode.source == nil && runs.contains {
                $0.tabID == tab.id && !$0.isMenu && $0.buttonID == mode.id && logs[$0.id]?.status?.isRunning == true
            }
        }
    }

    func startMode(_ mode: RunnerMode, in tab: RunnerTab) {
        guard runningMode(in: tab)?.id != mode.id else { return }
        guard !busyTabs.contains(tab.id) else { return }
        selectMode(mode, in: tab)
        transition(mode, in: tab, startAfterStop: true, skipIfAlreadyRunning: true)
    }

    func stopMode(_ mode: RunnerMode, in tab: RunnerTab) {
        guard runningMode(in: tab)?.id == mode.id else { return }
        transition(mode, in: tab, startAfterStop: false)
    }

    func restartMode(_ mode: RunnerMode, in tab: RunnerTab) {
        guard runningMode(in: tab)?.id == mode.id else { return }
        transition(mode, in: tab, startAfterStop: true, action: .restart)
    }

    func toggle(_ mode: RunnerMode, in tab: RunnerTab) {
        transition(mode, in: tab, startAfterStop: runningMode(in: tab)?.id != mode.id)
    }

    private func transition(_ mode: RunnerMode, in tab: RunnerTab, startAfterStop: Bool, skipIfAlreadyRunning: Bool = false,
                            action: LifecycleAction? = nil) {
        guard !busyTabs.contains(tab.id) else { return }
        busyTabs.insert(tab.id)
        modeActions[tab.id] = action ?? (startAfterStop ? .start : .stop)
        let live = runs.filter { $0.tabID == tab.id && !$0.isMenu && logs[$0.id]?.status?.isRunning == true }
        transitioningModes[tab.id] = live.isEmpty ? [mode.id] : Set(live.map(\.buttonID))
        Task {
            defer {
                transitioningModes[tab.id] = nil
                modeActions[tab.id] = nil
                busyTabs.remove(tab.id)
            }
            await discoveryTask?.value
            let stopping = runs.filter { $0.tabID == tab.id && !$0.isMenu && logs[$0.id]?.status?.isRunning == true }
            // Starting an already discovered mode must not duplicate or restart its processes.
            if skipIfAlreadyRunning, !stopping.isEmpty, stopping.allSatisfy({ $0.buttonID == mode.id }) {
                viewedModes[tab.id] = mode.id
                selectVisibleOutput()
                return
            }
            let stoppingModes: Set<String> = stopping.isEmpty ? [mode.id] : Set(stopping.map(\.buttonID))
            if transitioningModes[tab.id] != stoppingModes { transitioningModes[tab.id] = stoppingModes }
            for run in stopping { await stop(run.id) }
            for _ in 0..<100 where stopping.contains(where: { logs[$0.id]?.status?.isRunning == true }) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !stopping.contains(where: { logs[$0.id]?.status?.isRunning == true }) else {
                errorMessage = "The previous mode is still stopping. Stop its processes before starting another mode."
                return
            }
            if !startAfterStop {
                activeModes[tab.id] = nil
            } else {
                transitioningModes[tab.id] = [mode.id]
                viewedModes[tab.id] = mode.id
                selectVisibleOutput()
                activeModes[tab.id] = mode.id
                let batchID = UUID().uuidString
                for (index, script) in mode.scripts.enumerated() {
                    await start(script, button: mode, tab: tab, batchID: batchID, selectOutput: index == 0)
                }
                // Keep all mode buttons locked until the relay reports startup completion.
                while runs.contains(where: { $0.batchID == batchID && logs[$0.id]?.status == .starting }) {
                    try? await Task.sleep(for: .milliseconds(20))
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

    func stopSelected() {
        guard let run = selectedRun, logs[run.id]?.status?.isRunning == true,
              !busyTabs.contains(run.tabID), !restartingRuns.contains(run.id),
              !stoppingRuns.contains(run.id), logs[run.id]?.status != .stopping else { return }
        stoppingRuns.insert(run.id)
        busyTabs.insert(run.tabID)
        Task {
            defer {
                stoppingRuns.remove(run.id)
                busyTabs.remove(run.tabID)
            }
            await stop(run.id)
            // Keep the clicked button busy until the exit event reaches the UI.
            for _ in 0..<100 where logs[run.id]?.status?.isRunning == true {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    var canStartSelected: Bool {
        guard let run = selectedRun, logs[run.id]?.status?.isRunning == false,
              !busyTabs.contains(run.tabID), !startingRuns.contains(run.id),
              !restartingRuns.contains(run.id), !stoppingRuns.contains(run.id) else { return false }
        return canStart(run)
    }

    private func canStart(_ run: ScriptRun) -> Bool {
        !runs.contains { other in
            guard other.id != run.id, logs[other.id]?.status?.isRunning == true else { return false }
            if run.isSeed && other.isSeed && other.script.cwd == run.script.cwd { return true }
            guard other.tabID == run.tabID else { return false }
            if !run.isMenu && !other.isMenu && other.buttonID != run.buttonID { return true }
            return other.buttonID == run.buttonID && other.script == run.script
        }
    }

    func startSelected() {
        guard canStartSelected, let run = selectedRun else { return }
        startingRuns.insert(run.id)
        busyTabs.insert(run.tabID)
        let previousLog = logs[run.id]
        logs[run.id] = ScriptLog(status: .starting)
        Task {
            defer {
                startingRuns.remove(run.id)
                busyTabs.remove(run.tabID)
            }
            await discoveryTask?.value
            guard canStart(run) else {
                logs[run.id] = previousLog
                return
            }
            guard let index = runs.firstIndex(where: { $0.id == run.id }) else { return }
            runs[index].requestedStop = false
            if !run.isMenu { activeModes[run.tabID] = run.buttonID }
            await execute(run.id, script: run.script)
            while logs[run.id]?.status == .starting {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func reloadSelected() {
        guard let run = selectedRun, case .running = logs[run.id]?.status,
              !busyTabs.contains(run.tabID), !restartingRuns.contains(run.id),
              !stoppingRuns.contains(run.id) else { return }
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
            while logs[run.id]?.status == .starting {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func close(_ id: String) {
        guard logs[id]?.status?.isRunning != true, !startingRuns.contains(id),
              !restartingRuns.contains(id), !stoppingRuns.contains(id) else { return }
        runs.removeAll { $0.id == id }
        logs[id] = nil
        selectVisibleOutput()
    }

    func clearSelectedLog() {
        guard let id = selectedOutputID else { return }
        logs[id]?.buffer.removeAll()
    }

    func shutdown() async {
        discoveryTask?.cancel()
        await discoveryTask?.value
        for task in catalogTasks.values { task.cancel() }
        let tasks = Array(catalogTasks.values)
        await supervisor.stopAll()
        for task in tasks { await task.value }
    }

    func preserveProcesses(executablePath: String) async throws {
        discoveryTask?.cancel()
        await discoveryTask?.value
        for task in catalogTasks.values { task.cancel() }
        let tasks = Array(catalogTasks.values)
        try await supervisor.preserveOutput(executablePath: executablePath)
        for task in tasks { await task.value }
    }

    private func selectVisibleOutput() {
        let scripts = visibleScripts
        if !scripts.contains(where: { $0.id == selectedOutputID }) {
            selectedOutputID = scripts.first(where: { !$0.isMenu && logs[$0.id]?.hasDetectionMessage == true })?.id
                ?? scripts.last?.id
        }
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

func processTabTitle(_ title: String) -> String {
    title.replacingOccurrences(of: #"\s*(?:·\s*)?:\s*([0-9]{1,5})\s*$"#,
                               with: " : $1", options: .regularExpression)
}

func existingProcessMessage(script: RunnerScript, location: String, detectedAt: Date = Date(),
                            timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss XXX"
    let port = configuredLocalURL(for: script)?.port.map(String.init) ?? "Not configured"
    return """
    Detected an existing process:
    Location: \(URL(fileURLWithPath: location).standardizedFileURL.path)
    Configuration match: \(script.displayCommand)
    Port: \(port)
    Detected at: \(formatter.string(from: detectedAt))
    Live output and earlier logs are unavailable because this instance does not own its stdout/stderr.

    """
}

func configuredLocalURL(for script: RunnerScript) -> URL? {
    // Existing configurations annotate script titles with explicit ports, e.g. "Dev · :3010".
    let titlePattern = #"(?:^|[\s·]):([0-9]{1,5})(?=$|[\s·])"#
    let argumentPattern = #"(?:^|\s)--port(?:=|\s+)([0-9]{1,5})(?=$|\s)"#
    func port(in text: String, pattern: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let value = Int(text[range]),
              (1...65535).contains(value) else { return nil }
        return value
    }
    let titlePort = port(in: script.title, pattern: titlePattern)
    let commandPort = port(in: script.command ?? script.arguments.joined(separator: " "), pattern: argumentPattern)
    let environmentPort = script.environment["PORT"].flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil }
    guard let value = titlePort ?? commandPort ?? environmentPort else { return nil }
    return URL(string: "http://localhost:\(value)/")
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
        case .notRunning: "Not running"
        case .starting: "Starting"
        case let .running(pid): "Running · PID \(pid)"
        case .stopping: "Stopping"
        case let .exited(code): code == 0 ? "Finished" : "Error · code \(code)"
        case let .signalled(signal): "Stopped · signal \(signal)"
        case let .failed(message): "Not running · \(message)"
        case .unobservedExit: "Finished · exit code unavailable"
        }
    }
    var isRunning: Bool {
        switch self { case .starting, .running, .stopping: true; default: false }
    }
}

import AppKit
import Combine
import Foundation
import ScriptModeRunnerCore

struct ScriptLog {
    var buffer = ByteRingBuffer()
    var status: ProcessStatus?
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var configuration: RunnerConfiguration?
    @Published private(set) var errorMessage: String?
    @Published var selectedTabID: String?
    @Published var selectedOutputID: String?
    @Published private(set) var activeModes: [String: String] = [:]
    @Published private(set) var logs: [String: ScriptLog] = [:]

    let configURL: URL
    private let relay: EventRelay
    private let supervisor: ProcessSupervisor

    init(configURL: URL = ConfigurationLoader.defaultURL) {
        self.configURL = configURL
        let relay = EventRelay()
        self.relay = relay
        self.supervisor = ProcessSupervisor { event in relay.receive(event) }
        relay.owner = self
        reload()
    }

    var selectedTab: RunnerTab? {
        configuration?.tabs.first { $0.id == selectedTabID }
    }

    var visibleScripts: [(id: String, script: RunnerScript)] {
        guard let tab = selectedTab, let modeID = activeModes[tab.id],
              let mode = tab.buttons.first(where: { $0.id == modeID }) else { return [] }
        return mode.scripts.map { (runID(tabID: tab.id, modeID: mode.id, scriptID: $0.id), $0) }
    }

    func reload() {
        do {
            let loaded = try ConfigurationLoader().load(from: configURL)
            configuration = loaded
            errorMessage = nil
            if selectedTabID.flatMap({ id in loaded.tabs.first { $0.id == id } }) == nil {
                selectedTabID = loaded.tabs.first?.id
            }
        } catch {
            errorMessage = "\(configURL.path)\n\(error.localizedDescription)"
        }
    }

    func toggle(_ mode: RunnerMode, in tab: RunnerTab) {
        Task {
            if activeModes[tab.id] == mode.id {
                await deactivate(mode, in: tab)
                activeModes[tab.id] = nil
            } else {
                if let oldID = activeModes[tab.id], let old = tab.buttons.first(where: { $0.id == oldID }) {
                    await deactivate(old, in: tab)
                }
                activeModes[tab.id] = mode.id
                await activate(mode, in: tab)
            }
        }
    }

    func clearSelectedLog() {
        guard let id = selectedOutputID, var log = logs[id] else { return }
        log.buffer.removeAll()
        logs[id] = log
    }

    func shutdown() async {
        await supervisor.stopAll()
    }

    private func activate(_ mode: RunnerMode, in tab: RunnerTab) async {
        for (index, script) in mode.scripts.enumerated() {
            let id = runID(tabID: tab.id, modeID: mode.id, scriptID: script.id)
            if index == 0 { selectedOutputID = id }
            if logs[id]?.status?.isRunning == true {
                continue
            }
            logs[id] = ScriptLog()
            do {
                try await supervisor.start(runID: id, spec: script.launchSpec())
            } catch {
                logs[id]?.status = .failed(message: error.localizedDescription)
            }
        }
    }

    private func deactivate(_ mode: RunnerMode, in tab: RunnerTab) async {
        await withTaskGroup(of: Void.self) { group in
            for script in mode.scripts {
                let id = runID(tabID: tab.id, modeID: mode.id, scriptID: script.id)
                group.addTask { await self.supervisor.stop(runID: id, policy: mode.onDeactivate) }
            }
        }
    }

    fileprivate func receive(_ event: ProcessEvent) {
        switch event {
        case let .output(id, stream, data):
            var log = logs[id] ?? ScriptLog()
            if stream == .stderr {
                log.buffer.append(Data("[stderr] ".utf8))
            }
            log.buffer.append(data)
            logs[id] = log
        case let .status(id, status):
            var log = logs[id] ?? ScriptLog()
            log.status = status
            logs[id] = log
        }
    }
}

private final class EventRelay: @unchecked Sendable {
    weak var owner: AppState?

    func receive(_ event: ProcessEvent) {
        Task { @MainActor [weak self] in self?.owner?.receive(event) }
    }
}

private func runID(tabID: String, modeID: String, scriptID: String) -> String {
    "\(tabID)/\(modeID)/\(scriptID)"
}

extension ProcessStatus {
    var displayText: String {
        switch self {
        case .starting: "Запускается"
        case let .running(pid): "Работает · PID \(pid)"
        case .stopping: "Останавливается"
        case let .exited(code): code == 0 ? "Завершён" : "Ошибка · код \(code)"
        case let .signalled(signal): "Остановлен · сигнал \(signal)"
        case let .failed(message): "Не запущен · \(message)"
        }
    }

    var isRunning: Bool {
        switch self {
        case .starting, .running, .stopping: true
        default: false
        }
    }
}

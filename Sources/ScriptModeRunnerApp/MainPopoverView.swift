import AppKit
import ScriptModeRunnerCore
import SwiftUI

struct MainPopoverView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            header
            if let config = state.configuration, !config.tabs.isEmpty {
                content(config)
            } else {
                ContentUnavailableView(
                    "Нет конфигурации",
                    systemImage: "doc.badge.gearshape",
                    description: Text(state.errorMessage ?? "Добавьте хотя бы одну вкладку")
                )
            }
            if let error = state.errorMessage, state.configuration != nil {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
        .padding(12)
        .frame(width: 680, height: 480)
    }

    private var header: some View {
        HStack {
            Text("Script Mode Runner").font(.headline)
            Spacer()
            Button("Reload", systemImage: "arrow.clockwise") { state.reload() }
                .labelStyle(.iconOnly)
                .help("Перечитать \(state.configURL.path)")
            Button("Quit", systemImage: "power") { NSApplication.shared.terminate(nil) }
                .labelStyle(.iconOnly)
        }
    }

    @ViewBuilder
    private func content(_ config: RunnerConfiguration) -> some View {
        Picker("Вкладка", selection: $state.selectedTabID) {
            ForEach(config.tabs) { tab in Text(tab.title).tag(Optional(tab.id)) }
        }
        .pickerStyle(.segmented)

        if let tab = state.selectedTab {
            HStack {
                ForEach(tab.buttons, id: \.id) { (mode: RunnerMode) in
                    let active = state.activeModes[tab.id] == mode.id
                    Button {
                        state.toggle(mode, in: tab)
                    } label: {
                        Label(mode.title, systemImage: active ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(active ? .accentColor : nil)
                }
                Spacer()
            }

            if state.visibleScripts.isEmpty {
                Spacer()
                ContentUnavailableView("Режим не запущен", systemImage: "terminal")
                Spacer()
            } else {
                output
            }
        }
    }

    private var output: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("Вывод", selection: $state.selectedOutputID) {
                    ForEach(state.visibleScripts, id: \.id) { item in
                        Text(item.script.title).tag(Optional(item.id))
                    }
                }
                .pickerStyle(.segmented)
                Button("Очистить") { state.clearSelectedLog() }
            }
            if let id = state.selectedOutputID, let log = state.logs[id] {
                HStack {
                    Circle().fill(log.status?.isRunning == true ? .green : .secondary).frame(width: 7, height: 7)
                    Text(log.status?.displayText ?? "Не запущен").font(.caption).foregroundStyle(.secondary)
                    Text("· \(log.buffer.count) bytes").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
                LogTextView(text: log.buffer.string)
            }
        }
    }
}

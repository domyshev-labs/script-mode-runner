import AppKit
import ScriptModeRunnerCore
import SwiftUI

private struct ParameterSelection: Identifiable {
    let id = UUID()
    let item: MenuItem
    let button: RunnerMode
    let tab: RunnerTab
}

struct MainPopoverView: View {
    @ObservedObject var state: AppState
    @State private var pendingParameter: ParameterSelection?
    @State private var parameterValue = ""

    var body: some View {
        VStack(spacing: 10) {
            header
            if let config = state.configuration, !config.tabs.isEmpty { content(config) }
            else {
                ContentUnavailableView("No configuration", systemImage: "doc.badge.gearshape",
                                       description: Text(state.errorMessage ?? "Add at least one tab"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = state.errorMessage, state.configuration != nil {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
        .padding(12)
        .frame(width: 680, height: 480)
        .sheet(item: $pendingParameter) { selection in
            VStack(alignment: .leading, spacing: 12) {
                Text(selection.item.title).font(.headline)
                Text(selection.item.parameter?.prompt ?? "Argument")
                TextField("Value", text: $parameterValue)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { pendingParameter = nil }.keyboardShortcut(.cancelAction)
                    Button("Run") {
                        state.launch(selection.item, button: selection.button, tab: selection.tab, parameterValue: parameterValue)
                        pendingParameter = nil
                    }
                    .disabled(parameterValue.isEmpty || state.seedIsRunning(selection.button))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 360)
        }
    }

    private var header: some View {
        HStack {
            Text("Script Mode Runner").font(.headline)
            Spacer()
            Button("Reload", systemImage: "arrow.clockwise") { state.reload() }
                .labelStyle(.iconOnly).help("Reread the configuration and refresh command catalogs.\n\(state.configURL.path)")
            Button("Quit", systemImage: "power") { NSApplication.shared.terminate(nil) }
                .labelStyle(.iconOnly)
        }
    }

    @ViewBuilder
    private func content(_ config: RunnerConfiguration) -> some View {
        Picker("Tab", selection: $state.selectedTabID) {
            ForEach(config.tabs) { tab in Text(tab.title).tag(Optional(tab.id)) }
        }
        .pickerStyle(.segmented)
        if let tab = state.selectedTab {
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        alignedButtons(tab, alignment: .left)
                        Spacer(minLength: 8)
                        alignedButtons(tab, alignment: .right)
                    }
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                    .padding(.vertical, 3)
                }
            }.frame(height: 32)
            if state.visibleScripts.isEmpty {
                ContentUnavailableView("No runs yet", systemImage: "terminal",
                                       description: Text("Start a mode or choose a command from a menu"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { output }
        }
    }

    private func alignedButtons(_ tab: RunnerTab, alignment: ButtonAlignment) -> some View {
        ForEach(tab.buttons.filter { $0.align == alignment }) { button in
            buttonView(button, tab: tab)
                .padding(.leading, button.marginLeft)
                .padding(.trailing, button.marginRight)
        }
    }

    @ViewBuilder
    private func buttonView(_ button: RunnerMode, tab: RunnerTab) -> some View {
        let activity = state.activity(button, in: tab)
        if button.source != nil {
            let catalog = state.catalogs[state.catalogKey(button, tab: tab)] ?? CatalogState()
            Menu {
                if catalog.loading { Text("Loading…") }
                if let error = catalog.error { Text(error) }
                if !catalog.loading && catalog.error == nil && catalog.items.isEmpty { Text("No commands available") }
                ForEach(catalog.items) { item in
                    Button(item.title) {
                        if let parameter = item.parameter {
                            parameterValue = parameter.defaultValue ?? ""
                            pendingParameter = ParameterSelection(item: item, button: button, tab: tab)
                        } else { state.launch(item, button: button, tab: tab) }
                    }
                    .disabled(catalog.loading || state.seedIsRunning(button))
                }
                Divider()
                Button("Refresh") { state.refreshCatalog(button, in: tab) }.disabled(catalog.loading)
            } label: { buttonLabel(button.title, activity: activity, menu: true) }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
            .simultaneousGesture(TapGesture().onEnded { state.refreshCatalog(button, in: tab) })
        } else {
            Button { state.toggle(button, in: tab) } label: {
                buttonLabel(button.title, activity: activity, menu: false)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
            .disabled(state.busyTabs.contains(tab.id))
        }
    }

    private func buttonLabel(_ title: String, activity: ButtonActivity, menu: Bool) -> some View {
        HStack(spacing: 5) {
            if activity == .transitioning { ProgressView().controlSize(.mini) }
            else if menu { Image(systemName: "list.bullet").foregroundStyle(.secondary) }
            else {
                let stopping = activity == .running || activity == .partial
                let color: Color = stopping ? .red : .green
                Image(systemName: stopping ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 13.7275, weight: .semibold))
                    .foregroundStyle(color.gradient)
                    .shadow(color: color.opacity(0.35), radius: 1, y: 1)
            }
            Text(title).lineLimit(1)
        }
        .font(.system(size: 13))
        .fixedSize(horizontal: true, vertical: false)
    }

    private var output: some View {
        VStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(state.visibleScripts) { run in
                            HStack(spacing: 4) {
                                Button { state.selectedOutputID = run.id } label: {
                                    Text(run.script.displayCommand).lineLimit(1).truncationMode(.tail).frame(maxWidth: 190)
                                }.buttonStyle(.plain)
                                if state.logs[run.id]?.status?.isRunning != true {
                                    Button { state.close(run.id) } label: { Image(systemName: "xmark").font(.caption2) }
                                        .buttonStyle(.plain).help("Close completed log")
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(state.selectedOutputID == run.id ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .help(run.script.displayCommand).id(run.id)
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
                .onChange(of: state.selectedOutputID) { _, id in if let id { proxy.scrollTo(id) } }
            }
            if let id = state.selectedOutputID, let log = state.logs[id] {
                HStack {
                    Circle().fill(statusColor(log.status)).frame(width: 7, height: 7)
                    Text(log.status?.displayText ?? "Not running").font(.caption).foregroundStyle(.secondary)
                    Text("· \(log.buffer.count) bytes").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    if log.status?.isRunning == true {
                        Button("Stop") { state.stopSelected() }.disabled(log.status == .stopping)
                    }
                    Button("Clear") { state.clearSelectedLog() }
                }
                LogTextView(text: log.buffer.string).id(id)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func statusColor(_ status: ProcessStatus?) -> Color {
        switch status {
        case .running: .green
        case .starting, .stopping: .orange
        case .failed: .red
        case let .exited(code) where code != 0: .red
        default: .secondary
        }
    }
}

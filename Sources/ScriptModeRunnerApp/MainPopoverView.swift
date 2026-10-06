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
    @Environment(\.colorScheme) private var colorScheme
    @State private var showReloadHelp = false
    @State private var reloadHelpTask: Task<Void, Never>?
    @State private var pendingParameter: ParameterSelection?
    @State private var parameterValue = ""

    var body: some View {
        VStack(spacing: 10) {
            header.zIndex(1)
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
        .background(windowBackground)
        .onDisappear {
            reloadHelpTask?.cancel()
            showReloadHelp = false
        }
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
            Button("Reload", systemImage: "arrow.clockwise") {
                reloadHelpTask?.cancel()
                showReloadHelp = false
                state.reload()
            }
            .labelStyle(.iconOnly)
            .accessibilityHint("Reread the configuration and refresh command catalogs")
            .onHover { hovering in
                reloadHelpTask?.cancel()
                if hovering {
                    reloadHelpTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled else { return }
                        showReloadHelp = true
                    }
                } else { showReloadHelp = false }
            }
            .overlay(alignment: .topTrailing) {
                if showReloadHelp {
                    reloadHelp
                        .offset(y: 30)
                        .allowsHitTesting(false)
                }
            }
            Button("Quit", systemImage: "power") { NSApplication.shared.terminate(nil) }
                .labelStyle(.iconOnly)
        }
    }

    private var windowBackground: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.20, green: 0.22, blue: 0.26), Color(red: 0.16, green: 0.18, blue: 0.21)]
                : [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    private var reloadHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Reload configuration", systemImage: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
            Text("Rereads the config file and refreshes command and seed catalogs. Running processes keep working.")
                .font(.system(size: 12))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.94) : Color.primary)
            Text(state.configURL.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.8) : Color.secondary)
                .textSelection(.disabled)
        }
        .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
        .padding(14)
        .frame(width: 290, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(colorScheme == .dark ? Color(red: 0.17, green: 0.21, blue: 0.28) : .white,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.15), radius: 12, y: 5)
    }

    @ViewBuilder
    private func content(_ config: RunnerConfiguration) -> some View {
        HStack(spacing: 2) {
            ForEach(config.tabs) { tab in
                ProjectTabView(tab: tab, selected: state.selectedTabID == tab.id,
                               select: { state.selectedTabID = tab.id },
                               move: { state.moveTab($0, to: tab.id) })
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
        if let tab = state.selectedTab {
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        modeControls(tab)
                        alignedButtons(tab, alignment: .left)
                        Spacer(minLength: 8)
                        alignedButtons(tab, alignment: .right)
                    }
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                    .padding(.vertical, 3)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .scrollIndicators(.automatic)
            }.frame(height: 32)
            if state.visibleScripts.isEmpty {
                ContentUnavailableView("No runs yet", systemImage: "terminal",
                                       description: Text("Start a mode or choose a command from a menu"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { output }
        }
    }

    private func alignedButtons(_ tab: RunnerTab, alignment: ButtonAlignment) -> some View {
        ForEach(tab.buttons.filter { $0.source != nil && $0.align == alignment }) { button in
            buttonView(button, tab: tab)
                .padding(.leading, button.marginLeft)
                .padding(.trailing, button.marginRight)
        }
    }

    @ViewBuilder
    private func modeControls(_ tab: RunnerTab) -> some View {
        if let selected = state.selectedMode(in: tab) {
            let running = state.runningMode(in: tab)
            let busy = state.busyTabs.contains(tab.id)
            HStack(spacing: 8) {
                Menu {
                    ForEach(tab.buttons.filter { $0.source == nil }) { mode in
                        Button {
                            state.selectMode(mode, in: tab)
                        } label: {
                            if selected.id == mode.id {
                                Label(mode.title, systemImage: "checkmark")
                            } else { Text(mode.title) }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if running?.id == selected.id && !busy {
                            Image(systemName: "play.circle.fill").foregroundStyle(.green)
                        }
                        Text(selected.title)
                        if busy { ProgressView().controlSize(.mini) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
                .disabled(busy)
                HStack(spacing: 6) {
                    ModeControlButton(symbol: "play.fill", tint: .green,
                                      help: "Start \(selected.title)", enabled: !busy && running?.id != selected.id) {
                        state.startMode(selected, in: tab)
                    }
                    ModeControlButton(symbol: "arrow.clockwise", tint: .accentColor,
                                      help: "Restart \(selected.title)", enabled: !busy && running?.id == selected.id) {
                        state.restartMode(selected, in: tab)
                    }
                    ModeControlButton(symbol: "stop.fill", tint: .red,
                                      help: "Stop \(running?.title ?? selected.title)", enabled: !busy && running != nil) {
                        if let running { state.stopMode(running, in: tab) }
                    }
                }
            }
            .font(.system(size: 13))
            .fixedSize(horizontal: true, vertical: false)
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
            } label: { buttonLabel(button.title, activity: activity) }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
            .simultaneousGesture(TapGesture().onEnded { state.refreshCatalog(button, in: tab) })
        }
    }

    private func buttonLabel(_ title: String, activity: ButtonActivity) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "list.bullet").foregroundStyle(.secondary)
            Text(title).lineLimit(1)
            if activity == .transitioning {
                ProgressView().controlSize(.mini)
            }
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
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .scrollIndicators(.automatic)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: state.selectedOutputID) { _, id in if let id { proxy.scrollTo(id) } }
            }
            if let id = state.selectedOutputID, let log = state.logs[id] {
                HStack {
                    Circle().fill(statusColor(log.status)).frame(width: 7, height: 7)
                    Text(log.status?.displayText ?? "Not running").font(.caption).foregroundStyle(.secondary)
                    Text("· \(log.buffer.count) bytes").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    if log.status?.isRunning == true {
                        Button("Reload") { state.reloadSelected() }
                            .help("Restart the selected command")
                            .disabled(log.status == .starting || log.status == .stopping ||
                                      state.restartingRuns.contains(id) ||
                                      state.selectedRun.map { state.busyTabs.contains($0.tabID) } == true)
                        Button("Stop") { state.stopSelected() }
                            .disabled(log.status == .stopping || state.restartingRuns.contains(id))
                    }
                    Button("Clear") { state.clearSelectedLog() }
                }
                if let url = log.latestRunningLink {
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "link")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help(url.absoluteString)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    .background(PointingHandCursorRegion().allowsHitTesting(false))
                }
                LogTextView(text: log.buffer.string).id(id)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08), lineWidth: 1))
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

private struct PointingHandCursorRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorView() }

    func updateNSView(_ view: NSView, context: Context) {
        view.window?.invalidateCursorRects(for: view)
    }

    private final class CursorView: NSView {
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

private struct ModeControlButton: View {
    let symbol: String
    let tint: Color
    let help: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? tint : Color.secondary.opacity(0.5))
                .frame(width: 16, height: 24)
                .background(tint.opacity(enabled ? (hovering ? 0.24 : 0.08) : 0),
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(tint.opacity(enabled && hovering ? 0.5 : 0), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct ProjectTabView: View {
    let tab: RunnerTab
    let selected: Bool
    let select: () -> Void
    let move: (String) -> Bool
    @State private var dropTarget = false

    var body: some View {
        Button(action: select) {
            Text(tab.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(selected ? Color(nsColor: .controlBackgroundColor) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(dropTarget ? Color.accentColor : Color.clear, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help("Select \(tab.title). Drag to reorder projects.")
        .draggable("script-mode-runner-tab/" + tab.id)
        .dropDestination(for: String.self) { items, _ in
            let prefix = "script-mode-runner-tab/"
            guard items.count == 1, let item = items.first, item.hasPrefix(prefix) else { return false }
            return move(String(item.dropFirst(prefix.count)))
        } isTargeted: { dropTarget = $0 }
    }
}

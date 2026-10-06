import AppKit
import ModeRunnerCore
import SwiftUI

private struct ParameterSelection: Identifiable {
    let id = UUID()
    let item: MenuItem
    let button: RunnerMode
    let tab: RunnerTab
}

struct MainPopoverView: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var pendingRunnerAction: RunnerAction?
    @State private var terminateProcesses = false
    @State private var confirmedRunnerAction: RunnerAction?
    @State private var pendingParameter: ParameterSelection?
    @State private var parameterValue = ""
    @State private var draggedProjectID: String?
    @State private var dropTargetProjectID: String?

    var body: some View {
        VStack(spacing: 11) {
            header.zIndex(1)
            if let config = state.configuration, !config.tabs.isEmpty { content(config) }
            else {
                ContentUnavailableView("No configuration", systemImage: "doc.badge.gearshape",
                                       description: Text(state.errorMessage ?? "Add at least one tab"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = state.errorMessage, state.configuration != nil {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(3)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(18)
        .frame(width: 760, height: 560)
        .background(windowBackground)
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: state.selectedTabID)
        .onDisappear {
            draggedProjectID = nil
            dropTargetProjectID = nil
        }
        .sheet(item: $pendingRunnerAction, onDismiss: {
            guard let action = confirmedRunnerAction else { return }
            confirmedRunnerAction = nil
            (NSApplication.shared.delegate as? AppDelegate)?.perform(action, terminateProcesses: terminateProcesses)
        }) { action in
            VStack(alignment: .leading, spacing: 16) {
                Label(action.title + "?", systemImage: action == .restart ? "arrow.clockwise" : "power")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("Running processes will keep working unless you choose to terminate them.")
                Toggle("Terminate processes", isOn: $terminateProcesses)
                    .toggleStyle(.checkbox)
                HStack {
                    Spacer()
                    Button("Cancel") { pendingRunnerAction = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Confirm") {
                        confirmedRunnerAction = action
                        pendingRunnerAction = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28)
            .frame(width: 420)
        }
        .sheet(item: $pendingParameter) { selection in
            VStack(alignment: .leading, spacing: 12) {
                Label(selection.item.title, systemImage: "terminal")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
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
            .padding(28).frame(width: 400)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: RunnerIcon.image)
                .resizable().interpolation(.high)
                .frame(width: 29, height: 29)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mode Runner").font(.system(size: 14.5, weight: .semibold, design: .rounded))
                Text("Your local workspace").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
            if state.discoveringProcesses {
                ProgressView().controlSize(.small).help("Finding running processes")
            }
            RunnerActionsMenu(configURL: state.configURL, reload: { state.reload() }) { action in
                terminateProcesses = false
                pendingRunnerAction = action
            }
            .frame(width: 26, height: 26)
            .runnerGlass(radius: 8, interactive: true)
        }
    }

    @ViewBuilder
    private var windowBackground: some View {
        if reduceTransparency || contrast == .increased {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private func content(_ config: RunnerConfiguration) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 6
            RunnerGlassGroup {
              HStack(spacing: 2) {
                ForEach(config.tabs) { tab in
                    ProjectTabView(tab: tab, selected: state.selectedTabID == tab.id,
                                   running: state.runningMode(in: tab) != nil,
                                   dragging: draggedProjectID == tab.id,
                                   dropTarget: dropTargetProjectID == tab.id && draggedProjectID != tab.id,
                                   select: { state.selectedTabID = tab.id },
                                   dragChanged: { location in
                                       draggedProjectID = tab.id
                                       dropTargetProjectID = projectTabID(at: location, width: width, tabs: config.tabs, height: 29)
                                   },
                                   dragEnded: { location in
                                       if let target = projectTabID(at: location, width: width, tabs: config.tabs, height: 29) {
                                           _ = state.moveTab(tab.id, to: target)
                                       }
                                       draggedProjectID = nil
                                       dropTargetProjectID = nil
                                   })
                    .frame(maxWidth: .infinity)
                    .zIndex(draggedProjectID == tab.id ? 1 : 0)
                }
              }
              .coordinateSpace(name: "projectTabs")
            }
            .padding(3)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 13))
        }
        .frame(height: 35)
        if let tab = state.selectedTab {
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    RunnerGlassGroup {
                      HStack(spacing: 8) {
                        modeControls(tab)
                        alignedButtons(tab, alignment: .left)
                        Spacer(minLength: 6)
                        alignedButtons(tab, alignment: .right)
                      }
                      .frame(minWidth: geometry.size.width, alignment: .leading)
                    }
                    .padding(.vertical, 3)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .scrollIndicators(.automatic)
            }.frame(height: 35)
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
            let busy = state.busyTabs.contains(tab.id) || state.discoveringProcesses
            HStack(spacing: 6) {
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
                .padding(.horizontal, 10)
                .frame(height: 27)
                .runnerGlass(radius: 10, tint: running?.id == selected.id ? .green.opacity(0.12) : nil, interactive: true)
                .disabled(busy)
                HStack(spacing: 4) {
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
            .font(.system(size: 10.5))
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
            .padding(.horizontal, 10)
            .frame(height: 27)
            .runnerGlass(radius: 10, interactive: true)
            .simultaneousGesture(TapGesture().onEnded { state.refreshCatalog(button, in: tab) })
        }
    }

    private func buttonLabel(_ title: String, activity: ButtonActivity) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "list.bullet").foregroundStyle(.secondary)
            Text(title).lineLimit(1)
            if activity == .transitioning {
                ProgressView().controlSize(.mini)
            }
        }
        .font(.system(size: 10.5))
        .fixedSize(horizontal: true, vertical: false)
    }

    private var output: some View {
        VStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    RunnerGlassGroup {
                      HStack(spacing: 8) {
                        ForEach(state.visibleScripts) { run in
                            HStack(spacing: 4) {
                                Button { state.selectedOutputID = run.id } label: {
                                    HStack(spacing: 6) {
                                        Circle().fill(statusColor(state.logs[run.id]?.status)).frame(width: 6, height: 6)
                                        Text(run.script.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 190)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(state.selectedOutputID == run.id ? [.isSelected] : [])
                                if state.logs[run.id]?.status?.isRunning != true {
                                    Button { state.close(run.id) } label: { Image(systemName: "xmark").font(.caption2) }
                                        .buttonStyle(.plain).help("Close completed log").accessibilityLabel("Close " + run.script.title)
                                }
                            }
                            .font(.system(size: 12, weight: state.selectedOutputID == run.id ? .semibold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .runnerGlass(tint: state.selectedOutputID == run.id ? .accentColor.opacity(0.18) : nil,
                                         interactive: true)
                            .help(run.script.displayCommand).id(run.id)
                        }
                      }
                      .padding(2)
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .scrollIndicators(.automatic)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: state.selectedOutputID) { _, id in if let id { proxy.scrollTo(id) } }
            }
            if let id = state.selectedOutputID, let log = state.logs[id] {
                HStack(spacing: 8) {
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
                .controlSize(.small)
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                if let url = log.latestRunningLink {
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "link")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help(url.absoluteString)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .runnerGlass(tint: .accentColor.opacity(0.1), interactive: true)
                    .background(PointingHandCursorRegion().allowsHitTesting(false))
                }
                LogTextView(text: log.buffer.string, boldFirstLine: log.hasDetectionMessage).id(id)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
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

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(enabled ? tint : Color.secondary.opacity(0.5))
                .frame(width: 26, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .runnerGlass(radius: 8, tint: enabled ? tint.opacity(0.1) : nil, interactive: enabled)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ProjectTabView: View {
    let tab: RunnerTab
    let selected: Bool
    let running: Bool
    let dragging: Bool
    let dropTarget: Bool
    let select: () -> Void
    let dragChanged: (CGPoint) -> Void
    let dragEnded: (CGPoint) -> Void
    @GestureState private var dragOffset: CGSize = .zero

    var body: some View {
        label
            .onTapGesture(perform: select)
            .gesture(dragGesture)
            .offset(x: dragOffset.width)
            .opacity(dragging ? 0.85 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { select() }
            .help("Select \(tab.title). Hold the mouse button and drag left or right to reorder projects.")
    }

    private var label: some View {
        HStack(spacing: 4) {
            if running { Circle().fill(.green).frame(width: 5, height: 5) }
            Text(tab.title)
        }
            .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .frame(height: 29)
            .modifier(ProjectTabSurface(selected: selected || dragging))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(dropTarget ? Color.accentColor : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("projectTabs"))
            .updating($dragOffset) { value, offset, _ in offset = value.translation }
            .onChanged { dragChanged($0.location) }
            .onEnded { dragEnded($0.location) }
    }
}

private struct ProjectTabSurface: ViewModifier {
    let selected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if selected { content.runnerGlass(radius: 10, tint: .accentColor.opacity(0.12), interactive: true) }
        else { content }
    }
}

func projectTabID(at location: CGPoint, width: CGFloat, tabs: [RunnerTab], height: CGFloat = 24) -> String? {
    guard !tabs.isEmpty, width > 0, location.x >= 0, location.x < width,
          location.y >= 0, location.y <= height else { return nil }
    let segmentWidth = (width + 2) / CGFloat(tabs.count)
    return tabs[min(Int(location.x / segmentWidth), tabs.count - 1)].id
}

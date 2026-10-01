import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var statusItem: NSStatusItem?
    private let mainPopover = NSPopover()
    private let startupPopover = NSPopover()
    private var startupTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        self.state = state
        NSApplication.shared.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Script Mode Runner")
            button.toolTip = "Script Mode Runner"
            button.target = self
            button.action = #selector(togglePopover)
        }
        mainPopover.behavior = .transient
        mainPopover.contentViewController = NSHostingController(rootView: MainPopoverView(state: state))
        startupPopover.behavior = .transient
        startupPopover.contentViewController = NSHostingController(rootView:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Script Mode Runner").font(.headline)
                    Text("Started. Click here to open.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(14)
        )
        startupTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let button = statusItem?.button,
                  button.window != nil, !mainPopover.isShown else { return }
            startupPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            startupPopover.close()
        }
    }

    @objc private func togglePopover() {
        startupTask?.cancel()
        startupPopover.close()
        guard let button = statusItem?.button else { return }
        if mainPopover.isShown { mainPopover.performClose(nil) }
        else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            mainPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            mainPopover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        startupTask?.cancel()
        guard let state else { return .terminateNow }
        Task {
            await state.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ScriptModeRunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

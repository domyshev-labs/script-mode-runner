import AppKit
import ModeRunnerCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var statusItem: NSStatusItem?
    private let mainPopover = NSPopover()
    private let startupPopover = NSPopover()
    private var startupTask: Task<Void, Never>?
    private var pendingAction: RunnerAction?
    private var terminateProcesses = false
    private var preparingTermination = false
    private var readyToTerminate = false
    private var exitWatchdog: Process?

    func perform(_ action: RunnerAction, terminateProcesses: Bool) {
        guard !preparingTermination else { return }
        pendingAction = action
        self.terminateProcesses = terminateProcesses
        beginTermination(NSApplication.shared)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        self.state = state
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Mode Runner")
            button.toolTip = "Mode Runner"
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
                    Text("Mode Runner").font(.headline)
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
        else { showMainPopover(relativeTo: button) }
    }

    private func showMainPopover(relativeTo button: NSStatusBarButton) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        mainPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        mainPopover.contentViewController?.view.window?.makeKey()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        startupTask?.cancel()
        startupPopover.close()
        if let button = statusItem?.button, !mainPopover.isShown {
            showMainPopover(relativeTo: button)
        }
        // Reopening from Finder or Spotlight should never create a separate window.
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate || state == nil { return .terminateNow }
        beginTermination(sender)
        // Keep servicing the normal event loop while asynchronous cleanup runs.
        return .terminateCancel
    }

    private func beginTermination(_ sender: NSApplication) {
        guard !preparingTermination, let state else { return }
        preparingTermination = true
        startupTask?.cancel()
        startupPopover.close()
        mainPopover.close()
        let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        do {
            exitWatchdog = try RunnerExitWatchdog.launch(
                pid: ProcessInfo.processInfo.processIdentifier,
                action: pendingAction ?? .poweroff, executablePath: executablePath
            )
        } catch {
            reportTerminationFailure(error)
            return
        }
        Task {
            do {
                if terminateProcesses { await state.shutdown() }
                else { try await state.preserveProcesses(executablePath: executablePath) }
                readyToTerminate = true
                sender.terminate(nil)
            } catch {
                reportTerminationFailure(error)
            }
        }
    }

    private func reportTerminationFailure(_ error: Error) {
        if exitWatchdog?.isRunning == true { exitWatchdog?.terminate() }
        exitWatchdog = nil
        preparingTermination = false
        pendingAction = nil
        terminateProcesses = false
        let alert = NSAlert()
        alert.messageText = "Could not close Mode Runner"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

}

@main
@MainActor
enum ModeRunnerApp {
    static func main() {
        if CommandLine.arguments.contains("--drain-process-output") {
            ProcessSupervisor.drainInheritedOutput()
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        application.mainMenu = makeMainMenu()
        // NSApplication holds its delegate weakly; retain it for the event loop.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    private static func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Mode Runner")
        appMenu.addItem(withTitle: "Quit Mode Runner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        return menu
    }
}

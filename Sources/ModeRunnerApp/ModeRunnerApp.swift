import AppKit
import ModeRunnerCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var statusItem: NSStatusItem?
    private let mainPopover = NSPopover()
    private var statusIcon: StatusIconView?
    private var startupTask: Task<Void, Never>?
    private var pendingAction: RunnerAction?
    private var terminateProcesses = false
    private var preparingTermination = false
    private var readyToTerminate = false
    private var exitWatchdog: Process?
    private let informationWindows = RunnerInformationWindows()
    private let actionPreferences = RunnerActionPreferences()
    private let statusMenuCoordinator = RunnerActionsMenu.Coordinator()

    override init() {
        super.init()
        informationWindows.mainPopover = mainPopover
        statusMenuCoordinator.onClose = { [weak self] in self?.statusItem?.menu = nil }
    }

    @objc func showAbout() {
        informationWindows.showAbout(relativeTo: mainPopover.contentViewController?.view.window)
    }
    @objc func showDocumentation() {
        informationWindows.showDocumentation(relativeTo: mainPopover.contentViewController?.view.window)
    }

    @objc func showSettings() {
        informationWindows.showSettings(preferences: actionPreferences,
                                        relativeTo: mainPopover.contentViewController?.view.window)
    }

    func request(_ action: RunnerAction) {
        if actionPreferences.showConfirmation, !mainPopover.isShown, let button = statusItem?.button {
            showMainPopover(relativeTo: button)
        }
        actionPreferences.request(action) { [weak self] action, terminate in
            self?.perform(action, terminateProcesses: terminate)
        }
    }

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
            let icon = StatusIconView(frame: button.bounds)
            icon.autoresizingMask = [.width, .height]
            button.addSubview(icon)
            statusIcon = icon
            button.setAccessibilityLabel("Mode Runner")
            button.toolTip = "Mode Runner"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        mainPopover.behavior = .transient
        mainPopover.contentViewController = NSHostingController(rootView: MainPopoverView(state: state, actions: actionPreferences))
        startupTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let icon = statusIcon,
                  icon.window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            defer { icon.pulseScale = 1 }
            let clock = ContinuousClock()
            let start = clock.now
            while !Task.isCancelled {
                let elapsed = start.duration(to: clock.now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                guard seconds < StartupPulse.duration else { break }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { break }
                icon.pulseScale = StartupPulse.scale(at: seconds)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopStartupPulse() {
        startupTask?.cancel()
        startupTask = nil
        statusIcon?.pulseScale = 1
    }

    @objc private func togglePopover() {
        stopStartupPulse()
        guard let button = statusItem?.button else { return }
        if NSApplication.shared.currentEvent?.type == .rightMouseUp {
            guard let state else { return }
            statusMenuCoordinator.parent = RunnerActionsMenu(configURL: state.configURL,
                                                            reload: { state.reload() },
                                                            select: { [weak self] in self?.request($0) })
            let menu = statusMenuCoordinator.makeMenu(appearance: button.effectiveAppearance)
            // Let the status item position its menu below the menu bar from the first frame.
            statusItem?.menu = menu
            button.performClick(nil)
            return
        }
        if mainPopover.isShown { mainPopover.performClose(nil) }
        else { showMainPopover(relativeTo: button) }
    }

    private func showMainPopover(relativeTo button: NSStatusBarButton) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        mainPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        mainPopover.contentViewController?.view.window?.makeKey()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        stopStartupPulse()
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
        stopStartupPulse()
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

import AppKit
import SwiftUI

enum RunnerAction: String, Identifiable {
    case restart, poweroff

    var id: String { rawValue }
    var title: String {
        switch self {
        case .restart: "Quit&Start \"Mode Runner\""
        case .poweroff: "Quit \"Mode Runner\""
        }
    }

    var systemImage: String { self == .restart ? "arrow.right.square" : "power" }
}

// Keep native menu navigation while presenting a styled, noninteractive help panel.
struct RunnerActionsMenu: NSViewRepresentable {
    let configURL: URL
    let reload: () -> Void
    let select: (RunnerAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSControl {
        let button = SquareMenuButton(frame: .zero)
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        button.toolTip = "Runner actions"
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("Runner actions")
        return button
    }

    func updateNSView(_ button: NSControl, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: RunnerActionsMenu?
        var onClose: (() -> Void)?
        private var helpTimer: Timer?
        private var helpPanel: NSPanel?
        private var menuAppearance: NSAppearance?

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            hideHelp()
            guard item === menu.items.first else { return }
            let pointer = NSEvent.mouseLocation
            let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showHelp(near: pointer) }
            }
            helpTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }

        func menuDidClose(_ menu: NSMenu) {
            hideHelp()
            onClose?()
        }

        private func hideHelp() {
            helpTimer?.invalidate()
            helpTimer = nil
            helpPanel?.orderOut(nil)
            helpPanel = nil
        }

        private func showHelp(near pointer: NSPoint) {
            guard let parent else { return }
            let host = NSHostingView(rootView: ReloadConfigurationHelp(configURL: parent.configURL))
            let size = host.fittingSize
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) }?.visibleFrame ?? NSScreen.main!.visibleFrame
            let origin = NSPoint(
                x: max(screen.minX + 8, min(pointer.x - size.width - 20, screen.maxX - size.width - 8)),
                y: max(screen.minY + 8, min(pointer.y - size.height + 28, screen.maxY - size.height - 8))
            )
            let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.appearance = menuAppearance
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
            panel.contentView = host
            helpPanel = panel
            panel.orderFrontRegardless()
        }

        @objc func openMenu(_ sender: NSControl) {
            guard parent != nil else { return }
            let menu = makeMenu(appearance: sender.effectiveAppearance)
            let menuY = sender.isFlipped ? sender.bounds.maxY + 4 : sender.bounds.minY - 4
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuY), in: sender)
        }

        func makeMenu(appearance: NSAppearance) -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            menuAppearance = appearance
            let reload = NSMenuItem(title: "Reload configuration", action: #selector(reloadConfiguration), keyEquivalent: "")
            reload.target = self
            reload.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            menu.addItem(reload)
            let settings = NSMenuItem(title: "Settings...", action: #selector(AppDelegate.showSettings), keyEquivalent: "")
            settings.target = NSApplication.shared.delegate
            settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            menu.addItem(settings)
            menu.addItem(.separator())
            let about = NSMenuItem(title: "About...", action: #selector(AppDelegate.showAbout), keyEquivalent: "")
            about.target = NSApplication.shared.delegate
            about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
            menu.addItem(about)
            let documentation = NSMenuItem(title: "Documentation", action: #selector(AppDelegate.showDocumentation), keyEquivalent: "")
            documentation.target = NSApplication.shared.delegate
            documentation.image = NSImage(systemSymbolName: "book", accessibilityDescription: nil)
            menu.addItem(documentation)
            menu.addItem(.separator())
            for action in [RunnerAction.restart, .poweroff] {
                let item = NSMenuItem(title: action.title, action: #selector(selectAction(_:)), keyEquivalent: "")
                item.representedObject = action.rawValue
                item.target = self
                item.image = NSImage(systemSymbolName: action.systemImage,
                                     accessibilityDescription: nil)
                menu.addItem(item)
            }
            return menu
        }

        @objc func reloadConfiguration() { parent?.reload() }

        @objc func selectAction(_ sender: NSMenuItem) {
            guard let rawValue = sender.representedObject as? String,
                  let action = RunnerAction(rawValue: rawValue) else { return }
            parent?.select(action)
        }
    }
}

@MainActor
private final class SquareMenuButton: NSControl {
    private var hovered = false
    private var pressed = false
    private var hoverTrackingArea: NSTrackingArea?

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
        displayIfNeeded()
        _ = sendAction(action, to: target)
        pressed = false
        hovered = bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool { sendAction(action, to: target) }

    override func keyDown(with event: NSEvent) {
        if event.characters == " " || event.keyCode == 36 { _ = sendAction(action, to: target) }
        else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let background: NSColor
        if pressed { background = NSColor.labelColor.withAlphaComponent(0.12) }
        else if hovered { background = NSColor.labelColor.withAlphaComponent(0.06) }
        else { background = NSColor.clear }
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let strokeWidth: CGFloat = 1.2
        let halfLineLength: CGFloat = (10.8 - strokeWidth) / 2
        let lines = NSBezierPath()
        lines.lineWidth = strokeWidth
        lines.lineCapStyle = .round
        for y in [bounds.midY - 3.6, bounds.midY, bounds.midY + 3.6] {
            lines.move(to: NSPoint(x: bounds.midX - halfLineLength, y: y))
            lines.line(to: NSPoint(x: bounds.midX + halfLineLength, y: y))
        }
        NSColor.labelColor.setStroke()
        lines.stroke()
    }
}

private struct ReloadConfigurationHelp: View {
    let configURL: URL
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Reload configuration", systemImage: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
            Text("Loads the configuration from this file and refreshes command catalogs:")
                .font(.system(size: 12))
                .lineSpacing(3)
            Text(configURL.path)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(colorScheme == .dark
                    ? Color(red: 0.63, green: 0.83, blue: 1)
                    : Color(red: 0.12, green: 0.36, blue: 0.65))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            Text("Running processes keep working.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(18)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .runnerGlass(radius: 18)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .padding(12)
    }
}

import AppKit
import ModeRunnerCore
import SwiftUI

struct ProcessTabTooltipContent {
    let command: String
    let port: String

    init(script: RunnerScript) {
        command = script.displayCommand
        port = configuredLocalURL(for: script)?.port.map(String.init) ?? "Not configured"
    }
}

// A passive tracking view preserves tab clicks and provides a two-column tooltip.
struct ProcessTabTooltip: NSViewRepresentable {
    let script: RunnerScript

    func makeNSView(context: Context) -> ProcessTabTooltipTrackingView {
        ProcessTabTooltipTrackingView(frame: .zero)
    }

    func updateNSView(_ view: ProcessTabTooltipTrackingView, context: Context) {
        view.content = ProcessTabTooltipContent(script: script)
    }

    static func dismantleNSView(_ view: ProcessTabTooltipTrackingView, coordinator: ()) {
        view.hideTooltip()
    }
}

@MainActor
final class ProcessTabTooltipTrackingView: NSView {
    var content: ProcessTabTooltipContent?
    private var hoverArea: NSTrackingArea?
    private var timer: Timer?
    private var panel: NSPanel?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hideTooltip()
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showTooltip() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func mouseExited(with event: NSEvent) { hideTooltip() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        hideTooltip()
        super.viewWillMove(toWindow: newWindow)
    }

    func hideTooltip() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func showTooltip() {
        guard let content, let window, window.isVisible,
              bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        let host = NSHostingView(rootView: ProcessTabTooltipTable(content: content))
        let size = host.fittingSize
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        guard let screen = window.screen else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let origin = NSPoint(
            x: max(visible.minX, min(anchor.minX, visible.maxX - size.width)),
            y: max(visible.minY, min(anchor.minY - size.height - 6, visible.maxY - size.height))
        )
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = window.effectiveAppearance
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        panel.contentView = host
        self.panel = panel
        panel.orderFrontRegardless()
    }
}

private struct ProcessTabTooltipTable: View {
    let content: ProcessTabTooltipContent

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                Text("command:").foregroundStyle(.secondary)
                Text(verbatim: content.command)
            }
            GridRow {
                Text("port:").foregroundStyle(.secondary)
                Text(verbatim: content.port)
            }
        }
        .font(.system(size: 11))
        .padding(10)
        .frame(maxWidth: 560, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    }
}

import AppKit
import SwiftUI

@MainActor
final class RunnerPopover: NSObject {
    static let contentSize = NSSize(width: 760, height: 560)
    private(set) var popover = NSPopover()
    private var needsRebuild = true

    override init() {
        super.init()
        popover.behavior = .transient
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        // A hidden popover can retain geometry from a disconnected display.
        // Rebuild on the next presentation, once the status button is on its new screen.
        needsRebuild = true
    }

    func prepare<Content: View>(content: () -> Content) -> NSPopover {
        guard needsRebuild else { return popover }
        let behavior = popover.behavior
        popover.close()
        let replacement = NSPopover()
        replacement.behavior = behavior
        let controller = NSHostingController(rootView: content())
        controller.sizingOptions = []
        controller.view.setFrameSize(Self.contentSize)
        replacement.contentViewController = controller
        replacement.contentSize = Self.contentSize
        popover = replacement
        needsRebuild = false
        return replacement
    }
}

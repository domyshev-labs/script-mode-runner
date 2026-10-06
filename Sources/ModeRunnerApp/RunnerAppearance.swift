import AppKit
import SwiftUI

// Use the system renderer so newer macOS versions supply their current glass appearance.
struct RunnerGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 8, content: content)
        } else {
            content()
        }
    }
}

private struct RunnerGlass: ViewModifier {
    var radius: CGFloat
    var tint: Color?
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.25)))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background((tint ?? .clear).opacity(0.12), in: shape)
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}

extension View {
    func runnerGlass(radius: CGFloat = 12, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(RunnerGlass(radius: radius, tint: tint, interactive: interactive))
    }
}

@MainActor
enum RunnerIcon {
    static var image: NSImage {
        let image = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "Mode Runner")!
        image.isTemplate = false
        return image
    }
}

// A dedicated view keeps the status item's hit target stationary during the pulse.
@MainActor
final class StatusIconView: NSView {
    private let image = RunnerIcon.image
    var pulseScale: CGFloat = 1 { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(18 * pulseScale, min(bounds.width, bounds.height))
        image.draw(in: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                              width: side, height: side))
    }
}

enum StartupPulse {
    static let duration = 1.8

    static func scale(at elapsed: TimeInterval) -> CGFloat {
        guard elapsed > 0, elapsed < duration else { return 1 }
        // Three smooth grow/shrink cycles, each returning exactly to the resting size.
        let phase = elapsed / (duration / 3)
        return 1 + 0.22 * pow(sin(.pi * phase), 2)
    }
}

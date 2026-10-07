import AppKit
import SwiftUI

// Use the system renderer so newer macOS versions supply their current glass appearance.
struct RunnerGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

private struct RunnerGlass<Surface: Shape>: ViewModifier {
    var shape: Surface
    var tint: Color?
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.25)))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background((tint ?? .clear).opacity(0.12), in: shape)
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.1)))
        }
    }
}

extension View {
    func runnerGlass(radius: CGFloat = 12, tint: Color? = nil, interactive: Bool = false) -> some View {
        runnerGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint, interactive: interactive)
    }

    func runnerGlass<Surface: Shape>(in shape: Surface, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(RunnerGlass(shape: shape, tint: tint, interactive: interactive))
    }
}

// Both side edges lean to the right at the top, like a slash.
struct SlantedTabShape: Shape {
    var slant: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let inset = min(slant, rect.width / 2)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

struct LogActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct HoverLabel: View {
        let label: ButtonStyleConfiguration.Label
        let pressed: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            label
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.primary.opacity(enabled && (hovered || pressed) ? 0.12 : 0),
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(RoundedRectangle(cornerRadius: 5))
                .onHover { hovered = $0 }
        }
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

struct DotActivityIndicator: View {
    @State private var started = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            Canvas { drawing, size in
                let elapsed = max(0, context.date.timeIntervalSince(started))
                let phase = reduceMotion ? 2.0 : elapsed.truncatingRemainder(dividingBy: 1.2) / 0.4
                let stage = Int(phase)
                let progress = phase - Double(stage)
                // Hold each pose briefly, then move in straight lines to the next pose.
                let t = min(max((progress - 0.35) / 0.65, 0), 1)
                let eased = t * t * (3 - 2 * t)
                let poses: [(x: Double, y: Double, radius: Double)] = [(0, 3.5, 1.6), (3.5, 0, 1.6), (0, 0, 2.8), (0, 3.5, 1.6)]
                let from = poses[stage], to = poses[stage + 1]
                let x = from.x + (to.x - from.x) * eased
                let y = from.y + (to.y - from.y) * eased
                let radius = from.radius + (to.radius - from.radius) * eased
                for direction in [-1.0, 1.0] {
                    let rect = CGRect(x: size.width / 2 + x * direction - radius,
                                      y: size.height / 2 + y * direction - radius,
                                      width: radius * 2, height: radius * 2)
                    drawing.fill(Path(ellipseIn: rect), with: .foreground)
                }
            }
        }
        .accessibilityLabel("In progress")
    }
}

struct ProcessActionButton: View {
    let title: String
    let loading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .opacity(loading ? 0 : 1)
                .overlay {
                    if loading { DotActivityIndicator().frame(width: 14, height: 14) }
                }
        }
        .accessibilityLabel(title + (loading ? ", in progress" : ""))
    }
}

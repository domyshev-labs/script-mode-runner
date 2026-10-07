import AppKit
import SwiftUI

@MainActor
final class RunnerInformationWindows: NSObject, NSWindowDelegate {
    weak var mainPopover: NSPopover?
    private var presentedWindows: Set<ObjectIdentifier> = []
    private var aboutWindow: NSWindow?
    private var documentationWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func showAbout(relativeTo parent: NSWindow? = nil) {
        if aboutWindow == nil {
            aboutWindow = makeAboutWindow()
        }
        present(aboutWindow, relativeTo: parent)
    }

    func showDocumentation(relativeTo parent: NSWindow? = nil) {
        if documentationWindow == nil {
            do {
                documentationWindow = try makeDocumentationWindow()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not open documentation"
                alert.informativeText = error.localizedDescription
                NSApplication.shared.activate(ignoringOtherApps: true)
                alert.runModal()
                return
            }
        }
        present(documentationWindow, relativeTo: parent, centeredOnScreen: true)
    }

    func showSettings(preferences: RunnerActionPreferences, relativeTo parent: NSWindow? = nil) {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow(preferences: preferences)
        }
        present(settingsWindow, relativeTo: parent)
    }

    func makeSettingsWindow(preferences: RunnerActionPreferences) -> NSWindow {
        makeWindow(title: "Mode Runner Settings", size: NSSize(width: 440, height: 230),
                   minimumSize: NSSize(width: 440, height: 230), resizable: false,
                   content: RunnerSettingsView(preferences: preferences))
    }

    func makeAboutWindow() -> NSWindow {
        makeWindow(title: "About Mode Runner", size: NSSize(width: 480, height: 320),
                   minimumSize: NSSize(width: 480, height: 320), resizable: false,
                   content: RunnerAboutView())
    }

    func makeDocumentationWindow() throws -> NSWindow {
        guard let url = Bundle.module.url(forResource: "Usage", withExtension: "md") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let markdown = try String(contentsOf: url, encoding: .utf8)
        return makeWindow(title: "Mode Runner Documentation", size: NSSize(width: 720, height: 620),
                          minimumSize: NSSize(width: 520, height: 400), resizable: true,
                          content: RunnerDocumentationView(markdown: markdown))
    }

    private func makeWindow<Content: View>(title: String, size: NSSize,
                                          minimumSize: NSSize, resizable: Bool,
                                          content: Content) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = true
        let controller = NSHostingController(rootView: content.frame(
            minWidth: minimumSize.width, maxWidth: .infinity,
            minHeight: minimumSize.height, maxHeight: .infinity
        ))
        // AppKit owns window sizing; SwiftUI's ideal size must not shrink the window.
        controller.sizingOptions = []
        window.contentViewController = controller
        window.contentMinSize = minimumSize
        if !resizable { window.contentMaxSize = size }
        window.setContentSize(size)
        window.center()
        return window
    }

    func prepareForPresentation(_ window: NSWindow, relativeTo parent: NSWindow?,
                                centeredOnScreen: Bool = false) {
        let screen = parent?.screen ?? NSScreen.main
        guard let parent else {
            window.level = .normal
            if centeredOnScreen, let screen {
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                              y: screen.visibleFrame.midY - window.frame.height / 2))
            }
            return
        }
        window.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
        let frame = window.frame
        var origin = NSPoint(x: parent.frame.midX - frame.width / 2,
                             y: parent.frame.midY - frame.height / 2)
        if let screen {
            let visible = screen.visibleFrame
            if centeredOnScreen {
                origin = NSPoint(x: visible.midX - frame.width / 2,
                                 y: visible.midY - frame.height / 2)
            }
            origin.x = max(visible.minX, min(origin.x, visible.maxX - frame.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - frame.height))
        }
        window.setFrameOrigin(origin)
    }

    private func present(_ window: NSWindow?, relativeTo parent: NSWindow?,
                         centeredOnScreen: Bool = false) {
        guard let window else { return }
        beginPresentation(window)
        prepareForPresentation(window, relativeTo: parent, centeredOnScreen: centeredOnScreen)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func beginPresentation(_ window: NSWindow) {
        presentedWindows.insert(ObjectIdentifier(window))
        // Keep the workspace open while focus moves to an information window.
        mainPopover?.behavior = .applicationDefined
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              presentedWindows.remove(ObjectIdentifier(window)) != nil else { return }
        // Finish the close-button event before restoring transient dismissal.
        DispatchQueue.main.async { [weak self] in
            guard let self, presentedWindows.isEmpty, let popover = mainPopover else { return }
            if popover.isShown {
                popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            }
            popover.behavior = .transient
        }
    }
}

private struct RunnerAboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        guard let version else { return "Development build" }
        return "Version \(version)" + (build.map { " (\($0))" } ?? "")
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: RunnerIcon.image).resizable().frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("Mode Runner").font(.title2.bold())
            Text(version).font(.caption).foregroundStyle(.secondary)
            Text("Run local command groups from your menu bar.").foregroundStyle(.secondary)
            Text("Created by ilia domyshev")
            Link("GitHub · domyshev-labs/script-mode-runner",
                 destination: URL(string: "https://github.com/domyshev-labs/script-mode-runner")!)
        }
        .textSelection(.enabled)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Render the portable guide's headings, paragraphs, lists, and fenced code locally.
private struct RunnerDocumentationView: View {
    let markdown: String

    private struct Block: Identifiable {
        enum Kind { case heading(Int), paragraph, bullet, code }
        let id: Int
        let kind: Kind
        let text: String
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var lines: [String] = []
        var inCode = false
        func append(_ kind: Block.Kind, _ text: String) {
            result.append(Block(id: result.count, kind: kind, text: text))
        }
        func flush() {
            guard !lines.isEmpty else { return }
            append(inCode ? .code : .paragraph, lines.joined(separator: inCode ? "\n" : " "))
            lines.removeAll()
        }
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("```") { flush(); inCode.toggle() }
            else if inCode { lines.append(line) }
            else if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() }
            else if line.hasPrefix("#") {
                flush()
                let level = line.prefix(while: { $0 == "#" }).count
                append(.heading(level), String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("- ") {
                flush()
                append(.bullet, String(line.dropFirst(2)))
            } else { lines.append(line) }
        }
        flush()
        return result
    }

    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(blocks) { block in
                    switch block.kind {
                    case .heading(let level):
                        inline(block.text).font(level == 1 ? .title.bold() : .title3.bold())
                            .padding(.top, level == 1 ? 0 : 12)
                    case .paragraph:
                        inline(block.text)
                    case .bullet:
                        HStack(alignment: .top, spacing: 10) {
                            Text("•")
                            inline(block.text).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .code:
                        Text(verbatim: block.text).font(.system(.callout, design: .monospaced))
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .lineSpacing(4)
            .textSelection(.enabled)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

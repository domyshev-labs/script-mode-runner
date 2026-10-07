import AppKit
import ModeRunnerCore
import Testing
@testable import ModeRunnerApp

@Test func startupPulseHasExactlyThreePeaksAndReturnsToRest() {
    #expect(StartupPulse.scale(at: -1) == 1)
    #expect(StartupPulse.scale(at: 0) == 1)
    for cycle in 0..<3 {
        let start = Double(cycle) * 0.6
        #expect(abs(StartupPulse.scale(at: start) - 1) < 0.0001)
        #expect(abs(StartupPulse.scale(at: start + 0.3) - 1.22) < 0.0001)
        #expect(abs(StartupPulse.scale(at: start + 0.6) - 1) < 0.0001)
    }
    #expect(StartupPulse.scale(at: StartupPulse.duration) == 1)
    #expect(StartupPulse.scale(at: 5) == 1)
}

@MainActor
@Test func bundledMenuBarIconPreservesColorAndDoesNotInterceptClicks() {
    let icon = RunnerIcon.image
    #expect(!icon.isTemplate)
    #expect(icon.size.width == 128)
    #expect(icon.size.height == 128)
    let view = StatusIconView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    #expect(view.hitTest(NSPoint(x: 12, y: 12)) == nil)
}

@MainActor
@Test func slantedProjectDropTargetsFollowVisibleDividers() {
    let tabs = ["one", "two", "three"].map { RunnerTab(id: $0, title: $0, buttons: []) }
    func target(_ x: CGFloat, _ y: CGFloat) -> String? {
        projectTabID(at: CGPoint(x: x, y: y), width: 310, tabs: tabs,
                     height: 30, spacing: -10, slant: 10)
    }
    // The first slash moves from x=110 at the top to x=100 at the bottom.
    #expect(target(105, 0) == "one")
    #expect(target(105, 15) == "two")
    #expect(target(105, 30) == "two")
    #expect(target(205, 0) == "two")
    #expect(target(205, 30) == "three")
    #expect(target(5, 0) == nil)
    #expect(target(305, 30) == nil)
    #expect(target(5, 30) == "one")
    #expect(target(305, 0) == "three")
}

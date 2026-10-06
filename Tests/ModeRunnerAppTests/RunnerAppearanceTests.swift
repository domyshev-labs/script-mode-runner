import AppKit
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

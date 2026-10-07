import Foundation
import Testing
@testable import ModeRunnerApp

@Test func processTabsShowFullTitlesWhenTheRowHasRoom() {
    #expect(processTabWidths(idealWidths: [280, 220], availableWidth: 724) == [280, 220])
}

@Test func processTabsShrinkLongTitlesOnlyAfterFillingTheContainer() {
    let widths = processTabWidths(idealWidths: [400, 220], availableWidth: 508)
    #expect(abs(widths[0] - 280) < 0.001)
    #expect(widths[1] == 220)
    let equal = processTabWidths(idealWidths: [400, 380], availableWidth: 508)
    #expect(equal.allSatisfy { abs($0 - 250) < 0.001 })
}

@Test func crowdedProcessTabsKeepUsableWidthsForHorizontalScrolling() {
    #expect(processTabWidths(idealWidths: [400, 220, 80], availableWidth: 180) == [96, 96, 80])
    #expect(processTabWidths(idealWidths: [], availableWidth: 180).isEmpty)
}

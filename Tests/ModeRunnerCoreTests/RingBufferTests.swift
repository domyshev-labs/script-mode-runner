import Foundation
import Testing
@testable import ModeRunnerCore

@Test func ringBufferKeepsNewestBytes() {
    var buffer = ByteRingBuffer(capacity: 5)
    buffer.append(Data("abc".utf8))
    buffer.append(Data("def".utf8))
    #expect(buffer.string == "bcdef")
}

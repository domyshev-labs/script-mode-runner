import Foundation

public struct ByteRingBuffer: Sendable {
    public let capacity: Int
    private var data = Data()

    public init(capacity: Int = 5 * 1024 * 1024) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ newData: Data) {
        if newData.count >= capacity {
            data = Data(newData.suffix(capacity))
            return
        }
        data.append(newData)
        if data.count > capacity {
            data.removeFirst(data.count - capacity)
        }
    }

    public mutating func removeAll() {
        data.removeAll(keepingCapacity: true)
    }

    public var string: String {
        String(decoding: data, as: UTF8.self)
    }
}

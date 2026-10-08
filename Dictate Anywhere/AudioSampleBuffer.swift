import Foundation

/// FIFO PCM storage. Consuming frames advances a cursor; compaction is occasional
/// instead of shifting the remaining recording for every VAD or preview frame.
nonisolated struct AudioSampleBuffer {
    private var storage: [Float] = []
    private var start = 0

    var count: Int { storage.count - start }
    var isEmpty: Bool { count == 0 }
    var samples: ArraySlice<Float> { storage[start...] }

    mutating func append(_ samples: [Float]) {
        if start >= 4_096 && start >= storage.count / 2 {
            storage.removeFirst(start)
            start = 0
        }
        storage.append(contentsOf: samples)
    }

    mutating func discardFirst(_ count: Int) {
        precondition(count >= 0 && count <= self.count)
        start += count
        if start == storage.count { reset(keepingCapacity: true) }
    }

    mutating func reset(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        start = 0
    }
}

import Darwin
import Foundation

nonisolated enum S1MiniCPUConfiguration {
    static var threadCount: Int32 {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let physical = sysctlbyname("hw.physicalcpu", &count, &size, nil, 0) == 0 ? Int(count) : 1
        return Int32(threads(physicalCores: physical, activeProcessors: ProcessInfo.processInfo.activeProcessorCount))
    }

    // Bound work to physical cores instead of oversubscribing Intel's SMT
    // siblings. The small S1 graph is memory-bound; cap larger workstations at 8.
    static func threads(physicalCores: Int, activeProcessors: Int) -> Int {
        max(1, min(8, physicalCores, activeProcessors))
    }
}

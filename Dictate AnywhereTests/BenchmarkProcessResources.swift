import Darwin
import Foundation

/// Process counters, not model-only memory or a power/energy measurement.
/// Peak RSS is cumulative for this process; isolate models in separate runs
/// when comparing memory. CPU time includes all of the process's threads.
struct BenchmarkProcessResources {
    let cpuMilliseconds: Double
    let peakResidentBytes: Int64

    static func sample() throws -> Self {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return Self(cpuMilliseconds:
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000,
            peakResidentBytes: Int64(usage.ru_maxrss))
    }
}

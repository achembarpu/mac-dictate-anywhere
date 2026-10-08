import Accelerate
import Foundation

/// Matches the recording-wide overlapping volume test without retaining PCM.
/// Silero remains the separate fallback for speech below these volume thresholds.
nonisolated struct AudioVolumeGate {
    static let windowSamples = 8_000
    private static let hopSamples = windowSamples / 2
    private var pending = AudioSampleBuffer()
    private var recent = AudioSampleBuffer()
    private var totalSamples = 0
    private var lastFullWindowEnd = 0
    private var qualified = false

    var recentSamples: [Float] { Array(recent.samples) }
    var retainedSampleCount: Int { pending.count + recent.count }

    mutating func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        recent.append(samples)
        recent.discardFirst(max(0, recent.count - Self.windowSamples))
        totalSamples += samples.count
        guard !qualified else { return }
        pending.append(samples)
        while pending.count >= Self.windowSamples {
            qualified = Self.qualifies(pending.samples.prefix(Self.windowSamples))
            lastFullWindowEnd = totalSamples - pending.count + Self.windowSamples
            if qualified {
                pending.reset()
                return
            }
            pending.discardFirst(Self.hopSamples)
        }
    }

    var containsSignificantAudio: Bool {
        // The old scan stops at a window ending exactly at the recording end.
        // Rechecking its shorter overlapping suffix would change peak density.
        qualified || (totalSamples != lastFullWindowEnd && Self.qualifies(pending.samples))
    }

    static func qualifies(_ samples: ArraySlice<Float>) -> Bool {
        guard !samples.isEmpty else { return false }
        var rms: Float = 0
        samples.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &rms, vDSP_Length($0.count)) }
        if rms > 0.005 { return true }
        var peak: Float = 0
        samples.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress!, 1, &peak, vDSP_Length($0.count)) }
        guard peak >= 0.02 else { return false }
        let voiced = samples.reduce(into: 0) { if abs($1) >= 0.02 { $0 += 1 } }
        return Float(voiced) / Float(samples.count) >= 0.015
    }
}

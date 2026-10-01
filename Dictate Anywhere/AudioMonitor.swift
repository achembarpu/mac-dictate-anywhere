//
//  AudioMonitor.swift
//  Dictate Anywhere
//
//  RMS audio level calculation for waveform visualization.
//

import Foundation
import Accelerate

/// Only the latest RMS window is needed for visualization. Recording and
/// recognition keep their audio in separate buffers owned by each engine.
nonisolated struct AudioLevelSampleBuffer {
    private(set) var samples: [Float] = []

    mutating func append(_ incoming: [Float]) {
        guard !incoming.isEmpty else { return }
        let latest = incoming.suffix(AudioMonitor.windowSampleCount)
        let retainedCount = AudioMonitor.windowSampleCount - latest.count
        if samples.count > retainedCount {
            samples.removeFirst(samples.count - retainedCount)
        }
        samples.append(contentsOf: latest)
    }

    func latest(count: Int) -> [Float] {
        Array(samples.suffix(max(0, count)))
    }

    mutating func reset(keepingCapacity: Bool) {
        samples.removeAll(keepingCapacity: keepingCapacity)
    }
}

@Observable
final class AudioMonitor {
    // MARK: - Properties

    var smoothedLevel: Float = 0.0

    private let attackSmoothing: Float = 0.08
    private let releaseSmoothing: Float = 0.65
    nonisolated static let windowSampleCount = 800
    private let visualizationGain: Float = 6.6

    static let displayLevelTolerance: Float = 0.01

    // MARK: - Public

    /// Updates the level from raw audio samples
    func update(samples: ArraySlice<Float>) {
        guard !samples.isEmpty else { return }
        let window = samples.suffix(Self.windowSampleCount)

        let rms = calculateRMS(window)
        let smoothing = rms > smoothedLevel ? attackSmoothing : releaseSmoothing
        smoothedLevel = smoothedLevel * smoothing + rms * (1 - smoothing)
    }

    static func hasMeaningfulLevelChange(from previous: Float?, to current: Float) -> Bool {
        guard let previous else { return true }
        return abs(current - previous) >= displayLevelTolerance
    }

    /// Resets the monitor state
    func reset() {
        smoothedLevel = 0
    }

    // MARK: - Private

    private func calculateRMS(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            vDSP_rmsqv(buffer.baseAddress!, 1, &rms, vDSP_Length(buffer.count))
        }
        let scaled = min(1.0, rms * visualizationGain)
        return powf(scaled, 0.85)
    }
}

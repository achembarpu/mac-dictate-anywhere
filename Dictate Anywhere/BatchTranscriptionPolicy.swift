import Foundation
import FluidAudio

/// Audio-time policies. Inference time never creates a queue of stale previews.
nonisolated enum BatchTranscriptionPolicy {
    static let sampleRate = 16_000
    static let pollingMilliseconds: UInt64 = 500
    static let firstPreviewSamples = sampleRate / 2
    static let previewDeltaSamples = sampleRate
    static let previewWindowSamples = sampleRate * 15
    static let senseVoiceTargetSamples = sampleRate * 15
    static let senseVoiceMaximumSamples = sampleRate * 30

    /// Preserve the app's SDK decode configuration for previews and parent
    /// comparisons; the overlap session has its own model-aware window policy.
    static var asrConfig: ASRConfig {
        ASRConfig(streamingEnabled: true, streamingThreshold: sampleRate * 10)
    }

    /// The selected language constrains script, not vocabulary or language detection.
    static func scriptLanguage(for model: ParakeetModelChoice, selected: SupportedLanguage) -> Language? {
        guard model == .multilingual || model == .multilingualUltra else { return nil }
        // SDK Cyrillic/Greek filters reject Latin names. Russian goldens lose
        // "NextGen" even when aggregate WER is unchanged. Keep automatic
        // decoding for these scripts until the SDK can allow foreign names.
        switch selected {
        case .bulgarian, .ukrainian, .russian, .greek: return nil
        default: return Language(rawValue: selected.rawValue)
        }
    }

    static func shouldPreview(totalSamples: Int, lastPreviewSamples: Int, hasVisibleText: Bool) -> Bool {
        totalSamples - lastPreviewSamples >= (hasVisibleText ? previewDeltaSamples : firstPreviewSamples)
    }

    /// A successful final decode may legitimately be shorter than a live guess.
    static func finalTranscript(_ final: String, fallback: String) -> String {
        let text = final.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
}

/// Speech classification can qualify quiet audio rejected by the volume gate.
/// The last observation expires so silence does not schedule endless previews.
nonisolated struct BatchSpeechPresence {
    private(set) var hasSpeech = false
    private var lastSpeechSample: Int?

    mutating func observe(isSpeech: Bool, at sample: Int) {
        guard isSpeech else { return }
        hasSpeech = true
        lastSpeechSample = sample
    }

    func hasRecentSpeech(at sample: Int) -> Bool {
        guard let lastSpeechSample else { return false }
        return sample - lastSpeechSample <= BatchTranscriptionPolicy.firstPreviewSamples
    }
}

/// Chooses disjoint SenseVoice segments without filtering out any captured audio.
nonisolated struct SenseVoicePauseBoundaries {
    private(set) var pauses: [Int] = []

    mutating func recordPause(at sample: Int) {
        guard sample > 0, pauses.last != sample else { return }
        pauses.append(sample)
    }

    func nextBoundary(start: Int, end: Int) -> Int? {
        let target = start + BatchTranscriptionPolicy.senseVoiceTargetSamples
        let maximum = start + BatchTranscriptionPolicy.senseVoiceMaximumSamples
        guard end >= target else { return nil }
        let available = pauses.filter { $0 > start && $0 <= min(end, maximum) }
        if let beforeTarget = available.last(where: { $0 <= target }) { return beforeTarget }
        if let afterTarget = available.first { return afterTarget }
        return end >= maximum ? maximum : nil
    }

    mutating func didCommit(through sample: Int) {
        pauses.removeAll { $0 <= sample }
    }
}

/// Only the provisional UI uses this timeline. Final text comes from the SDK's
/// token-aware overlap merger, never from string suffix/prefix deduplication.
nonisolated struct BatchPreviewTimeline {
    private(set) var words: [WordTiming] = []

    mutating func update(_ timings: [TokenTiming]) {
        let incoming = buildWordTimings(from: timings)
        guard let first = incoming.first else { return }
        // A new SDK window can replace its predecessor's trailing word.
        words.removeAll { $0.endTime > first.startTime }
        words.append(contentsOf: incoming)
    }

    /// A batch-only backend has no SDK live updates. Keep the prior prefix and
    /// replace the covered provisional tail using original audio positions.
    mutating func recordPreview(_ result: ASRResult, startingAt sample: Int) -> String {
        let offset = Double(sample) / Double(BatchTranscriptionPolicy.sampleRate)
        let timings = (result.tokenTimings ?? []).map {
            TokenTiming(token: $0.token, tokenId: $0.tokenId, startTime: $0.startTime + offset,
                        endTime: $0.endTime + offset, confidence: $0.confidence)
        }
        update(timings)
        return words.isEmpty ? result.text : words.map(\.word).joined(separator: " ")
    }

    func preview(_ result: ASRResult, startingAt sample: Int) -> String {
        guard let last = words.last else { return result.text }
        let offset = Double(sample) / Double(BatchTranscriptionPolicy.sampleRate)
        // If recognition falls behind, keep the covered prefix visible until
        // the SDK catches up instead of displaying a gap in the recording.
        guard offset <= last.startTime else { return words.map(\.word).joined(separator: " ") }
        let tail = buildWordTimings(from: result.tokenTimings ?? [])
            .filter { $0.endTime + offset > last.startTime }
        guard !tail.isEmpty else { return words.map(\.word).joined(separator: " ") }
        return (words.dropLast().map(\.word) + tail.map(\.word)).joined(separator: " ")
    }
}

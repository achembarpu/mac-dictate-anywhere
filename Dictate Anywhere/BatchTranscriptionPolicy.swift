import Foundation
import FluidAudio

/// Audio-time policies. Inference time never creates a queue of stale previews.
nonisolated enum BatchTranscriptionPolicy {
    static let sampleRate = 16_000
    static let batchProcessingSignalSamples = sampleRate / 4
    static let firstPreviewSamples = sampleRate / 2
    static let previewDeltaSamples = sampleRate
    static let sustainedPreviewStartSamples = sampleRate * 8
    static let sustainedPreviewDeltaSamples = sampleRate * 2
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

    /// Growing-window TDT guesses repeatedly decode the same audio. Preserve
    /// early feedback, then reduce duplicate inference on sustained recordings.
    static func shouldPreview(isEnabled: Bool = true, totalSamples: Int, lastPreviewSamples: Int,
                              hasVisibleText: Bool, model: ParakeetModelChoice) -> Bool {
        guard isEnabled else { return false }
        let interval: Int
        if !hasVisibleText { interval = firstPreviewSamples }
        else if !model.usesTrueStreaming, model != .senseVoice, totalSamples >= sustainedPreviewStartSamples {
            interval = sustainedPreviewDeltaSamples
        } else { interval = previewDeltaSamples }
        return totalSamples - lastPreviewSamples >= interval
    }

    /// A successful final decode may legitimately be shorter than a live guess.
    static func finalTranscript(_ final: String, fallback: String) -> String {
        let text = final.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
}

/// Coalesces capture callbacks into bounded audio-time work notifications.
/// The consumer drains all queued samples after each signal, so a full signal
/// buffer never drops audio or creates a backlog of stale decode requests.
nonisolated struct AudioProcessingSignalThreshold: Sendable {
    private let subsequentChunkSamples: Int
    private var nextSignalSample: Int

    init(thresholdSamples: Int) {
        self.init(firstChunkSamples: thresholdSamples, subsequentChunkSamples: thresholdSamples)
    }

    init(firstChunkSamples: Int, subsequentChunkSamples: Int) {
        precondition(firstChunkSamples > 0 && subsequentChunkSamples > 0)
        self.subsequentChunkSamples = subsequentChunkSamples
        self.nextSignalSample = firstChunkSamples
    }

    /// Signals only when the recording timeline crosses the next complete SDK
    /// chunk boundary. A coalesced wake can cover several boundaries because
    /// the consumer passes all accumulated samples to the SDK at once.
    mutating func shouldSignal(totalSamples: Int) -> Bool {
        guard totalSamples >= nextSignalSample else { return false }
        nextSignalSample += subsequentChunkSamples
        while nextSignalSample <= totalSamples {
            nextSignalSample += subsequentChunkSamples
        }
        return true
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

/// Keeps authoritative streaming tokens separate from manual provisional tokens.
/// Final text comes from the SDK's token-aware overlap merger, never this timeline.
nonisolated struct BatchPreviewTimeline {
    private(set) var authoritativeWords: [WordTiming] = []
    private(set) var provisionalWords: [WordTiming] = []
    private var provisionalFallbackText = ""

    mutating func recordAuthoritativeUpdate(_ timings: [TokenTiming]) {
        let incoming = buildWordTimings(from: timings)
        guard let first = incoming.first else { return }
        // SDK updates contain only the current chunk. A new chunk may revise
        // its predecessor's trailing word, matching the legacy stream timeline.
        authoritativeWords.removeAll { $0.endTime > first.startTime }
        authoritativeWords.append(contentsOf: incoming)
        discardAuthoritativeProvisionalPrefix()
    }

    /// Retain an overlapping bridge between SDK progress and the rolling manual
    /// suffix. A newly arrived SDK chunk always owns its timeline; the manual
    /// guess cannot replace that authoritative prefix.
    mutating func recordProvisionalPreview(_ result: ASRResult, startingAt sample: Int) -> String {
        let offset = Double(sample) / Double(BatchTranscriptionPolicy.sampleRate)
        provisionalFallbackText = result.text
        let incoming = (result.tokenTimings ?? []).map {
            TokenTiming(token: $0.token, tokenId: $0.tokenId, startTime: $0.startTime + offset,
                        endTime: $0.endTime + offset, confidence: $0.confidence)
        }
        let words = buildWordTimings(from: incoming)
        if let first = words.first {
            provisionalWords.removeAll { $0.endTime > first.startTime }
            provisionalWords.append(contentsOf: words)
            discardAuthoritativeProvisionalPrefix()
        }
        return previewText
    }

    var previewText: String {
        guard let authoritativeLast = authoritativeWords.last else {
            return provisionalWords.isEmpty
                ? provisionalFallbackText
                : provisionalWords.map(\.word).joined(separator: " ")
        }
        // SDK chunks are authoritative, including their trailing word. The
        // rolling manual timeline fills only the uncovered bridge and suffix.
        var bridge = provisionalWords.filter { $0.endTime > authoritativeLast.endTime }
        // A word crossing the frontier may be the same boundary token the SDK
        // just confirmed. Keep one copy while retaining any earlier bridge.
        if let first = bridge.first, first.startTime < authoritativeLast.endTime,
           first.word == authoritativeLast.word {
            bridge.removeFirst()
        }
        return (authoritativeWords.map(\.word) + bridge.map(\.word)).joined(separator: " ")
    }

    private mutating func discardAuthoritativeProvisionalPrefix() {
        guard let frontier = authoritativeWords.last?.endTime else { return }
        provisionalWords.removeAll { $0.endTime <= frontier }
    }
}

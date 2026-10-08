@preconcurrency import AVFoundation
import Foundation
import FluidAudio

/// A recording-scoped decoder. The SDK input stream is single-use, so each
/// recording gets a new session while the already-loaded models are reused.
actor BatchTranscriptionSession {
    /// Keep the rolling TDT preview's most recent audio small enough to bound
    /// joint-decoder work. The authoritative final still consumes every sample.
    private let provisionalTDTWindowSamples: Int?

    private enum Backend {
        case parakeet(AsrManager, SlidingWindowAsrManager)
        case parakeetBatch(AsrManager)
        case senseVoice(SenseVoiceManager)
    }

    private let backend: Backend
    private let language: Language?
    private let vad: VadManager?
    private let previewsEnabled: Bool
    private var updateTask: Task<Void, Never>?
    private var samples = AudioSampleBuffer()
    private var startSample = 0
    private var totalSamples = 0
    private var lastPreviewTotalSamples = 0
    private var previewTimeline = BatchPreviewTimeline()
    private var committedText = ""
    private var pauseBoundaries = SenseVoicePauseBoundaries()
    private var vadState = VadStreamState.initial()
    private var vadPending = AudioSampleBuffer()
    private var speechPresence = BatchSpeechPresence()

    private init(backend: Backend, vad: VadManager?, language: Language? = nil,
                 previewsEnabled: Bool, provisionalTDTWindowSamples: Int? = nil) {
        self.backend = backend
        self.vad = vad
        self.language = language
        self.previewsEnabled = previewsEnabled
        self.provisionalTDTWindowSamples = provisionalTDTWindowSamples
    }

    static func parakeet(models: AsrModels, previewManager: AsrManager, vad: VadManager?, language: Language?,
                         requiresWholeRecordingFinal: Bool, previewsEnabled: Bool) async throws -> BatchTranscriptionSession {
        if models.version == .v2 || requiresWholeRecordingFinal {
            // The SDK batch path preserves v2 mel context and repairs gaps.
            // Its live overlap path drops clear speech in shifted-seam goldens.
            // Vocabulary uses a whole-recording final too, so its previews do
            // not need a second overlap decoder whose result would be discarded.
            return BatchTranscriptionSession(backend: .parakeetBatch(previewManager), vad: vad, language: language,
                                             previewsEnabled: previewsEnabled)
        }
        // The short provisional window is evaluated only for the v3 and 110M
        // streaming paths. V2, Ultra, and whole-recording vocabulary previews
        // retain their existing context until they pass their own quality gate.
        let provisionalWindow = models.version == .v3 || models.version == .tdtCtc110m
            ? 12 * BatchTranscriptionPolicy.sampleRate
            : nil
        let overlapping = SlidingWindowAsrManager(config: .streaming.applying(language: language))
        try await overlapping.loadModels(models)
        let session = BatchTranscriptionSession(backend: .parakeet(previewManager, overlapping), vad: vad,
                                                language: language, previewsEnabled: previewsEnabled,
                                                provisionalTDTWindowSamples: provisionalWindow)
        try await session.start()
        return session
    }

    static func senseVoice(manager: SenseVoiceManager, vad: VadManager?, previewsEnabled: Bool) -> BatchTranscriptionSession {
        BatchTranscriptionSession(backend: .senseVoice(manager), vad: vad, previewsEnabled: previewsEnabled)
    }

    private func start() async throws {
        guard case .parakeet(_, let overlapping) = backend else { return }
        let updates = await overlapping.transcriptionUpdates
        updateTask = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled else { break }
                await self?.accept(update)
            }
        }
        try await overlapping.startStreaming(source: .microphone)
    }

    private func accept(_ update: SlidingWindowTranscriptionUpdate) {
        guard previewsEnabled else { return }
        previewTimeline.recordAuthoritativeUpdate(update.tokenTimings)
    }

    func append(_ newSamples: [Float]) async throws {
        guard !newSamples.isEmpty else { return }
        samples.append(newSamples)
        totalSamples += newSamples.count
        switch backend {
        case .parakeet(_, let overlapping):
            await overlapping.streamAudio(try Self.pcmBuffer(newSamples))
            retainPreviewWindow()
        case .parakeetBatch:
            retainPreviewWindow()
        case .senseVoice: break
        }
        if vad != nil {
            vadPending.append(newSamples)
            try await processVad()
        }
        try await commitSenseVoiceSegments()
    }

    private func retainPreviewWindow() {
        let excess = samples.count - BatchTranscriptionPolicy.previewWindowSamples
        if excess > 0 {
            samples.discardFirst(excess)
            startSample += excess
        }
    }

    private func processVad(flushTail: Bool = false) async throws {
        // Cached speech models remain usable without the optional VAD asset.
        // The engine's volume gate still qualifies audio, and SenseVoice's
        // maximum segment length still bounds retained audio without pauses.
        guard let vad else { return }
        let trace = PerfTrace.begin("stt.batchVAD", counts: ["input_samples": vadPending.count])
        do {
            while vadPending.count >= VadManager.chunkSize || (flushTail && !vadPending.isEmpty) {
                let count = min(vadPending.count, VadManager.chunkSize)
                var chunk = Array(vadPending.samples.prefix(count))
                chunk.append(contentsOf: repeatElement(Float(0), count: VadManager.chunkSize - count))
                let result = try await vad.processStreamingChunk(chunk, state: vadState)
                vadState = result.state
                vadPending.discardFirst(count)
                speechPresence.observe(isSpeech: result.state.triggered, at: min(result.state.processedSamples, totalSamples))
                if case .senseVoice = backend, let event = result.event, event.isEnd {
                    pauseBoundaries.recordPause(at: min(event.sampleIndex, totalSamples))
                }
            }
            trace.end(outcome: "completed")
        } catch {
            trace.end(outcome: PerfTrace.outcome(for: error))
            throw error
        }
    }

    var hasRecentSpeech: Bool { speechPresence.hasRecentSpeech(at: totalSamples) }

    func containsSpeechIncludingTail() async throws -> Bool {
        try await processVad(flushTail: true)
        return speechPresence.hasSpeech
    }

    func preview() async throws -> String {
        guard previewsEnabled else { return committedText }
        let maximumTDTWindowSamples = provisionalTDTWindowSamples ?? .max
        guard !samples.isEmpty else { return committedText }
        // A failed SenseVoice segment is retained for retry. Keep its provisional
        // decode bounded too; the authoritative finish still processes every sample.
        let input: [Float]
        let inputStartSample: Int
        switch backend {
        case .parakeet, .parakeetBatch:
            let windowCount = min(samples.count, max(1, maximumTDTWindowSamples))
            let skipped = samples.count - windowCount
            input = Array(samples.samples.suffix(windowCount))
            inputStartSample = startSample + skipped
        case .senseVoice:
            input = Array(samples.samples.prefix(BatchTranscriptionPolicy.senseVoiceMaximumSamples))
            inputStartSample = startSample
        }
        let newCount = min(input.count, totalSamples - lastPreviewTotalSamples)
        let trace = PerfTrace.begin("stt.batchPreview", counts: [
            "input_samples": input.count, "new_samples": newCount,
            "reprocessed_samples": input.count - newCount
        ])
        defer { trace.end() }
        lastPreviewTotalSamples = totalSamples
        switch backend {
        case .parakeet(let manager, _):
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(input, decoderState: &state, language: language)
            return previewTimeline.recordProvisionalPreview(result, startingAt: inputStartSample)
        case .parakeetBatch(let manager):
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(input, decoderState: &state, language: language)
            return previewTimeline.recordProvisionalPreview(result, startingAt: inputStartSample)
        case .senseVoice(let manager):
            let result = try await manager.transcribe(audio: input)
            return ParakeetEngine.joinChunkTranscripts(base: committedText, addition: result)
        }
    }

    private func commitSenseVoiceSegments() async throws {
        guard case .senseVoice(let manager) = backend else { return }
        while let boundary = pauseBoundaries.nextBoundary(start: startSample, end: totalSamples) {
            let count = boundary - startSample
            let chunk = Array(samples.samples.prefix(count))
            let text = try await manager.transcribe(audio: chunk)
            // Retire audio only after a successful decode, preserving failure recovery.
            committedText = ParakeetEngine.joinChunkTranscripts(base: committedText, addition: text)
            samples.discardFirst(count)
            startSample = boundary
            pauseBoundaries.didCommit(through: boundary)
        }
    }

    /// Whole-recording decoders consume the engine's retained original audio.
    /// Other backends have received every sample incrementally and ignore it.
    func finish(recordedSamples: [Float] = []) async throws -> String {
        let trace = PerfTrace.begin("stt.batchFinish", counts: ["retained_samples": samples.count])
        defer { trace.end() }
        switch backend {
        case .parakeetBatch(let manager):
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            return try await manager.transcribe(recordedSamples, decoderState: &state, language: language).text
        case .parakeet(_, let overlapping):
            do {
                let text = try await overlapping.finish()
                await closeOverlap(overlapping)
                return text
            } catch {
                await closeOverlap(overlapping)
                throw error
            }
        case .senseVoice(let manager):
            try await commitSenseVoiceSegments()
            if !samples.isEmpty {
                let text = try await manager.transcribe(audio: Array(samples.samples))
                committedText = ParakeetEngine.joinChunkTranscripts(base: committedText, addition: text)
                samples.reset()
            }
            return committedText
        }
    }

    func cancel() async {
        if case .parakeet(_, let overlapping) = backend {
            await overlapping.cancel()
            // The pinned SDK's cancel() requests cancellation but does not
            // await the recognizer task. finish() joins that task even when
            // it reports the expected cancellation error.
            _ = try? await overlapping.finish()
            await closeOverlap(overlapping)
        }
        samples.reset()
        vadPending.reset()
    }

    private func closeOverlap(_ overlapping: SlidingWindowAsrManager) async {
        await overlapping.cleanup()
        updateTask?.cancel()
        await updateTask?.value
        updateTask = nil
    }

    private static func pcmBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw TranscriptionError.audioEngineSetupFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        return buffer
    }
}

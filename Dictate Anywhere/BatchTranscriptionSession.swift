@preconcurrency import AVFoundation
import Foundation
import FluidAudio

/// A recording-scoped decoder. The SDK input stream is single-use, so each
/// recording gets a new session while the already-loaded models are reused.
actor BatchTranscriptionSession {
    private enum Backend {
        case parakeet(AsrManager, SlidingWindowAsrManager)
        case parakeetBatch(AsrManager)
        case senseVoice(SenseVoiceManager)
    }

    private let backend: Backend
    private let vad: VadManager
    private var updateTask: Task<Void, Never>?
    private var samples: [Float] = []
    private var startSample = 0
    private var totalSamples = 0
    private var lastPreviewTotalSamples = 0
    private var previewTimeline = BatchPreviewTimeline()
    private var committedText = ""
    private var pauseBoundaries = SenseVoicePauseBoundaries()
    private var vadState = VadStreamState.initial()
    private var vadPending: [Float] = []
    private var speechPresence = BatchSpeechPresence()

    private init(backend: Backend, vad: VadManager) {
        self.backend = backend
        self.vad = vad
    }

    static func parakeet(models: AsrModels, previewManager: AsrManager, vad: VadManager) async throws -> BatchTranscriptionSession {
        if models.version == .v2 {
            // The SDK batch path preserves v2 mel context and repairs gaps.
            // Its live overlap path drops clear speech in shifted-seam goldens.
            return BatchTranscriptionSession(backend: .parakeetBatch(previewManager), vad: vad)
        }
        let overlapping = SlidingWindowAsrManager(config: .streaming)
        try await overlapping.loadModels(models)
        let session = BatchTranscriptionSession(backend: .parakeet(previewManager, overlapping), vad: vad)
        try await session.start()
        return session
    }

    static func senseVoice(manager: SenseVoiceManager, vad: VadManager) -> BatchTranscriptionSession {
        BatchTranscriptionSession(backend: .senseVoice(manager), vad: vad)
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
        previewTimeline.update(update.tokenTimings)
    }

    func append(_ newSamples: [Float]) async throws {
        guard !newSamples.isEmpty else { return }
        samples.append(contentsOf: newSamples)
        totalSamples += newSamples.count
        switch backend {
        case .parakeet(_, let overlapping):
            await overlapping.streamAudio(try Self.pcmBuffer(newSamples))
            retainPreviewWindow()
        case .parakeetBatch:
            retainPreviewWindow()
        case .senseVoice: break
        }
        vadPending.append(contentsOf: newSamples)
        try await processVad()
        try await commitSenseVoiceSegments()
    }

    private func retainPreviewWindow() {
        let excess = samples.count - BatchTranscriptionPolicy.previewWindowSamples
        if excess > 0 {
            samples.removeFirst(excess)
            startSample += excess
        }
    }

    private func processVad(flushTail: Bool = false) async throws {
        let trace = PerfTrace.begin("stt.batchVAD", counts: ["input_samples": vadPending.count])
        do {
            while vadPending.count >= VadManager.chunkSize || (flushTail && !vadPending.isEmpty) {
                let count = min(vadPending.count, VadManager.chunkSize)
                var chunk = Array(vadPending.prefix(count))
                chunk.append(contentsOf: repeatElement(Float(0), count: VadManager.chunkSize - count))
                let result = try await vad.processStreamingChunk(chunk, state: vadState)
                vadState = result.state
                vadPending.removeFirst(count)
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
        guard !samples.isEmpty else { return committedText }
        // A failed SenseVoice segment is retained for retry. Keep its provisional
        // decode bounded too; the authoritative finish still processes every sample.
        let input: [Float]
        switch backend {
        case .parakeet, .parakeetBatch: input = samples
        case .senseVoice: input = Array(samples.prefix(BatchTranscriptionPolicy.senseVoiceMaximumSamples))
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
            let result = try await manager.transcribe(input, decoderState: &state)
            return previewTimeline.preview(result, startingAt: startSample)
        case .parakeetBatch(let manager):
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(input, decoderState: &state)
            return previewTimeline.recordPreview(result, startingAt: startSample)
        case .senseVoice(let manager):
            let result = try await manager.transcribe(audio: input)
            return ParakeetEngine.joinChunkTranscripts(base: committedText, addition: result)
        }
    }

    private func commitSenseVoiceSegments() async throws {
        guard case .senseVoice(let manager) = backend else { return }
        while let boundary = pauseBoundaries.nextBoundary(start: startSample, end: totalSamples) {
            let count = boundary - startSample
            let chunk = Array(samples.prefix(count))
            let text = try await manager.transcribe(audio: chunk)
            // Retire audio only after a successful decode, preserving failure recovery.
            committedText = ParakeetEngine.joinChunkTranscripts(base: committedText, addition: text)
            samples.removeFirst(count)
            startSample = boundary
            pauseBoundaries.didCommit(through: boundary)
        }
    }

    /// V2's batch decoder consumes the engine's already-retained original audio.
    /// Other backends have received every sample incrementally and ignore it.
    func finish(recordedSamples: [Float] = []) async throws -> String {
        let trace = PerfTrace.begin("stt.batchFinish", counts: ["retained_samples": samples.count])
        defer { trace.end() }
        switch backend {
        case .parakeetBatch(let manager):
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            return try await manager.transcribe(recordedSamples, decoderState: &state).text
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
                let text = try await manager.transcribe(audio: samples)
                committedText = ParakeetEngine.joinChunkTranscripts(base: committedText, addition: text)
                samples.removeAll()
            }
            return committedText
        }
    }

    func cancel() async {
        if case .parakeet(_, let overlapping) = backend {
            await overlapping.cancel()
            await closeOverlap(overlapping)
        }
        samples.removeAll()
        vadPending.removeAll()
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

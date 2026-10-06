import AVFoundation

/// One converter per audio stream. Callers serialize conversion and finish.
/// Returned buffers own their samples and may safely enter an async input queue.
nonisolated final class PCMStreamConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private var receivedInput = false
    private var finished = false

    init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws {
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        guard inputFormat.sampleRate > 0, outputFormat.sampleRate > 0 else {
            throw TranscriptionError.audioFormatError
        }
        if inputFormat == outputFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw TranscriptionError.audioFormatError
            }
            self.converter = converter
        }
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
        guard !finished, input.format == inputFormat else {
            throw TranscriptionError.audioFormatError
        }
        guard input.frameLength > 0 else { return [] }
        receivedInput = true
        guard converter != nil else { return [input] }
        let frames = ceil(Double(input.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate) + 64
        guard frames < Double(UInt32.max) else { throw TranscriptionError.audioFormatError }
        var supplied = false
        return try drain(capacity: AVAudioFrameCount(frames)) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
    }

    /// Delivers filter history once. Never reset between blocks of one stream.
    func finish() throws -> [AVAudioPCMBuffer] {
        guard !finished else { return [] }
        finished = true
        guard receivedInput, let converter else { return [] }
        let prime = converter.primeInfo
        let frames = ceil((Double(prime.leadingFrames) + Double(prime.trailingFrames) + 1)
            * outputFormat.sampleRate / inputFormat.sampleRate) + 64
        guard frames < Double(UInt32.max) else { throw TranscriptionError.audioFormatError }
        return try drain(capacity: AVAudioFrameCount(max(256, frames))) { _, status in
            status.pointee = .endOfStream
            return nil
        }
    }

    private func drain(
        capacity: AVAudioFrameCount,
        input: AVAudioConverterInputBlock
    ) throws -> [AVAudioPCMBuffer] {
        guard let converter else { return [] }
        var buffers: [AVAudioPCMBuffer] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw TranscriptionError.audioFormatError
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: input)
            guard status != .error, error == nil else {
                throw error ?? TranscriptionError.audioFormatError
            }
            if output.frameLength > 0 { buffers.append(output) }
            if status != .haveData || output.frameLength == 0 { return buffers }
        }
    }
}

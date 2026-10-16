import Foundation

/// Owns all speculative cleanup for one recording. Recording polling supplies
/// causal observations; Stop never grants work or waits before stopping capture.
@MainActor
final class EOUCleanupDraftSession {
    struct Configuration: Equatable, Sendable {
        let modelURL: URL
        let modelRevision: Int
        let settingsRevision: Int
        let styling: S1MiniStyling
        let structure: S1MiniStructure
        let context: String
    }

    struct Candidate {
        fileprivate let configuration: Configuration
        fileprivate let output: String

        func output(matching configuration: Configuration?) -> String? {
            self.configuration == configuration ? output : nil
        }
    }

    typealias Processor = @MainActor (String, Configuration) async throws -> String

    private let startedAt: TimeInterval
    private let process: Processor
    private var configuration: Configuration?
    private var source = ""
    private var sourceChangedAt: TimeInterval
    private var pauseAt: TimeInterval?
    private var lastLaunchAt: TimeInterval?
    private var lastAttemptedSource: String?
    private var launchCount = 0
    private var generation = 0
    private var running: Task<Void, Never>?
    private var candidate: Candidate?
    private var closed = false

    init(now: TimeInterval, process: @escaping Processor) {
        startedAt = now
        sourceChangedAt = now
        self.process = process
    }

    func noteEndOfUtterance(now: TimeInterval) {
        guard !closed else { return }
        pauseAt = now
    }

    /// A nil configuration disables speculation without losing ownership of a
    /// cancelled request. The budget cannot be replenished by toggling controls.
    func update(
        source: String, configuration: Configuration?, now: TimeInterval,
        prepareSource: (String) -> String = { $0 }
    ) {
        guard !closed else { return }
        if configuration != self.configuration {
            invalidate()
            self.configuration = configuration
            lastAttemptedSource = nil
        }
        if source != self.source {
            self.source = source
            sourceChangedAt = now
        }
        guard let configuration, running == nil, launchCount < 15,
              !source.isEmpty, source.utf8.count <= 12_000,
              source != lastAttemptedSource else { return }
        let elapsed = now - (lastLaunchAt ?? startedAt)
        guard elapsed >= 8 else { return }
        let stable = now - sourceChangedAt >= 0.75
        let paused = pauseAt.map { $0 >= sourceChangedAt } ?? false
        guard stable || paused || elapsed >= 10 else { return }

        lastAttemptedSource = source
        let preparedSource = prepareSource(source)
        guard !preparedSource.isEmpty else { return }
        launchCount += 1
        lastLaunchAt = now
        let generation = generation
        running = Task(priority: .utility) { [weak self, process] in
            do {
                try Task.checkCancellation()
                let output = try await process(preparedSource, configuration)
                try Task.checkCancellation()
                if let self, !self.closed, self.generation == generation,
                   self.configuration == configuration, !output.isEmpty {
                    self.candidate = Candidate(configuration: configuration, output: output)
                }
            } catch {
                // A speculative failure leaves ordinary final cleanup intact.
            }
            self?.running = nil
        }
    }

    /// Immediately invalidate a draft; the task is retained until it unwinds.
    func invalidate() {
        generation += 1
        candidate = nil
        running?.cancel()
    }

    /// Freeze only already-completed output at the actual Stop boundary.
    func freeze() -> Candidate? {
        guard !closed else { return nil }
        closed = true
        let completed = candidate
        candidate = nil
        running?.cancel()
        return completed
    }

    func cancel() {
        closed = true
        invalidate()
    }

    func join() async {
        await running?.value
    }
}

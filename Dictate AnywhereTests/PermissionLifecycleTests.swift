import XCTest
import CoreAudio
@testable import Dictate_Anywhere

@MainActor
final class PermissionLifecycleTests: XCTestCase {
    private var directory: URL!
    private var restoreSettings: (() -> Void)!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = Settings.shared
        let engine = settings.engineChoice
        let sound = settings.soundEffectsEnabled
        let boost = settings.boostMicrophoneVolumeEnabled
        let mute = settings.muteSystemAudioDuringRecordingEnabled
        let preserve = settings.preserveCancelledSessions
        let microphone = settings.selectedMicrophoneUID
        let autoSwitch = settings.inputSourceAutoSwitchEnabled
        restoreSettings = {
            settings.engineChoice = engine
            settings.soundEffectsEnabled = sound
            settings.boostMicrophoneVolumeEnabled = boost
            settings.muteSystemAudioDuringRecordingEnabled = mute
            settings.preserveCancelledSessions = preserve
            settings.selectedMicrophoneUID = microphone
            settings.inputSourceAutoSwitchEnabled = autoSwitch
        }
        settings.engineChoice = .assemblyAI
        settings.soundEffectsEnabled = false
        settings.boostMicrophoneVolumeEnabled = false
        settings.muteSystemAudioDuringRecordingEnabled = false
        settings.preserveCancelledSessions = false
        settings.selectedMicrophoneUID = nil
        settings.inputSourceAutoSwitchEnabled = false
    }

    override func tearDown() async throws {
        restoreSettings()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testCancellationDuringFailedStartupPermissionRefreshKeepsOverlayHidden() async {
        await assertInvalidatedStartupKeepsOverlayHidden(shutdown: false)
    }

    func testShutdownDuringFailedStartupPermissionRefreshKeepsOverlayHidden() async {
        await assertInvalidatedStartupKeepsOverlayHidden(shutdown: true)
    }

    private func assertInvalidatedStartupKeepsOverlayHidden(shutdown: Bool) async {
        let refreshStarted = expectation(description: "failed startup refresh began")
        let releaseRefresh = expectation(description: "allow permission refresh to finish")
        let permissions = Permissions(statusProvider: {
            refreshStarted.fulfill()
            // This synchronous provider runs on Permissions' private queue.
            // Hold it there while the main actor cancels or shuts down startup.
            _ = XCTWaiter.wait(for: [releaseRefresh], timeout: 5)
            return (true, false)
        })
        permissions.micGranted = true
        let engine = PermissionLifecycleEngine()
        engine.startError = TranscriptionError.audioEngineSetupFailed
        let app = AppState(
            permissions: permissions,
            recoveryStore: DictationRecoveryStore(directory: directory),
            engine: engine,
            contextCapture: { _ in nil }
        )

        let starting = Task { await app.startDictation() }
        await fulfillment(of: [refreshStarted], timeout: 3)
        XCTAssertEqual(app.status, .recording)
        if shutdown {
            await app.shutdown()
        } else {
            await app.cancelDictation()
        }
        XCTAssertEqual(app.status, .idle)
        XCTAssertFalse(app.overlay.isVisible)

        releaseRefresh.fulfill()
        await starting.value

        XCTAssertEqual(app.status, .idle)
        XCTAssertFalse(app.overlay.isVisible, "An invalidated startup must not restore the processing overlay")
        XCTAssertFalse(app.canCancelDictation)
        await app.shutdown()
    }

    func testResolvedSpeechSetupRearmsWithoutAppActivation() async {
        let engine = PermissionLifecycleEngine()
        engine.isReady = false
        let permissions = Permissions(statusProvider: { (true, false) })
        await permissions.refreshForDictation()
        let app = AppState(
            permissions: permissions,
            recoveryStore: DictationRecoveryStore(directory: directory),
            engine: engine,
            contextCapture: { _ in nil }
        )
        let requests = MainWindowRequestCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .requestShowMainWindow, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { requests.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        app.enginePreparationError = "Speech setup is unavailable"
        await app.startDictation()
        await app.startDictation()
        XCTAssertEqual(requests.count, 1, "Repeated attempts at unresolved setup should open the window once")
        XCTAssertEqual(app.selectedAttentionIssueID, .speechSetup)

        await app.prepareActiveEngine()
        XCTAssertTrue(engine.isReady)
        XCTAssertFalse(app.attentionIssues.contains { $0.id == .speechSetup })

        engine.isReady = false
        app.enginePreparationError = "Selected speech setup is unavailable"
        await app.startDictation()
        await app.startDictation()
        XCTAssertEqual(requests.count, 2, "A new setup blocker should request the window again without activation")
        XCTAssertEqual(app.status, .idle)
        await app.shutdown()
    }

    func testFailedPreparationDoesNotRearmUnresolvedSpeechSetup() async {
        let engine = PermissionLifecycleEngine()
        engine.isReady = false
        engine.prepareError = TranscriptionError.audioEngineSetupFailed
        let permissions = Permissions(statusProvider: { (true, false) })
        await permissions.refreshForDictation()
        let app = AppState(
            permissions: permissions,
            recoveryStore: DictationRecoveryStore(directory: directory),
            engine: engine,
            contextCapture: { _ in nil }
        )
        let requests = MainWindowRequestCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .requestShowMainWindow, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { requests.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        app.enginePreparationError = "Speech setup is unavailable"
        await app.startDictation()
        await app.prepareActiveEngine()
        XCTAssertFalse(engine.isReady)
        XCTAssertTrue(app.attentionIssues.contains { $0.id == .speechSetup })
        await app.startDictation()
        XCTAssertEqual(requests.count, 1)
        await app.shutdown()
    }

    func testAssemblyAIKeyEditsRearmSetupWithoutPreparationOrActivation() async throws {
        try XCTSkipUnless(
            (ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Requires missing-key readiness without an environment override"
        )
        let settings = Settings.shared
        let savedAPIKey = settings.assemblyAIAPIKey
        defer { settings.assemblyAIAPIKey = savedAPIKey }
        settings.assemblyAIAPIKey = ""
        let permissions = Permissions(statusProvider: { (true, false) })
        permissions.micGranted = true
        let app = AppState(
            permissions: permissions,
            recoveryStore: DictationRecoveryStore(directory: directory),
            contextCapture: { _ in nil }
        )
        let requests = MainWindowRequestCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .requestShowMainWindow, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { requests.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertFalse(app.activeEngine.isReady)
        await app.startDictation()
        await app.startDictation()
        XCTAssertEqual(requests.count, 1)

        app.updateAssemblyAIAPIKey(" \n ")
        XCTAssertFalse(app.activeEngine.isReady)
        await app.startDictation()
        XCTAssertEqual(requests.count, 1, "Whitespace must not rearm unresolved setup")

        // Entry and Clear can occur consecutively, without preparation,
        // activation, dictation, or a view update while the key is present.
        app.updateAssemblyAIAPIKey("permission-lifecycle-test-key")
        XCTAssertTrue(app.activeEngine.isReady)
        XCTAssertFalse(app.attentionIssues.contains { $0.id == .speechSetup })
        app.updateAssemblyAIAPIKey("")
        XCTAssertFalse(app.activeEngine.isReady)
        XCTAssertTrue(app.attentionIssues.contains { $0.id == .speechSetup })

        await app.startDictation()
        await app.startDictation()
        XCTAssertEqual(requests.count, 2, "Cleared setup should request the window again")
        XCTAssertEqual(app.status, .idle)
        await app.shutdown()
    }

    func testGrantedFirstPermissionDoesNotStartRecordingAfterHoldRelease() async {
        let permissionRequested = expectation(description: "microphone permission requested")
        let permissionResponse = SuspendedPermissionResponse {
            permissionRequested.fulfill()
        }
        let permissions = Permissions(statusProvider: { (false, false) })
        let appState = AppState(permissions: permissions, microphonePermissionRequester: {
            await permissionResponse.waitForResolution()
        })
        let binding = HotkeyBinding(
            id: UUID(),
            keyCode: nil,
            modifiersRawValue: HotkeyModifiers([.function]).rawValue,
            displayName: "fn",
            mode: .holdToRecord
        )

        appState.hotkeyService.onKeyDown?(binding)
        await fulfillment(of: [permissionRequested], timeout: 1)
        XCTAssertTrue(appState.isHoldToRecordKeyDown)

        appState.hotkeyService.onKeyUp?(binding)
        for _ in 0..<100 where appState.isHoldToRecordKeyDown {
            await Task.yield()
        }
        XCTAssertFalse(appState.isHoldToRecordKeyDown)
        await permissionResponse.resolve(granted: true)
        // Resolving the continuation resumes another task; a single yield is
        // not a completion barrier for its permission-state update.
        for _ in 0..<100 where !appState.permissions.micGranted {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(appState.permissions.micGranted)
        XCTAssertEqual(appState.status, .idle)
        await appState.shutdown()
    }
}

@MainActor
private final class MainWindowRequestCounter {
    var count = 0
}

@MainActor
private final class PermissionLifecycleEngine: TranscriptionEngine {
    var recoveryCapture: RecoveryAudioCapture?
    var isReady = true
    var currentTranscript = ""
    var audioSamples: [Float] = []
    var startError: Error?
    var prepareError: Error?

    func levelSamples(count: Int) -> [Float] { [] }
    func prepare() async throws {
        if let prepareError { throw prepareError }
        isReady = true
    }
    func startRecording(deviceID: AudioDeviceID?) async throws {
        if let startError { throw startError }
    }
    func stopAudioCapture() async {}
    func stopRecording() async -> String { "" }
    func cancel() async {}
    func transcribeRecording(at url: URL) async throws -> String { "" }
}

private actor SuspendedPermissionResponse {
    private let onRequest: @Sendable () -> Void
    private var continuation: CheckedContinuation<Bool, Never>?

    init(onRequest: @escaping @Sendable () -> Void) {
        self.onRequest = onRequest
    }

    func waitForResolution() async -> Bool {
        onRequest()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(granted: Bool) {
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

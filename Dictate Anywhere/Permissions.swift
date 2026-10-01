//
//  Permissions.swift
//  Dictate Anywhere
//
//  Microphone, Accessibility, and Automation permission checks.
//

import Foundation
import AVFoundation
import AppKit
import CoreServices

@Observable
final class Permissions {
    enum Kind {
        case microphone
        case accessibility
        case automation
    }

    enum AutomationAuthorization: Sendable {
        case unknown
        case granted
        case denied
    }

    // MARK: - State

    private(set) var hasChecked = false
    var micGranted: Bool = false
    private(set) var automationAuthorization: AutomationAuthorization = .unknown
    var automationDenied: Bool { automationAuthorization == .denied }
    var accessibilityGranted: Bool = false {
        didSet {
            guard oldValue != accessibilityGranted else { return }
            onAccessibilityPermissionChanged?(accessibilityGranted)
        }
    }

    var allGranted: Bool {
        micGranted && accessibilityGranted
    }

    var onAccessibilityPermissionChanged: ((Bool) -> Void)?

    // MARK: - Private

    private let queue = DispatchQueue(label: "com.dictate-anywhere.permissions", qos: .userInitiated)
    private var pollingTimer: Timer?
    private let statusProvider: @Sendable () -> (mic: Bool, accessibility: Bool)
    private let automationStatusProvider: @Sendable () -> AutomationAuthorization

    // MARK: - Initialization

    init(
        statusProvider: (@Sendable () -> (mic: Bool, accessibility: Bool))? = nil,
        automationStatusProvider: (@Sendable () -> AutomationAuthorization)? = nil
    ) {
        self.statusProvider = statusProvider ?? Self.currentStatus
        self.automationStatusProvider = automationStatusProvider ?? Self.currentAutomationAuthorization
    }

    // MARK: - Public Methods

    /// Checks all permissions without prompting (async, off MainActor).
    func refresh() async {
        await refresh(includeAutomation: true)
    }

    /// The dictation hot path only needs the two permissions it uses directly.
    /// Automation is checked at startup/activation and by actual paste results.
    func refreshForDictation() async {
        await refresh(includeAutomation: false)
    }

    private func refresh(includeAutomation: Bool) async {
        let provider = statusProvider
        let automationProvider = automationStatusProvider
        let (mic, accessibility, automation) = await withCheckedContinuation { continuation in
            queue.async {
                let (mic, accessibility) = provider()
                let automation = includeAutomation ? automationProvider() : nil
                continuation.resume(returning: (mic, accessibility, automation))
            }
        }
        micGranted = mic
        accessibilityGranted = accessibility
        if let automation, automation != .unknown {
            automationAuthorization = automation
        }
        hasChecked = true
    }

    /// Actual paste results are more reliable than a read-only preflight when
    /// System Events is not running or macOS reports an unknown consent state.
    func recordAutomationPastePermission(denied: Bool) {
        automationAuthorization = denied ? .denied : .granted
    }

    /// The banner uses one entry point, while macOS determines whether a
    /// first-time request or a trip to System Settings is possible.
    func resolve(_ kind: Kind) async {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                _ = await requestMic()
            case .authorized:
                micGranted = true
            case .denied, .restricted:
                micGranted = false
                openMicrophoneSettings()
            @unknown default:
                micGranted = false
                openMicrophoneSettings()
            }
        case .accessibility:
            openAccessibilitySettings()
        case .automation:
            openAutomationSettings()
        }
    }

    /// Requests microphone permission
    func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micGranted = true
            return true
        case .denied, .restricted:
            micGranted = false
            return false
        case .notDetermined:
            break
        @unknown default:
            micGranted = false
            return false
        }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        micGranted = granted
        return granted
    }

    /// Prompts the user to grant Accessibility permission via the system dialog.
    /// This calls AXIsProcessTrustedWithOptions which adds the app to the Accessibility
    /// list and shows the macOS "wants to control your computer" prompt.
    @discardableResult
    func promptForAccessibility() -> Bool {
        checkAccessibilityForUse(promptIfNeeded: true)
    }

    @discardableResult
    func checkAccessibilityForUse(promptIfNeeded: Bool) -> Bool {
        let granted: Bool
        if promptIfNeeded {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            granted = AXIsProcessTrustedWithOptions(options)
        } else {
            granted = AXIsProcessTrusted()
        }
        accessibilityGranted = granted
        return granted
    }

    /// Opens System Settings to Accessibility pane (fallback for manual add).
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens System Settings to the Microphone pane after a previous denial.
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts polling accessibility permission every ~2.5 seconds.
    /// Automatically stops once all permissions are granted.
    func startPolling() {
        guard pollingTimer == nil else { return }
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshForDictation()
                guard self.allGranted else { return }
                self.stopPolling()
            }
        }
    }

    /// Stops accessibility permission polling.
    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    // MARK: - Private

    /// Runs on the private background queue via `queue.async`, never on the main actor.
    private nonisolated static func currentStatus() -> (mic: Bool, accessibility: Bool) {
        (
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            AXIsProcessTrusted()
        )
    }

    /// Read-only Automation preflight. Unknown means no warning until an actual
    /// paste provides a definite answer; this never requests consent at startup.
    private nonisolated static func currentAutomationAuthorization() -> AutomationAuthorization {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, false
        )
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unknown
        }
    }
}

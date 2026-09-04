//
//  OverlayScreenSession.swift
//  Dictate Anywhere
//
//  Holds the dictation overlay's chosen display for one dictation.
//

import CoreGraphics

/// One attached display, identified by something stabler than its position in
/// the screen list.
struct OverlayDisplay: Equatable {
    /// `CGDirectDisplayID` — stable for a physical display across
    /// reconfiguration, unlike an index into `NSScreen.screens`.
    let id: CGDirectDisplayID
    let visibleFrame: CGRect
}

/// Remembers which display the overlay chose, for the length of one dictation.
///
/// Choosing is expensive — it crosses a process boundary to ask the target
/// application where it is — and `OverlayWindow` repositions itself on every
/// update, which for the listening waveform is about thirty times a second.
/// Choosing per update would put those synchronous calls on the main thread at
/// that rate, stalling the UI whenever the target app is slow to answer, and
/// would let the overlay hop displays mid-sentence if the pointer wandered.
final class OverlayScreenSession {
    private let resolver: OverlayScreenResolving
    private var chosenDisplayID: CGDirectDisplayID?
    private var targetProcessIdentifier: pid_t?

    init(resolver: OverlayScreenResolving = SystemOverlayScreenResolver()) {
        self.resolver = resolver
    }

    /// Starts a dictation, discarding any display the previous one chose.
    ///
    /// - Parameter targetProcessIdentifier: the app the transcript will be
    ///   pasted into, captured before audio startup. The overlay follows this
    ///   app rather than whichever one happens to be frontmost by the time the
    ///   microphone is live. Nil falls back to the frontmost app.
    func begin(targetProcessIdentifier: pid_t?) {
        self.targetProcessIdentifier = targetProcessIdentifier
        chosenDisplayID = nil
    }

    /// Visible frame of this dictation's display, choosing one on first use.
    ///
    /// Display geometry itself is cheap and does shift while the overlay is up
    /// — the dock hides, the menu bar reveals — so it is re-read every time
    /// even though the choice of display is not.
    func visibleFrame() -> CGRect? {
        let displays = resolver.displays()

        // Matching by display id rather than list position: unplugging a
        // monitor or reordering displays shifts indices, and a stale index
        // stays in range while naming a different physical display.
        if let chosenDisplayID, let display = displays.first(where: { $0.id == chosenDisplayID }) {
            return display.visibleFrame
        }

        // Left unchosen when nothing can be resolved, so a lookup that failed
        // once does not leave the overlay unplaced for the whole dictation.
        guard let resolvedID = resolver.resolveDisplayID(forApplication: targetProcessIdentifier),
              let display = displays.first(where: { $0.id == resolvedID }) else {
            return nil
        }

        chosenDisplayID = resolvedID
        return display.visibleFrame
    }

    /// Ends the dictation, so the next overlay chooses its display afresh.
    func end() {
        chosenDisplayID = nil
        targetProcessIdentifier = nil
    }
}

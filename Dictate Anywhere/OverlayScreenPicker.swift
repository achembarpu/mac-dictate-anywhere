//
//  OverlayScreenPicker.swift
//  Dictate Anywhere
//
//  Display selection math for the dictation overlay.
//
//  Kept free of AppKit types so the multi-display arithmetic is testable
//  without attaching real monitors.
//

import CoreGraphics

enum OverlayScreenPicker {
    /// Index of the display the overlay belongs on.
    ///
    /// `NSScreen.main` is unusable here: it means "screen with *our* key
    /// window", and this app dictates into other apps from an accessory
    /// activation policy, so it has no key window and AppKit falls back to the
    /// primary display. Follow the text instead — the focused field first, the
    /// pointer next, the primary display only as a last resort.
    ///
    /// - Parameters:
    ///   - screenFrames: Display frames in AppKit global coordinates, primary first.
    ///   - focusPoint: The focused text field's location, if accessibility could resolve it.
    ///   - mouseLocation: The pointer's location, if known.
    /// - Returns: An index into `screenFrames`, or nil when there are no displays.
    static func pickScreenIndex(screenFrames: [CGRect], focusPoint: CGPoint?, mouseLocation: CGPoint?) -> Int? {
        guard !screenFrames.isEmpty else { return nil }

        if let focusPoint, let index = screenFrames.firstIndex(where: { $0.contains(focusPoint) }) {
            return index
        }

        if let mouseLocation, let index = screenFrames.firstIndex(where: { $0.contains(mouseLocation) }) {
            return index
        }

        return 0
    }

    /// Converts an Accessibility point into AppKit global coordinates.
    ///
    /// Accessibility measures downward from the top-left of the primary
    /// display; AppKit measures upward from its bottom-left. Displays stacked
    /// above the primary therefore report negative accessibility y values.
    static func appKitPoint(fromAccessibilityPoint point: CGPoint, primaryFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x, y: primaryFrame.maxY - point.y)
    }

    /// Bottom-centered origin for the overlay within a display's visible frame.
    ///
    /// Works for any display position because `visibleFrame` is already in
    /// global coordinates, including the negative origins of displays arranged
    /// left of or below the primary.
    static func overlayOrigin(inVisibleFrame visibleFrame: CGRect, size: CGSize, bottomMargin: CGFloat) -> CGPoint {
        CGPoint(
            x: visibleFrame.origin.x + (visibleFrame.width - size.width) / 2,
            y: visibleFrame.origin.y + bottomMargin
        )
    }
}

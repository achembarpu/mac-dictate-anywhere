import Foundation

/// Installation and successful preparation are separate facts. Shared wording
/// keeps speech, cleanup and optional recognition components consistent.
nonisolated enum ModelReadiness: Equatable, Sendable {
    case notDownloaded, downloaded, available, configured, needsSetup
    case downloading(Double), verifying, preparing, deleting, ready
    case unavailable(String), failed(String)

    var title: String {
        switch self {
        case .notDownloaded: return "Not downloaded"
        case .downloaded: return "Downloaded"
        case .available: return "Available"
        case .configured: return "Configured"
        case .needsSetup: return "Not set up"
        case .downloading: return "Downloading…"
        case .verifying: return "Verifying…"
        case .preparing: return "Preparing for first use…"
        case .deleting: return "Deleting…"
        case .ready: return "Ready"
        case .unavailable: return "Unavailable"
        case .failed: return "Needs attention"
        }
    }

    var detail: String? {
        switch self {
        case .unavailable(let reason), .failed(let reason): return reason
        default: return nil
        }
    }

    var isWorking: Bool {
        switch self {
        case .downloading, .verifying, .preparing, .deleting: return true
        default: return false
        }
    }

    var isReady: Bool { self == .ready }

    var progress: Double? {
        guard case .downloading(let value) = self, value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .verifying: return "checkmark.shield"
        case .preparing: return "hourglass"
        case .deleting: return "trash.circle"
        case .failed, .unavailable: return "exclamationmark.circle"
        default: return "internaldrive"
        }
    }
}

//
//  OverlayContent.swift
//  Dictate Anywhere
//
//  Pill-shaped overlay content for dictation states.
//

import SwiftUI

enum OverlayMetrics {
    static let footprintScale: CGFloat = 0.65
    static let typeScale: CGFloat = 0.78

    static func size(_ value: CGFloat) -> CGFloat {
        (value * footprintScale).rounded()
    }

    static func type(_ value: CGFloat) -> CGFloat {
        (value * typeScale * 10).rounded() / 10
    }
}

/// Overlay display states
enum OverlayState: Equatable {
    case listening
    case processing
    case success
    case copiedOnly
    case preparingModel(name: String)
}

/// Observable model bridging OverlayWindow → SwiftUI
@Observable
final class OverlayModel {
    private(set) var overlayState: OverlayState = .listening
    private(set) var audioLevel: Float = 0
    private(set) var transcript: String = ""
    var isVisible: Bool = false
    var cancellationProgress: Double?

    /// Keep waveform updates independent of the transcript and pill layout.
    func updateListening(level: Float, transcript: String) {
        if audioLevel != level { audioLevel = level }
        if self.transcript != transcript { self.transcript = transcript }
    }

    func updateState(_ state: OverlayState) {
        if state != .listening {
            updateListening(level: 0, transcript: "")
        }
        if overlayState != state { overlayState = state }
    }
}

struct OverlayContent: View {
    let model: OverlayModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: OverlayState { model.overlayState }
    private var isVisible: Bool { model.isVisible }

    private var showTextPreview: Bool {
        Settings.shared.showTextPreview
    }

    private var overlayTextColor: Color {
        if colorScheme == .dark {
            if #available(macOS 26, *) { return .white.opacity(0.95) }
            return .white
        }

        if #available(macOS 26, *) { return .black.opacity(0.88) }
        return .black
    }

    private var overlaySecondaryTextColor: Color {
        if colorScheme == .dark {
            if #available(macOS 26, *) { return .white.opacity(0.82) }
            return .white.opacity(0.85)
        }

        if #available(macOS 26, *) { return .black.opacity(0.72) }
        return .black.opacity(0.78)
    }

    private var stateCategory: String {
        switch state {
        case .listening: "listening"
        case .processing: "processing"
        case .success: "success"
        case .copiedOnly: "copiedOnly"
        case .preparingModel: "preparingModel"
        }
    }

    private var statusCircleDiameter: CGFloat {
        OverlayMetrics.size(48)
    }

    private var isCircularStatusState: Bool {
        if model.cancellationProgress != nil { return false }
        switch state {
        case .processing, .success:
            return true
        default:
            return false
        }
    }

    private var statusBottomInset: CGFloat {
        isCircularStatusState ? 1 : 0
    }

    private var pillWidth: CGFloat {
        if model.cancellationProgress != nil { return OverlayMetrics.size(260) }
        switch state {
        case .listening:
            return showTextPreview ? OverlayMetrics.size(260) : OverlayMetrics.size(130)
        case .processing, .success:
            return statusCircleDiameter
        case .copiedOnly:
            return OverlayMetrics.size(130)
        case .preparingModel:
            return OverlayMetrics.size(240)
        }
    }

    private var pillHeight: CGFloat {
        if model.cancellationProgress != nil { return OverlayMetrics.size(64) }
        switch state {
        case .listening:
            return showTextPreview ? OverlayMetrics.size(124) : OverlayMetrics.size(44)
        case .processing, .success:
            return statusCircleDiameter
        case .copiedOnly:
            return OverlayMetrics.size(44)
        case .preparingModel:
            return OverlayMetrics.size(44)
        }
    }

    var body: some View {
        VStack {
            Spacer()

            pill
                .scaleEffect(isVisible ? 1.0 : 0.95)
                .opacity(isVisible ? 1.0 : 0)
                .padding(.bottom, statusBottomInset)
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: isVisible)
        }
        .frame(width: OverlayMetrics.size(320), height: OverlayMetrics.size(200))
    }

    private var pill: some View {
        VStack(spacing: 0) {
            pillContent
                .id(stateCategory)
                .transition(reduceMotion ? .identity : .opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: stateCategory)
        }
        .frame(width: pillWidth, height: pillHeight)
        .modifier(GlassPillModifier(isCircular: isCircularStatusState))
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82), value: isCircularStatusState)
    }

    @ViewBuilder
    private var pillContent: some View {
        if let progress = model.cancellationProgress {
            CancellationProgressView(progress: progress, tint: overlayTextColor)
        } else {
            switch state {
            case .listening:
                ListeningOverlayContent(
                    model: model,
                    showTextPreview: showTextPreview,
                    textColor: overlaySecondaryTextColor
                )

            case .processing:
                ProcessingStatusView(tint: overlayTextColor)

            case .success:
                SuccessStatusView()

            case .copiedOnly:
                HStack(spacing: OverlayMetrics.size(10)) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: OverlayMetrics.type(16)))
                        .foregroundStyle(.orange)
                    Text("Press ⌘V")
                        .font(.system(size: OverlayMetrics.type(12), weight: .medium))
                        .foregroundStyle(overlayTextColor.opacity(0.9))
                }

            case .preparingModel(let name):
                HStack(spacing: OverlayMetrics.size(10)) {
                    ProcessingStatusView(tint: overlayTextColor)
                    Text("Loading \(name)…")
                        .font(.system(size: OverlayMetrics.type(12), weight: .medium))
                        .foregroundStyle(overlayTextColor.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.horizontal, OverlayMetrics.size(14))
            }
        }
    }
}

/// Transcript observation is independent of the waveform level.
struct ListeningOverlayContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: OverlayModel
    let showTextPreview: Bool
    let textColor: Color

    var body: some View {
        if showTextPreview && !model.transcript.isEmpty {
            let previewText = OverlayPreviewText.trimmed(model.transcript)
            VStack(spacing: OverlayMetrics.size(6)) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(previewText)
                            .font(.system(size: OverlayMetrics.type(13), weight: .light))
                            .foregroundStyle(textColor)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .id("transcript")
                    }
                    .frame(height: OverlayMetrics.size(66))
                    .onChange(of: previewText) { _, _ in
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) {
                            proxy.scrollTo("transcript", anchor: .bottom)
                        }
                    }
                }
                .padding(.horizontal, OverlayMetrics.size(16))
                .padding(.top, OverlayMetrics.size(10))

                OverlayWaveformContent(model: model)
                    .padding(.horizontal, OverlayMetrics.size(16))
                    .padding(.bottom, OverlayMetrics.size(8))
            }
        } else if showTextPreview {
            VStack {
                Spacer()
                OverlayWaveformContent(model: model)
                    .padding(.horizontal, OverlayMetrics.size(16))
                    .padding(.bottom, OverlayMetrics.size(8))
            }
        } else {
            OverlayWaveformContent(model: model)
                .padding(.horizontal, OverlayMetrics.size(20))
        }
    }
}

struct OverlayWaveformContent: View {
    let model: OverlayModel

    var body: some View {
        WaveformView(audioLevel: model.audioLevel)
    }
}

enum OverlayPreviewText {
    static let maximumCharacters = Int(320 * OverlayMetrics.footprintScale)

    static func trimmed(_ transcript: String) -> String {
        guard let start = transcript.index(
            transcript.endIndex,
            offsetBy: -maximumCharacters,
            limitedBy: transcript.startIndex
        ), start != transcript.startIndex else { return transcript }
        return "…" + String(transcript[start...])
    }
}

// MARK: - Glass pill background

struct CancellationProgressView: View {
    let progress: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            Text("Hold to cancel")
                .font(.system(size: OverlayMetrics.type(13), weight: .medium))
                .foregroundStyle(tint)
            ProgressView(value: progress)
                .tint(.orange)
                .accessibilityLabel("Hold to cancel")
        }
        .padding(.horizontal, 16)
    }
}

private struct GlassPillModifier: ViewModifier {
    let isCircular: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if isCircular {
            decorated(content: content, shape: Circle())
        } else {
            decorated(
                content: content,
                shape: RoundedRectangle(cornerRadius: OverlayMetrics.size(22), style: .continuous)
            )
        }
    }

    @ViewBuilder
    private func decorated<S: Shape>(content: Content, shape: S) -> some View {
        if #available(macOS 26, *) {
            let tint = colorScheme == .dark ? Color.black.opacity(0.30) : Color.black.opacity(0.24)
            let stroke = colorScheme == .dark ? Color.white.opacity(0.25) : Color.white.opacity(0.18)
            content
                .glassEffect(.regular.tint(tint), in: shape)
                .overlay(shape.stroke(stroke, lineWidth: 1))
        } else {
            content
                .background(shape.fill(Color.black.opacity(0.85)))
                .clipShape(shape)
                .overlay(shape.stroke(.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: OverlayMetrics.size(12), x: 0, y: OverlayMetrics.size(4))
        }
    }
}

private struct ProcessingStatusView: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    private var ringSize: CGFloat {
        OverlayMetrics.size(24)
    }

    private var centerDotSize: CGFloat {
        OverlayMetrics.size(5)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.12), lineWidth: 1)

            Circle()
                .trim(from: 0.16, to: 0.82)
                .stroke(
                    tint.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round)
                )
                .rotationEffect(.degrees(isAnimating ? 360 : 0))

            Circle()
                .fill(tint.opacity(0.9))
                .frame(width: centerDotSize, height: centerDotSize)
        }
        .frame(width: ringSize, height: ringSize)
        .onAppear {
            guard !reduceMotion, !isAnimating else { return }
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled { isAnimating = false }
        }
    }
}

private struct SuccessStatusView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRevealed = false

    private var ringSize: CGFloat {
        OverlayMetrics.size(24)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)

            Circle()
                .stroke(Color.green.opacity(0.42), lineWidth: 1)
                .scaleEffect(isRevealed ? 1.28 : 0.72)
                .opacity(isRevealed ? 0 : 0.8)

            Circle()
                .trim(from: 0, to: isRevealed ? 1 : 0.12)
                .stroke(
                    Color.green.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: OverlayMetrics.type(18)))
                .foregroundStyle(.green)
                .scaleEffect(isRevealed ? 1 : 0.72)
                .opacity(isRevealed ? 1 : 0)
        }
        .frame(width: ringSize, height: ringSize)
        .onAppear {
            isRevealed = false
            withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.72)) {
                isRevealed = true
            }
        }
    }
}

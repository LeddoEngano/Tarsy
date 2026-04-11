import SwiftUI
import Combine

// MARK: - Controller

/// State machine for a WhatsApp-style press-to-record, slide-left-to-cancel
/// interaction. Owns a `VoiceInputManager` and translates raw gesture updates
/// into published state that a HUD view can bind to.
@MainActor
final class VoiceRecorderController: ObservableObject {
    // Live state — read by the HUD.
    @Published var isRecording = false
    @Published var isCancelling = false
    @Published var elapsedSeconds = 0
    @Published var dragOffsetX: CGFloat = 0
    @Published var waveformSamples: [Float] = []

    // Config
    let voiceInput: VoiceInputManager
    let cancelThreshold: CGFloat = 80
    var contextualStrings: [String] = []
    let maxWaveformSamples: Int = 30

    // Callbacks
    var onStart: (() -> Void)? = nil
    var onPartial: ((String) -> Void)? = nil
    var onCommit: ((String) -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    /// Fired when the HUD should disappear — this is the release moment, before
    /// the tail of the transcription arrives. Use this for snappy UI updates.
    var onRelease: (() -> Void)? = nil

    private var timer: Timer?
    private var levelObservation: AnyCancellable?

    init(voiceInput: VoiceInputManager? = nil) {
        let resolved = voiceInput ?? VoiceInputManager()
        self.voiceInput = resolved
        // Mirror audio-level samples into a ring buffer for the waveform.
        levelObservation = resolved.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.pushLevel(level)
            }
    }

    // MARK: Gesture entry points

    func start() {
        guard !isRecording else { return }
        isRecording = true
        isCancelling = false
        elapsedSeconds = 0
        dragOffsetX = 0
        waveformSamples = []
        Haptics.medium()
        onStart?()
        voiceInput.startRecording(contextualStrings: contextualStrings) { [weak self] partial in
            self?.onPartial?(partial)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    func updateDrag(_ translationX: CGFloat) {
        // Only negative (leftward) drag matters for cancelling. Clamp positive
        // drag to 0 so the icon doesn't wander right.
        let clamped = min(0, translationX)
        dragOffsetX = clamped
        let cancelling = clamped < -cancelThreshold
        if cancelling != isCancelling {
            isCancelling = cancelling
            Haptics.medium()   // tactile "entered cancel zone" pulse
        }
    }

    func release() {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil

        let committed = !isCancelling

        // Hide the HUD immediately for snappiness — the recognizer keeps
        // finalizing in the background and the onCommit callback fires when
        // the tail transcription arrives (up to ~1.5s later).
        isRecording = false
        dragOffsetX = 0
        let wasCancelling = isCancelling
        isCancelling = false
        onRelease?()

        if committed {
            Haptics.light()
            voiceInput.stopRecording(commit: true) { [weak self] finalText in
                guard let self = self else { return }
                let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self.onCommit?(trimmed)
            }
        } else {
            _ = wasCancelling  // silence unused-var if we later diverge
            Haptics.error()
            voiceInput.stopRecording(commit: false, completion: nil)
            onCancel?()
        }
    }

    // MARK: Formatting helpers

    var elapsedText: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    /// 0...1 progress toward the cancel threshold.
    var cancelProgress: CGFloat {
        min(1, max(0, -dragOffsetX / cancelThreshold))
    }

    private func pushLevel(_ level: Float) {
        guard isRecording else { return }
        waveformSamples.append(level)
        if waveformSamples.count > maxWaveformSamples {
            waveformSamples.removeFirst(waveformSamples.count - maxWaveformSamples)
        }
    }
}

// MARK: - HUD

/// The visual "recording..." bar. Used inline inside an input row, or floated
/// above a fullscreen mic button. Pure view — parents decide placement.
struct VoiceRecordingHUD: View {
    @ObservedObject var recorder: VoiceRecorderController
    var style: Style = .inlineBar

    enum Style {
        case inlineBar       // fills the chat input row
        case floatingPill    // compact pill for fullscreen floating mics
    }

    @State private var dotVisible = true
    private let blinkTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            // Pulsing red dot + timer
            HStack(spacing: 6) {
                Circle()
                    .fill(TarsyTheme.accentTerracotta)
                    .frame(width: 8, height: 8)
                    .opacity(dotVisible ? 1 : 0.2)
                    .onReceive(blinkTimer) { _ in
                        dotVisible.toggle()
                    }
                Text(recorder.elapsedText)
                    .font(TarsyTheme.font(size: 12, weight: .medium))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .monospacedDigit()
            }

            // Waveform
            waveform
                .frame(maxWidth: .infinity)
                .opacity(recorder.isCancelling ? 0.2 : 1.0)

            // Slide-to-cancel hint (fades out as drag progresses, replaced by
            // trash icon when the user crosses the threshold)
            Group {
                if recorder.isCancelling {
                    HStack(spacing: 6) {
                        Image(systemName: "trash.fill")
                            .font(TarsyTheme.font(size: 14, weight: .semibold))
                        Text("Release to cancel")
                            .font(TarsyTheme.font(size: 11, weight: .medium))
                    }
                    .foregroundColor(TarsyTheme.accentTerracotta)
                    .transition(.scale.combined(with: .opacity))
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(TarsyTheme.font(size: 11, weight: .medium))
                        Text("Slide to cancel")
                            .font(TarsyTheme.font(size: 11))
                    }
                    .foregroundColor(TarsyTheme.textSecondary)
                    .offset(x: recorder.dragOffsetX * 0.5)
                    .opacity(1 - recorder.cancelProgress)
                }
            }
        }
        .padding(.horizontal, style == .floatingPill ? 14 : 12)
        .padding(.vertical, style == .floatingPill ? 10 : 8)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(TarsyTheme.backgroundSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(
                            recorder.isCancelling
                                ? TarsyTheme.accentTerracotta
                                : TarsyTheme.textSecondary.opacity(0.2),
                            lineWidth: 1
                        )
                )
        )
        .animation(.easeInOut(duration: 0.15), value: recorder.isCancelling)
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<recorder.maxWaveformSamples, id: \.self) { i in
                let sample: Float = {
                    let offset = recorder.maxWaveformSamples - recorder.waveformSamples.count
                    let idx = i - offset
                    return (idx >= 0 && idx < recorder.waveformSamples.count)
                        ? recorder.waveformSamples[idx]
                        : 0
                }()
                Capsule()
                    .fill(TarsyTheme.textPrimary.opacity(0.85))
                    .frame(width: 2, height: max(3, CGFloat(sample) * 24))
            }
        }
        .frame(height: 24)
    }
}

// MARK: - Gesture modifier

/// Builds the WhatsApp-style hold-to-record gesture. Shared between the
/// inline and draggable modifiers below.
@MainActor
private func makeRecordGesture(recorder: VoiceRecorderController) -> some Gesture {
    LongPressGesture(minimumDuration: 0.15)
        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
        .onChanged { value in
            switch value {
            case .first:
                break
            case .second(true, let drag):
                if !recorder.isRecording {
                    recorder.start()
                }
                if let drag = drag {
                    recorder.updateDrag(drag.translation.width)
                }
            default:
                break
            }
        }
        .onEnded { _ in
            if recorder.isRecording {
                recorder.release()
            }
        }
}

extension View {
    /// Attaches a WhatsApp-style press-to-record gesture. Fires `start` after
    /// a ~150ms hold, streams drag translation into `updateDrag`, and calls
    /// `release` on liftoff. Taps shorter than 150ms are ignored.
    func voiceRecordGesture(recorder: VoiceRecorderController) -> some View {
        self.gesture(makeRecordGesture(recorder: recorder))
    }

    /// Variant for floating buttons that can be dragged around the screen.
    /// A quick drag (>12pt movement before the 150ms hold threshold) enters
    /// **reposition** mode and moves the button via the `offset` binding.
    /// Staying still for 150ms enters **record** mode — slide-left-to-cancel
    /// still applies from that point. `offsetBase` tracks the button's
    /// resting position between drags.
    func draggableVoiceRecordButton(
        recorder: VoiceRecorderController,
        offset: Binding<CGSize>,
        offsetBase: Binding<CGSize>
    ) -> some View {
        let reposition = DragGesture(minimumDistance: 12)
            .onChanged { value in
                offset.wrappedValue = CGSize(
                    width: offsetBase.wrappedValue.width + value.translation.width,
                    height: offsetBase.wrappedValue.height + value.translation.height
                )
            }
            .onEnded { _ in
                offsetBase.wrappedValue = offset.wrappedValue
                Haptics.light()
            }

        // Record takes precedence when both gestures are eligible at the same
        // instant — if the finger stays still for 150ms, `record` recognizes
        // and cancels reposition. If the finger moves 12pt first, reposition
        // wins and record is cancelled.
        let record = makeRecordGesture(recorder: recorder)
        return self
            .offset(offset.wrappedValue)
            .gesture(record.exclusively(before: reposition))
    }
}

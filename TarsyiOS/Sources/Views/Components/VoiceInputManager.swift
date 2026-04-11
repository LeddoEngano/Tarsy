import Foundation
import Speech
import AVFoundation

@MainActor
class VoiceInputManager: ObservableObject {
    @Published var isRecording = false
    @Published var transcription = ""
    @Published var audioLevel: Float = 0   // 0...1 RMS, drives the waveform HUD
    @Published var needsLanguageSelection = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var onPartial: ((String) -> Void)?
    private var committedText = ""
    private var lastPartialText = ""
    private var taskGeneration = 0
    private var extraContextualStrings: [String] = []

    // Finalize-on-release state. When the user releases the button we call
    // endAudio() and keep the recognition task alive long enough for the final
    // `isFinal` callback to arrive — that's where the tail of their speech lives.
    private var isFinalizing = false
    private var finalizeCompletion: ((String) -> Void)?
    private var finalizeTimeoutTask: Task<Void, Never>?

    static let languageKey = "voice_language"

    static let supportedLanguages: [(code: String, name: String)] = [
        ("en-US", "English"),
        ("pt-BR", "Português (BR)"),
        ("es-ES", "Español"),
        ("fr-FR", "Français"),
        ("de-DE", "Deutsch"),
        ("it-IT", "Italiano"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
        ("zh-CN", "中文 (简体)"),
    ]

    /// Vocabulary hints injected into every recognition request. Biases the recognizer
    /// toward Tarsy/coding terminology so things like "Claude", "git commit", "refactor"
    /// transcribe cleanly instead of turning into homophones.
    private static let defaultContextualStrings: [String] = [
        "Claude", "Claude Code", "Codex", "Gemini", "Aider", "Tarsy",
        "git", "commit", "branch", "merge", "rebase", "PR", "pull request",
        "terminal", "workspace", "file", "function", "class", "variable",
        "refactor", "debug", "test", "build", "deploy", "lint",
        "iOS", "macOS", "Swift", "SwiftUI", "TypeScript", "Python", "JavaScript",
    ]

    var selectedLanguage: String {
        get { UserDefaults.standard.string(forKey: Self.languageKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.languageKey) }
    }

    init() {
        let lang = UserDefaults.standard.string(forKey: Self.languageKey) ?? ""
        let locale = lang.isEmpty ? Locale.current : Locale(identifier: lang)
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    func setLanguage(_ code: String) {
        selectedLanguage = code
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: code))
    }

    // MARK: - Start

    func startRecording(
        contextualStrings: [String] = [],
        onPartial: ((String) -> Void)? = nil
    ) {
        if UserDefaults.standard.string(forKey: Self.languageKey) == nil {
            self.onPartial = onPartial
            self.extraContextualStrings = contextualStrings
            needsLanguageSelection = true
            return
        }

        self.onPartial = onPartial
        self.extraContextualStrings = contextualStrings

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self = self else { return }
                guard status == .authorized else {
#if DEBUG
                    print("[Voice] Speech recognition not authorized: \(status.rawValue)")
#endif
                    return
                }
                self.committedText = ""
                self.lastPartialText = ""
                self.transcription = ""
                self.isFinalizing = false
                self.beginRecognitionTask()
            }
        }
    }

    // MARK: - Stop

    /// Finalize recording. On `commit: true` we flush the audio tail and wait for the
    /// recognizer's final callback before delivering the transcription — this is what
    /// makes releasing the button feel instant instead of requiring an extra hold.
    /// On `commit: false` we throw the audio away (slide-to-cancel).
    func stopRecording(commit: Bool, completion: ((String) -> Void)? = nil) {
        if !commit {
            cancelRecording()
            completion?("")
            return
        }

        // Already stopped — return whatever we have.
        guard isRecording, let request = recognitionRequest else {
            let text = transcription
            cleanup()
            completion?(text)
            return
        }

        // Transition: recording → finalizing. The recognition callback still runs
        // because we key it on (isRecording || isFinalizing), but the HUD can hide.
        isRecording = false
        isFinalizing = true
        finalizeCompletion = completion

        // Stop feeding audio but do NOT cancel the task — endAudio() triggers the
        // final `isFinal` callback with the tail transcription included.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request.endAudio()

        // Safety timeout: if the final callback never arrives, deliver what we have.
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self = self, self.isFinalizing else { return }
            self.deliverFinal()
        }
    }

    /// Back-compat shim: old call sites that just want to tear down without caring
    /// about the tail can keep calling this. New code should use the commit variant.
    func stopRecording() {
        stopRecording(commit: true, completion: nil)
    }

    private func cancelRecording() {
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil
        finalizeCompletion = nil
        isFinalizing = false
        cleanup()
    }

    private func deliverFinal() {
        guard isFinalizing else { return }
        isFinalizing = false
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil
        let text = transcription
        let cb = finalizeCompletion
        finalizeCompletion = nil
        cleanup()
        cb?(text)
    }

    private func cleanup() {
        isRecording = false
        audioLevel = 0
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        committedText = ""
        lastPartialText = ""
    }

    // MARK: - Recognition pipeline

    private func beginRecognitionTask() {
        // Bump generation so old task callbacks are ignored when we restart.
        taskGeneration += 1
        let currentGen = taskGeneration

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        if !audioEngine.isRunning {
            let audioSession = AVAudioSession.sharedInstance()
            do {
                // .default mode keeps AGC and noise suppression — much more accurate
                // for phone-held conversational speech than .measurement (which is
                // meant for lab-grade signal capture and disables those filters).
                try audioSession.setCategory(.record, mode: .default, options: .duckOthers)
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
#if DEBUG
                print("[Voice] Audio session error: \(error)")
#endif
                return
            }
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // Prefer server recognition for accuracy. Apple's docs note on-device models
        // are less accurate than server-side because they lack continuous updates,
        // and Tarsy's use case (dictating coding tasks) favors accuracy over privacy.
        // Server is the default; we explicitly leave requiresOnDeviceRecognition off.
        request.contextualStrings = Self.defaultContextualStrings + extraContextualStrings
        self.recognitionRequest = request

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self, self.taskGeneration == currentGen else { return }
                // Accept callbacks during both recording AND finalizing — the final
                // callback after endAudio() arrives while isFinalizing == true.
                guard self.isRecording || self.isFinalizing else { return }

                if let result = result {
                    let partial = result.bestTranscription.formattedString

                    // iOS 18 bug: after a pause, bestTranscription resets to a shorter string.
                    // Detect this by checking if the new partial is significantly shorter than
                    // what we had, and commit the previous text before it's lost.
                    if !self.lastPartialText.isEmpty && partial.count < self.lastPartialText.count / 2 {
                        let committed = self.committedText.isEmpty
                            ? self.lastPartialText
                            : self.committedText + ". " + self.lastPartialText
                        self.committedText = committed
                    }

                    self.lastPartialText = partial
                    let full = self.committedText.isEmpty ? partial : self.committedText + ". " + partial
                    self.transcription = full
                    self.onPartial?(full)

                    if result.isFinal {
                        self.committedText = full
                        self.lastPartialText = ""
                        if self.isFinalizing {
                            // User released — deliver the completed transcription.
                            self.deliverFinal()
                        } else if self.isRecording {
                            // Long-recording boundary (Apple enforces ~1 minute
                            // server-side limits). Transparently restart so the
                            // user can keep talking.
                            self.beginRecognitionTask()
                        }
                        return
                    }
                }

                if let error = error as? NSError {
                    let isBoundaryError = error.domain == "kAFAssistantErrorDomain"
                        && (error.code == 1110 || error.code == 216)
                    if isBoundaryError {
                        if self.isFinalizing {
                            self.deliverFinal()
                            return
                        }
                        if self.isRecording {
                            if !self.transcription.isEmpty {
                                self.committedText = self.transcription
                            }
                            self.beginRecognitionTask()
                        }
                        return
                    }
#if DEBUG
                    print("[Voice] Recognition error: \(error)")
#endif
                    if self.isFinalizing {
                        self.deliverFinal()
                    } else {
                        self.cleanup()
                    }
                }
            }
        }

        if !audioEngine.isRunning {
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)

                // Sample RMS for the waveform HUD.
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0 else { return }
                var sum: Float = 0
                for i in 0..<frameCount {
                    let s = channelData[i]
                    sum += s * s
                }
                let rms = sqrt(sum / Float(frameCount))
                // Scale: typical speech sits around 0.02-0.1 RMS, amplify into 0...1.
                let level = min(1.0, max(0.0, rms * 8.0))
                Task { @MainActor [weak self] in
                    self?.audioLevel = level
                }
            }

            do {
                audioEngine.prepare()
                try audioEngine.start()
                isRecording = true
                transcription = ""
            } catch {
#if DEBUG
                print("[Voice] Audio engine error: \(error)")
#endif
                cleanup()
            }
        } else {
            isRecording = true
        }
    }
}

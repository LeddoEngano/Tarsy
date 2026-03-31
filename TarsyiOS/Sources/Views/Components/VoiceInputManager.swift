import Foundation
import Speech
import AVFoundation

@MainActor
class VoiceInputManager: ObservableObject {
    @Published var isRecording = false
    @Published var transcription = ""
    @Published var needsLanguageSelection = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var onTranscription: ((String) -> Void)?
    private var committedText = ""
    private var lastPartialText = ""
    private var taskGeneration = 0

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

    func startRecording(onTranscription: @escaping (String) -> Void) {
        if UserDefaults.standard.string(forKey: Self.languageKey) == nil {
            self.onTranscription = onTranscription
            needsLanguageSelection = true
            return
        }

        self.onTranscription = onTranscription

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard status == .authorized else {
#if DEBUG
                    print("[Voice] Speech recognition not authorized: \(status.rawValue)")
#endif
                    return
                }
                self?.committedText = ""
                self?.lastPartialText = ""
                self?.beginRecognitionTask()
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
        committedText = ""
        lastPartialText = ""
    }

    private func beginRecognitionTask() {
        // Bump generation so old task callbacks are ignored
        taskGeneration += 1
        let currentGen = taskGeneration

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        if !audioEngine.isRunning {
            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
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
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self, self.isRecording, self.taskGeneration == currentGen else { return }

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
                    self.onTranscription?(full)

                    if result.isFinal {
                        self.committedText = full
                        self.lastPartialText = ""
                        self.beginRecognitionTask()
                        return
                    }
                }

                if let error = error as? NSError {
                    if error.domain == "kAFAssistantErrorDomain" && (error.code == 1110 || error.code == 216) {
                        if self.isRecording {
                            // Commit whatever we have so far before restarting
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
                    self.stopRecording()
                }
            }
        }

        if !audioEngine.isRunning {
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
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
                stopRecording()
            }
        } else {
            isRecording = true
        }
    }
}

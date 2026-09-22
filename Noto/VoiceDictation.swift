import Speech
import AVFoundation

// Live speech-to-text into a text field (the AI question box), separate from Transcriber (which transcribes a
// finished audio file): this one streams the microphone through SFSpeechAudioBufferRecognitionRequest and
// reports partial results as the user talks. On-device only, same as Transcriber.
final class VoiceDictation: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var partialText = ""
    var onError: ((Error) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))

    func start() {
        guard !isListening, let recognizer, recognizer.isAvailable else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                DispatchQueue.main.async { self?.onError?(TranscribeError.notAuthorized) }
                return
            }
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    guard granted else { self?.onError?(RecordingPermissionDenied()); return }
                    self?.begin(recognizer)
                }
            }
        }
    }

    private func begin(_ recognizer: SFSpeechRecognizer) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onError?(error)
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?(error)
            return
        }
        isListening = true
        partialText = ""

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            if let result {
                DispatchQueue.main.async { self?.partialText = result.bestTranscription.formattedString }
            }
            if error != nil || result?.isFinal == true {
                DispatchQueue.main.async { self?.stop() }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isListening = false
    }
}

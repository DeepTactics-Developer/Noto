import Speech

enum TranscribeError: LocalizedError {
    case notAuthorized
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "음성 인식 권한이 필요합니다. 설정에서 허용해주세요."
        case .unavailable: "이 기기에서는 음성 인식을 사용할 수 없습니다."
        }
    }
}

// On-device only (requiresOnDeviceRecognition), matching the rest of the app's local-first AI — no audio ever
// leaves the device to get a transcript.
enum Transcriber {
    static func transcribe(fileURL: URL, locale: String = "ko-KR") async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            throw TranscribeError.unavailable
        }
        guard await requestAuthorization() else { throw TranscribeError.notAuthorized }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return } // the callback can otherwise fire again after the final result
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    private static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

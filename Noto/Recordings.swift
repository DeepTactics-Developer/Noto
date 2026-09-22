import Foundation
import AVFoundation

struct Recording: Codable, Identifiable {
    let id: UUID
    var filename: String
    var pageIndex: Int
    var duration: TimeInterval
    var createdAt: Date

    init(id: UUID = UUID(), filename: String, pageIndex: Int, duration: TimeInterval, createdAt: Date = .now) {
        self.id = id
        self.filename = filename
        self.pageIndex = pageIndex
        self.duration = duration
        self.createdAt = createdAt
    }
}

// One JSON list of recordings per document, alongside meta.json — there are never enough of these per
// document to need InkStore/ObjectStore's per-page split or debounced saving.
enum RecordingStore {
    private static func url(for folder: DocumentFolder) -> URL { folder.url.appending(path: "recordings.json") }

    static func all(for folder: DocumentFolder) -> [Recording] {
        guard let data = try? Data(contentsOf: url(for: folder)),
              let list = try? JSONDecoder().decode([Recording].self, from: data) else { return [] }
        return list
    }

    private static func save(_ recordings: [Recording], for folder: DocumentFolder) {
        guard let data = try? JSONEncoder().encode(recordings) else { return }
        try? data.write(to: url(for: folder), options: .atomic)
    }

    @discardableResult
    static func add(filename: String, pageIndex: Int, duration: TimeInterval, for folder: DocumentFolder) -> Recording {
        var list = all(for: folder)
        let recording = Recording(filename: filename, pageIndex: pageIndex, duration: duration)
        list.append(recording)
        save(list, for: folder)
        return recording
    }

    static func delete(_ id: UUID, for folder: DocumentFolder) {
        var list = all(for: folder)
        guard let removed = list.first(where: { $0.id == id }) else { return }
        list.removeAll { $0.id == id }
        save(list, for: folder)
        try? FileManager.default.removeItem(at: folder.fileURL(removed.filename))
    }
}

struct RecordingPermissionDenied: LocalizedError {
    var errorDescription: String? { "마이크 접근 권한이 필요합니다. 설정에서 허용해주세요." }
}

// Records to the document's own folder ("rec_<uuid>.m4a"), tied to whatever page is current when recording
// starts. One recording per start/stop — no live scrubbing against the strokes drawn while recording yet.
final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var filename: String?
    var onFinish: ((String, TimeInterval) -> Void)?
    var onError: ((Error) -> Void)?

    var isRecording: Bool { recorder?.isRecording ?? false }

    func start(in folder: DocumentFolder) {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    self?.onError?(RecordingPermissionDenied())
                    return
                }
                self?.beginRecording(in: folder)
            }
        }
    }

    private func beginRecording(in folder: DocumentFolder) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let name = "rec_\(UUID().uuidString).m4a"
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let newRecorder = try AVAudioRecorder(url: folder.fileURL(name), settings: settings)
            newRecorder.delegate = self
            newRecorder.record()
            recorder = newRecorder
            filename = name
            startedAt = .now
        } catch {
            onError?(error)
        }
    }

    func stop() {
        guard let recorder, let startedAt, let filename else { return }
        recorder.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        let duration = Date.now.timeIntervalSince(startedAt)
        self.recorder = nil
        self.startedAt = nil
        self.filename = nil
        onFinish?(filename, duration)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error { DispatchQueue.main.async { self.onError?(error) } }
    }
}

// Plays one recording at a time; `playingID` drives the play/stop icon in RecordingList.
final class RecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playingID: UUID?
    private var player: AVAudioPlayer?

    func toggle(_ recording: Recording, folder: DocumentFolder) {
        if playingID == recording.id {
            player?.stop()
            player = nil
            playingID = nil
            return
        }
        guard let newPlayer = try? AVAudioPlayer(contentsOf: folder.fileURL(recording.filename)) else { return }
        newPlayer.delegate = self
        newPlayer.play()
        player = newPlayer
        playingID = recording.id
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.playingID = nil }
    }
}

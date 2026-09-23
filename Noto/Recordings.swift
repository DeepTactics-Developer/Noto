import Foundation
import AVFoundation

struct Recording: Codable, Identifiable {
    let id: UUID
    var filename: String
    var pageIndex: Int
    var duration: TimeInterval
    var createdAt: Date
    // Filled in lazily, only once the user taps "텍스트 보기" — never computed eagerly, so the list stays quick
    // to load and quiet until asked. Optional properties decode to nil automatically for older recordings.json
    // files that predate this field, so no custom Codable needed.
    var transcript: String?

    init(id: UUID = UUID(), filename: String, pageIndex: Int, duration: TimeInterval, createdAt: Date = .now, transcript: String? = nil) {
        self.id = id
        self.filename = filename
        self.pageIndex = pageIndex
        self.duration = duration
        self.createdAt = createdAt
        self.transcript = transcript
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

    // `id` matches the one VoiceRecorder minted when it started, so strokes tagged with it while recording
    // (InkStroke.recordingID) line up with this Recording.
    @discardableResult
    static func add(id: UUID, filename: String, pageIndex: Int, duration: TimeInterval, for folder: DocumentFolder) -> Recording {
        var list = all(for: folder)
        let recording = Recording(id: id, filename: filename, pageIndex: pageIndex, duration: duration)
        list.append(recording)
        save(list, for: folder)
        return recording
    }

    static func setTranscript(_ transcript: String, for id: UUID, in folder: DocumentFolder) {
        var list = all(for: folder)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].transcript = transcript
        save(list, for: folder)
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
    // Minted at the start of recording (not at the end, like the rest of this class's state) so strokes drawn
    // while it's running can be tagged with the SAME id the eventual Recording gets — see InkPageView.activeRecording.
    private(set) var id: UUID?
    var onFinish: ((UUID, String, TimeInterval) -> Void)?
    var onError: ((Error) -> Void)?

    var isRecording: Bool { recorder?.isRecording ?? false }
    // (id, seconds elapsed) while recording, for tagging strokes as they're drawn.
    var elapsed: (id: UUID, seconds: TimeInterval)? {
        guard let id, let startedAt else { return nil }
        return (id, Date.now.timeIntervalSince(startedAt))
    }

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
            // .spokenAudio tunes the session's own signal processing for speech specifically (vs. music/.default),
            // which is what a lecture recording actually is — matters for how well Transcriber can read it back.
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)
            let name = "rec_\(UUID().uuidString).m4a"
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 96000,
            ]
            let newRecorder = try AVAudioRecorder(url: folder.fileURL(name), settings: settings)
            newRecorder.delegate = self
            newRecorder.record()
            recorder = newRecorder
            filename = name
            startedAt = .now
            id = UUID()
        } catch {
            onError?(error)
        }
    }

    func stop() {
        guard let recorder, let startedAt, let filename, let id else { return }
        recorder.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        let duration = Date.now.timeIntervalSince(startedAt)
        self.recorder = nil
        self.startedAt = nil
        self.filename = nil
        self.id = nil
        onFinish?(id, filename, duration)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error { DispatchQueue.main.async { self.onError?(error) } }
    }
}

// Plays one recording at a time; `playingID` drives the play/stop icon in RecordingList. While playing, ticks
// `onTick` a few times a second with (recording id, seconds into it) so the note view can highlight whatever
// ink was drawn at that moment — the audio↔stroke sync.
final class RecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playingID: UUID?
    private var player: AVAudioPlayer?
    private var tickTimer: Timer?
    var onTick: ((UUID, TimeInterval) -> Void)?

    func toggle(_ recording: Recording, folder: DocumentFolder) {
        if playingID == recording.id {
            stop()
            return
        }
        guard let newPlayer = try? AVAudioPlayer(contentsOf: folder.fileURL(recording.filename)) else { return }
        newPlayer.delegate = self
        newPlayer.play()
        player = newPlayer
        playingID = recording.id
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, let player = self.player, let id = self.playingID else { return }
            self.onTick?(id, player.currentTime)
        }
    }

    private func stop() {
        player?.stop()
        player = nil
        playingID = nil
        tickTimer?.invalidate()
        tickTimer = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            // One last tick right at the end, in case periodic timer ticks (every 0.15s) landed just short of a
            // stroke drawn in the final moment of the recording and never caught it.
            if let id = self.playingID { self.onTick?(id, player.duration) }
            self.stop()
        }
    }
}

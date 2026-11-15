import AVFoundation
import Foundation
import MeetingCore
import Observation

@MainActor @Observable
final class PlaybackCoordinator {
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var waveformTracks: [AudioSource: [Float]] = [:]
    private(set) var waveformLoading = false
    var waveformError: String?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    var waveform: [Float] {
        if let selectedSource { return waveformTracks[selectedSource] ?? [] }
        let tracks = Array(waveformTracks.values)
        guard let first = tracks.first else { return [] }
        return first.indices.map { index in tracks.map { $0[index] }.max() ?? 0 }
    }
    var errorMessage: String?
    var selectedSource: AudioSource? { didSet { updateVolumes() } }
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let tracks: PlaybackTracks
    @ObservationIgnored private var chunks: [AudioChunk] = []
    @ObservationIgnored private var store: RecordingStore?
    @ObservationIgnored private var recordingID: UUID?
    @ObservationIgnored private var scheduled: Set<UUID> = []
    @ObservationIgnored private var openFiles: [UUID: AVAudioFile] = [:]
    @ObservationIgnored private var anchorTime: TimeInterval = 0
    @ObservationIgnored private var anchorPosition: Double = 0

    init() {
        tracks = PlaybackTracks(engine: engine)
    }
    private func updateVolumes() {
        tracks.select(selectedSource)
    }
    func load(_ recording: Recording?, store: RecordingStore?) {
        waveformTask?.cancel(); waveformTracks = [:]; waveformLoading = false; waveformError = nil
        stop(); chunks = []; position = 0; duration = 0; errorMessage = nil
        self.store = store; recordingID = recording?.id
        tracks.clear()
        guard let recording, let store else { return }
        waveformLoading = true
        waveformTask = Task { [weak self] in
            do {
                let tracks = try await AudioWaveform.load(recording, store: store)
                try Task.checkCancellation()
                self?.waveformTracks = tracks
            } catch is CancellationError { return }
            catch { self?.waveformError = "波形暂不可用，仍可拖动定位。" }
            self?.waveformLoading = false
        }
        do {
            chunks = AudioTimeline.playableChunks(recording.chunks, after: -1)
            duration = recording.duration
            try tracks.prepare(recording, store: store)
            selectedSource = nil
        } catch {
            DiagnosticLog.shared.failure("playback.load.failed", error: error, fields: ["recording_id": recording.id.uuidString])
            tracks.clear(); chunks = []; errorMessage = error.localizedDescription
        }
    }
    func toggle() { if isPlaying { pause() } else { play() } }
    func play() {
        guard !chunks.isEmpty, duration > 0 else { return }
        if position >= duration { position = 0 }
        resetSchedule()
        do {
            anchorPosition = position
            try scheduleAhead()
            if !engine.isRunning { try engine.start() }
            let delay = 0.08
            anchorTime = ProcessInfo.processInfo.systemUptime + delay
            let time = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay))
            tracks.play(at: time)
            isPlaying = true; errorMessage = nil
        } catch {
            DiagnosticLog.shared.failure("playback.start.failed", error: error, fields: ["recording_id": recordingID?.uuidString ?? "unknown"])
            stop(); errorMessage = "无法播放录音：\(error.localizedDescription)"
        }
    }
    // Keep only a small look-ahead window open. Hour-long dual-track meetings
    // must not exhaust the process's file-descriptor limit by opening every WAV.
    private func scheduleAhead() throws {
        guard let store, let recordingID else { return }
        for chunk in chunks where chunk.end > position && chunk.offset <= position + 30 && !scheduled.contains(chunk.id) {
            let file = try AVAudioFile(forReading: store.audioURL(recording: recordingID, fileName: chunk.fileName))
            try tracks.enqueue(chunk, file: file, from: anchorPosition)
            scheduled.insert(chunk.id); openFiles[chunk.id] = file
        }
        for chunk in chunks where chunk.end + 1 < position { openFiles.removeValue(forKey: chunk.id) }
    }
    private func resetSchedule() {
        tracks.stop(); scheduled = []; openFiles = [:]
    }
    func pause() { tick(); resetSchedule(); isPlaying = false }
    func stop() { resetSchedule(); engine.stop(); isPlaying = false }
    func seek(to time: Double) {
        let resume = isPlaying
        resetSchedule(); isPlaying = false
        position = AudioTimeline.position(time, duration: duration)
        if resume { play() }
    }
    func tick() {
        guard isPlaying else { return }
        position = AudioTimeline.position(anchorPosition + max(0, ProcessInfo.processInfo.systemUptime - anchorTime), duration: duration)
        if position >= duration { resetSchedule(); isPlaying = false; return }
        do { try scheduleAhead() }
        catch {
            DiagnosticLog.shared.failure("playback.continue.failed", error: error, fields: ["recording_id": recordingID?.uuidString ?? "unknown"])
            stop(); errorMessage = "无法继续回放：\(error.localizedDescription)"
        }
    }
}

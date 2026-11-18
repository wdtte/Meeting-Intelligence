import Foundation
import AVFoundation

// Access is serialized by the capture worker. The main actor only loads snapshots
// before capture or after the worker has stopped.
public struct RecordingStore: Sendable {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    public static func applicationStore() throws -> RecordingStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try RecordingStore(root: support.appendingPathComponent("Meeting Intelligence/Recordings", isDirectory: true))
    }
    public func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func audioURL(recording: UUID, fileName: String) throws -> URL {
        guard fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              !fileName.isEmpty, fileName != ".", fileName != ".." else {
            throw MeetingError.message("录音文件路径无效。")
        }
        return directory(for: recording).appendingPathComponent(fileName)
    }
    public func save(_ recording: Recording) throws {
        try DiskFormat.write(recording, to: directory(for: recording.id).appendingPathComponent("recording.json"))
    }
    public func loadCatalog(recover: Bool = false) throws -> (recordings: [Recording], warnings: [String]) {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var records: [Recording] = [], warnings: [String] = []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            do { records.append(try loadFolder(folder, recover: recover)) }
            catch { warnings.append("\(folder.path)：\(error.localizedDescription)") }
        }
        return (records.sorted { $0.startedAt > $1.startedAt }, warnings)
    }
    private func loadFolder(_ folder: URL, recover: Bool) throws -> Recording {
        var recording = try DiskFormat.read(Recording.self, at: folder.appendingPathComponent("recording.json"))
        guard recording.id.uuidString == folder.lastPathComponent else { throw MeetingError.message("录音目录与 ID 不匹配。") }
        if recover && recording.status == .recording {
            for index in recording.chunks.indices where !recording.chunks[index].isComplete {
                let chunk = recording.chunks[index]
                let url = try audioURL(recording: recording.id, fileName: chunk.fileName)
                if FileManager.default.fileExists(atPath: url.path), let file = try? AVAudioFile(forReading: url), file.length > 0 {
                    recording.chunks[index].duration = Double(file.length) / file.processingFormat.sampleRate
                    recording.chunks[index].isComplete = true
                }
            }
            recording.status = .interrupted
            recording.note = "上次录音意外中断；已保留完成片段。"
            try save(recording)
        }
        return recording
    }
    public func loadAll(recover: Bool = false) throws -> [Recording] {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var recordings: [Recording] = []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            let url = folder.appendingPathComponent("recording.json")
            // A corrupt manifest is surfaced; it is never silently replaced or deleted.
            var recording = try DiskFormat.read(Recording.self, at: url)
            guard (1...2).contains(recording.schemaVersion), recording.id.uuidString == folder.lastPathComponent else {
                throw MeetingError.message("无法读取录音目录：\(folder.lastPathComponent)。请保留原文件。")
            }
            if recover && recording.status == .recording {
                for index in recording.chunks.indices where !recording.chunks[index].isComplete {
                    let chunk = recording.chunks[index]
                    let finalURL = try audioURL(recording: recording.id, fileName: chunk.fileName)
                    // Only recover closed, renamed chunks. Leave the final partial WAV
                    // untouched: its header may not have been flushed before a crash.
                    if FileManager.default.fileExists(atPath: finalURL.path),
                       let file = try? AVAudioFile(forReading: finalURL), file.length > 0 {
                        recording.chunks[index].duration = Double(file.length) / file.processingFormat.sampleRate
                        recording.chunks[index].isComplete = true
                    }
                }
                recording.status = .interrupted
                recording.note = "上次录音意外中断；已保留完成的音频片段，最后一个未完成片段可能缺失。"
                try save(recording)
            }
            recordings.append(recording)
        }
        return recordings.sorted { $0.startedAt > $1.startedAt }
    }
}

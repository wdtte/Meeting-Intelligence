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
        let folder = directory(for: recording.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recording).write(to: folder.appendingPathComponent("recording.json"), options: .atomic)
    }
    public func loadAll(recover: Bool = false) throws -> [Recording] {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var recordings: [Recording] = []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            let url = folder.appendingPathComponent("recording.json")
            // A corrupt manifest is surfaced; it is never silently replaced or deleted.
            var recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url))
            guard recording.schemaVersion == 1, recording.id.uuidString == folder.lastPathComponent else {
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

import Foundation

extension RecordingStore {
    public func rename(_ id: UUID, to title: String) throws -> Recording {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw MeetingError.message("会议名称不能为空。") }
        var recording = try readForManagement(id)
        recording.title = clean
        try save(recording)
        return recording
    }

    func readForManagement(_ id: UUID) throws -> Recording {
        let url = directory(for: id).appendingPathComponent("recording.json")
        let recording = try DiskFormat.read(Recording.self, at: url)
        guard recording.id == id, (1...2).contains(recording.schemaVersion), recording.status != .recording else {
            throw MeetingError.message("无法修改正在录制或信息异常的会议。")
        }
        return recording
    }

    public func moveToTrash(_ id: UUID) throws {
        try moveToTrash(id) { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    /// Stage an external transcript inside the meeting folder so both files go to
    /// Trash together. Restore its original location if the trash operation fails.
    func moveToTrash(_ id: UUID, trash: (URL) throws -> Void) throws {
        let recording = try readForManagement(id)
        let folder = directory(for: id)
        let manager = FileManager.default
        var staged: (original: URL, temporary: URL)?
        if let path = recording.transcriptPath, manager.fileExists(atPath: path) {
            let original = URL(fileURLWithPath: path)
            _ = try TranscriptDocument.load(from: original, recordingID: id)
            let resolved = original.resolvingSymlinksInPath().path
            let insideFolder = resolved.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
            if !insideFolder {
                let temporary = folder.appendingPathComponent("transcript-\(UUID()).json")
                try manager.moveItem(at: original, to: temporary)
                staged = (original, temporary)
            }
        }
        do { try trash(folder) }
        catch {
            if let staged {
                do { try manager.moveItem(at: staged.temporary, to: staged.original) }
                catch { throw MeetingError.message("删除未完成，转写文件保留在 \(staged.temporary.path)。\(error.localizedDescription)") }
            }
            throw error
        }
    }
}

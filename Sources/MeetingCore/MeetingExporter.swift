import Foundation

public enum MeetingExportKind: String, CaseIterable, Sendable {
    case transcriptAndAudio, audio, transcript

    public var title: String {
        switch self {
        case .transcriptAndAudio: "导出转写＋音频"
        case .audio: "导出音频"
        case .transcript: "导出转写"
        }
    }
    public var fileExtension: String { self == .audio ? "m4a" : "html" }
    public var includesAudio: Bool { self != .transcript }
    public var includesTranscript: Bool { self != .audio }
    public var explanation: String {
        switch self {
        case .transcriptAndAudio: "导出单个 HTML 文件，内含摘要（如已生成）、转写和合并音频。可离线查看、播放及点击字幕回听，文件大小比单独音频略大。"
        case .audio: "系统音频与麦克风将按原始时间线混合为一个 M4A 文件。"
        case .transcript: "导出包含摘要（如已生成）、发言来源和时间戳的 HTML 文件，可在浏览器中离线阅读和搜索，不包含音频。"
        }
    }
}

public enum MeetingExporter {
    @concurrent public static func export(_ recording: Recording, transcript: TranscriptDocument?,
                                         store: RecordingStore, kind: MeetingExportKind, to destination: URL) async throws {
        try Task.checkCancellation()
        if kind == .audio {
            try await MergedAudioExporter.export(recording, store: store, to: destination)
            return
        }
        guard recording.status != .recording else { throw MeetingError.message("请先结束录音，再导出会议。") }
        guard destination.isFileURL, destination.pathExtension.lowercased() == "html" else {
            throw MeetingError.message("请选择 HTML 文件保存位置。")
        }
        guard let transcript, transcript.recordingID == recording.id else {
            throw MeetingError.message("暂无与这场会议匹配的转写结果。")
        }
        try TranscriptHTMLWriter.validate(transcript)
        let working = destination.deletingLastPathComponent().appendingPathComponent(".meeting-export-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: working) }
        let audioURL = kind.includesAudio ? working.appendingPathComponent("audio.m4a") : nil
        if let audioURL { try await MergedAudioExporter.export(recording, store: store, to: audioURL) }
        let htmlURL = working.appendingPathComponent("meeting.html")
        try TranscriptHTMLWriter.write(recording: recording, transcript: transcript, audioURL: audioURL, to: htmlURL)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: htmlURL)
        } else {
            try FileManager.default.moveItem(at: htmlURL, to: destination)
        }
    }
}

enum TranscriptHTMLWriter {
    static func validate(_ transcript: TranscriptDocument) throws {
        guard transcript.segments.allSatisfy({
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end < 1_000_000_000
        }) else { throw MeetingError.message("转写时间戳无效，无法导出。") }
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func write(recording: Recording, transcript: TranscriptDocument, audioURL: URL?, to destination: URL) throws {
        guard let templateURL = Bundle.main.url(forResource: "TranscriptExport", withExtension: "html")
            ?? Bundle.module.url(forResource: "TranscriptExport", withExtension: "html") else {
            throw MeetingError.message("导出页面模板缺失，请重新安装应用。")
        }
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
            ?? Bundle.module.url(forResource: "AppIcon", withExtension: "png") else {
            throw MeetingError.message("导出图标缺失，请重新安装应用。")
        }
        let icon = "data:image/png;base64," + (try Data(contentsOf: iconURL)).base64EncodedString()
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let date = DateFormatter()
        date.locale = Locale(identifier: "zh_CN")
        date.dateFormat = "yyyy年M月d日 HH:mm zzz"
        let completed = MeetingReadSnapshot(recording: recording, transcript: transcript, transcriptURL: destination, revision: "export").contentState == "complete"
        let values = [
            "NONCE": nonce,
            "APP_ICON": icon,
            "TITLE": escape(recording.title),
            "APPLICATION": escape(recording.applicationName),
            "DATE": escape((recording.origin == .imported ? "导入于 " : "") + date.string(from: recording.startedAt)),
            "DURATION": AudioTimeline.clock(recording.duration),
            "COUNT": String(transcript.segments.count),
            "NOTICE": completed ? "" : "转写尚未全部完成 · 本文件仅包含导出时已有的内容",
            "TRANSCRIPT_HINT": audioURL == nil ? "按时间排列，保留发言来源。" : "点击时间戳或文字，回听对应发言。"
        ]
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw MeetingError.message("无法创建 HTML 文件，请检查保存位置。")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
        // Replace tokens from the original template only. Never interpret a title or
        // transcript containing template syntax as another substitution or script.
        let regex = try NSRegularExpression(pattern: #"\{\{([A-Z_]+)\}\}"#)
        var cursor = template.startIndex
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            try Task.checkCancellation()
            guard let range = Range(match.range, in: template), let keyRange = Range(match.range(at: 1), in: template) else { continue }
            try write(String(template[cursor..<range.lowerBound]))
            let key = String(template[keyRange])
            switch key {
            case "PLAYER":
                if let audioURL {
                    // The seek control also works as a plain slider if the
                    // optional waveform cannot be read.
                    let peaks = (try? AudioWaveform.mergedPeaks(at: audioURL)) ?? []
                    try Task.checkCancellation()
                    let envelope = peaks.map(String.init).joined(separator: ",")
                    try write("""
                    <section class="player-dock" aria-label="会议音频">
                    <div class="player">
                      <audio id="audio" controls preload="metadata" aria-label="会议录音" src="data:audio/mp4;base64,
                    """)
                    try writeBase64(audioURL, to: output)
                    try write("""
                    ">当前浏览器不支持播放此音频，请使用 Safari、Chrome 或 Edge。</audio>
                      <div id="player-controls" class="player-controls" hidden>
                        <div class="transport">
                          <button id="backward" type="button" aria-label="后退 15 秒" title="后退 15 秒"><svg class="icon" aria-hidden="true"><use href="#back"/></svg></button>
                          <button id="play" type="button" aria-label="播放录音" title="播放录音"><svg class="icon" aria-hidden="true"><use href="#play-icon"/></svg></button>
                          <button id="forward-button" type="button" aria-label="前进 15 秒" title="前进 15 秒"><svg class="icon" aria-hidden="true"><use href="#forward"/></svg></button>
                        </div>
                        <div class="timeline">
                          <span id="playback-time" class="playback-time"></span>
                          <div class="seek-track">
                            <canvas id="waveform" data-peaks="\(envelope)" aria-hidden="true" hidden></canvas>
                            <input type="range" id="position" min="0" max="0" value="0" step="any" aria-label="录音播放进度" disabled>
                          </div>
                        </div>
                        <select id="speed" aria-label="播放速度" title="播放速度"><option value="0.5">0.5×</option><option value="0.75">0.75×</option><option value="1" selected>1×</option><option value="1.5">1.5×</option><option value="2">2×</option><option value="3">3×</option></select>
                      </div>
                      <p id="audio-error" class="player-error" role="status" hidden></p>
                    </div>
                    </section>
                    """)
                }
            case "SUMMARY":
                if transcript.currentSummary != nil || transcript.summaryExportNotice != nil {
                    try write("<section class=\"summary\" aria-labelledby=\"summary-title\"><h2 id=\"summary-title\">会议摘要</h2>")
                    if let notice = transcript.summaryExportNotice { try write("<p class=\"notice\">\(escape(notice))</p>") }
                    if let summary = transcript.currentSummary, let text = summary.text {
                        try write("<p class=\"summary-text\">\(escape(text))</p><p class=\"summary-model\">\(escape(summary.model ?? ""))</p>")
                    }
                    try write("</section>")
                }
            case "SEGMENTS":
                let ordered = transcript.resolvedSegments.enumerated().sorted {
                    $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
                }
                for (index, segment) in ordered {
                    try Task.checkCancellation()
                    let time = AudioTimeline.clock(segment.start)
                    let timestamp = audioURL == nil ? "<span class=\"timestamp\">\(time)</span>" :
                        "<button class=\"timestamp\" type=\"button\" aria-label=\"从 \(time) 播放\">\(time)</button>"
                    let icon = segment.source == .microphone ? "mic" : "speaker"
                    let engine = escape(segment.engine ?? "Apple SpeechTranscriber")
                    try write("""
                    <article class="segment" id="segment-\(index)" data-start="\(segment.start)" data-end="\(segment.end)">
                      <div class="segment-meta">
                        \(timestamp)
                        <div class="segment-labels">
                          <span class="source label"><svg class="icon" aria-hidden="true"><use href="#\(icon)"/></svg>\(segment.source.label)</span>
                          <span class="speaker">\(escape(transcript.speakerName(for: segment)))</span>
                          <span class="engine">\(engine)</span>
                        </div>
                      </div>
                      <p class="segment-text">\(escape(segment.text))</p>
                    </article>
                    """)
                }
                if ordered.isEmpty { try write("<p class=\"empty\">暂无转写文字。</p>") }
            default:
                try write(values[key] ?? "")
            }
            cursor = range.upperBound
        }
        try write(String(template[cursor...]))
        try output.synchronize()
    }

    /// Keep memory bounded and preserve base64 groups even if a read returns short.
    static func writeBase64(_ url: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var pending = Data()
        while let block = try input.read(upToCount: 64 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            pending.append(block)
            let count = pending.count / 3 * 3
            if count > 0 {
                try output.write(contentsOf: pending.prefix(count).base64EncodedData())
                pending = Data(pending.dropFirst(count))
            }
        }
        if !pending.isEmpty { try output.write(contentsOf: pending.base64EncodedData()) }
    }
}

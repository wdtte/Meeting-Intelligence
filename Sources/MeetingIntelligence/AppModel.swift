import AppKit
import AVFoundation
import Foundation
import MeetingCore
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class AppModel {
    enum State { case idle, preparing, recording, stopping }
    enum Page { case meetings, settings }
    var page: Page = .meetings
    var storageSettings: StorageSettings?
    var historyWarnings: [String] = []
    var recordings: [Recording] = []
    var selectedID: UUID?
    var state: State = .idle
    var elapsed: Double = 0
    var savedDuration: Double = 0
    var peak: Float = 0
    var lastAudioAt: TimeInterval?
    var errorMessage: String?
    var libraryError: String?
    var captureName = ""
    var activeRecordingID: UUID?
    var playback = PlaybackCoordinator()
    var transcription = TranscriptionCoordinator()
    var followTranscript = true
    var renamingRecordingID: UUID?
    var recordingTitleDraft = ""
    var deletionCandidate: Recording?
    var deletingRecordingID: UUID?

    func canManage(_ id: UUID) -> Bool {
        !isBusy && deletingRecordingID == nil && exportingRecordingID != id
    }
    func beginRename(_ id: UUID) {
        guard canManage(id), let recording = recordings.first(where: { $0.id == id }) else { return }
        if renamingRecordingID != nil { commitRename() }
        if selectedID != id || page != .meetings { select(id) }
        recordingTitleDraft = recording.title
        renamingRecordingID = id
    }
    func commitRename() {
        guard let id = renamingRecordingID else { return }
        renamingRecordingID = nil
        guard canManage(id), let source = recordingStores[id] else { return }
        do {
            let updated = try source.rename(id, to: recordingTitleDraft)
            if let index = recordings.firstIndex(where: { $0.id == id }) { recordings[index] = updated }
        } catch { errorMessage = error.localizedDescription }
    }
    func requestDeletion(_ id: UUID) {
        guard canManage(id) else { return }
        commitRename()
        deletionCandidate = recordings.first(where: { $0.id == id })
    }
    func deleteRecording(_ id: UUID) async {
        guard canManage(id), let source = recordingStores[id] else { return }
        deletingRecordingID = id
        defer { deletingRecordingID = nil }
        if selectedID == id { playback.load(nil, store: nil) }
        await transcription.stopAndForget(id)
        do {
            try source.moveToTrash(id)
            recordings.removeAll { $0.id == id }
            recordingStores.removeValue(forKey: id)
            exportedFiles.removeValue(forKey: id)
            if selectedID == id {
                selectedID = recordings.first?.id
                playback.load(selectedRecording, store: selectedID.flatMap { recordingStores[$0] })
            }
        } catch {
            if let recording = recordings.first(where: { $0.id == id }) {
                transcription.load(recording)
                if selectedID == id { playback.load(recording, store: source) }
            }
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }
    var exportingRecordingID: UUID?
    var exportedFiles: [UUID: URL] = [:]
    var exportingKind: MeetingExportKind?
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    func exportMeeting(recordingID: UUID, kind: MeetingExportKind) {
        guard !isBusy, deletingRecordingID == nil, exportingRecordingID == nil,
              let recording = recordings.first(where: { $0.id == recordingID }),
              let source = recordingStores[recordingID],
              !kind.includesAudio || recording.duration > 0,
              !kind.includesTranscript || (transcription.documents[recordingID] != nil && !transcription.summaryRunning.contains(recordingID)) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = kind == .audio ? [.mpeg4Audio] : [.html]
        panel.canCreateDirectories = true
        panel.title = kind.title
        panel.message = kind.explanation
        panel.prompt = "导出"
        let title = recording.title.components(separatedBy: CharacterSet(charactersIn: "/:\n\r"))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = kind == .audio ? "" : kind == .transcriptAndAudio ? "-转写与音频" : "-转写"
        panel.nameFieldStringValue = "\(title.isEmpty ? "会议记录" : String(title.prefix(120)))\(suffix).\(kind.fileExtension)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let snapshot = transcription.documents[recordingID]
        exportingRecordingID = recordingID
        exportingKind = kind
        exportedFiles.removeValue(forKey: recordingID)
        exportTask = Task { [weak self] in
            do {
                try await MeetingExporter.export(recording, transcript: snapshot, store: source, kind: kind, to: destination)
                self?.exportedFiles[recordingID] = destination
            } catch is CancellationError {
                // Cancellation leaves the original files and any existing destination intact.
            } catch {
                self?.errorMessage = "导出失败：\(error.localizedDescription)"
            }
            self?.exportingRecordingID = nil
            self?.exportingKind = nil
            self?.exportTask = nil
        }
    }

    func cancelExport() { exportTask?.cancel() }
    func revealExportedFile(recordingID: UUID) {
        if let url = exportedFiles[recordingID] { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    var microphoneEnabled = UserDefaults.standard.bool(forKey: "microphoneEnabled") {
        didSet { UserDefaults.standard.set(microphoneEnabled, forKey: "microphoneEnabled") }
    }
    var microphoneDeviceID = UserDefaults.standard.string(forKey: "microphoneDeviceID") ?? "" {
        didSet { UserDefaults.standard.set(microphoneDeviceID, forKey: "microphoneDeviceID") }
    }
    private(set) var microphoneDevices: [MicrophoneDevice] = []
    var selectedMicrophoneUnavailable: Bool {
        !microphoneDeviceID.isEmpty && !microphoneDevices.contains { $0.id == microphoneDeviceID }
    }
    func refreshMicrophones() async {
        // HAL device queries may wait on audio drivers. Keep them off the UI actor.
        let devices = await Task.detached(priority: .utility) {
            try? MicrophoneDevice.available()
        }.value
        guard !Task.isCancelled, microphoneEnabled else { return }
        if let devices, devices != microphoneDevices {
            microphoneDevices = devices
        }
    }
    // This choice belongs to the next recording, never to the provider settings.
    var useCloudTranscription = false
    var transcriptionLocale = UserDefaults.standard.string(forKey: "transcriptionLocale") ?? "zh-CN" {
        didSet {
            UserDefaults.standard.set(transcriptionLocale, forKey: "transcriptionLocale")
            Task { await prepareSpeechModel() }
        }
    }
    var cloudProvider = TranscriptionProviderID.cloudProviders.first {
        TranscriptionProviderID(rawValue: UserDefaults.standard.string(forKey: "transcriptionProvider") ?? "") == $0
    } ?? .qwen {
        didSet { UserDefaults.standard.set(cloudProvider.rawValue, forKey: "transcriptionProvider") }
    }
    var qwenRegion = QwenRegion(rawValue: UserDefaults.standard.string(forKey: "qwenRegion") ?? "beijing") ?? .beijing {
        didSet {
            UserDefaults.standard.set(qwenRegion.rawValue, forKey: "qwenRegion")
            apiKeyDraft = ""; refreshCredentialStatus()
        }
    }
    var qwenWorkspaceID = UserDefaults.standard.string(forKey: "qwenWorkspaceID") ?? "" {
        didSet { UserDefaults.standard.set(qwenWorkspaceID, forKey: "qwenWorkspaceID") }
    }
    var skipCloudSilence = UserDefaults.standard.object(forKey: "skipCloudSilence") as? Bool ?? true {
        didSet { UserDefaults.standard.set(skipCloudSilence, forKey: "skipCloudSilence") }
    }
    var apiKeyDraft = ""
    var apiKeySaved = false
    var credentialStatus = ""
    private var cloudConfiguration: CloudTranscriptionConfiguration {
        var configuration = CloudTranscriptionConfiguration(region: qwenRegion,
            workspaceID: qwenWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines), skipSilence: skipCloudSilence)
        configuration.provider = cloudProvider
        return configuration
    }
    func refreshCredentialStatus() {
        do {
            switch try TranscriptionCredentials.presence(region: qwenRegion) {
            case .saved:
                apiKeySaved = true
                credentialStatus = "\(qwenRegion.label) API Key 已保存在系统钥匙串"
            case .missing:
                apiKeySaved = false
                credentialStatus = "尚未保存\(qwenRegion.label) API Key"
            case .authorizationRequired:
                apiKeySaved = true
                credentialStatus = "钥匙串待授权，请点击“授权钥匙串访问”"
            }
        } catch { apiKeySaved = false; credentialStatus = error.localizedDescription }
    }
    func saveAPIKey() {
        do {
            try cloudConfiguration.validate()
            try TranscriptionCredentials.save(apiKeyDraft, region: qwenRegion)
            apiKeyDraft = ""; refreshCredentialStatus()
        } catch { credentialStatus = error.localizedDescription }
    }
    func authorizeAPIKey() {
        do {
            let available = try TranscriptionCredentials.authorize(region: qwenRegion)
            apiKeySaved = available
            credentialStatus = available
                ? "密钥已可用；系统提示中选择“始终允许”可记住对本应用的授权。"
                : "尚未保存\(qwenRegion.label) API Key"
        } catch { credentialStatus = error.localizedDescription }
    }
    func deleteAPIKey() {
        do { try TranscriptionCredentials.delete(region: qwenRegion); apiKeyDraft = ""; refreshCredentialStatus() }
        catch { credentialStatus = error.localizedDescription }
    }
    func openQwenConsole() {
        let region = qwenRegion == .beijing ? "cn-beijing" : "ap-southeast-1"
        NSWorkspace.shared.open(URL(string: "https://bailian.console.aliyun.com/\(region)/model/settings/api-key")!)
    }
    var summaryBaseURL = UserDefaults.standard.string(forKey: SummaryConfiguration.baseURLPreference) ?? SummaryConfiguration.defaultBaseURL
    var summaryModel = UserDefaults.standard.string(forKey: SummaryConfiguration.modelPreference) ?? SummaryConfiguration.defaultModel
    var summaryAPIKeyDraft = ""
    var summaryAPIKeySaved = false
    var summaryCredentialStatus = ""
    func refreshSummaryCredentialStatus() {
        do {
            switch try SummaryCredentials.presence() {
            case .saved:
                summaryAPIKeySaved = true; summaryCredentialStatus = "摘要 API Key 已保存在系统钥匙串"
            case .missing:
                summaryAPIKeySaved = false; summaryCredentialStatus = "尚未配置摘要 API Key"
            case .authorizationRequired:
                summaryAPIKeySaved = true; summaryCredentialStatus = "摘要钥匙串待授权，请点击“授权钥匙串访问”"
            }
        } catch { summaryCredentialStatus = error.localizedDescription }
    }
    func saveSummarySettings() {
        do {
            let configuration = SummaryConfiguration(baseURL: summaryBaseURL, model: summaryModel)
            try configuration.validate()
            if !summaryAPIKeyDraft.isEmpty { try SummaryCredentials.save(summaryAPIKeyDraft) }
            else if !summaryAPIKeySaved { throw MeetingError.message("请输入摘要 API Key。") }
            UserDefaults.standard.set(configuration.baseURL, forKey: SummaryConfiguration.baseURLPreference)
            UserDefaults.standard.set(configuration.model, forKey: SummaryConfiguration.modelPreference)
            summaryBaseURL = configuration.baseURL; summaryModel = configuration.model; summaryAPIKeyDraft = ""
            refreshSummaryCredentialStatus()
            summaryCredentialStatus += "；配置已保存"
        } catch { summaryCredentialStatus = error.localizedDescription }
    }
    func authorizeSummaryAPIKey() {
        do {
            summaryAPIKeySaved = try SummaryCredentials.authorize()
            summaryCredentialStatus = summaryAPIKeySaved ? "摘要密钥已可用；系统提示中选择“始终允许”可记住授权。" : "尚未保存摘要 API Key"
        } catch { summaryCredentialStatus = error.localizedDescription }
    }
    func deleteSummaryAPIKey() {
        do { try SummaryCredentials.delete(); summaryAPIKeyDraft = ""; refreshSummaryCredentialStatus() }
        catch { summaryCredentialStatus = error.localizedDescription }
    }
    func generateSummary(_ id: UUID) {
        guard !isBusy, deletingRecordingID == nil, exportingRecordingID != id,
              let recording = recordings.first(where: { $0.id == id }) else { return }
        transcription.generateSummary(recording)
    }
    private func validatedCloudConfiguration() throws -> CloudTranscriptionConfiguration {
        let configuration = cloudConfiguration
        try configuration.validate()
        guard try TranscriptionCredentials.load(region: configuration.region) != nil else {
            throw MeetingError.message("请先在设置中保存\(configuration.region.label)地域的百炼 API Key。")
        }
        return configuration
    }
    func resubmitCloudSelected() {
        guard deletingRecordingID == nil, let recording = selectedRecording, let source = recordingStores[recording.id] else { return }
        do { try transcription.resetUnfinishedCloudJobs(recording, store: source) }
        catch { errorMessage = error.localizedDescription }
    }
    var modelStatus = "正在检查系统语音资源…"
    var modelPreparing = false
    var microphonePeak: Float = 0
    var microphoneLastAudioAt: TimeInterval?
    var microphoneWarning: String?
    var transcriptionNotice: String?
    var recoveringAudioDevice = false
    var microphoneStatus: String {
        guard microphoneEnabled else { return "麦克风未开启" }
        if let microphoneWarning { return microphoneWarning }
        if recoveringAudioDevice { return "正在重新连接麦克风…" }
        let processing = state == .recording ? " · 共享输入" : ""
        guard let time = microphoneLastAudioAt, ProcessInfo.processInfo.systemUptime - time < 4 else { return "麦克风暂未检测到声音" + processing }
        return "正在接收麦克风音频" + processing
    }
    func prepareSpeechModel() async {
        guard !modelPreparing else { return }
        modelPreparing = true; modelStatus = "正在自动准备系统语音资源…首次下载可能需要几分钟"
        let locale = transcriptionLocale
        do {
            _ = try await LocalTranscriber.prepare(locale: locale, download: true)
            modelStatus = "系统语音资源已就绪"
            transcriptionNotice = nil
        } catch { modelStatus = error.localizedDescription }
        modelPreparing = false
    }
    func transcribeSelected(useCloud: Bool = false) {
        guard !isBusy, deletingRecordingID == nil, var recording = selectedRecording, let source = recordingStores[recording.id], let settings = storageSettings else { return }
        do {
            if recording.transcriptPath == nil {
                recording.transcriptPath = settings.transcriptDirectory.appendingPathComponent("\(recording.id).json").path
                recording.transcriptionLocale = transcriptionLocale
                try source.save(recording); try reload()
            }
            if useCloud, recording.cloudTranscription == nil {
                recording.cloudTranscription = try validatedCloudConfiguration()
                try source.save(recording); try reload()
            }
            transcription.submit(recording, store: source, retry: true)
        } catch { errorMessage = error.localizedDescription }
    }
    func playSegment(_ segment: TranscriptSegment) {
        playback.seek(to: segment.start)
        if !playback.isPlaying { playback.play() }
    }
    func navigateTranscript(_ direction: TranscriptNavigation.Direction) -> Bool {
        guard page == .meetings, !isBusy, renamingRecordingID == nil,
              deletingRecordingID == nil, deletionCandidate == nil, errorMessage == nil,
              let id = selectedID, playback.duration > 0,
              let segments = transcription.documents[id]?.segments, !segments.isEmpty else { return false }
        playback.tick()
        if let target = TranscriptNavigation.destination(in: segments, from: playback.position, direction: direction) {
            playback.seek(to: target)
        }
        return true
    }
    @ObservationIgnored var store: RecordingStore?
    @ObservationIgnored private var settingsStore: StorageSettingsStore?
    @ObservationIgnored private var recordingStores: [UUID: RecordingStore] = [:]
    @ObservationIgnored private let capture = ProcessAudioCapture()
    @ObservationIgnored private var startedAt: TimeInterval = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    var isBusy: Bool { state != .idle }
    var selectedRecording: Recording? { recordings.first { $0.id == selectedID } }
    var inputStatus: String {
        guard state == .recording else { return "等待开始" }
        if recoveringAudioDevice { return "音频设备已切换，正在恢复录音…" }
        guard let lastAudioAt else { return "等待系统音频 · 请播放会议或其他声音" }
        return ProcessInfo.processInfo.systemUptime - lastAudioAt > 4 ? "暂未检测到声音 · 请检查音源与权限" : "正在接收系统音频"
    }
    init() {
        do {
            let settingsStore = try StorageSettingsStore.applicationStore()
            self.settingsStore = settingsStore
            let settings = try settingsStore.load()
            storageSettings = settings
            store = try RecordingStore(root: settings.audioDirectory)
            try reload(recover: true)
        }
        catch { libraryError = error.localizedDescription }
        refreshCredentialStatus()
        refreshSummaryCredentialStatus()
        Task { [weak self] in await self?.prepareSpeechModel() }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.playback.tick()
                if self.state == .recording {
                    self.elapsed = max(0, ProcessInfo.processInfo.systemUptime - self.startedAt)
                    self.peak *= 0.75
                    self.microphonePeak *= 0.75
                }
            }
        }
    }
    func reload(recover: Bool = false) throws {
        guard let settings = storageSettings, let store else { return }
        var sources: [UUID: RecordingStore] = [:]
        var combined: [UUID: Recording] = [:]
        historyWarnings = []
        // Active directory is authoritative if a user manually copied a meeting.
        let roots = Array(Set(settings.audioHistoryDirectories)).filter { $0 != store.root } + [store.root]
        for root in roots {
            do {
                guard FileManager.default.fileExists(atPath: root.path) else {
                    throw MeetingError.message("目录不可用：\(root.path)")
                }
                let source = try RecordingStore(root: root)
                for recording in try source.loadAll(recover: recover) {
                    combined[recording.id] = recording
                    sources[recording.id] = source
                }
            } catch {
                if root == store.root { throw error }
                historyWarnings.append("旧录音目录暂不可用：\(root.path)")
            }
        }
        recordingStores = sources
        recordings = combined.values.sorted { $0.startedAt > $1.startedAt }
        for recording in recordings { transcription.load(recording) }
    }
    func select(_ id: UUID?) {
        guard !isBusy, deletingRecordingID == nil else { return }
        commitRename()
        page = .meetings
        selectedID = id
        if id == nil { useCloudTranscription = false }
        playback.load(selectedRecording, store: id.flatMap { recordingStores[$0] })
    }
    func start() async {
        guard state == .idle, deletingRecordingID == nil else { return }
        guard let store, libraryError == nil else { return }
        page = .meetings
        state = .preparing; playback.stop(); errorMessage = nil
        var recording = Recording.systemAudio(title: "会议录音 · \(Date().formatted(date: .abbreviated, time: .shortened))")
        if let settings = storageSettings {
            recording.transcriptPath = settings.transcriptDirectory.appendingPathComponent("\(recording.id).json").path
            recording.transcriptionLocale = transcriptionLocale
        }
        if useCloudTranscription {
            do { recording.cloudTranscription = try validatedCloudConfiguration() }
            catch { state = .idle; errorMessage = error.localizedDescription; return }
        }
        activeRecordingID = recording.id; captureName = AudioSource.application.label
        recoveringAudioDevice = false
        elapsed = 0; savedDuration = 0; peak = 0; lastAudioAt = nil
        microphonePeak = 0; microphoneLastAudioAt = nil; microphoneWarning = nil; transcriptionNotice = nil
        do {
            if microphoneEnabled {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else { throw MeetingError.message("麦克风权限未开启。请在系统设置中允许，或关闭麦克风选项后录制系统音频。") }
            }
            let microphoneUID = microphoneDeviceID.isEmpty ? nil : microphoneDeviceID
            try await capture.start(recording: recording, store: store, microphone: microphoneEnabled,
                                    microphoneUID: microphoneUID) { [weak self] event in
                Task { @MainActor in self?.receive(event) }
            }
            startedAt = ProcessInfo.processInfo.systemUptime
            state = .recording
        } catch {
            state = .idle; activeRecordingID = nil; errorMessage = error.localizedDescription
            do { try reload() } catch { libraryError = error.localizedDescription }
        }
    }
    @discardableResult func stop() async -> Bool {
        guard state == .recording else { return false }
        state = .stopping
        return await capture.stop()
    }
    private func receive(_ event: CaptureEvent) {
        switch event {
        case .recovering(let recovering):
            recoveringAudioDevice = recovering
            peak = 0; microphonePeak = 0; lastAudioAt = nil; microphoneLastAudioAt = nil
        case .snapshot(let recording):
            if let store { transcription.submit(recording, store: store) }
        case .microphoneUnavailable(let warning):
            microphoneWarning = warning
            microphonePeak = 0; microphoneLastAudioAt = nil
        case .microphoneMeter(let meter):
            microphonePeak = max(microphonePeak, meter.peak)
            savedDuration = max(savedDuration, meter.savedDuration)
            if meter.peak > 0.001 { microphoneLastAudioAt = ProcessInfo.processInfo.systemUptime }
        case .meter(let meter):
            peak = max(peak, meter.peak); savedDuration = max(savedDuration, meter.savedDuration)
            if meter.peak > 0.001 { lastAudioAt = ProcessInfo.processInfo.systemUptime }
        case .stopped(let recording):
            recoveringAudioDevice = false
            if let store { transcription.submit(recording, store: store) }
            state = .idle; activeRecordingID = nil; useCloudTranscription = false
            do { try reload() } catch { libraryError = error.localizedDescription }
            selectedID = recording.id
            playback.load(recording, store: recordingStores[recording.id] ?? store)
        case .failure(let message):
            recoveringAudioDevice = false
            state = .idle; activeRecordingID = nil; errorMessage = message
            do { try reload() } catch { libraryError = error.localizedDescription }
        }
    }
    func showSettings() {
        guard !isBusy, deletingRecordingID == nil else { return }
        commitRename()
        playback.pause()
        selectedID = nil
        page = .settings
    }
    func chooseDirectory(_ kind: StorageDirectoryKind) {
        guard !isBusy, let settings = storageSettings, let settingsStore else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = "选择此文件夹"
        panel.message = kind == .audio ? "选择录音保存目录。已有录音保留在原位置。" : "选择 transcript 数据保存目录。"
        panel.directoryURL = kind == .audio ? settings.audioDirectory : settings.transcriptDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let updated = settings.changing(kind, to: url)
            let candidate = try RecordingStore(root: updated.audioDirectory)
            _ = try candidate.loadAll()
            try settingsStore.save(updated, validating: url)
            storageSettings = updated
            store = candidate
            libraryError = nil
            try reload()
        } catch { errorMessage = "无法设置保存目录：\(error.localizedDescription)" }
    }
    func revealDirectory(_ directory: URL?) {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch { errorMessage = error.localizedDescription }
    }
    func revealRecordings() { revealDirectory(store?.root) }
}

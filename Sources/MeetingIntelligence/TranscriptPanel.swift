import SwiftUI
import MeetingCore

struct SpeechModelControls: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("转写语言", selection: $model.transcriptionLocale) {
                Text("普通话（简体中文）").tag("zh-CN")
                Text("English (US)").tag("en-US")
            }.disabled(model.modelPreparing)
            HStack {
                Button(model.modelPreparing ? "正在准备模型…" : "重新检查系统语音资源") {
                    Task { await model.prepareSpeechModel() }
                }.disabled(model.modelPreparing)
                if model.modelPreparing { ProgressView().controlSize(.small) }
            }
            Text(model.modelStatus).font(.caption).foregroundStyle(.secondary)
            Text("默认使用中文，通过 macOS 语音转写服务在本机处理。语言资源由 Apple 管理，缺少时自动下载，无需另装模型。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

// Use the property wrapper explicitly: CLT does not bundle the newer State macro plugin.
private typealias TranscriptViewState<Value> = SwiftUI.State<Value>

struct TranscriptPanel: View {
    @Bindable var model: AppModel
    let recordingID: UUID
    let live: Bool
    @TranscriptViewState private var confirmCloudResubmission = false
    @TranscriptViewState private var followPlayback = true
    private enum Page: Hashable { case transcript, summary }
    @TranscriptViewState private var page = Page.transcript
    @TranscriptViewState private var detailsExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Observe the destination, not every playback tick. During silence keep the
    // preceding utterance in view; overlapping tracks use a stable latest start.
    private var playbackSegmentID: UUID? {
        guard !live else { return nil }
        return (segments.last { $0.start <= model.playback.position } ?? segments.first)?.id
    }
    private func revealPlayback(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let id = playbackSegmentID else { return }
        if animated && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
    private var document: TranscriptDocument? { model.transcription.documents[recordingID] }
    private var segments: [TranscriptSegment] { document?.segments ?? [] }
    private var recording: Recording? { model.recordings.first { $0.id == recordingID } }
    private var isRunning: Bool { model.transcription.running.contains(recordingID) }
    private var isSummaryRunning: Bool { model.transcription.summaryRunning.contains(recordingID) }
    private var isCloudRunning: Bool { model.transcription.cloudRunning.contains(recordingID) }
    private var cloudModel: String? {
        if let provider = document?.cloud?.configuration.provider ?? recording?.cloudTranscription?.provider {
            return provider.label
        }
        return live && model.useCloudTranscription ? model.cloudProvider.label : nil
    }
    private var cloudRequested: Bool { cloudModel != nil }
    private var status: String {
        if let error = document?.error { return error }
        if live, let notice = model.transcriptionNotice { return notice }
        if isRunning && !isCloudRunning { return "正在本地转写，音频已保存" }
        if live { return "每段音频保存后更新本地字幕，约 10 秒一次" }
        if document?.status == "completed" { return segments.isEmpty ? "转写完成，未识别到语音" : "本地转写完成" }
        return "可从已保存的录音继续转写"
    }
    private var hasAudio: Bool { (recording?.duration ?? 0) > 0 }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    if live {
                        HStack {
                            transcriptHeading
                            Spacer(minLength: 8)
                            Toggle("跟随最新", isOn: $model.followTranscript)
                                .toggleStyle(.checkbox).font(.caption)
                        }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) {
                                transcriptHeading.fixedSize()
                                Spacer(minLength: 8)
                                transcriptActions(proxy).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                transcriptHeading
                                HStack {
                                    Spacer(minLength: 0)
                                    transcriptActions(proxy)
                                }
                            }
                        }
                    }
                    if live || !cloudRequested || document?.error != nil || (isRunning && !isCloudRunning) {
                        transcriptionStatus
                    }
                    cloudProgress
                    exportStatus
                    if !live {
                        HStack(spacing: 12) {
                            Picker("会议内容", selection: $page) {
                                Text("字幕").tag(Page.transcript)
                                Text("会议摘要").tag(Page.summary)
                            }.pickerStyle(.segmented).frame(width: 220)
                            summaryStatus
                        }
                    }
                }.padding(.horizontal, live ? 16 : 4).padding(.vertical, live ? 12 : 16)

                if live { Divider().padding(.horizontal, 16) }

                if !live && page == .summary {
                    LightScrollView {
                        summarySection
                            .padding(.horizontal, 4).padding(.top, 8).padding(.bottom, 24)
                    }.frame(minHeight: 0, maxHeight: .infinity)
                } else if segments.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "text.bubble").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                        Text(isRunning || live ? "正在等待识别到的发言" : document?.status == "completed" ? "未识别到语音" : "暂无转写内容")
                            .font(.callout.weight(.medium))
                        Text(isRunning || live ? "音频保存后，文字会自动出现在这里。" : document?.status == "completed" ? "可以使用下方播放条回听录音。" : "在右上角的更多菜单中继续转写。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 24)
                } else {
                    LightScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if !live, document?.cloud != nil { transcriptDetails.padding(.horizontal, 12).padding(.bottom, 8) }
                            ForEach(segments) { segment in
                                TranscriptRow(segment: segment, live: live,
                                              active: !live && segment.contains(model.playback.position)) {
                                    model.playSegment(segment)
                                }.id(segment.id)
                            }
                        }.padding(.horizontal, live ? 4 : 0)
                            .padding(.top, 2).padding(.bottom, 16)
                    }
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .onChange(of: playbackSegmentID, initial: true) { _, _ in
                        if !live && followPlayback { revealPlayback(proxy, animated: model.playback.isPlaying) }
                    }
                    .onChange(of: followPlayback) { _, follow in
                        if !live && follow { revealPlayback(proxy) }
                    }
                    .onChange(of: model.playback.isPlaying) { _, playing in
                        if !live && playing && followPlayback { revealPlayback(proxy) }
                    }
                    .onChange(of: segments.last?.id, initial: true) { _, id in
                        if live && model.followTranscript, let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                    .onChange(of: model.followTranscript) { _, follow in
                        if live && follow, let id = segments.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }.frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: recordingID) { _, _ in detailsExpanded = false; page = .transcript }
        .confirmationDialog("重新提交未完成的云端任务？", isPresented: $confirmCloudResubmission) {
            Button("重新提交（可能重复计费）", role: .destructive) { model.resubmitCloudSelected() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先到百炼控制台核对已有任务。重新提交会放弃未完成片段的 task ID，可能产生重复费用；已完成的片段会保留。")
        }
    }

    @ViewBuilder private var summaryStatus: some View {
        if isSummaryRunning {
            ProgressView().controlSize(.mini)
            Text(summaryProgressText).font(.caption).foregroundStyle(.secondary)
        } else if document?.summary?.error != nil {
            Text("摘要需重试").font(.caption).foregroundStyle(.orange)
        } else if document?.currentSummary != nil {
            Text("摘要已生成").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var transcriptDetails: some View {
        DisclosureGroup("转写详情", isExpanded: $detailsExpanded) {
            if let cloud = document?.cloud {
                VStack(alignment: .leading, spacing: 4) {
                    Text("跳过静音 \(AudioTimeline.clock(cloud.skippedSeconds)) · 按音轨累计")
                    if cloud.noSpeechCount > 0 {
                        Text("云端未识别到语音：\(cloud.noSpeechCount) 个片段，保留本地结果")
                    }
                    if cloud.jobs.values.contains(where: { $0.usage != nil }) {
                        Text("输入 \(cloud.inputTokens) / 输出 \(cloud.outputTokens) Token")
                    }
                }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.font(.caption).foregroundStyle(.secondary)
    }

    private var summaryProgressText: String {
        guard let update = model.transcription.summaryProgress[recordingID] else { return "正在准备摘要…完成后自动保存。" }
        let stage = update.stage == "discovering" ? "正在选择模型" : update.stage == "merging" ? "正在合并摘要" : "正在总结转写"
        return update.total > 0 ? "\(stage) · \(update.completed) / \(update.total) 个分段" : stage
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("会议摘要", systemImage: "text.badge.star").font(.headline)
                Spacer()
                if isSummaryRunning {
                    ProgressView().controlSize(.small)
                    Button("取消") { model.transcription.cancelSummary(recordingID) }
                } else {
                    Button(document?.currentSummary == nil ? "生成摘要" : "重新生成") { model.generateSummary(recordingID) }
                        .disabled(model.isBusy || model.exportingRecordingID == recordingID || recording.map { !model.transcription.canSummarize($0) } != false)
                }
            }
            if let summary = document?.currentSummary, let text = summary.text {
                Text(verbatim: text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let name = summary.model { Text(name).font(.caption).foregroundStyle(.tertiary) }
                if let usage = summary.usage {
                    Text("输入 \(usage.inputTokens.map(String.init) ?? "—") / 输出 \(usage.outputTokens.map(String.init) ?? "—") Token")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            if isSummaryRunning {
                Text(summaryProgressText)
                    .font(.caption).foregroundStyle(.secondary)
            } else if let error = document?.summary?.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            } else if document?.currentSummary == nil {
                Text("配置摘要服务后，云端转写完成时自动生成；仅本地转写需点击“生成摘要”。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcriptHeading: some View {
        HStack(spacing: 10) {
            Text(live ? "录制中转写" : "转写记录").font(.headline)
                .help(live ? "录制中更新本地字幕" : "使用 ← / → 键按字幕语句调整播放位置")
            if !segments.isEmpty {
                Text("\(segments.count) 段发言").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func transcriptActions(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            if page == .transcript {
                HStack(spacing: 4) {
                    Toggle(isOn: $followPlayback) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .frame(width: 28, height: 28)
                            .background(followPlayback ? Color.primary.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }.toggleStyle(.button).buttonStyle(.borderless).tint(.primary)
                        .help(followPlayback ? "跟随播放已开启，点击暂停自动滚动" : "开启跟随播放")
                        .accessibilityLabel("跟随播放")
                        .accessibilityValue(followPlayback ? "已开启" : "已关闭")
                    Button { revealPlayback(proxy) } label: {
                        Image(systemName: "location").frame(width: 28, height: 28)
                    }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("定位正在回听的发言").accessibilityLabel("定位播放位置")
                        .disabled(segments.isEmpty)
                }
                Divider().frame(height: 18)
            }
            primaryTranscriptionAction
            exportMenu
            transcriptionMenu
        }.controlSize(.regular)
    }

    private var transcriptionStatus: some View {
        HStack(alignment: .top, spacing: 7) {
            if isRunning && !isCloudRunning { ProgressView().controlSize(.mini) }
            else { Image(systemName: document?.error != nil ? "exclamationmark.circle" : "text.bubble").font(.caption) }
            Text(status).font(.caption).textSelection(.enabled)
        }.foregroundStyle(document?.error != nil ? Color.orange : Color.secondary)
    }

    @ViewBuilder private var cloudProgress: some View {
        if let cloudModel {
            let cloud = document?.cloud
            let chunks = recording?.chunks.filter(\.isComplete) ?? []
            let completed = chunks.count { cloud?.jobs[$0.id.uuidString]?.completed == true }
            let noFragment = cloud?.error?.contains("（SUCCESS_WITH_NO_VALID_FRAGMENT）") == true
            let progressText = switch cloud?.status {
            case "completed": "已完成"
            case "failed" where noFragment: "可继续"
            case "failed": "未完成"
            case "interrupted": "已暂停"
            default: isCloudRunning ? "正在精校" : live ? "录制结束后开始" : "等待开始"
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label(cloudModel, systemImage: "cloud").fontWeight(.medium)
                    Text(progressText)
                    Spacer(minLength: 4)
                    if !live, !chunks.isEmpty { Text("\(completed) / \(chunks.count) 个片段").monospacedDigit() }
                }
                if !live, !chunks.isEmpty {
                    ProgressView(value: Double(completed), total: Double(chunks.count))
                        .controlSize(.mini)
                        .accessibilityLabel("云端转写进度")
                }
                if let error = cloud?.error {
                    Text(noFragment ? "有片段未识别到有效语音。点击「继续云端转写」可查询原任务并接着处理。" : error)
                        .foregroundStyle(.orange).textSelection(.enabled)
                } else if let cloud, cloud.noSpeechCount > 0 {
                    Text("\(cloud.noSpeechCount) 个片段未识别到语音，已保留本地结果")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var primaryTranscriptionAction: some View {
        if !cloudRequested {
            Button("云端转写", systemImage: "cloud") { model.transcribeSelected(useCloud: true) }
                .buttonStyle(.bordered).controlSize(.regular)
                .help("使用 \(model.cloudProvider.label) 精校这条录音，完成后替换本地字幕")
                .disabled(!hasAudio || model.isBusy)
        } else if isRunning {
            Button("暂停转写", systemImage: "pause") { model.transcription.pause(recordingID) }
                .buttonStyle(.bordered).controlSize(.regular)
        } else if document?.cloud?.status != "completed" {
            Button("继续云端转写", systemImage: "cloud") { model.transcribeSelected() }
                .buttonStyle(.bordered).controlSize(.regular)
                .disabled(!hasAudio || model.isBusy)
        }
    }

    private var exportMenu: some View {
        Menu {
            ForEach(MeetingExportKind.allCases, id: \.self) { kind in
                Button("\(kind.title)…（\(kind.fileExtension.uppercased())）") {
                    model.exportMeeting(recordingID: recordingID, kind: kind)
                }.disabled((kind.includesAudio && !hasAudio) || (kind.includesTranscript && (document == nil || isSummaryRunning)))
            }
        } label: { Label("导出", systemImage: "square.and.arrow.up") }
        .fixedSize().disabled(model.isBusy || model.exportingRecordingID != nil)
    }

    private var transcriptionMenu: some View {
        Menu {
            if isRunning {
                Button("暂停转写", systemImage: "pause") { model.transcription.pause(recordingID) }
            } else if cloudRequested {
                if document?.cloud?.status != "completed" {
                    Button("继续云端转写", systemImage: "cloud") { model.transcribeSelected() }.disabled(!hasAudio)
                }
            } else if document?.status != "completed" {
                Button("继续本地转写", systemImage: "text.bubble") { model.transcribeSelected() }.disabled(!hasAudio)
            }
            if !cloudRequested {
                Button("使用 \(model.cloudProvider.label) 云端精校…", systemImage: "cloud") { model.transcribeSelected(useCloud: true) }
                    .disabled(!hasAudio)
            }
            if document?.cloud?.status == "failed", !isRunning {
                Button("核对后重新提交未完成片段…") { confirmCloudResubmission = true }
            }
            Divider()
            Button("转写设置…", systemImage: "gearshape") { model.showSettings() }
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("转写操作").accessibilityLabel("更多转写操作")
    }

    @ViewBuilder private var exportStatus: some View {
        if !live, model.exportingRecordingID == recordingID {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("正在\(model.exportingKind?.title ?? "导出")…")
                Spacer()
                Button("取消") { model.cancelExport() }
            }.font(.caption).foregroundStyle(.secondary)
        } else if !live, let url = model.exportedFiles[recordingID] {
            HStack {
                Label("文件已导出", systemImage: "checkmark.circle")
                Spacer()
                Button("在 Finder 中显示") { model.revealExportedFile(recordingID: recordingID) }.help(url.path)
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    let live: Bool
    let active: Bool
    var play: () -> Void
    private var engineLabel: String { segment.engine ?? "Apple SpeechTranscriber" }

    var body: some View {
        Button(action: play) {
            HStack(alignment: .top, spacing: 16) {
                Text(AudioTimeline.clock(segment.start))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading).padding(.top, 2)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Label(segment.source.label, systemImage: segment.source == .microphone ? "mic" : "speaker.wave.2")
                            .font(.system(size: 11, weight: .medium))
                        Text(engineLabel).font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.primary.opacity(0.06), in: Capsule())
                    }.foregroundStyle(.secondary)
                    Text(segment.text).font(.system(size: 14)).lineSpacing(5).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 14)
            .background(active ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                if active { Capsule().fill(.primary.opacity(0.45)).frame(width: 2).padding(.vertical, 14) }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(live)
        .accessibilityLabel("\(segment.source.label)，\(engineLabel)，\(AudioTimeline.clock(segment.start))，\(segment.text)")
        .help(live ? engineLabel : "点击回听 · \(engineLabel)")
    }
}

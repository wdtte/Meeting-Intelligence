import SwiftUI
import MeetingCore

struct ContentView: View {
    @Bindable var model: AppModel
    @FocusState private var titleFocused: Bool
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "waveform").font(.title2.weight(.heavy)).padding(9)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    Text("Meeting\nIntelligence").font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 18).padding(.top, 16)
                Button { model.select(nil) } label: {
                    Label("新录制", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(MonochromeButtonStyle()).padding(.horizontal, 18).disabled(model.isBusy)
                VStack(alignment: .leading, spacing: 8) {
                    Text("最近会议").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                    GeometryReader { geometry in
                        LightScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(model.recordings) { recording in
                                    Button { model.select(recording.id) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(recording.title)
                                                .font(.system(size: 13, weight: .medium))
                                                .lineLimit(1).truncationMode(.tail)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            HStack(spacing: 6) {
                                                HStack(spacing: 3) {
                                                    Text(recording.startedAt.formatted(date: .abbreviated, time: .omitted))
                                                        .lineLimit(1).truncationMode(.tail)
                                                    Text("· \(AudioTimeline.clock(recording.duration))").fixedSize()
                                                }.foregroundStyle(.secondary)
                                                Spacer(minLength: 0)
                                                if recording.status == .interrupted || recording.status == .failed {
                                                    Label("需要检查", systemImage: "exclamationmark.circle")
                                                        .foregroundStyle(.orange).fixedSize()
                                                        .help(recording.note ?? "录音未正常完成，请检查详情。")
                                                }
                                            }.font(.caption)
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(model.selectedID == recording.id && model.page == .meetings ? Color.gray.opacity(0.20) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 8))
                                        .contentShape(Rectangle())
                                    }
                                    .contextMenu {
                                        Button("重命名", systemImage: "pencil") { model.beginRename(recording.id) }
                                        Divider()
                                        Button("删除记录…", systemImage: "trash", role: .destructive) { model.requestDeletion(recording.id) }
                                    }
                                    .disabled(!model.canManage(recording.id))
                                    .buttonStyle(.plain).help(recording.title)
                                    .accessibilityLabel(recording.title)
                                    .accessibilityAddTraits(model.selectedID == recording.id && model.page == .meetings ? .isSelected : [])
                                }
                            }
                            // Constrain text to the actual sidebar width, including very long unbroken names.
                            .frame(width: max(0, geometry.size.width - 16), alignment: .leading)
                            .padding(.horizontal, 8)
                        }
                    }
                }.disabled(model.isBusy)
                Button { model.showSettings() } label: {
                    Label("设置", systemImage: "gearshape").font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(model.page == .settings ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 10).disabled(model.isBusy)
            }.navigationSplitViewColumnWidth(min: 220, ideal: 252, max: 320)
        } detail: {
            // Bound the page to the window, and reserve the transport's height
            // before laying out expandable content. A safe-area inset on that
            // content can move outside the viewport during disclosure layout.
            GeometryReader { viewport in
                VStack(spacing: 0) {
                    Group {
                        if model.isBusy { recordingView }
                        else if model.page == .settings { SettingsPage(model: model) }
                        else if let recording = model.selectedRecording { detail(recording) }
                        else { setupView }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()

                    if !model.isBusy, model.page == .meetings, let recording = model.selectedRecording {
                        MeetingPlaybackBar(playback: model.playback, recording: recording)
                            .disabled(model.deletingRecordingID == recording.id)
                            .frame(maxWidth: 840)
                            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 16)
                            .frame(maxWidth: .infinity)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                            .transition(.identity)
                            .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    }
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle("Meeting Intelligence")
        .toolbar(removing: .title)
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("删除这条会议记录？", isPresented: Binding(
            get: { model.deletionCandidate != nil },
            set: { if !$0 { model.deletionCandidate = nil } }
        ), presenting: model.deletionCandidate) { recording in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await model.deleteRecording(recording.id) } }
        } message: { recording in
            Text("“\(recording.title)”的录音和转写将移到废纸篓。已导出的文件会保留。")
        }
        .onChange(of: titleFocused) { if !titleFocused { model.commitRename() } }
        .safeAreaInset(edge: .bottom) {
            if let error = model.libraryError {
                Label("读取录音失败：\(error)", systemImage: "exclamationmark.triangle").font(.callout)
                    .padding().frame(maxWidth: .infinity).background(.orange.opacity(0.12))
            }
        }
    }
    private var setupView: some View {
        LightScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("每一场对话，都值得留下。").font(.system(size: 27, weight: .semibold))
                    Text("录制这台 Mac 的系统声音，记录每一场会议。").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 22) {
                    Label("新录制", systemImage: "record.circle").font(.headline)
                    Label("音频来源：系统音频", systemImage: "speaker.wave.2")
                        .font(.callout)
                    Text("录制所有应用播放的声音，合并为一条系统音频轨，不区分来源应用。")
                        .font(.callout).foregroundStyle(.secondary)
                    MicrophoneControls(model: model)
                    Label("建议佩戴耳机，以获得最佳录音与转写质量，减少扬声器声音被麦克风重复收录。", systemImage: "headphones")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("本地转写始终开启", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("本次录制使用云端转写", isOn: $model.useCloudTranscription)
                    HStack {
                        Text(model.useCloudTranscription
                             ? "录制时显示本地字幕，结束后使用 \(model.cloudProvider.label) 云端精校。"
                             : "先生成本地字幕，录制后也可在会议详情中补做云端转写。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("配置云端服务") { model.showSettings() }.font(.caption)
                    }
                    Divider()
                    HStack {
                        Label(model.useCloudTranscription ? "会后上传 Qwen 云端精校" : "仅保存在这台 Mac",
                              systemImage: model.useCloudTranscription ? "cloud" : "lock.shield")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button { Task { await model.start() } } label: {
                            Label("开始录音", systemImage: "record.circle").padding(.horizontal, 12).padding(.vertical, 5)
                        }.buttonStyle(.borderedProminent).tint(.red)
                            .disabled(model.store == nil || model.libraryError != nil)
                    }
                }.padding(28).card()
                Label("首次使用会请求系统音频录制权限。录制后请确认音量有变化。", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.useCloudTranscription ? "本地字幕 + Qwen 云端精校" : "本地录音与转写").font(.callout.weight(.medium))
                    Text(model.useCloudTranscription
                         ? "系统音频与麦克风分轨保存在本机；录制中约每 10 秒更新本地字幕。停止后上传至百炼精校，成功结果替换本地字幕，支持点击回听。"
                         : "系统音频与麦克风分轨保存；字幕约每 10 秒更新，结束后补齐最后一段。语音模型仅在本机处理音频。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(40).frame(maxWidth: 820)
        }
    }
    private var recordingView: some View {
        LightScrollView {
            VStack(spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("新的会议录音").font(.title2.weight(.semibold))
                        Label(model.captureName, systemImage: "speaker.wave.2").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(model.state == .recording ? "录制中" : model.state == .preparing ? "准备中" : "保存中", systemImage: "record.circle.fill")
                        .font(.callout).foregroundStyle(.red)
                }
                VStack(spacing: 22) {
                    Image(systemName: "waveform").font(.system(size: 32)).foregroundStyle(.red)
                        .frame(width: 72, height: 72).background(.red.opacity(0.07), in: Circle())
                    Text(AudioTimeline.clock(model.elapsed)).font(.system(size: 48, weight: .light, design: .monospaced))
                    Text(model.inputStatus).font(.callout).foregroundStyle(.secondary)
                    if model.microphoneEnabled {
                        HStack {
                            Image(systemName: model.microphoneWarning == nil ? "mic.fill" : "mic.slash")
                            Text(model.microphoneStatus)
                            if model.microphoneWarning == nil {
                                ProgressView(value: Double(model.microphonePeak)).frame(width: 100)
                            }
                        }.font(.callout).foregroundStyle(model.microphoneWarning == nil ? Color.secondary : .orange)
                    }
                    LevelWaveform(levels: model.levels).frame(height: 75).accessibilityLabel("系统音频音量 \(Int(model.peak * 100))%")
                    Text(model.savedDuration > 0 ? "已完成保存 \(AudioTimeline.clock(model.savedDuration))" : "首个音频片段写入后将显示保存进度")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { Task { await model.stop() } } label: {
                        Label("结束录音", systemImage: "stop.fill").padding(.horizontal, 20).padding(.vertical, 7)
                    }.buttonStyle(.borderedProminent).tint(.red).disabled(model.state != .recording)
                }.padding(30).card()
                if let id = model.activeRecordingID {
                    TranscriptPanel(model: model, recordingID: id, live: true)
                        .frame(height: 260).padding(22).card()
                }
            }.padding(36).frame(maxWidth: .infinity)
        }
    }
    private func detail(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    if model.renamingRecordingID == recording.id {
                        TextField("会议名称", text: $model.recordingTitleDraft)
                            .textFieldStyle(.plain).font(.system(size: 26, weight: .semibold))
                            .lineLimit(2).focused($titleFocused)
                            .onAppear { titleFocused = true }
                            .onSubmit { model.commitRename(); titleFocused = false }
                            .onExitCommand { model.renamingRecordingID = nil; titleFocused = false }
                            .accessibilityLabel("编辑会议名称")
                    } else {
                        Button { model.beginRename(recording.id) } label: {
                            Text(recording.title).font(.system(size: 26, weight: .semibold))
                                .lineLimit(2).truncationMode(.tail).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).help("\(recording.title)\n点击修改会议名称")
                            .disabled(!model.canManage(recording.id))
                    }
                    Button(role: .destructive) { model.requestDeletion(recording.id) } label: {
                        Image(systemName: "trash").font(.body).frame(width: 30, height: 32)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("删除记录").accessibilityLabel("删除记录")
                        .disabled(!model.canManage(recording.id))
                }
                HStack(spacing: 16) {
                    Label(recording.startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    Label(recording.applicationName, systemImage: recording.bundleIdentifier.isEmpty ? "speaker.wave.2" : "app")
                    Label(AudioTimeline.clock(recording.duration), systemImage: "clock").fixedSize()
                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if model.deletingRecordingID == recording.id {
                    ProgressView("正在停止转写并删除…").controlSize(.small)
                }
                if let note = recording.note {
                    Label(note, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange).lineLimit(3).help(note)
                }
            }.padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 22)
            Divider().padding(.horizontal, 32)
            TranscriptPanel(model: model, recordingID: recording.id, live: false)
                .id(recording.id)
                .disabled(model.deletingRecordingID != nil)
                .padding(.horizontal, 28)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: 940, maxHeight: .infinity, alignment: .top)
    }

}

private struct LevelWaveform: View {
    let levels: [Float]
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let step = size.width / Double(max(1, levels.count))
                for (index, level) in levels.enumerated() {
                    let height = max(2, Double(sqrt(max(0, level))) * size.height)
                    let rect = CGRect(x: Double(index) * step, y: (size.height - height) / 2, width: max(1, step - 3), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.red.opacity(level > 0.001 ? 0.8 : 0.15)))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
private extension View {
    func card() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.07), lineWidth: 1))
    }
}

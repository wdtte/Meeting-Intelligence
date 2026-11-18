import SwiftUI
import MeetingCore

struct SettingsPage: View {
    @Bindable var model: AppModel
    var body: some View {
        LightScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("设置").font(.system(size: 27, weight: .semibold))
                    Text("管理录音、转写、摘要服务与会议数据。").foregroundStyle(.secondary)
                }
                APIUsageDashboard(model: model).padding(28).settingsCard()
                VStack(alignment: .leading, spacing: 24) {
                    Label("数据存储", systemImage: "internaldrive").font(.headline)
                    HStack {
                        Button("打开迁移备份") { model.revealBackups() }
                        Button("恢复元数据备份…") { model.restoreMetadataBackup() }
                            .disabled(!model.transcription.running.isEmpty || !model.transcription.summaryRunning.isEmpty)
                    }
                    Text("首次使用 v2 功能前备份原始元数据；备份不含音频。恢复会检测备份后的编辑冲突，不会覆盖新数据。降级需使用相应备份。")
                        .font(.caption).foregroundStyle(.secondary)
                    directoryRow("录音保存目录", icon: "waveform", url: model.storageSettings?.audioDirectory, kind: .audio)
                    Divider()
                    directoryRow("Transcript 数据保存目录", icon: "text.alignleft", url: model.storageSettings?.transcriptDirectory, kind: .transcript)
                    Text("目录设置会自动保存。切换录音目录后，新录音使用新位置；已有录音不会移动，仍可在历史记录中查看。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("字幕按会议保存为 JSON。切换目录仅影响新会议，已有字幕仍从原位置读取。")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(28).settingsCard()
                VStack(alignment: .leading, spacing: 20) {
                    Label("录音与本地转写", systemImage: "waveform").font(.headline)
                    MicrophoneControls(model: model)
                    Label("建议佩戴耳机，以获得最佳录音与转写质量，减少扬声器声音被麦克风重复收录。", systemImage: "headphones")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("本地字幕按采集来源区分；云端可识别任务内发言人，支持导入音频。")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("应用录音始终本地转写；导入直接云端转写", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    SpeechModelControls(model: model)
                }.padding(28).settingsCard()
                if !model.historyWarnings.isEmpty {
                    ForEach(model.historyWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    }
                }
                VStack(alignment: .leading, spacing: 18) {
                    Label("云端转写服务", systemImage: "cloud").font(.headline)
                    Picker("Provider", selection: $model.cloudProvider) {
                        ForEach(TranscriptionProviderID.cloudProviders, id: \.self) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    Text("在这里配置云端服务。在新录制页面勾选“本次录制使用云端转写”，或在会议详情中点击“云端转写”，才会上传音频。本地转写始终开启；云端成功结果逐片段替换本地字幕，点击可回听。")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.cloudProvider == .qwen {
                        Picker("百炼地域", selection: $model.qwenRegion) {
                            ForEach(QwenRegion.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        TextField("Workspace ID（可选）", text: $model.qwenWorkspaceID)
                            .textFieldStyle(.roundedBorder)
                        Text("可从百炼控制台获取业务空间 ID；留空使用该地域的标准接口。API Key、业务空间和模型权限须属于同一地域。")
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField(model.apiKeySaved ? "输入新的 API Key 以替换" : "输入百炼 API Key", text: $model.apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("保存 API Key") { model.saveAPIKey() }
                                .disabled(model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("移除 Key", role: .destructive) { model.deleteAPIKey() }.disabled(!model.apiKeySaved)
                            Spacer()
                            Button("前往百炼创建 API Key ↗") { model.openQwenConsole() }
                        }
                        Text(model.credentialStatus).font(.caption).foregroundStyle(.secondary)
                        Button("授权钥匙串访问…") { model.authorizeAPIKey() }.disabled(!model.apiKeySaved)
                        Text("日常转写不会弹出密码框。首次授权请选择系统提示中的“始终允许”，以记住对本应用的访问许可；钥匙串锁定时仍需解锁。")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("新任务默认区分发言人（最多 120 分钟）", isOn: $model.diarizationEnabled)
                        Toggle("分片精校时跳过整段静音，减少云端用量", isOn: $model.skipCloudSilence)
                        Text("只跳过整段接近零音量的片段；轻声、背景噪声及片段内的停顿仍会上传。原录音和回听时间轴保持完整。双轨按各自上传的音频分别计量。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("启用后会将音频片段上传至所选地域的百炼临时存储，并使用 Qwen-Audio 3.1 异步转写。API Key 仅保存在系统钥匙串。费用按百炼实际用量结算。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(28).settingsCard()
                VStack(alignment: .leading, spacing: 18) {
                    Label("会议摘要", systemImage: "text.badge.star").font(.headline)
                    LabeledContent("Provider", value: SummaryProviderID.openAICompatible.label)
                    TextField("Base URL，例如 https://api.openai.com/v1", text: $model.summaryBaseURL)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("摘要 Base URL")
                    TextField("模型，例如 deepseek-chat 或 gpt-4o-mini", text: $model.summaryModel)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("摘要模型")
                    SecureField(model.summaryAPIKeySaved ? "输入新的 API Key 以替换" : "输入摘要 API Key", text: $model.summaryAPIKeyDraft)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("摘要 API Key")
                    HStack {
                        Button("保存摘要配置") { model.saveSummarySettings() }
                        Button("移除 Key", role: .destructive) { model.deleteSummaryAPIKey() }.disabled(!model.summaryAPIKeySaved)
                        Spacer()
                        Button("授权钥匙串访问…") { model.authorizeSummaryAPIKey() }.disabled(!model.summaryAPIKeySaved)
                    }
                    Text(model.summaryCredentialStatus).font(.caption).foregroundStyle(.secondary)
                    Text("配置后，仅在云端转写完成时自动生成摘要。仅本地转写的会议需点击“生成摘要”，避免自动消耗 Token。历史会议也可手动生成；移除 Key 可停止后续自动摘要。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("支持 OpenAI Chat Completions 协议，直接使用你填写的模型。DeepSeek 可填写 Base URL https://api.deepseek.com 和模型 deepseek-chat；也可使用服务支持的其他模型。Base URL 应包含服务要求的路径（如 /v1），本机服务可使用 HTTP。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("API Key 仅保存在系统钥匙串。摘要保存至会议 Transcript JSON，并随 HTML、JSON 和 Markdown 转写导出。长会议会分段总结后合并，费用按服务实际用量结算。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(28).settingsCard()
                VStack(alignment: .leading, spacing: 12) {
                    Label("诊断日志", systemImage: "doc.text.magnifyingglass").font(.headline)
                    Text("记录录音设备切换、回放和云端请求的状态、任务 ID 与错误码。日志仅保存在本机，不包含 API Key、音频、转写正文或上传链接。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(DiagnosticLog.directory.path).font(.caption.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("打开日志目录") {
                            DiagnosticLog.shared.record("diagnostics.open")
                            DiagnosticLog.shared.flush()
                            model.revealDirectory(DiagnosticLog.directory)
                        }
                        Spacer()
                        Text("每份最多 2 MB，保留最近 4 份").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · 构建 \(Bundle.main.object(forInfoDictionaryKey: "MIBuildTime") as? String ?? "未知")")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(28).settingsCard()
            }.padding(40).frame(maxWidth: 900, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func directoryRow(_ title: String, icon: String, url: URL?, kind: StorageDirectoryKind) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.callout.weight(.medium))
            Text(url?.path ?? "保存目录配置不可用")
                .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("选择文件夹…") { model.chooseDirectory(kind) }
                    .accessibilityLabel("选择\(title)")
                Button("在 Finder 中打开") { model.revealDirectory(url) }
                    .accessibilityLabel("打开\(title)")
            }.disabled(url == nil)
        }
    }
}
private extension View {
    func settingsCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.07), lineWidth: 1))
    }
}

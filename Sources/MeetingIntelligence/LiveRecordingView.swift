import SwiftUI
import MeetingCore

struct LiveRecordingView: View {
    let model: AppModel

    private var isRecording: Bool { model.state == .recording }
    private var status: String {
        switch model.state {
        case .preparing: "准备中"
        case .stopping: "保存中"
        case .recording, .idle: "录制中"
        }
    }
    private var savedStatus: String {
        if model.savedDuration > 0 { return "已保存 \(AudioTimeline.clock(model.savedDuration))" }
        return model.state == .stopping ? "正在保存音频…" : "等待首段音频保存"
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 14) {
                controls
                inputs
            }
            .fixedSize(horizontal: false, vertical: true)

            if let id = model.activeRecordingID {
                TranscriptPanel(model: model, recordingID: id, live: true)
                    .id(id)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.10))
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .frame(maxWidth: 960, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text("会议录音").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    HStack(spacing: 5) {
                        if isRecording {
                            Circle().fill(.red).frame(width: 6, height: 6).accessibilityHidden(true)
                        } else {
                            ProgressView().controlSize(.mini).accessibilityHidden(true)
                        }
                        Text(status).font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background((isRecording ? Color.red : .secondary).opacity(0.10), in: Capsule())
                }
                Text(savedStatus).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .fixedSize()

            Spacer(minLength: 0)

            Text(AudioTimeline.clock(model.elapsed))
                .font(.system(size: 34, weight: .medium)).monospacedDigit()
                .accessibilityLabel("已录制").accessibilityValue(AudioTimeline.clock(model.elapsed))
                .fixedSize()

            Button { Task { await model.stop() } } label: {
                Label("结束录音", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(.red)
            .disabled(!isRecording)
            .fixedSize()
        }
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("原始输入").fontWeight(.medium)
                Spacer()
                Text("保存时自动均衡音量")
            }
            .font(.caption).foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 10) {
                inputTile("系统音频", icon: "speaker.wave.2",
                          status: isRecording ? model.inputStatus : status,
                          warning: isRecording && model.recoveringAudioDevice) {
                    InputLevelMeter(source: "系统音频", peak: model.peak, tint: .red)
                }
                inputTile("麦克风", icon: model.microphoneEnabled && model.microphoneWarning == nil ? "mic" : "mic.slash",
                          status: microphoneStatus,
                          warning: model.microphoneEnabled && (model.microphoneWarning != nil || (isRecording && model.recoveringAudioDevice))) {
                    if model.microphoneEnabled && model.microphoneWarning == nil {
                        InputLevelMeter(source: "麦克风", peak: model.microphonePeak, tint: .accentColor)
                    }
                }
            }
        }
    }

    private var microphoneStatus: String {
        if !model.microphoneEnabled { return "未开启" }
        if let warning = model.microphoneWarning { return warning }
        return isRecording ? model.microphoneStatus : status
    }

    private func inputTile<Meter: View>(_ title: String, icon: String, status: String, warning: Bool,
                                        @ViewBuilder meter: () -> Meter) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon).font(.callout.weight(.medium)).fixedSize()
                Spacer(minLength: 0)
                meter()
            }
            .frame(height: 22)
            Text(status)
                .font(.caption)
                .foregroundStyle(warning ? Color.orange : .secondary)
                .lineLimit(2, reservesSpace: true)
                .help(status)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

}

private struct InputLevelMeter: View {
    let source: String
    let peak: Float
    let tint: Color
    private var decibels: Double { peak > 0 ? min(0, 20 * log10(Double(peak))) : -.infinity }
    private static let ticks = [-72, -48, -24, 0]

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                let fraction = max(0, (decibels + 72) / 72)
                RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.20))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(tint)
                            .frame(width: geometry.size.width * fraction)
                    }
                    .overlay {
                        ForEach(Self.ticks.dropFirst().dropLast(), id: \.self) { tick in
                            Rectangle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 1)
                                .position(x: geometry.size.width * Double(tick + 72) / 72, y: geometry.size.height / 2)
                        }
                    }
            }.frame(height: 5)
            HStack(spacing: 0) {
                ForEach(Self.ticks, id: \.self) { tick in
                    if tick != Self.ticks.first { Spacer(minLength: 0) }
                    Text(tick < 0 ? "−\(-tick)" : "0 dB")
                }
            }.font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(width: 116)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(source)原始输入峰值")
        .accessibilityValue(decibels < -72 ? "低于负 72 dBFS" : "\(Int(decibels.rounded())) dBFS")
        .help("原始输入峰值，补偿前（dBFS）。0 dBFS 为满刻度。")
    }
}

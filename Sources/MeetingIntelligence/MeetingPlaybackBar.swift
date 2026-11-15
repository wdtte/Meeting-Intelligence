import SwiftUI
import MeetingCore

/// A compact transport capsule: controls, meeting information with waveform,
/// and a native menu for the playback source.
struct MeetingPlaybackBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var playback: PlaybackCoordinator
    let recording: Recording

    private var canPlay: Bool { playback.duration > 0 && playback.errorMessage == nil }
    private var sourceLabel: String { playback.selectedSource?.label ?? "混听" }
    private var status: String {
        if let error = playback.errorMessage { return error }
        if recording.duration == 0 { return "本次未收到可回放音频" }
        if playback.waveformLoading { return "正在生成波形…" }
        if let error = playback.waveformError { return error }
        return recording.applicationName
    }

    private func sourceOption(_ title: String, source: AudioSource?) -> some View {
        Button { playback.selectedSource = source } label: {
            if playback.selectedSource == source {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Button { playback.seek(to: playback.position - 15) } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 18, weight: .medium)).frame(width: 30, height: 36)
                }.help("后退 15 秒").accessibilityLabel("后退 15 秒")
                Button { playback.toggle() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 23, weight: .semibold)).frame(width: 36, height: 36)
                }
                .help(playback.isPlaying ? "暂停" : "播放")
                .accessibilityLabel(playback.isPlaying ? "暂停录音回放" : "播放录音")
                Button { playback.seek(to: playback.position + 15) } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 18, weight: .medium)).frame(width: 30, height: 36)
                }.help("前进 15 秒").accessibilityLabel("前进 15 秒")
            }.buttonStyle(.plain).disabled(!canPlay)

            VStack(alignment: .leading, spacing: 0) {
                Text(recording.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(recording.title)
                HStack(spacing: 8) {
                    Text(status).lineLimit(1).truncationMode(.tail).help(status)
                        .foregroundStyle(playback.errorMessage == nil ? Color.secondary : Color.red)
                    Spacer(minLength: 0)
                    Text("\(AudioTimeline.clock(playback.position)) / \(AudioTimeline.clock(recording.duration))")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .fixedSize()
                }.font(.system(size: 11))
                WaveformPlaybackSlider(value: Binding(get: { playback.position }, set: { playback.seek(to: $0) }),
                                       range: 0...max(0.01, playback.duration), peaks: playback.waveform)
                    .frame(height: 16)
                    .accessibilityLabel("录音播放进度")
                    .disabled(!canPlay)
            }.frame(minWidth: 100, maxWidth: .infinity)
                .frame(height: 44)

            Menu {
                sourceOption("混听", source: nil)
                sourceOption("系统音频", source: .application)
                sourceOption("麦克风", source: .microphone)
                    .disabled(!recording.chunks.contains { $0.audioSource == .microphone })
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 32, height: 36).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("回放音轨：\(sourceLabel)")
            .accessibilityLabel("选择回放音轨")
            .accessibilityValue(sourceLabel)
        }
        .frame(height: 44)
        .padding(.leading, 20).padding(.trailing, 18).padding(.vertical, 8)
        .glassEffect(.regular.tint(colorScheme == .dark ? .black.opacity(0.18) : .white.opacity(0.72)), in: .capsule)
        .overlay(Capsule().strokeBorder(.primary.opacity(0.05), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
    }
}

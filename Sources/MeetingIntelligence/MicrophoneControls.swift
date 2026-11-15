import SwiftUI

struct MicrophoneControls: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("同时录制麦克风", isOn: $model.microphoneEnabled)
            if model.microphoneEnabled {
                Picker("麦克风设备", selection: $model.microphoneDeviceID) {
                    Text("系统默认").tag("")
                    ForEach(model.microphoneDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                    if model.selectedMicrophoneUnavailable {
                        Text("之前选择的设备（未连接）").tag(model.microphoneDeviceID)
                    }
                }
                if model.selectedMicrophoneUnavailable {
                    Label("所选麦克风未连接。请重新连接或选择另一台设备，否则只录制系统音频。", systemImage: "mic.slash")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .task(id: model.microphoneEnabled) {
            guard model.microphoneEnabled else { return }
            while !Task.isCancelled {
                model.refreshMicrophones()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }
}

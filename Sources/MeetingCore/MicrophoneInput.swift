import AudioToolbox
import AVFoundation
import CoreAudio
import RealtimeAudio

/// Shared, input-only AUHAL. Binding directly to the default input avoids the
/// automatic input/output aggregate AVAudioEngine can create during a call.
final class MicrophoneInput {
    private static let inputBus: AudioUnitElement = 1
    private var unit: AudioUnit?
    private var render: OpaquePointer?
    private var running = false
    private let deviceUID: String?
    private let device: AudioObjectID
    private var deviceFormat = AudioStreamBasicDescription()
    private(set) var buffer: AVAudioPCMBuffer!

    var ring: OpaquePointer { MIMicrophoneRenderRing(render!) }
    var renderError: OSStatus { MIMicrophoneRenderError(render!) }

    init(deviceUID: String?) throws {
        self.deviceUID = deviceUID
        device = try MicrophoneDevice.resolve(deviceUID)
        guard device != kAudioObjectUnknown else {
            throw MeetingError.message(deviceUID == nil ? "没有可用的系统输入设备。" : "所选麦克风未连接。")
        }
        do { try configure() }
        catch { dispose(); throw error }
    }

    private func configure() throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                   componentSubType: kAudioUnitSubType_HALOutput,
                                                   componentManufacturer: kAudioUnitManufacturer_Apple,
                                                   componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw MeetingError.message("macOS 未提供共享音频输入组件。")
        }
        try check(AudioComponentInstanceNew(component, &unit), "open_unit")
        guard let unit else { throw MeetingError.message("无法打开共享麦克风。") }
        let bus = Self.inputBus
        try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, bus, UInt32(1), "enable_input")
        try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0), "disable_output")
        try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device, "select_input")
        deviceFormat = try format(unit, scope: kAudioUnitScope_Input)

        // Devices such as the built-in microphone array may expose three raw
        // channels. Record its first pair so it fits the existing audio pipeline.
        let channels = min(2, deviceFormat.mChannelsPerFrame)
        guard channels > 0, deviceFormat.mSampleRate > 0,
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: deviceFormat.mSampleRate,
                                      channels: channels, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 8192) else {
            throw MeetingError.message("麦克风格式不可用，请检查系统输入设备。")
        }
        self.buffer = buffer
        try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, bus,
                pcm.streamDescription.pointee, "configure_format")
        if channels < deviceFormat.mChannelsPerFrame {
            let map = (0..<Int32(channels)).map { $0 }
            try map.withUnsafeBufferPointer {
                try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output,
                                               bus, $0.baseAddress!, UInt32($0.count * MemoryLayout<Int32>.size)), "map_channels")
            }
        }
        guard let render = MIMicrophoneRenderCreate(unit, channels, buffer.frameCapacity) else {
            throw MeetingError.message("无法分配麦克风缓冲区。")
        }
        self.render = render
        try set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                AURenderCallbackStruct(inputProc: MIMicrophoneInputProc, inputProcRefCon: UnsafeMutableRawPointer(render)),
                "set_callback")
        try check(AudioUnitInitialize(unit), "initialize_unit")
        try check(AudioOutputUnitStart(unit), "start_unit")
        running = true
        guard try MicrophoneDevice.resolve(deviceUID) == device else {
            throw MeetingError.message("启动时麦克风设备发生变化。")
        }
    }

    func routeIsStable() throws -> Bool {
        guard let unit, running, MIRingDropped(ring) == 0 else { return false }
        try check(renderError, "render_input")
        guard try MicrophoneDevice.resolve(deviceUID) == device else { return false }
        let current = try format(unit, scope: kAudioUnitScope_Input)
        return current.mSampleRate == deviceFormat.mSampleRate && current.mChannelsPerFrame == deviceFormat.mChannelsPerFrame
    }

    func stop() {
        guard let unit, running else { return }
        if AudioOutputUnitStop(unit) == noErr { running = false }
    }

    private func dispose() {
        guard let unit else { return }
        stop()
        AudioUnitUninitialize(unit)
        let status = AudioComponentInstanceDispose(unit)
        self.unit = nil
        // Do not free callback storage if the OS has failed to release the unit.
        if status == noErr, let render { MIMicrophoneRenderDestroy(render) }
        else if status != noErr {
            DiagnosticLog.shared.record("capture.microphone.dispose_failed", fields: ["code": String(status)])
        }
        render = nil
    }

    deinit { dispose() }

    private func format(_ unit: AudioUnit, scope: AudioUnitScope) throws -> AudioStreamBasicDescription {
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: value))
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, Self.inputBus, &value, &size), "read_format")
        return value
    }

    private func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                        _ element: AudioUnitElement, _ value: T, _ stage: String) throws {
        try withUnsafeBytes(of: value) { bytes in
            try check(AudioUnitSetProperty(unit, property, scope, element, bytes.baseAddress!, UInt32(bytes.count)), stage)
        }
    }

    private func check(_ status: OSStatus, _ stage: String) throws {
        guard status == noErr else {
            DiagnosticLog.shared.record("capture.microphone.audio_unit_failed", fields: ["stage": stage, "code": String(status)])
            throw MeetingError.message("麦克风采集失败（Core Audio \(status)）。")
        }
    }
}

import CoreAudio
import Foundation

public struct MicrophoneDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    public static func available() throws -> [MicrophoneDevice] {
        var address = Hardware.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try Hardware.check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size), "读取音频设备列表")
        let stride = MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        guard !ids.isEmpty else { return [] }
        try ids.withUnsafeMutableBytes { bytes in
            try Hardware.check(AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!), "读取音频设备列表")
        }
        var seen = Set<String>()
        return ids.prefix(Int(size) / stride).compactMap { object in
            guard hasInput(object), let uid = string(object, kAudioDevicePropertyDeviceUID),
                  let name = string(object, kAudioObjectPropertyName), seen.insert(uid).inserted else { return nil }
            return MicrophoneDevice(id: uid, name: name)
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    static func resolve(_ uid: String?) throws -> AudioObjectID {
        guard let uid else {
            return try Hardware.scalar(system, kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(kAudioObjectUnknown))
        }
        var address = Hardware.address(kAudioHardwarePropertyTranslateUIDToDevice)
        // Keep the bridged string alive until the HAL has consumed the qualifier.
        let value = uid as CFString
        var qualifier = Unmanaged.passUnretained(value)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: device))
        let status = withExtendedLifetime(value) {
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout.size(ofValue: qualifier)), &qualifier, &size, &device)
        }
        try Hardware.check(status, "查找所选麦克风")
        return device
    }

    private static func hasInput(_ object: AudioObjectID) -> Bool {
        var address = Hardware.address(kAudioDevicePropertyStreams)
        address.mScope = kAudioObjectPropertyScopeInput
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Hardware.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

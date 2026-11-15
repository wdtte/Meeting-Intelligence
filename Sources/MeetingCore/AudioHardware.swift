import CoreAudio
import Foundation

enum Hardware {
    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw MeetingError.message("\(operation)失败（Core Audio \(status)）。请检查系统设置中的“隐私与安全性 → 屏幕与系统音频录制”权限及音频设备。")
        }
    }
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var value = initial; var size = UInt32(MemoryLayout<T>.size); var property = address(selector)
        try withUnsafeMutableBytes(of: &value) { bytes in
            try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, bytes.baseAddress!), "读取音频属性")
        }
        return value
    }
    /// An empty exclusion list captures current and future audio processes, even
    /// when no app is producing sound yet. No process discovery or PID tracking.
    static func globalTapDescription() -> CATapDescription {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Meeting Intelligence · 系统音频"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }
}

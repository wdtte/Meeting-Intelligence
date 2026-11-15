import AppKit
import CoreAudio
import Foundation
import RealtimeAudio

public struct TargetApplication: Identifiable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let name: String
    public let path: String
    public let processID: pid_t
    public var id: String { bundleIdentifier }

    /// Lower numbers keep frequently used meeting sources at the top, even while idle.
    public var preferredOrder: Int? {
        PreferredApplicationCatalog.order(bundleIdentifier: bundleIdentifier, name: name)
    }

    func ownsAudioProcess(pid: pid_t, executablePath: String?) -> Bool {
        pid == processID || executablePath?.hasPrefix(path + "/") == true
    }

    public static func choices(from running: [TargetApplication], outputActiveIDs: Set<String>?,
                               selectedID: String, showAll: Bool) -> [TargetApplication] {
        running.filter {
            showAll || outputActiveIDs == nil || $0.preferredOrder != nil || $0.id == selectedID
                || outputActiveIDs?.contains($0.id) == true
        }.sorted {
            let lhs = $0.preferredOrder ?? Int.max, rhs = $1.preferredOrder ?? Int.max
            if lhs != rhs { return lhs < rhs }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// Output IO activity includes silent streams; it does not require recording audio.
    /// nil means detection is unavailable, so callers should expose all running apps.
    public static func outputActiveIDs(in applications: [TargetApplication]) -> Set<String>? {
        do {
            let objects = try Hardware.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
            var active = Set<String>()
            for object in objects {
                let output = try Hardware.scalar(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))
                guard output != 0 else { continue }
                let pid = try Hardware.scalar(object, kAudioProcessPropertyPID, initial: pid_t(0))
                let path = Hardware.executablePath(for: pid)
                for app in applications where app.ownsAudioProcess(pid: pid, executablePath: path) {
                    active.insert(app.id)
                }
            }
            return active
        } catch { return nil }
    }

    @MainActor public static func running() -> [TargetApplication] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundle = app.bundleIdentifier, let url = app.bundleURL,
                  seen.insert(bundle).inserted else { return nil }
            return TargetApplication(bundleIdentifier: bundle, name: app.localizedName ?? bundle, path: url.path, processID: app.processIdentifier)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

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
    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var property = address(selector); var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "读取音频进程列表")
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !values.isEmpty else { return [] }
        try values.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, bytes.baseAddress!), "读取音频进程")
        }
        return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
    static func processObjects(for target: TargetApplication) throws -> [AudioObjectID] {
        let objects = try objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return objects.filter { object in
            guard let pid = try? scalar(object, kAudioProcessPropertyPID, initial: pid_t(0)) else { return false }
            return target.ownsAudioProcess(pid: pid, executablePath: executablePath(for: pid))
        }.sorted()
    }
    static func executablePath(for pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4096)
        guard MIProcessPath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

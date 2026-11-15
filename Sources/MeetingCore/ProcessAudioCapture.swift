import AVFoundation
import CoreAudio
import Foundation
import RealtimeAudio

public enum CaptureEvent: Sendable {
    case meter(AudioMeter)
    case snapshot(Recording)
    case microphoneMeter(AudioMeter)
    case microphoneUnavailable(String)
    case stopped(Recording)
    case failure(String)
    case recovering(Bool)
}

// The serial queue owns every mutable property; only the C ring crosses into HAL.
public final class ProcessAudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MeetingIntelligence.capture", qos: .userInitiated)
    private var micInput: MicrophoneInput?
    private var microphoneEnabled = false
    private var microphoneUID: String?
    private var microphoneWarning: String?
    private var outputDevice: AudioObjectID = 0
    private var recovery: CaptureRecoverySchedule?
    private var recoveryError = ""
    private var lastSnapshotCount = 0
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var ring: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var writer: ChunkWriter?
    private var buffer: AVAudioPCMBuffer?
    private var epoch: UInt64 = 0
    private var lastMeter: TimeInterval = 0
    private var started = false
    private var callback: (@Sendable (CaptureEvent) -> Void)?

    public init() {}

    public func start(recording: Recording, store: RecordingStore, microphone: Bool = false,
                      microphoneUID: String? = nil,
                      onEvent: @escaping @Sendable (CaptureEvent) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.tap == 0, self.device == 0, self.writer == nil else {
                    continuation.resume(throwing: MeetingError.message("已有录音或未释放的音频设备；请结束录音或重启应用。"))
                    return
                }
                do {
                    self.callback = onEvent
                    var recording = recording
                    self.microphoneEnabled = microphone
                    self.microphoneUID = microphoneUID
                    self.microphoneWarning = nil
                    self.recovery = nil
                    self.lastSnapshotCount = 0
                    // Opening a Bluetooth microphone can change the output profile.
                    // Establish input first, then capture the resulting output format.
                    self.startMicrophoneIfEnabled()
                    recording.microphoneCaptureMode = self.micInput == nil ? nil : .shared
                    recording.note = self.microphoneWarning
                    try self.configureHardware()
                    guard let format = self.buffer?.format else { throw CaptureFormatChanged() }
                    self.writer = try ChunkWriter(recording: recording, store: store, format: format)
                    // Hardware startup can block. Discard
                    // warm-up on both tracks until the serial writer can drain.
                    self.epoch = mach_absolute_time()
                    if let ring = self.ring { MIRingSetStartTime(ring, self.epoch) }
                    if let ring = self.micInput?.ring { MIRingSetStartTime(ring, self.epoch) }
                    self.startTimer()
                    DiagnosticLog.shared.record("capture.started", fields: ["recording_id": recording.id.uuidString])
                    continuation.resume()
                } catch {
                    let cleanupErrors = self.cleanupHardware()
                    let message = ([error.localizedDescription] + cleanupErrors).joined(separator: "\n")
                    do { _ = try self.writer?.finish(status: .failed, note: message) }
                    catch { onEvent(.failure("录音启动失败，且无法更新保存状态：\(error.localizedDescription)")) }
                    self.writer = nil; self.callback = nil
                    continuation.resume(throwing: MeetingError.message(message))
                }
            }
        }
    }
    public func stop() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let failure = self.finish()
                continuation.resume(returning: failure == nil)
            }
        }
    }
    private func configureHardware() throws {
        outputDevice = try defaultOutputDevice()
        guard outputDevice != 0 else { throw MeetingError.message("正在等待可用的音频输出设备。") }
        let description = Hardware.globalTapDescription()
        try Hardware.check(AudioHardwareCreateProcessTap(description, &tap), "创建系统音频采集")
        let stream = try Hardware.scalar(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        var asbd = stream
        guard let format = AVAudioFormat(streamDescription: &asbd), format.commonFormat == .pcmFormatFloat32,
              format.channelCount > 0, format.channelCount <= 2, format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw MeetingError.message("当前音频设备格式不受支持。请使用单声道或立体声输出设备。")
        }
        self.buffer = buffer
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Intelligence Capture",
            kAudioAggregateDeviceUIDKey: "local.meeting-intelligence.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]]
        ]
        try Hardware.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device), "创建音频采集设备")
        guard let ring = MIRingCreate(64, 65536) else { throw MeetingError.message("无法分配录音缓冲区。") }
        self.ring = ring
        MIRingSetStartTime(ring, UInt64.max)
        try Hardware.check(AudioDeviceCreateIOProcID(device, MIAudioIOProc, UnsafeMutableRawPointer(ring), &ioProc), "创建音频回调")
        try Hardware.check(AudioDeviceStart(device, ioProc), "开始系统音频录制")
        started = true; lastMeter = 0
    }
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
    }
    private func defaultOutputDevice() throws -> AudioObjectID {
        try Hardware.scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                            initial: AudioObjectID(0))
    }
    private func routeChanged() throws -> Bool {
        // Check before draining: HAL can change layout/rate while old packets are queued.
        // A device ID change also matters when both outputs use the same format.
        guard try defaultOutputDevice() == outputDevice else { return true }
        if microphoneEnabled, try !microphoneRouteIsStable() { return true }
        var stream = try Hardware.scalar(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &stream), let buffer else { return true }
        return format != buffer.format
    }
    private func microphoneRouteIsStable() throws -> Bool {
        try micInput?.routeIsStable() ?? false
    }
    private func tick() {
        guard writer != nil else { return }
        if recovery != nil { recoverIfDue(); return }
        do {
            let changed: Bool
            do {
                changed = try routeChanged()
            } catch {
                // Transient HAL property failures are common while Bluetooth changes profile.
                try beginRecovery(reason: error.localizedDescription)
                return
            }
            if changed { try beginRecovery(); return }
            try drain()
        } catch is CaptureFormatChanged {
            do { try beginRecovery() } catch { finish(error: error.localizedDescription) }
        } catch { finish(error: error.localizedDescription) }
    }
    private func beginRecovery(reason: String = "音频设备发生变化") throws {
        guard recovery == nil else { return }
        DiagnosticLog.shared.record("capture.route_recovery.begin", fields: ["recording_id": writer?.recording.id.uuidString ?? "unknown"])
        // Discard queued packets of uncertain format; never interpret them with a new rate.
        // Already-written samples are committed before opening the replacement hardware.
        if let ring { MIRingSetStartTime(ring, UInt64.max) }
        if let micInput { MIRingSetStartTime(micInput.ring, UInt64.max) }
        try writer?.checkpoint()
        if let writer { callback?(.snapshot(writer.recording)) }
        recovery = CaptureRecoverySchedule(now: ProcessInfo.processInfo.systemUptime)
        recoveryError = reason
        callback?(.recovering(true))
        let errors = cleanupHardware(preserveMicrophone: true)
        if !errors.isEmpty { recoveryError = errors.joined(separator: "\n") }
    }
    private func recoverIfDue() {
        switch recovery?.advance(now: ProcessInfo.processInfo.systemUptime) {
        case .wait, .none: return
        case .expired:
            DiagnosticLog.shared.record("capture.route_recovery.expired", fields: ["recording_id": writer?.recording.id.uuidString ?? "unknown"])
            finish(error: "音频设备切换后未能恢复采集，已保存录音。请检查设备连接。\n\(recoveryError)")
            return
        case .retry: break
        }
        do {
            let errors = cleanupHardware(preserveMicrophone: true)
            guard errors.isEmpty else { throw MeetingError.message(errors.joined(separator: "\n")) }
            startMicrophoneIfEnabled()
            try configureHardware()
            guard try !routeChanged() else { throw CaptureFormatChanged() }
            // Keep the original meeting epoch. The resume gate only discards device warm-up.
            let resumeTime = mach_absolute_time()
            if let ring { MIRingSetStartTime(ring, resumeTime) }
            if let micInput { MIRingSetStartTime(micInput.ring, resumeTime) }
            recovery = nil
            DiagnosticLog.shared.record("capture.route_recovery.completed", fields: ["recording_id": writer?.recording.id.uuidString ?? "unknown"])
            callback?(.recovering(false))
        } catch {
            recoveryError = ([error.localizedDescription] + cleanupHardware(preserveMicrophone: true)).joined(separator: "\n")
            DiagnosticLog.shared.failure("capture.route_recovery.retry", error: error, fields: ["recording_id": writer?.recording.id.uuidString ?? "unknown"])
        }
    }
    private func startMicrophoneIfEnabled() {
        guard microphoneEnabled, micInput == nil else { return }
        do {
            micInput = try MicrophoneInput(deviceUID: microphoneUID)
            if let micInput {
                DiagnosticLog.shared.record("capture.microphone.started", fields: [
                    "channels": String(micInput.buffer.format.channelCount),
                    "sample_rate": String(micInput.buffer.format.sampleRate)
                ])
            }
        } catch {
            microphoneEnabled = false
            let warning = writer == nil
                ? "麦克风未能启动，本次仅录制系统音频。\(error.localizedDescription)"
                : "麦克风未能重新连接，之后仅录制系统音频。\(error.localizedDescription)"
            microphoneWarning = warning
            callback?(.microphoneUnavailable(warning))
            DiagnosticLog.shared.failure("capture.microphone.unavailable", error: error,
                                         fields: ["stage": writer == nil ? "start" : "recover"])
        }
    }
    private func drain() throws {
        if let ring, let buffer { try drain(ring, into: buffer, source: .application) }
        if let micInput { try drain(micInput.ring, into: micInput.buffer, source: .microphone) }
        if let writer {
            let count = writer.recording.chunks.filter(\.isComplete).count
            if count != lastSnapshotCount { lastSnapshotCount = count; callback?(.snapshot(writer.recording)) }
        }
    }
    private func drain(_ ring: OpaquePointer, into buffer: AVAudioPCMBuffer, source: AudioSource) throws {
        guard let writer else { return }
        if MIRingDropped(ring) > 0 {
            throw MeetingError.message("\(source.label)缓冲区溢出或音频时间戳无效，已停止录音并保留完成的片段。")
        }
        var packet = MIPacket()
        while MIRingPeek(ring, &packet) {
            defer { MIRingPop(ring) }
            let byteSizes = [packet.byteSizes.0, packet.byteSizes.1]
            let data = [packet.data.0, packet.data.1]
            let channels = [packet.channels.0, packet.channels.1]
            let bytesPerFrame = buffer.format.streamDescription.pointee.mBytesPerFrame
            guard bytesPerFrame > 0, byteSizes[0] % bytesPerFrame == 0 else { throw CaptureFormatChanged() }
            let frameCount = byteSizes[0] / bytesPerFrame
            guard frameCount > 0 else { continue }
            guard frameCount <= buffer.frameCapacity else { throw MeetingError.message("音频帧超出缓冲区容量。") }
            buffer.frameLength = frameCount
            let destinations = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard destinations.count == Int(packet.bufferCount) else { throw CaptureFormatChanged() }
            for index in destinations.indices {
                guard byteSizes[index] == destinations[index].mDataByteSize, channels[index] == destinations[index].mNumberChannels,
                      let source = data[index], let destination = destinations[index].mData else {
                    throw CaptureFormatChanged()
                }
                memcpy(destination, source, Int(byteSizes[index]))
            }
            guard packet.hostTime >= epoch else { continue }
            let offset = AVAudioTime.seconds(forHostTime: packet.hostTime - epoch)
            let meter = try writer.append(buffer, at: offset, source: source)
            let now = ProcessInfo.processInfo.systemUptime
            if source == .microphone { callback?(.microphoneMeter(meter)) }
            else if now - lastMeter >= 0.08 { callback?(.meter(meter)); lastMeter = now }
        }
    }
    @discardableResult private func finish(error: String? = nil) -> String? {
        guard tap != 0 || writer != nil else { return nil }
        timer?.cancel(); timer = nil
        var failure = error
        if started, device != 0 {
            let status = AudioDeviceStop(device, ioProc)
            if status == noErr { started = false }
            else { failure = "停止音频设备失败（\(status)）。请重启应用。" }
        }
        micInput?.stop()
        if error == nil, recovery == nil { do { try drain() } catch { failure = error.localizedDescription } }
        let cleanupErrors = cleanupHardware()
        if !cleanupErrors.isEmpty { failure = ([failure].compactMap { $0 } + cleanupErrors).joined(separator: "\n") }
        do {
            let notes = [microphoneWarning, failure].compactMap { $0 }
            if let recording = try writer?.finish(status: failure == nil ? .completed : .interrupted,
                                                   note: notes.isEmpty ? nil : notes.joined(separator: "\n")) {
                DiagnosticLog.shared.record("capture.finished", fields: ["recording_id": recording.id.uuidString, "status": recording.status.rawValue])
                callback?(.stopped(recording))
            }
        } catch { failure = "无法完成保存：\(error.localizedDescription)。已落盘片段保留在录音目录中。" }
        writer = nil; recovery = nil
        if let failure { callback?(.failure(failure)) }
        callback = nil
        return failure
    }
    @discardableResult private func cleanupHardware(preserveMicrophone: Bool = false) -> [String] {
        // Keep a healthy microphone open while rebuilding the output tap. Repeatedly
        // opening/closing Bluetooth input would bounce between HFP and A2DP profiles.
        if !preserveMicrophone || (try? microphoneRouteIsStable()) != true {
            micInput = nil
        }
        var failures: [String] = []
        if device != 0 {
            if started {
                let status = AudioDeviceStop(device, ioProc)
                if status == noErr { started = false }
                else { failures.append("停止采集设备失败（\(status)）。") }
            }
            if let ioProc {
                let status = AudioDeviceDestroyIOProcID(device, ioProc)
                if status == noErr { self.ioProc = nil }
                else { failures.append("释放音频回调失败（\(status)）。") }
            }
            let status = AudioHardwareDestroyAggregateDevice(device)
            if status == noErr { device = 0; ioProc = nil; started = false }
            else { failures.append("释放采集设备失败（\(status)）。请重启应用。") }
        }
        // A failed HAL teardown must not leave a callback pointing to freed memory.
        // Retain its context until successful teardown (or process exit).
        if ioProc == nil, let ring { MIRingDestroy(ring); self.ring = nil }
        if tap != 0 {
            let status = AudioHardwareDestroyProcessTap(tap)
            if status == noErr { tap = 0 }
            else { failures.append("释放系统音频采集失败（\(status)）。请重启应用。") }
        }
        buffer = nil
        return failures
    }
}

private struct CaptureFormatChanged: LocalizedError {
    var errorDescription: String? { "音频设备格式正在切换。" }
}

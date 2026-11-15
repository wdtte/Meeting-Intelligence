import AVFoundation
import CoreAudio
import Foundation
import RealtimeAudio

public enum CaptureEvent: Sendable {
    case meter(AudioMeter)
    case snapshot(Recording)
    case microphoneMeter(AudioMeter)
    case stopped(Recording)
    case failure(String)
    case recovering(Bool)
}

// The serial queue owns every mutable property; only the C ring crosses into HAL.
public final class ProcessAudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MeetingIntelligence.capture", qos: .userInitiated)
    private var micEngine: AVAudioEngine?
    private var micContext: MicrophoneRing?
    private var micRing: OpaquePointer?
    private var micBuffer: AVAudioPCMBuffer?
    private var micDevices: [AudioObjectID] = []
    private var microphoneEnabled = false
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
    private var target: TargetApplication?
    private var description: CATapDescription?
    private var processObjects: [AudioObjectID] = []
    private var epoch: UInt64 = 0
    private var lastCheck: TimeInterval = 0
    private var lastMeter: TimeInterval = 0
    private var started = false
    private var callback: (@Sendable (CaptureEvent) -> Void)?

    public init() {}

    public func start(target: TargetApplication, recording: Recording, store: RecordingStore, microphone: Bool = false,
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
                    recording.microphoneCaptureMode = microphone ? .shared : nil
                    self.microphoneEnabled = microphone
                    self.recovery = nil
                    self.lastSnapshotCount = 0
                    // Opening a Bluetooth microphone can change the output profile.
                    // Establish input first, then capture the resulting output format.
                    if microphone { try self.startMicrophone() }
                    try self.configureHardware(target: target)
                    guard let format = self.buffer?.format else { throw CaptureFormatChanged() }
                    self.writer = try ChunkWriter(recording: recording, store: store, format: format)
                    // Hardware startup can block. Discard
                    // warm-up on both tracks until the serial writer can drain.
                    self.epoch = mach_absolute_time()
                    if let ring = self.ring { MIRingSetStartTime(ring, self.epoch) }
                    if let ring = self.micRing { MIRingSetStartTime(ring, self.epoch) }
                    self.startTimer()
                    DiagnosticLog.shared.record("capture.started", fields: ["recording_id": recording.id.uuidString])
                    continuation.resume()
                } catch {
                    let cleanupErrors = self.cleanupHardware()
                    let message = ([error.localizedDescription] + cleanupErrors).joined(separator: "\n")
                    do { _ = try self.writer?.finish(status: .failed, note: message) }
                    catch { onEvent(.failure("录音启动失败，且无法更新保存状态：\(error.localizedDescription)")) }
                    self.writer = nil; self.callback = nil; self.target = nil
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
    private func configureHardware(target: TargetApplication) throws {
        outputDevice = try defaultOutputDevice()
        guard outputDevice != 0 else { throw MeetingError.message("正在等待可用的音频输出设备。") }
        self.target = target
        processObjects = try Hardware.processObjects(for: target)
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.name = "Meeting Intelligence · \(target.name)"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.bundleIDs = [target.bundleIdentifier]
        description.isProcessRestoreEnabled = true
        self.description = description
        try Hardware.check(AudioHardwareCreateProcessTap(description, &tap), "创建应用音频采集")
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
        try Hardware.check(AudioDeviceStart(device, ioProc), "开始应用音频录制")
        started = true; lastCheck = 0; lastMeter = 0
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
        guard let micEngine, let micBuffer, let micRing, micEngine.isRunning,
              MIRingDropped(micRing) == 0, try microphoneDevices() == micDevices else { return false }
        return micEngine.inputNode.outputFormat(forBus: 0) == micBuffer.format
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
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCheck > 1, let target {
                lastCheck = now
                guard kill(target.processID, 0) == 0 else {
                    finish(error: "所选应用已退出。已保存收到的音频，请重新选择应用开始录音。")
                    return
                }
                let current = try Hardware.processObjects(for: target)
                if current != processObjects, let description {
                    description.processes = current
                    var value = Unmanaged.passUnretained(description).toOpaque()
                    var address = Hardware.address(kAudioTapPropertyDescription)
                    try Hardware.check(AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &value), "更新应用音频进程")
                    processObjects = current
                }
            }
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
        if let micRing { MIRingSetStartTime(micRing, UInt64.max) }
        try writer?.checkpoint()
        if let writer { callback?(.snapshot(writer.recording)) }
        recovery = CaptureRecoverySchedule(now: ProcessInfo.processInfo.systemUptime)
        recoveryError = reason
        callback?(.recovering(true))
        let errors = cleanupHardware(preserveMicrophone: true)
        if !errors.isEmpty { recoveryError = errors.joined(separator: "\n") }
    }
    private func recoverIfDue() {
        guard let target else { return }
        switch recovery?.advance(now: ProcessInfo.processInfo.systemUptime) {
        case .wait, .none: return
        case .expired:
            DiagnosticLog.shared.record("capture.route_recovery.expired", fields: ["recording_id": writer?.recording.id.uuidString ?? "unknown"])
            finish(error: "音频设备切换后未能恢复采集，已保存录音。请检查设备连接。\n\(recoveryError)")
            return
        case .retry: break
        }
        guard kill(target.processID, 0) == 0 else {
            finish(error: "所选应用已退出，已保存收到的音频。")
            return
        }
        do {
            let errors = cleanupHardware(preserveMicrophone: true)
            guard errors.isEmpty else { throw MeetingError.message(errors.joined(separator: "\n")) }
            if microphoneEnabled, micEngine == nil { try startMicrophone() }
            try configureHardware(target: target)
            guard try !routeChanged() else { throw CaptureFormatChanged() }
            // Keep the original meeting epoch. The resume gate only discards device warm-up.
            let resumeTime = mach_absolute_time()
            if let ring { MIRingSetStartTime(ring, resumeTime) }
            if let micRing { MIRingSetStartTime(micRing, resumeTime) }
            recovery = nil
            DiagnosticLog.shared.record("capture.route_recovery.completed", fields: ["recording_id": writer?.recording.id.uuidString ?? "unknown"])
            callback?(.recovering(false))
        } catch {
            recoveryError = ([error.localizedDescription] + cleanupHardware(preserveMicrophone: true)).joined(separator: "\n")
            DiagnosticLog.shared.failure("capture.route_recovery.retry", error: error, fields: ["recording_id": writer?.recording.id.uuidString ?? "unknown"])
        }
    }
    private func startMicrophone() throws {
        micDevices = try microphoneDevices()
        // Ordinary shared input only; never create a VoiceProcessingIO unit.
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.channelCount <= 2,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let ring = MIRingCreate(64, 65536) else {
            throw MeetingError.message("麦克风格式不可用，请检查系统输入设备。")
        }
        micEngine = engine; micRing = ring; micBuffer = buffer
        MIRingSetStartTime(ring, UInt64.max)
        let context = MicrophoneRing(ring)
        micContext = context
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in
            _ = MIRingPush(context.pointer, buffer.audioBufferList, time.isHostTimeValid ? time.hostTime : 0)
        }
        engine.prepare()
        try engine.start()
        guard try microphoneDevices() == micDevices else {
            throw MeetingError.message("启动时音频设备发生变化，请重新开始录音。")
        }
    }
    private func microphoneDevices() throws -> [AudioObjectID] {
        let selectors = [kAudioHardwarePropertyDefaultInputDevice]
        return try selectors.map {
            try Hardware.scalar(AudioObjectID(kAudioObjectSystemObject), $0, initial: AudioObjectID(0))
        }
    }
    private func stopMicrophone() {
        if let engine = micEngine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        micEngine = nil; micDevices = []
    }
    private func drain() throws {
        if let ring, let buffer { try drain(ring, into: buffer, source: .application) }
        if let micRing, let micBuffer { try drain(micRing, into: micBuffer, source: .microphone) }
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
        stopMicrophone()
        if error == nil, recovery == nil { do { try drain() } catch { failure = error.localizedDescription } }
        let cleanupErrors = cleanupHardware()
        if !cleanupErrors.isEmpty { failure = ([failure].compactMap { $0 } + cleanupErrors).joined(separator: "\n") }
        do {
            if let recording = try writer?.finish(status: failure == nil ? .completed : .interrupted, note: failure) {
                DiagnosticLog.shared.record("capture.finished", fields: ["recording_id": recording.id.uuidString, "status": recording.status.rawValue])
                callback?(.stopped(recording))
            }
        } catch { failure = "无法完成保存：\(error.localizedDescription)。已落盘片段保留在录音目录中。" }
        writer = nil; target = nil; recovery = nil
        if let failure { callback?(.failure(failure)) }
        callback = nil
        return failure
    }
    @discardableResult private func cleanupHardware(preserveMicrophone: Bool = false) -> [String] {
        // Keep a healthy microphone open while rebuilding the output tap. Repeatedly
        // opening/closing Bluetooth input would bounce between HFP and A2DP profiles.
        if !preserveMicrophone || (try? microphoneRouteIsStable()) != true {
            stopMicrophone()
            micRing = nil; micBuffer = nil; micContext = nil
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
            else { failures.append("释放应用音频采集失败（\(status)）。请重启应用。") }
        }
        buffer = nil; description = nil
        return failures
    }
}

private final class MicrophoneRing: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    // A late engine callback retains this owner until it returns.
    deinit { MIRingDestroy(pointer) }
}

private struct CaptureFormatChanged: LocalizedError {
    var errorDescription: String? { "音频设备格式正在切换。" }
}

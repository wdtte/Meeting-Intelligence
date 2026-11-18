import AVFoundation
import Foundation

public struct PreparedCloudAudio: Sendable {
    public var url: URL?
    public var isSilent: Bool { url == nil }
}

public enum CloudAudioPreparation {
    /// Conservative energy gate, not speech classification: noise/music remain eligible.
    /// Only skips a whole near-zero chunk, so no timeline remapping or cut phonemes.
    public static func prepare(url: URL, skipSilence: Bool, progress: (@Sendable (Double) async -> Void)? = nil) async throws -> PreparedCloudAudio {
        let conversion = Task.detached(priority: .utility) { try await convert(url: url, skipSilence: skipSilence, progress: progress) }
        return try await withTaskCancellationHandler { try await conversion.value } onCancel: { conversion.cancel() }
    }

    private static func convert(url: URL, skipSilence: Bool, progress: (@Sendable (Double) async -> Void)?) async throws -> PreparedCloudAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate.isFinite, format.sampleRate > 0,
              format.commonFormat == .pcmFormatFloat32, format.channelCount > 0 else {
            throw MeetingError.message("音频格式无效或为空。")
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var energies = [Double](repeating: 0, count: Int(format.channelCount))
        var peaks = [Float](repeating: 0, count: energies.count)
        var monoEnergy: Double = 0
        var lastProgress = -Double.infinity
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let fraction = Double(file.framePosition) / Double(file.length) * 0.5
            if fraction - lastProgress >= 0.01 { await progress?(fraction); lastProgress = fraction }
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData else { throw MeetingError.message("无法读取音频样本。") }
            for frame in 0..<Int(buffer.frameLength) {
                var sum: Double = 0
                for channel in energies.indices {
                    let value = format.isInterleaved ? samples[0][frame * energies.count + channel] : samples[channel][frame]
                    guard value.isFinite else { throw MeetingError.message("音频包含无效样本。") }
                    energies[channel] += Double(value) * Double(value)
                    peaks[channel] = max(peaks[channel], abs(value)); sum += Double(value)
                }
                monoEnergy += pow(sum / Double(energies.count), 2)
            }
        }
        // Every channel must be below both thresholds; quiet speech is kept.
        if skipSilence && peaks.allSatisfy({ $0 <= 0.0001 }) && energies.allSatisfy({ sqrt($0 / Double(file.length)) <= 0.0000316 }) {
            return PreparedCloudAudio(url: nil)
        }
        let dominant = energies.indices.max(by: { energies[$0] < energies[$1] }) ?? 0
        let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
        guard let converter = AVAudioConverter(from: monoFormat, to: target) else { throw MeetingError.message("无法转换音频采样率。") }
        let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity)!
        // Mix distinct stereo content. Only fall back to the strongest channel when
        // phase cancellation would erase >99% of its energy.
        let useDominant = monoEnergy < (energies.max() ?? 0) * 0.01
        file.framePosition = 0
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Meeting-Upload-\(UUID()).wav")
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: destination) } }
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096)!
        var readError: Error?
        while true {
            try Task.checkCancellation()
            let fraction = 0.5 + Double(file.framePosition) / Double(file.length) * 0.5
            if fraction - lastProgress >= 0.01 { await progress?(fraction); lastProgress = fraction }
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { count, inputStatus in
                if file.framePosition >= file.length { inputStatus.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: buffer, frameCount: min(count, buffer.frameCapacity))
                    mono.frameLength = buffer.frameLength
                    guard let channels = buffer.floatChannelData, let output = mono.floatChannelData else {
                        throw MeetingError.message("无法读取音频声道。")
                    }
                    for frame in 0..<Int(buffer.frameLength) {
                        if useDominant {
                            output[0][frame] = format.isInterleaved ? channels[0][frame * energies.count + dominant] : channels[dominant][frame]
                        } else {
                            var sum: Float = 0
                            for channel in energies.indices {
                                sum += format.isInterleaved ? channels[0][frame * energies.count + channel] : channels[channel][frame]
                            }
                            output[0][frame] = sum / Float(energies.count)
                        }
                    }
                    inputStatus.pointee = .haveData
                    return mono
                } catch { readError = error; inputStatus.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }
            if let error { throw error }
            if converted.frameLength > 0 { try output.write(from: converted) }
            if status == .endOfStream { break }
            guard status != .error else { throw MeetingError.message("音频转换失败。") }
        }
        await progress?(1)
        success = true
        return PreparedCloudAudio(url: destination)
    }
}

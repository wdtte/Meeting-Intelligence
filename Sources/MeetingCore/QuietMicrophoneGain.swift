import Accelerate
import AVFoundation
import Darwin
import Foundation

/// Recover unusually low but present microphone signals. Silence and normal
/// speech keep their recorded level; the peak limit prevents clipping.
enum QuietMicrophoneGain {
    static let peakCeiling: Float = 0.25118 // -12 dBFS, before PCM rounding.
    static func decibels(peak: Float, rms: Double) -> Double {
        guard peak.isFinite, peak > 0, rms.isFinite, rms > 0 else { return 0 }
        let peakDB = 20 * log10(Double(peak))
        let rmsDB = 20 * log10(rms)
        // Require signal well above the quantization floor and some dynamics,
        // so intermittent speech is eligible but steady low noise is not.
        guard (-62 ..< -32).contains(peakDB), rmsDB >= -82, peakDB - rmsDB >= 12 else { return 0 }
        return min(40, (-32 - peakDB) * 2, -12 - peakDB)
    }

    /// Write a bounded-size copy and replace the raw WAV only when the
    /// conversion is complete. A failure leaves the original audio readable.
    static func apply(_ decibels: Double, to url: URL) throws {
        let working = url.deletingLastPathComponent().appendingPathComponent(".mic-gain-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: working) }
        try writeBoostedCopy(from: url, to: working, gain: Float(pow(10, decibels / 20)))
        try working.withUnsafeFileSystemRepresentation { source in
            try url.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination, Darwin.rename(source, destination) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private static func writeBoostedCopy(from source: URL, to target: URL, gain: Float) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let channels = buffer.floatChannelData else {
            throw MeetingError.message("麦克风音量补偿无法读取音频格式。")
        }
        let output = try AVAudioFile(forWriting: target, settings: input.fileFormat.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw MeetingError.message("麦克风音量补偿读取到空片段。") }
            let count = vDSP_Length(buffer.frameLength)
            var scale = gain, minimum = -peakCeiling, maximum = peakCeiling
            for channel in 0..<Int(format.channelCount) {
                let samples = channels[channel]
                vDSP_vsmul(samples, 1, &scale, samples, 1, count)
                vDSP_vclip(samples, 1, &minimum, &maximum, samples, 1, count)
            }
            try output.write(from: buffer)
        }
    }
}

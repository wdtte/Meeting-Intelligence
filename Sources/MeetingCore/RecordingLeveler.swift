import Accelerate
import AVFoundation
import Darwin
import Foundation

/// Measures short windows independently of HAL packet sizes, on the writer queue.
struct RecordingLeveler {
    private static let targetDB = -23.0
    private static let ceilingDB = -7.0 // Two peak-limited tracks can sum without clipping.
    private static let peakCeiling = Float(pow(10, ceilingDB / 20))
    private let windowFrames: Int
    private var peak: Float = 0
    private var windows: [Double] = []
    private var energy: Double = 0
    private var frames = 0
    private var channelCount = 1

    init(sampleRate: Double) {
        windowFrames = max(1, Int((sampleRate * 0.05).rounded()))
    }

    /// Returns the unprocessed packet peak for the live meter.
    mutating func measure(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData else { return 0 }
        channelCount = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let stride = interleaved ? channelCount : 1
        let count = Int(buffer.frameLength)
        var packetPeak: Float = 0
        var start = 0
        while start < count {
            let length = min(windowFrames - frames, count - start)
            for channel in 0..<channelCount {
                let data = interleaved ? samples[0].advanced(by: start * stride + channel) : samples[channel].advanced(by: start)
                var magnitude: Float = 0, squares: Float = 0
                vDSP_maxmgv(data, stride, &magnitude, vDSP_Length(length))
                vDSP_svesq(data, stride, &squares, vDSP_Length(length))
                packetPeak = max(packetPeak, magnitude)
                energy += Double(squares)
            }
            frames += length
            start += length
            if frames == windowFrames {
                windows.append(windowDB)
                frames = 0
                energy = 0
            }
        }
        peak = max(peak, packetPeak)
        return packetPeak
    }

    private var windowDB: Double {
        // Use a finite floor so even an entirely silent window can enter the estimate.
        10 * log10(max(1e-12, energy / (Double(frames) * Double(channelCount))))
    }

    struct Adjustment {
        let decibels: Double
        let headroom: Double
        let hasActivity: Bool
    }

    func adjustment(for source: AudioSource) -> Adjustment {
        guard peak.isFinite, peak > 0 else { return Adjustment(decibels: 0, headroom: 0, hasActivity: false) }
        let peakDB = 20 * log10(Double(peak))
        let headroom = Self.ceilingDB - peakDB
        let levels = (frames > 0 ? windows + [windowDB] : windows).filter(\.isFinite).sorted()
        // Percentiles of active windows avoid normalizing sparse speech against
        // the silence around it. Require dynamics before boosting quiet material.
        let usable = levels.filter { $0 >= (source == .microphone ? -76 : -68) }
        let reference = usable.isEmpty ? -120 : Self.percentile(usable, 0.9)
        let active = usable.filter { $0 >= reference - 12 }
        let hasActivity = peakDB >= -62 && !active.isEmpty
            && reference - Self.percentile(levels, 0.1) >= 8
        let desired = active.isEmpty ? 0 : Self.targetDB - Self.percentile(active, 0.75)
        let requested = hasActivity || desired <= -3 ? desired : 0
        let capped = min(headroom, min(source == .microphone ? 40 : 18, abs(requested) >= 3 ? requested : 0))
        return Adjustment(decibels: capped, headroom: headroom, hasActivity: hasActivity)
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted[Int((Double(sorted.count - 1) * p).rounded())]
    }

    /// Replace only a fully written WAV; even if leveling fails, the raw file is playable.
    static func apply(_ decibels: Double, startingAt startDB: Double, to url: URL) throws {
        let working = url.deletingLastPathComponent().appendingPathComponent(".audio-level-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: working) }
        try writeAdjustedCopy(from: url, to: working, from: Float(pow(10, startDB / 20)), to: Float(pow(10, decibels / 20)))
        try working.withUnsafeFileSystemRepresentation { source in
            try url.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination, Darwin.rename(source, destination) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private static func writeAdjustedCopy(from source: URL, to target: URL, from initialGain: Float, to gain: Float) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let channels = buffer.floatChannelData else {
            throw MeetingError.message("自动均衡无法读取音频格式。")
        }
        let output = try AVAudioFile(forWriting: target, settings: input.fileFormat.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let transition = min(input.length, AVAudioFramePosition(format.sampleRate * 0.025))
        while input.framePosition < input.length {
            let offset = input.framePosition
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw MeetingError.message("自动均衡读取到空片段。") }
            let ramp = initialGain == gain ? 0 : Int(max(0, min(AVAudioFramePosition(buffer.frameLength), transition - offset)))
            let length = Int(buffer.frameLength)
            var scale = gain, minimum = -peakCeiling, maximum = peakCeiling
            for channel in 0..<Int(format.channelCount) {
                let samples = channels[channel]
                for index in 0..<ramp {
                    let fraction = Float(offset + AVAudioFramePosition(index)) / Float(transition)
                    samples[index] *= initialGain + (gain - initialGain) * fraction
                }
                if ramp < length {
                    let tail = samples.advanced(by: ramp)
                    vDSP_vsmul(tail, 1, &scale, tail, 1, vDSP_Length(length - ramp))
                }
                vDSP_vclip(samples, 1, &minimum, &maximum, samples, 1, vDSP_Length(length))
            }
            try output.write(from: buffer)
        }
    }
}

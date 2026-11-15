import AVFoundation
import Accelerate
import Foundation

public enum AudioWaveform {
    /// Read the actual exported mix in bounded blocks. The HTML needs only a
    /// small peak envelope and never has to decode the whole file for drawing.
    static func mergedPeaks(at url: URL, count: Int = 384) throws -> [UInt8] {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let length = file.length
        guard length > 0, count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else { return [] }
        var peaks = [Float](repeating: 0, count: count)
        while file.framePosition < length {
            try Task.checkCancellation()
            let start = file.framePosition
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData else { return [] }
            let frames = Int(min(Int64(buffer.frameLength), length - start))
            var frame = 0
            while frame < frames {
                let bin = min(count - 1, Int((start + Int64(frame)) * Int64(count) / length))
                let boundary = (Int64(bin + 1) * length + Int64(count) - 1) / Int64(count)
                let end = min(frames, Int(boundary - start))
                for channel in 0..<Int(file.processingFormat.channelCount) {
                    var peak: Float = 0
                    vDSP_maxmgv(samples[channel].advanced(by: frame), 1, &peak, vDSP_Length(end - frame))
                    if peak.isFinite { peaks[bin] = max(peaks[bin], min(1, peak)) }
                }
                frame = end
            }
        }
        return peaks.map { UInt8((Double($0) * 255).rounded(.up)) }
    }

    /// Bounded memory; gaps stay empty and each track retains its original time base.
    @concurrent public static func load(_ recording: Recording, store: RecordingStore, count: Int = 1200) async throws -> [AudioSource: [Float]] {
        guard count > 0, recording.duration.isFinite, recording.duration > 0 else { return [:] }
        var result: [AudioSource: [Float]] = [:]
        for chunk in AudioTimeline.playableChunks(recording.chunks, after: -1) {
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: store.audioURL(recording: recording.id, fileName: chunk.fileName))
            let format = file.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else { continue }
            var peaks = result[chunk.audioSource] ?? [Float](repeating: 0, count: count)
            while file.framePosition < file.length {
                try Task.checkCancellation()
                let start = file.framePosition
                try file.read(into: buffer)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
                var frame = 0
                while frame < Int(buffer.frameLength) {
                    let time = chunk.offset + Double(start + Int64(frame)) / format.sampleRate
                    if time >= chunk.end || time >= recording.duration { break }
                    let bin = min(count - 1, max(0, Int(time / recording.duration * Double(count))))
                    let nextTime = min(chunk.end, Double(bin + 1) * recording.duration / Double(count))
                    let end = min(Int(buffer.frameLength), max(frame + 1, Int(ceil((nextTime - chunk.offset) * format.sampleRate - Double(start)))))
                    for channel in 0..<Int(format.channelCount) {
                        var peak: Float = 0
                        vDSP_maxmgv(channels[channel].advanced(by: frame), 1, &peak, vDSP_Length(end - frame))
                        if peak.isFinite { peaks[bin] = max(peaks[bin], min(1, peak)) }
                    }
                    frame = end
                }
            }
            result[chunk.audioSource] = peaks
        }
        return result
    }
}

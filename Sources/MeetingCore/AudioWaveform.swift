import AVFoundation
import Accelerate
import Foundation

public enum AudioWaveform {
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

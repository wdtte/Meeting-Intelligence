import Foundation

public enum PlaybackSpeed: Double, CaseIterable, Sendable {
    case half = 0.5, threeQuarters = 0.75, normal = 1, oneAndHalf = 1.5, double = 2, triple = 3

    public var label: String {
        switch self {
        case .half: "0.5x"
        case .threeQuarters: "0.75x"
        case .normal: "1x"
        case .oneAndHalf: "1.5x"
        case .double: "2x"
        case .triple: "3x"
        }
    }
}

public enum TranscriptNavigation {
    public enum Direction: Sendable { case previous, next }

    /// Equal timestamps on overlapping tracks are one seek destination. Left
    /// skips the current sentence even after playback has advanced into it.
    public static func destination(in segments: [TranscriptSegment], from position: Double,
                                   direction: Direction) -> Double? {
        guard position.isFinite else { return nil }
        let starts = Set(segments.map(\.start).filter { $0.isFinite && $0 >= 0 }).sorted()
        switch direction {
        case .previous:
            guard let current = starts.last(where: { $0 <= position + 0.05 }) else { return starts.first }
            return starts.last { $0 < current } ?? starts.first
        case .next: return starts.first { $0 > position + 0.05 }
        }
    }
}

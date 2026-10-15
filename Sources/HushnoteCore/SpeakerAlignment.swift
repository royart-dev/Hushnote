import Foundation

public enum SpeakerAlignment {
    public static func speaker(start: Double, end: Double, turns: [SpeakerTurn]) -> String {
        let overlaps = turns.map { ($0.speaker, max(0, min(end, $0.end) - max(start, $0.start))) }
            .filter { $0.1 > 0 }
        let scores = overlaps.reduce(into: [String: Double]()) { $0[$1.0, default: 0] += $1.1 }
        guard let best = scores.max(by: { $0.value < $1.value }) else { return "Meeting audio" }
        let competing = scores.filter { $0.key != best.key }.values.max() ?? 0
        if competing > best.value * 0.8 { return "Overlapping speakers" }
        return best.key
    }
}

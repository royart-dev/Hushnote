import Foundation

public enum Markdown {
    private static func yaml(_ string: String) -> String {
        // JSON double-quoted strings are valid YAML scalars.
        String(data: try! JSONEncoder().encode(string), encoding: .utf8)!
    }
    public static func render(_ meeting: Meeting, audioLinks: [(String, String)] = []) -> String {
        let date = ISO8601DateFormatter().string(from: meeting.startedAt)
        var text = """
        ---
        title: \(yaml(meeting.title))
        project: \(yaml(meeting.project))
        date: \(yaml(date))
        duration_seconds: \(Int(meeting.duration))
        meeting_id: \(yaml(meeting.id.uuidString))
        summary_method: \(yaml(meeting.summaryMethod))
        processing: on-device
        ---

        # \(meeting.title.replacingOccurrences(of: "\n", with: " "))

        """
        if !meeting.summary.isEmpty { text += "\n## Notes\n\n\(meeting.summary)\n" }
        if !audioLinks.isEmpty {
            text += "\n## Audio\n\n"
            for (label, path) in audioLinks {
                var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "#?[]()%")
                text += "- [\(label)](\(path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path))\n"
            }
        }
        if !meeting.warnings.isEmpty {
            text += "\n## Recording notes\n\n" + meeting.warnings.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        text += "\n## Transcript\n\n"
        for s in meeting.transcript.sorted(by: { $0.start < $1.start }) {
            text += "**[\(Meeting.timestamp(s.start))] \(meeting.displayName(s.speaker))**\n\n\(s.text)\n\n"
        }
        return text
    }
}

public enum LocalHighlights {
    // A faithful, deterministic fallback when an optional generative model isn't installed.
    // Selected sentences are copied from the transcript, never invented or paraphrased.
    public static func make(_ meeting: Meeting) -> String {
        let meaningful = meeting.transcript.filter { $0.text.split(separator: " ").count >= 5 }
        guard !meaningful.isEmpty else { return "No substantial speech was transcribed." }
        let terms = ["decid", "agree", "next", "action", "deadline", "will", "need", "follow up", "deliver", "plan"]
        let ranked = meaningful.enumerated().sorted { a, b in
            let score: (TranscriptSegment) -> Int = { s in
                let value = s.text.lowercased()
                return terms.reduce(0) { $0 + (value.contains($1) ? 1 : 0) }
            }
            let left = score(a.element), right = score(b.element)
            return left == right ? a.offset < b.offset : left > right
        }.prefix(8).map(\.element).sorted { $0.start < $1.start }
        return "Selected transcript excerpts:\n\n" + ranked.map {
            "- [\(Meeting.timestamp($0.start))] \(meeting.displayName($0.speaker)): \($0.text)"
        }.joined(separator: "\n")
    }
}

/// Splits generated notes into display blocks. Accepts the loose Markdown small models produce:
/// `## Heading`, `**Heading:**`, `Heading:`, `-`/`*`/`•`/`1.` items, and stray code fences.
public enum NoteOutline {
    public enum Block: Equatable, Sendable { case heading(String), item(String), paragraph(String) }

    public static func parse(_ markdown: String) -> [Block] {
        markdown.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("```") { return nil }
            if let match = line.wholeMatch(of: #/#{1,6}\s+(.+?):?/#) { return .heading(String(match.1)) }
            if let match = line.wholeMatch(of: #/\*\*(.+?):?\*\*:?/#) { return .heading(String(match.1)) }
            if let match = line.wholeMatch(of: #/([A-Z][A-Za-z ]{2,32}):/#) { return .heading(String(match.1)) }
            if let match = line.wholeMatch(of: #/(?:[-*•]|\d+[.)])\s+(.+)/#) { return .item(String(match.1)) }
            return .paragraph(line)
        }
    }
}

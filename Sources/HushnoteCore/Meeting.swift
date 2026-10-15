import Foundation

public enum MeetingState: String, Codable, Sendable {
    case recording, interrupted, ready, processing, complete, failed
}

public struct AudioChunk: Codable, Sendable, Identifiable {
    public var id: String { file }
    public var file: String
    public var source: String
    public var start: Double
    public var duration: Double
    public init(file: String, source: String, start: Double, duration: Double) {
        self.file = file; self.source = source; self.start = start; self.duration = duration
    }
}

public struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String
    public init(start: Double, end: Double, speaker: String, text: String) {
        id = UUID(); self.start = start; self.end = end; self.speaker = speaker; self.text = text
    }
}

public struct SpeakerTurn: Codable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public init(start: Double, end: Double, speaker: String) {
        self.start = start; self.end = end; self.speaker = speaker
    }
}

public struct Meeting: Codable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var project: String
    public var startedAt: Date
    public var duration: Double
    public var state: MeetingState
    public var chunks: [AudioChunk]
    public var transcript: [TranscriptSegment]
    public var speakerNames: [String: String]
    public var summary: String
    public var summaryMethod: String
    public var warnings: [String]
    public var completedChunks: [String]
    public var diarizationDone: Bool
    public var turns: [SpeakerTurn]
    public var microphoneOffset: Double

    public init(title: String = "Untitled meeting", project: String = "") {
        id = UUID(); self.title = title; self.project = project; startedAt = Date()
        duration = 0; state = .ready; chunks = []; transcript = []; speakerNames = [:]
        summary = ""; summaryMethod = ""; warnings = []; completedChunks = []
        diarizationDone = false; turns = []; microphoneOffset = 0
    }
    public var speakers: [String] { Array(Set(transcript.map(\.speaker))).sorted() }
    public func displayName(_ speaker: String) -> String { speakerNames[speaker] ?? speaker }
    public var plainTranscript: String {
        transcript.sorted { $0.start < $1.start }.map {
            "[\(Self.timestamp($0.start))] \(displayName($0.speaker)): \($0.text)"
        }.joined(separator: "\n")
    }
    public static func timestamp(_ value: Double) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%02d:%02d:%02d", seconds/3600, (seconds/60)%60, seconds%60)
    }
}

/// The lightweight listing of a meeting. The full `Meeting` is loaded only when it is opened.
public struct MeetingHeader: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var project: String
    public var startedAt: Date
    public var duration: Double
    public var state: MeetingState
    public init(_ meeting: Meeting) {
        id = meeting.id; title = meeting.title; project = meeting.project
        startedAt = meeting.startedAt; duration = meeting.duration; state = meeting.state
    }
}

public enum MeetingFiles {
    // Compact output: manifests are rewritten on every checkpoint, so size and encode time matter more than readability.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    public static func read(_ url: URL) throws -> Meeting {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(Meeting.self, from: Data(contentsOf: url))
    }
    /// Reads only the fields a meeting list needs; transcripts and speaker turns are never materialised.
    public static func readHeader(_ url: URL) throws -> MeetingHeader {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(MeetingHeader.self, from: Data(contentsOf: url, options: .mappedIfSafe))
    }
    public static func save(_ meeting: Meeting, to url: URL) throws {
        try encoder.encode(meeting).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    public static func safeName(_ input: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\n\r\t\0").union(.controlCharacters)
        let clean = input.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(clean.prefix(100)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return name.isEmpty ? "Meeting" : name
    }
    public static func validatedAudioURL(_ chunk: AudioChunk, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(chunk.file).standardizedFileURL.resolvingSymlinksInPath()
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(base), !chunk.file.hasPrefix("/"), chunk.duration >= 0 else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return url
    }
}

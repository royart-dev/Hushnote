import Foundation
import HushnoteCore
import CaptureRing
import AudioToolbox

// Lightweight assertions keep these checks runnable without the Xcode-only XCTest framework.
private func XCTAssertTrue(_ condition: @autoclosure () -> Bool) { if !condition() { fatalError("Expected true") } }
private func XCTAssertFalse(_ condition: @autoclosure () -> Bool) { if condition() { fatalError("Expected false") } }
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) { if lhs != rhs { fatalError("Expected \(lhs) to equal \(rhs)") } }
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) {
    do { _ = try expression() } catch { return }; fatalError("Expected an error")
}
private func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw CocoaError(.coderValueNotFound) }; return value
}

@main
final class CoreTests {
    static func main() throws {
        let checks = CoreTests()
        try checks.testSessionRoundTripAndEscapedMarkdown()
        try checks.testAudioPathCannotEscapeSession()
        checks.testSpeakerOverlapIsNotAssignedFalseIdentity()
        checks.testHighlightsAreSourceExcerpts()
        checks.testNoteOutlineAcceptsLooseModelMarkdown()
        try checks.testManifestReadsWaitForQueuedWrites()
        try checks.testRingBoundsAndWraparound()
        print("PASS: session persistence, header-only listing, Markdown/YAML escaping, path containment, speaker overlap, transcript excerpts, note outline, read-after-queued-write, bounded ring and wraparound")
    }
    func testSessionRoundTripAndEscapedMarkdown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var meeting = Meeting(title: "Roadmap: \"October\"\nreview", project: "Project #1")
        meeting.transcript = [TranscriptSegment(start: 61, end: 65, speaker: "Speaker 1", text: "We agreed to ship the fix on Friday.")]
        meeting.speakerNames["Speaker 1"] = "Alex"
        let url = directory.appendingPathComponent("session.json")
        try MeetingFiles.save(meeting, to: url)
        let restored = try MeetingFiles.read(url)
        XCTAssertEqual(restored.transcript, meeting.transcript)
        let header = try MeetingFiles.readHeader(url)
        XCTAssertEqual(header, MeetingHeader(restored))  // ISO-8601 manifests keep whole seconds
        let markdown = Markdown.render(restored, audioLinks: [("Audio", "Hushnote Audio/test #1.m4a")])
        XCTAssertTrue(markdown.contains("\\\"October\\\"\\nreview"))
        XCTAssertTrue(markdown.contains("[00:01:01] Alex"))
        XCTAssertTrue(markdown.contains("test%20%231.m4a"))
    }

    func testAudioPathCannotEscapeSession() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/session-test")
        let escape = AudioChunk(file: "../private-recording.caf", source: "system", start: 0, duration: 1)
        XCTAssertThrowsError(try MeetingFiles.validatedAudioURL(escape, in: directory))
        let absolute = AudioChunk(file: "/etc/passwd", source: "system", start: 0, duration: 1)
        XCTAssertThrowsError(try MeetingFiles.validatedAudioURL(absolute, in: directory))
        XCTAssertEqual(MeetingFiles.safeName("../a/b:c\n"), "a b c")
    }

    func testSpeakerOverlapIsNotAssignedFalseIdentity() {
        let turns = [SpeakerTurn(start: 0, end: 5, speaker: "Speaker 1"), SpeakerTurn(start: 3, end: 6, speaker: "Speaker 2")]
        XCTAssertEqual(SpeakerAlignment.speaker(start: 1, end: 2, turns: turns), "Speaker 1")
        XCTAssertEqual(SpeakerAlignment.speaker(start: 3, end: 4, turns: turns), "Overlapping speakers")
        XCTAssertEqual(SpeakerAlignment.speaker(start: 8, end: 9, turns: turns), "Meeting audio")
    }

    func testHighlightsAreSourceExcerpts() {
        var meeting = Meeting()
        meeting.transcript = [TranscriptSegment(start: 3, end: 8, speaker: "Speaker 1", text: "Alex will deliver the prototype on Friday.")]
        let notes = LocalHighlights.make(meeting)
        XCTAssertTrue(notes.contains(meeting.transcript[0].text))
        XCTAssertFalse(notes.contains("Monday"))
    }

    func testNoteOutlineAcceptsLooseModelMarkdown() {
        // Shape taken from real Qwen 2.5 1.5B output: fenced, bold headings with inner colons.
        let notes = "```markdown\n**Summary:**\n- Ship the beta first. [00:04:12]\n\n## Decisions\nAction items:\n1. Arjun sends the quote.\nPlain closing line.\n```"
        XCTAssertEqual(NoteOutline.parse(notes), [
            .heading("Summary"), .item("Ship the beta first. [00:04:12]"), .heading("Decisions"),
            .heading("Action items"), .item("Arjun sends the quote."), .paragraph("Plain closing line."),
        ])
    }

    /// Leaving a meeting queues its save; returning at once must read that save, not the older file.
    func testManifestReadsWaitForQueuedWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")
        var meeting = Meeting(title: "Before edits")
        meeting.transcript = (0..<400).map { TranscriptSegment(start: Double($0) * 9, end: Double($0) * 9 + 8, speaker: "Speaker \($0 % 3 + 1)", text: String(repeating: "word ", count: 30)) }
        try MeetingFiles.save(meeting, to: url)
        let writer = ManifestWriter()
        for edit in 1...25 {
            meeting.summary = "Edit \(edit)"
            writer.write(meeting, to: url) { error in fatalError("\(error)") }
        }
        XCTAssertEqual(try writer.read(url).summary, "Edit 25")
        XCTAssertEqual(try writer.serially { try MeetingFiles.read(url) }.summary, "Edit 25")
    }

    func testRingBoundsAndWraparound() throws {
        let ring = try XCTUnwrap(hn_ring_create(4)); defer { hn_ring_destroy(ring) }
        var data: [Float] = [1, 2, 3, 4, 5, 6]
        data.withUnsafeMutableBytes { bytes in
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            hn_ring_push(ring, &abl, 6)
        }
        XCTAssertEqual(hn_ring_dropped(ring), 2)
        var output = [Float](repeating: 0, count: 4)
        XCTAssertEqual(hn_ring_read(ring, &output, 3), 3)
        XCTAssertEqual(Array(output.prefix(3)), [1, 2, 3])
        data.withUnsafeMutableBytes { bytes in
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            hn_ring_push(ring, &abl, 3)
        }
        XCTAssertEqual(hn_ring_read(ring, &output, 4), 4)
        XCTAssertEqual(output, [4, 1.5, 3.5, 5.5])
        XCTAssertEqual(hn_ring_received(ring), 9)
    }
}

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
    @MainActor static func main() async throws {
        let checks = CoreTests()
        try checks.testSessionRoundTripAndEscapedMarkdown()
        try checks.testAudioPathCannotEscapeSession()
        checks.testSpeakerOverlapIsNotAssignedFalseIdentity()
        checks.testHighlightsAreSourceExcerpts()
        checks.testNoteOutlineAcceptsLooseModelMarkdown()
        try checks.testManifestReadsWaitForQueuedWrites()
        try checks.testRingBoundsAndWraparound()
        try await checks.testRouteRecoveryCoalescesAndLeavesOtherTrackRunning()
        try await checks.testRouteRecoveryRetriesUnavailableDevices()
        try await checks.testRouteRecoveryCannotRestartAfterStop()
        checks.testReconnectTimelineAndInterruptionProcessing()
        print("PASS: session persistence, header-only listing, Markdown/YAML escaping, path containment, speaker overlap, transcript excerpts, note outline, read-after-queued-write, bounded ring, route-switch coalescing, independent tracks, reconnect retries, stop cancellation, timeline continuity and interruption processing")
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

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    @MainActor
    func testRouteRecoveryCoalescesAndLeavesOtherTrackRunning() async throws {
        var running: Set<CaptureTrack> = [.system, .microphone]
        var closed: [CaptureTrack] = [], opened: [CaptureTrack] = []
        let recovery = CaptureRouteRecovery(settleDelay: .milliseconds(5), disconnect: {
            closed.append($0); running.remove($0)
        }, reconnect: { opened.append($0); running.insert($0) })
        recovery.begin([.system, .microphone])
        for _ in 0..<200 { recovery.changed(.microphone) }
        XCTAssertEqual(closed, [.microphone])
        XCTAssertEqual(running, [.system])
        try await waitUntil { recovery.pending.isEmpty }
        XCTAssertEqual(opened, [.microphone])
        XCTAssertEqual(running, [.system, .microphone])
        recovery.begin([.system])
        recovery.changed(.microphone)
        XCTAssertTrue(recovery.pending.isEmpty) // Don't enable a microphone the user turned off.
        recovery.stop()
    }

    @MainActor
    func testRouteRecoveryRetriesUnavailableDevices() async throws {
        var attempts: [CaptureTrack: Int] = [:]
        var closed: [CaptureTrack: Int] = [:]
        let recovery = CaptureRouteRecovery(settleDelay: .milliseconds(2), retryDelays: [.milliseconds(3), .milliseconds(5)],
            disconnect: { closed[$0, default: 0] += 1 }, reconnect: { track in
                attempts[track, default: 0] += 1
                if track == .microphone && attempts[track]! < 3 { throw CocoaError(.fileReadUnknown) }
            })
        recovery.begin([.system, .microphone])
        for _ in 0..<100 { recovery.changed(.system); recovery.changed(.microphone) }
        try await waitUntil { recovery.pending.isEmpty }
        XCTAssertEqual(attempts[.system], 1)
        XCTAssertEqual(attempts[.microphone], 3)
        XCTAssertEqual(closed[.system], 1)
        XCTAssertEqual(closed[.microphone], 3) // Partial allocations cleaned up after each failed attempt.
        recovery.stop()
    }

    @MainActor
    func testRouteRecoveryCannotRestartAfterStop() async throws {
        var attempts = 0
        var unavailable = true
        let recovery = CaptureRouteRecovery(settleDelay: .milliseconds(2), retryDelays: [.milliseconds(5)],
            disconnect: { _ in }, reconnect: { _ in
                attempts += 1
                if unavailable { throw CocoaError(.fileReadUnknown) }
            })
        recovery.begin([.system]); recovery.changed(.system)
        try await waitUntil { attempts > 0 }
        recovery.stop()
        let atStop = attempts
        recovery.changed(.system)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(attempts, atStop)
        XCTAssertTrue(recovery.pending.isEmpty)
        // A queued retry from the old recording must not open a graph in a new recording.
        unavailable = false
        recovery.begin([.microphone]); recovery.changed(.microphone)
        try await waitUntil { recovery.pending.isEmpty }
        XCTAssertEqual(attempts, atStop + 1)
        recovery.stop()
    }

    func testReconnectTimelineAndInterruptionProcessing() {
        let chunks = [AudioChunk(file: "system-0.caf", source: "system", start: 0.1, duration: 0.4),
                      AudioChunk(file: "mic-0.caf", source: "microphone", start: 0.2, duration: 20)]
        XCTAssertEqual(CaptureTimeline.nextOffset(elapsed: 0.3, chunks: chunks, source: "system"), 0.5)
        XCTAssertEqual(CaptureTimeline.nextOffset(elapsed: 2.5, chunks: chunks, source: "system"), 2.5)
        XCTAssertEqual(CaptureTimeline.nextOffset(elapsed: 0.1, chunks: [], source: "system"), 0.1)
        XCTAssertTrue(CaptureProcessing.shouldStart(requested: true, automatic: true, modelsAvailable: true, chunkCount: 238))
        XCTAssertFalse(CaptureProcessing.shouldStart(requested: false, automatic: true, modelsAvailable: true, chunkCount: 238))
        XCTAssertFalse(CaptureProcessing.shouldStart(requested: true, automatic: false, modelsAvailable: true, chunkCount: 238))
        XCTAssertFalse(CaptureProcessing.shouldStart(requested: true, automatic: true, modelsAvailable: false, chunkCount: 238))
        XCTAssertFalse(CaptureProcessing.shouldStart(requested: true, automatic: true, modelsAvailable: true, chunkCount: 0))
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

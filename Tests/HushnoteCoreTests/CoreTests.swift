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
        checks.testActivityMeterIgnoresChimesAndCountsSpeech()
        try checks.testSummaryEnginePrivacyAndSettings()
        try checks.testSummaryResponsesParse()
        checks.testQuietRecordingIsRemindedThenStopped()
        checks.testLiveAudioIsNeverStoppedAutomatically()
        checks.testKeepRecordingSnoozesAndSettingsAreHonoured()
        try checks.testManifestReadsWaitForQueuedWrites()
        try checks.testRingBoundsAndWraparound()
        try await checks.testRouteRecoveryCoalescesAndLeavesOtherTrackRunning()
        try await checks.testRouteRecoveryRetriesUnavailableDevices()
        try await checks.testRouteRecoveryCannotRestartAfterStop()
        checks.testReconnectTimelineAndInterruptionProcessing()
        print("PASS: session persistence, header-only listing, Markdown/YAML escaping, path containment, speaker overlap, transcript excerpts, note outline, summary engines, read-after-queued-write, bounded ring, route-switch coalescing, independent tracks, reconnect retries, activity meter, quiet reminders, stop cancellation, timeline continuity and interruption processing")
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

    func testSummaryEnginePrivacyAndSettings() throws {
        var settings = SummarySettings()
        XCTAssertFalse(settings.sendsOffDevice(.bundled))
        XCTAssertFalse(settings.sendsOffDevice(.localModel))
        XCTAssertFalse(settings.sendsOffDevice(.localServer))      // default Ollama address
        XCTAssertTrue(settings.sendsOffDevice(.chatGPT))
        XCTAssertTrue(settings.sendsOffDevice(.anthropic))
        settings.serverURL = "http://192.168.1.20:11434/v1"
        XCTAssertTrue(settings.sendsOffDevice(.localServer))       // another machine is not "this Mac"
        settings.serverURL = "http://localhost:1234/v1"
        XCTAssertFalse(settings.sendsOffDevice(.localServer))
        XCTAssertFalse(SummarySettings.isLoopback("http://127.0.0.1.example.com/v1"))
        XCTAssertFalse(SummarySettings.isLoopback("http://127.0.0.300:80"))
        XCTAssertTrue(SummarySettings.isLoopback("http://127.0.0.1:1234/v1"))
        XCTAssertTrue(SummarySettings.isLoopback("http://[::1]:11434/v1"))
        settings.engine = .chatGPT
        XCTAssertTrue(settings.needsConsent)
        settings.consented = [.chatGPT]
        XCTAssertFalse(settings.needsConsent)
        // Saved settings survive app versions that add or drop fields and engines.
        let restored = try JSONDecoder().decode(SummarySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
        let older = try JSONDecoder().decode(SummarySettings.self, from: Data(#"{"engine":"anthropic","futureField":1,"consented":["anthropic","someday"]}"#.utf8))
        XCTAssertEqual(older.engine, .anthropic)
        XCTAssertEqual(older.consented, [.anthropic])
        XCTAssertEqual(older.anthropicModel, "claude-opus-5-5")
        let unknown = try JSONDecoder().decode(SummarySettings.self, from: Data(#"{"engine":"gemini"}"#.utf8))
        XCTAssertEqual(unknown.engine, .bundled)
        XCTAssertEqual(SummaryPrompt.clean("```markdown\n## Summary\nShip it.\n``` [end of text]"), "## Summary\nShip it.")
    }

    func testSummaryResponsesParse() throws {
        let data = { (json: String) in Data(json.utf8) }
        XCTAssertEqual(try SummaryResponse.openAIResponses(data(###"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"## Summary"},{"type":"output_text","text":"\nShip it."}]}]}"###)), "## Summary\nShip it.")
        XCTAssertThrowsError(try SummaryResponse.openAIResponses(data(###"{"output":[{"type":"message","content":[{"type":"refusal","refusal":"No."}]}]}"###)))
        let partial = try SummaryResponse.openAIResponses(data(###"{"status":"incomplete","output":[{"type":"message","content":[{"type":"output_text","text":"Partial"}]}]}"###))
        XCTAssertTrue(partial.hasSuffix("cut short.)_"))
        XCTAssertEqual(try SummaryResponse.chatCompletions(data(###"{"choices":[{"message":{"role":"assistant","content":"Notes"},"finish_reason":"stop"}]}"###)), "Notes")
        XCTAssertEqual(try SummaryResponse.anthropicMessages(data(###"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"## Decisions"}]}"###)), "## Decisions")
        XCTAssertThrowsError(try SummaryResponse.anthropicMessages(data(###"{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"},"content":[]}"###)))
        XCTAssertThrowsError(try SummaryResponse.chatCompletions(data("not json")))
        XCTAssertEqual(SummaryResponse.errorMessage(data(###"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"###)), "invalid x-api-key")
        XCTAssertEqual(SummaryResponse.modelIDs(data(###"{"data":[{"id":"b"},{"id":"a"}]}"###)), ["a", "b"])
    }

    func testActivityMeterIgnoresChimesAndCountsSpeech() {
        let meter = ActivityMeter(startedAt: 100)
        // A 0.4 s chime is not activity.
        meter.observe(.system, rms: 0.05, seconds: 0.4, at: 110)
        XCTAssertEqual(meter.lastActive, 100)
        // Two seconds of silence forgets the chime, so a second chime does not add to the first.
        for step in 0..<8 { meter.observe(.system, rms: 0.0005, seconds: 0.25, at: 111 + Double(step) * 0.25) }
        meter.observe(.system, rms: 0.05, seconds: 0.4, at: 120)
        XCTAssertEqual(meter.lastActive, 100)
        // Sustained sound, even in short chunks, counts, and tracks are independent of each other.
        for step in 0..<6 { meter.observe(.microphone, rms: 0.03, seconds: 0.25, at: 130 + Double(step) * 0.25) }
        XCTAssertEqual(meter.lastActive, 131.25)
        meter.reset(at: 500)
        XCTAssertEqual(meter.lastActive, 500)
    }

    func testQuietRecordingIsRemindedThenStopped() {
        var policy = StopReminderPolicy()
        let on = StopReminderPolicy.Settings()
        // The meeting ended at 15 minutes and nobody pressed stop.
        XCTAssertEqual(policy.evaluate(elapsed: 15 * 60 + 500, lastActive: 15 * 60, settings: on), .none)
        XCTAssertEqual(policy.evaluate(elapsed: 25 * 60, lastActive: 15 * 60, settings: on), .remindQuiet(quiet: 600))
        XCTAssertTrue(policy.reminderOutstanding)
        // Reminders are sent once, not repeated every tick.
        XCTAssertEqual(policy.evaluate(elapsed: 25 * 60 + 2, lastActive: 15 * 60, settings: on), .none)
        XCTAssertEqual(policy.evaluate(elapsed: 44 * 60, lastActive: 15 * 60, settings: on), .none)
        XCTAssertEqual(policy.evaluate(elapsed: 45 * 60, lastActive: 15 * 60, settings: on), .autoStop(quiet: 1800, lastActive: 900))
    }

    func testLiveAudioIsNeverStoppedAutomatically() {
        var policy = StopReminderPolicy()
        let on = StopReminderPolicy.Settings()
        // Audio keeps arriving for 9 hours: no quiet reminder, no auto-stop, only hourly nudges from 2 h.
        var actions: [StopReminderPolicy.Action] = []
        var elapsed = 0.0
        while elapsed < 9 * 3600 {
            elapsed += 2
            let action = policy.evaluate(elapsed: elapsed, lastActive: elapsed - 1, settings: on)
            if action != .none { actions.append(action) }
        }
        XCTAssertEqual(actions, (2...9).map { .longRunning(hours: $0) })
        // Sound returning withdraws an outstanding reminder, and the stop clock does not carry over.
        var resumed = StopReminderPolicy()
        XCTAssertEqual(resumed.evaluate(elapsed: 1200, lastActive: 0, settings: on), .remindQuiet(quiet: 1200))
        XCTAssertEqual(resumed.evaluate(elapsed: 1300, lastActive: 1290, settings: on), .none)
        XCTAssertFalse(resumed.reminderOutstanding)
        // Quiet again later: a fresh reminder, not an immediate stop from the earlier one.
        XCTAssertEqual(resumed.evaluate(elapsed: 1300 + 20 * 60, lastActive: 1290, settings: on), .remindQuiet(quiet: 1210))
    }

    func testKeepRecordingSnoozesAndSettingsAreHonoured() {
        var policy = StopReminderPolicy()
        let on = StopReminderPolicy.Settings()
        XCTAssertEqual(policy.evaluate(elapsed: 600, lastActive: 0, settings: on), .remindQuiet(quiet: 600))
        policy.keepRecording(at: 620)
        XCTAssertFalse(policy.reminderOutstanding)
        XCTAssertEqual(policy.evaluate(elapsed: 2000, lastActive: 0, settings: on), .none)
        XCTAssertEqual(policy.evaluate(elapsed: 2420, lastActive: 0, settings: on), .remindQuiet(quiet: 2420))
        // Reminders off: nothing, and auto-stop can never fire without a reminder first.
        var off = StopReminderPolicy()
        let none = StopReminderPolicy.Settings(remindWhenQuiet: false, autoStopWhenQuiet: true)
        XCTAssertEqual(off.evaluate(elapsed: 5000, lastActive: 0, settings: none), .none)
        XCTAssertEqual(off.evaluate(elapsed: 9000, lastActive: 0, settings: none), .none)
        // Reminders on, auto-stop off: remind, never stop.
        var remindOnly = StopReminderPolicy()
        let keepGoing = StopReminderPolicy.Settings(remindWhenQuiet: true, autoStopWhenQuiet: false)
        XCTAssertEqual(remindOnly.evaluate(elapsed: 700, lastActive: 0, settings: keepGoing), .remindQuiet(quiet: 700))
        XCTAssertEqual(remindOnly.evaluate(elapsed: 5000, lastActive: 0, settings: keepGoing), .none)
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

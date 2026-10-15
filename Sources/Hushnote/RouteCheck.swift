import Foundation
import AVFoundation
import CaptureRing
import HushnoteCore

/// Permission-free integration check: simulated device handoffs use the real bounded ring,
/// TrackSink resampler/checkpoint writer, recovery coordinator and AAC/Markdown exporter.
enum RouteCheck {
    @MainActor static func run(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var sinks: [CaptureTrack: TrackSink] = [:]
        var chunks: [AudioChunk] = []
        var warnings: [String] = []
        var rates: [CaptureTrack: Double] = [.system: 48_000, .microphone: 44_100]
        var clock: TimeInterval = 0
        var failMicrophoneOnce = false
        let close: (CaptureTrack) -> Void = { track in
            if let sink = sinks.removeValue(forKey: track) {
                let result = sink.stop(); chunks += result.chunks; warnings += result.warnings
            }
        }
        let open: (CaptureTrack) throws -> Void = { track in
            if track == .microphone && failMicrophoneOnce {
                failMicrophoneOnce = false
                throw CaptureFailure(message: "Simulated device is still connecting")
            }
            let offset = CaptureTimeline.nextOffset(elapsed: clock, chunks: chunks, source: track.rawValue)
            let sink = try TrackSink(source: track.rawValue, sampleRate: rates[track]!, offset: offset, directory: directory)
            sinks[track] = sink; sink.start()
        }
        let recovery = CaptureRouteRecovery(settleDelay: .milliseconds(2), retryDelays: [.milliseconds(3)],
                                            disconnect: close, reconnect: open)
        recovery.begin([.system, .microphone])
        defer { recovery.stop(); CaptureTrack.allCases.forEach(close) }
        try open(.system); clock = 0.1; try open(.microphone)
        try feed(sinks[.system]!, seconds: 1)
        try feed(sinks[.microphone]!, seconds: 1)
        let originalMic = sinks[.microphone]
        clock = 1.35; rates[.system] = 44_100
        for _ in 0..<100 { recovery.changed(.system) }
        guard sinks[.microphone] === originalMic else { throw CaptureFailure(message: "Output switch interrupted the microphone") }
        try await wait(for: recovery)
        try feed(sinks[.system]!, seconds: 1)
        try feed(sinks[.microphone]!, seconds: 1)
        let replacementSystem = sinks[.system]
        clock = 2.7; rates[.microphone] = 16_000; failMicrophoneOnce = true
        recovery.changed(.microphone)
        guard sinks[.system] === replacementSystem else { throw CaptureFailure(message: "Input switch interrupted system audio") }
        try await wait(for: recovery)
        try feed(sinks[.system]!, seconds: 1)
        try feed(sinks[.microphone]!, seconds: 1)
        recovery.stop(); CaptureTrack.allCases.forEach(close)
        guard warnings.isEmpty, chunks.count == 4 else { throw CaptureFailure(message: "Unexpected checkpoint loss during device handoff") }
        var meeting = Meeting(title: "Device handoff check", project: "Testing")
        meeting.chunks = chunks.sorted { $0.start < $1.start }
        for track in CaptureTrack.allCases {
            let items = chunks.filter { $0.source == track.rawValue }.sorted { $0.start < $1.start }
            guard abs(items.reduce(0) { $0 + $1.duration } - 3) < 0.06 else { throw CaptureFailure(message: "Resampling lost audio across a format change") }
            guard items[1].start >= items[0].start + items[0].duration else { throw CaptureFailure(message: "Reconnect reset the recording timeline") }
            for chunk in items {
                let file = try AVAudioFile(forReading: directory.appendingPathComponent(chunk.file))
                guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else {
                    throw CaptureFailure(message: "A switched device produced the wrong checkpoint format")
                }
            }
            let output = directory.appendingPathComponent(track.rawValue + "-handoff.m4a")
            try AudioArchive.encode(chunks: items, sourceDirectory: directory, to: output)
            let file = try AVAudioFile(forReading: output)
            let length = Double(file.length) / file.processingFormat.sampleRate
            guard abs(length - (items.last!.start + items.last!.duration)) < 0.2 else {
                throw CaptureFailure(message: "Export compressed away the device handoff gap")
            }
        }
        meeting.duration = chunks.map { $0.start + $0.duration }.max() ?? 0
        try MeetingFiles.save(meeting, to: directory.appendingPathComponent("session.json"))
        _ = try AudioArchive.export(meeting, from: directory, destination: directory, includeAudio: true)
    }

    @MainActor private static func wait(for recovery: CaptureRouteRecovery) async throws {
        for _ in 0..<200 {
            if recovery.pending.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CaptureFailure(message: "Device recovery did not finish")
    }

    private static func feed(_ sink: TrackSink, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sink.sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
        var frame = 0
        let count = Int(seconds * sink.sampleRate)
        while frame < count {
            let n = min(2048, count - frame); buffer.frameLength = AVAudioFrameCount(n)
            for i in 0..<n { buffer.floatChannelData![0][i] = Float(sin(Double(frame + i) * 440 * 2 * .pi / sink.sampleRate) * 0.1) }
            hn_ring_push(sink.ring, buffer.audioBufferList, buffer.frameLength)
            frame += n
        }
    }
}


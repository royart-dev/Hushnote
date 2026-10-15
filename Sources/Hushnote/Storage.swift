import Foundation
import AppKit
import AVFoundation
import HushnoteCore

struct AppLocations {
    let root: URL
    var sessions: URL { root.appendingPathComponent("Sessions", isDirectory: true) }
    var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hushnote", isDirectory: true)
    }
    func prepare() throws {
        for directory in [root, sessions, models] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
    func directory(_ id: UUID) -> URL { sessions.appendingPathComponent(id.uuidString, isDirectory: true) }
    func manifest(_ id: UUID) -> URL { directory(id).appendingPathComponent("session.json") }
}

enum AudioArchive {
    static func background<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility) { try operation() }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    static func encode(chunks: [AudioChunk], sourceDirectory: URL, to target: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let output = try AVAudioFile(forWriting: target, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        var timeline: Int64 = 0
        for chunk in chunks.sorted(by: { $0.start < $1.start }) {
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: MeetingFiles.validatedAudioURL(chunk, in: sourceDirectory), commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else {
                throw CaptureFailure(message: "A recording chunk has an unexpected format.")
            }
            let desiredStart = Int64(chunk.start * 16_000)
            while timeline < desiredStart {
                buffer.frameLength = AVAudioFrameCount(min(8192, desiredStart - timeline))
                memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
                try output.write(from: buffer); timeline += Int64(buffer.frameLength)
            }
            while file.framePosition < file.length {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length-file.framePosition)))
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer); timeline += Int64(buffer.frameLength)
            }
        }
    }

    static func export(_ meeting: Meeting, from directory: URL, destination: URL, includeAudio: Bool) throws -> URL {
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HHmm"
        let name = MeetingFiles.safeName("\(stamp.string(from: meeting.startedAt)) \(meeting.project.isEmpty ? "" : meeting.project + " - ")\(meeting.title)")
        var stem = name + " " + String(meeting.id.uuidString.prefix(6))
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.appendingPathComponent(stem + ".md").path) {
            counter += 1; stem = name + " " + String(meeting.id.uuidString.prefix(6)) + " (\(counter))"
        }
        var links: [(String, String)] = []
        if includeAudio {
            let audioFolder = destination.appendingPathComponent("Hushnote Audio/" + stem, isDirectory: true)
            try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
            for source in ["system", "microphone"] {
                let chunks = meeting.chunks.filter { $0.source == source }
                if chunks.isEmpty { continue }
                let file = audioFolder.appendingPathComponent(source + ".m4a")
                try encode(chunks: chunks, sourceDirectory: directory, to: file)
                links.append((source == "system" ? "Meeting audio" : "My microphone", "Hushnote Audio/\(stem)/\(source).m4a"))
            }
        }
        let note = destination.appendingPathComponent(stem + ".md")
        try Data(Markdown.render(meeting, audioLinks: links).utf8).write(to: note, options: .atomic)
        return note
    }

    static func importFile(_ url: URL, to directory: URL) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else {
            throw CaptureFailure(message: "This audio format could not be opened.")
        }
        var chunks: [AudioChunk] = []
        var chunkFile: AVAudioFile?
        var total: Int64 = 0, start: Int64 = 0
        var readError: Error?
        while true {
            try Task.checkCancellation()
            var error: NSError?
            output.frameLength = 0
            let status = converter.convert(to: output, error: &error) { count, state in
                guard file.framePosition < file.length else { state.pointee = .endOfStream; return nil }
                do {
                    let requested = AVAudioFrameCount(min(Int64(max(1, count)), Int64(input.frameCapacity), file.length-file.framePosition))
                    try file.read(into: input, frameCount: requested)
                    state.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                    return input.frameLength > 0 ? input : nil
                } catch { readError = error; state.pointee = .endOfStream; return nil }
            }
            if let error { throw error }; if let readError { throw readError }
            if output.frameLength > 0 {
                if chunkFile == nil {
                    start = total
                    chunkFile = try AVAudioFile(forWriting: directory.appendingPathComponent("import-\(chunks.count).caf"), settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
                    ], commonFormat: .pcmFormatFloat32, interleaved: false)
                }
                try chunkFile!.write(from: output); total += Int64(output.frameLength)
            }
            if total-start >= 480_000 || status == .endOfStream {
                if let chunkFile {
                    chunks.append(AudioChunk(file: chunkFile.url.lastPathComponent, source: "system", start: Double(start)/16_000, duration: Double(total-start)/16_000))
                }
                chunkFile = nil
            }
            if status == .endOfStream { break }
            if status == .error { throw CaptureFailure(message: "Audio conversion failed.") }
        }
        return chunks
    }
}

/// Session manifests on disk. Listing reads headers only; full meetings load when opened.
enum Library {
    static func scan(_ sessions: URL) throws -> [MeetingHeader] {
        let folders = try FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        var headers: [MeetingHeader] = []
        for folder in folders {
            let manifest = folder.appendingPathComponent("session.json")
            guard let header = try? MeetingFiles.readHeader(manifest) else { continue }
            if header.state == .recording || header.state == .processing, let recovered = try? recover(manifest) {
                headers.append(MeetingHeader(recovered))
            } else {
                headers.append(header)
            }
        }
        return headers.sorted { $0.startedAt > $1.startedAt }
    }

    /// Marks an unfinished session as interrupted and adopts any checkpoint the manifest missed.
    static func recover(_ manifest: URL) throws -> Meeting {
        var meeting = try MeetingFiles.read(manifest)
        guard meeting.state == .recording || meeting.state == .processing else { return meeting }
        let folder = manifest.deletingLastPathComponent()
        meeting.state = .interrupted
        meeting.warnings.append("The previous session was interrupted. Recovered saved checkpoints; choose Process to continue.")
        // Recover the last closed or partially written PCM checkpoint as well.
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "caf" && !meeting.chunks.contains(where: { $0.file == file.lastPathComponent }) {
            guard let audio = try? AVAudioFile(forReading: file), audio.length > 0 else { continue }
            let source = file.lastPathComponent.hasPrefix("microphone") ? "microphone" : "system"
            let offset = meeting.chunks.filter { $0.source == source }.map { $0.start + $0.duration }.max() ?? (source == "microphone" ? meeting.microphoneOffset : 0)
            meeting.chunks.append(AudioChunk(file: file.lastPathComponent, source: source, start: offset, duration: Double(audio.length)/audio.processingFormat.sampleRate))
        }
        meeting.duration = meeting.chunks.map { $0.start + $0.duration }.max() ?? meeting.duration
        try MeetingFiles.save(meeting, to: manifest)
        return meeting
    }

    static func size(of directory: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

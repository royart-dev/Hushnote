import Foundation
import AVFoundation
import CoreML
import FluidAudio
import HushnoteCore

struct WorkerFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct WorkerMain {
    static func main() async {
        // The app reads "n/total" progress lines from a pipe; flush each line as it is printed.
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let mode = args.first else { throw WorkerFailure(message: "Expected prepare, diarize, transcribe, or inspect.") }
            if mode == "runtime-info" {
                print("bundle=\(Bundle.main.bundleURL.path)")
                print("resources=\(Bundle.main.resourceURL?.path ?? "none")")
                return
            }
            if mode == "prepare", args.count == 2 {
                let root = URL(fileURLWithPath: args[1], isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                _ = try await AsrModels.download(to: root.appendingPathComponent(ModelLayout.speechFolder), version: .v2)
                _ = try await DiarizerModels.download(to: root.appendingPathComponent(ModelLayout.speakerFolder))
                print("Speech and speaker models installed.")
            } else if mode == "diarize", args.count == 3 {
                try await diarize(manifest: URL(fileURLWithPath: args[1]), root: URL(fileURLWithPath: args[2]))
            } else if mode == "transcribe", args.count == 3 {
                try await transcribe(manifest: URL(fileURLWithPath: args[1]), root: URL(fileURLWithPath: args[2]))
            } else if mode == "fixture", args.count == 3 || args.count == 4 {
                let audio = URL(fileURLWithPath: args[1])
                let directory = URL(fileURLWithPath: args[2], isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = try AVAudioFile(forReading: audio)
                var meeting = Meeting(title: "Speech pipeline validation", project: "Testing")
                meeting.duration = Double(file.length) / file.processingFormat.sampleRate
                guard meeting.duration <= 35 else { throw WorkerFailure(message: "Use a fixture under 35 seconds.") }
                let destination = directory.appendingPathComponent("fixture.wav")
                if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: audio, to: destination) }
                let source = args.count == 4 && args[3] == "microphone" ? "microphone" : "system"
                meeting.chunks = [AudioChunk(file: "fixture.wav", source: source, start: 0, duration: meeting.duration)]
                try MeetingFiles.save(meeting, to: directory.appendingPathComponent("session.json"))
            } else if mode == "inspect", args.count == 2 {
                let meeting = try MeetingFiles.read(URL(fileURLWithPath: args[1]))
                print("\(meeting.title): \(meeting.chunks.count) audio chunks; \(meeting.transcript.count) transcript passages; \(meeting.speakers.count) speakers")
            } else { throw WorkerFailure(message: "Invalid worker arguments.") }
        } catch {
            FileHandle.standardError.write(Data("Hushnote: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func samples(_ chunk: AudioChunk, directory: URL) throws -> [Float] {
        guard chunk.duration <= 35 else { throw WorkerFailure(message: "Audio checkpoint is too long. Import the audio again to split it safely.") }
        return try AudioConverter().resampleAudioFile(MeetingFiles.validatedAudioURL(chunk, in: directory))
    }

    static func diarize(manifest: URL, root: URL) async throws {
        var meeting = try MeetingFiles.read(manifest)
        if meeting.diarizationDone { return }
        meeting.state = .processing; try MeetingFiles.save(meeting, to: manifest)
        let directory = manifest.deletingLastPathComponent()
        let modelDirectory = root.appendingPathComponent(ModelLayout.speakerFolder)
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
        do {
            // This overload loads only local files. It cannot initiate downloads.
            let models = try DiarizerModels.load(
                localSegmentationModel: modelDirectory.appendingPathComponent("pyannote_segmentation.mlmodelc"),
                localEmbeddingModel: modelDirectory.appendingPathComponent("wespeaker_v2.mlmodelc"), configuration: config)
            let diarizer = DiarizerManager()
            diarizer.initialize(models: models)
            var turns: [SpeakerTurn] = []
            var labels: [String: String] = [:]
            let systemChunks = meeting.chunks.filter({ $0.source == "system" }).sorted(by: { $0.start < $1.start })
            for (index, chunk) in systemChunks.enumerated() {
                print("Diarized \(index)/\(systemChunks.count) checkpoints")
                try autoreleasepool {
                    let audio = try samples(chunk, directory: directory)
                    if audio.count < 4800 { return }
                    let result = try diarizer.performCompleteDiarization(audio, atTime: chunk.start)
                    for segment in result.segments {
                        let id = segment.speakerId
                        if labels[id] == nil { labels[id] = "Speaker \(labels.count + 1)" }
                        turns.append(SpeakerTurn(start: Double(segment.startTimeSeconds), end: Double(segment.endTimeSeconds), speaker: labels[id]!))
                    }
                }
            }
            meeting.turns = turns
        } catch {
            meeting.warnings.append("Speaker separation was unavailable: \(error.localizedDescription). System speech remains labeled Meeting audio; microphone speech is labeled You.")
        }
        meeting.diarizationDone = true
        try MeetingFiles.save(meeting, to: manifest)
        // The worker exits here before the ASR process starts, releasing all models.
    }

    static func transcribe(manifest: URL, root: URL) async throws {
        var meeting = try MeetingFiles.read(manifest)
        if !meeting.chunks.isEmpty && meeting.chunks.allSatisfy({ meeting.completedChunks.contains($0.file) }) {
            meeting.state = .complete
            try MeetingFiles.save(meeting, to: manifest)
            print("All transcription checkpoints are already complete.")
            return
        }
        meeting.state = .processing; try MeetingFiles.save(meeting, to: manifest)
        let directory = manifest.deletingLastPathComponent()
        let models = try AsrModels.loadLocal(from: root.appendingPathComponent(ModelLayout.speechFolder), version: .v2)
        let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1))
        try await manager.loadModels(models)
        for chunk in meeting.chunks.sorted(by: { $0.start < $1.start }) {
            if meeting.completedChunks.contains(chunk.file) { continue }
            let audio = try autoreleasepool { try samples(chunk, directory: directory) }
            if audio.count < 4800 || rms(audio) < 0.00015 {
                meeting.completedChunks.append(chunk.file); try MeetingFiles.save(meeting, to: manifest); continue
            }
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(audio, decoderState: &decoderState)
            if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let words = buildWordTimings(from: result.tokenTimings ?? [])
                if words.isEmpty {
                    meeting.transcript.append(TranscriptSegment(start: chunk.start, end: chunk.start + chunk.duration,
                                                                speaker: chunk.source == "microphone" ? "You" : "Meeting audio", text: result.text))
                } else {
                    var group: TranscriptSegment?
                    for word in words {
                        let start = chunk.start + word.startTime, end = chunk.start + word.endTime
                        let speaker = chunk.source == "microphone" ? "You" : SpeakerAlignment.speaker(start: start, end: max(start + 0.02, end), turns: meeting.turns)
                        if var current = group, current.speaker == speaker, start-current.start < 18 {
                            current.text += " " + word.word; current.end = end; group = current
                        } else {
                            if let group { meeting.transcript.append(group) }
                            group = TranscriptSegment(start: start, end: end, speaker: speaker, text: word.word)
                        }
                    }
                    if let group { meeting.transcript.append(group) }
                }
            }
            meeting.completedChunks.append(chunk.file)
            try MeetingFiles.save(meeting, to: manifest)
            print("Transcribed \(meeting.completedChunks.count)/\(meeting.chunks.count) checkpoints")
        }
        await manager.cleanup()
        meeting.transcript.sort { $0.start < $1.start }
        if meeting.summary.isEmpty {
            meeting.summary = LocalHighlights.make(meeting)
            meeting.summaryMethod = "Selected transcript excerpts (no generative model)"
        }
        meeting.state = .complete; try MeetingFiles.save(meeting, to: manifest)
        print("Transcript saved.")
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
}

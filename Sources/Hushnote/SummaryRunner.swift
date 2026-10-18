import Foundation
import CryptoKit
import HushnoteCore

@MainActor
enum SummaryRunner {
    static let modelName = "qwen2.5-1.5b-instruct-q4_k_m.gguf"

    static func install(in directory: URL) async throws {
        let url = URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/\(modelName)")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CaptureFailure(message: "The summary model download did not complete.")
        }
        let expected = "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e"
        let checksum = try await Task.detached(priority: .utility) {
            let file = try FileHandle(forReadingFrom: temporary); defer { try? file.close() }
            var hash = SHA256()
            while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        try Task.checkCancellation()
        guard checksum == expected else { throw CaptureFailure(message: "The model checksum did not match. The downloaded file was not installed.") }
        let destination = directory.appendingPathComponent(modelName)
        if FileManager.default.fileExists(atPath: destination.path) { return }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Summarises with any provider: sections sized to its context, then a combining pass if needed.
    static func make(_ meeting: Meeting, provider: SummaryProvider,
                     progress: ((Int, Int) -> Void)? = nil) async throws -> String {
        var parts = split(meeting.plainTranscript, limit: provider.partLimit)
        guard !parts.isEmpty else { return "No speech was transcribed." }
        var depth = 0
        repeat {
            depth += 1
            var notes: [String] = []
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                if depth == 1 { progress?(index, parts.count) }
                notes.append(try await provider.generate(part, combine: depth > 1))
            }
            if notes.count == 1 { return notes[0] }
            parts = split(notes.joined(separator: "\n\n"), limit: provider.partLimit)
            if depth >= 6 { return notes.joined(separator: "\n\n") }
        } while true
    }

    private static func split(_ text: String, limit: Int) -> [String] {
        var parts: [String] = [], current = ""
        for line in text.components(separatedBy: .newlines) {
            if !current.isEmpty && current.utf8.count + line.utf8.count > limit {
                parts.append(current); current = ""
            }
            var remainder = line
            while remainder.utf8.count > limit {
                let prefix = String(remainder.prefix(limit / 4))
                if !current.isEmpty { parts.append(current); current = "" }
                parts.append(prefix); remainder.removeFirst(prefix.count)
            }
            current += remainder + "\n"
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(current) }
        return parts
    }
}

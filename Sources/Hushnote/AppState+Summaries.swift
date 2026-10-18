import Foundation
import AppKit
import UniformTypeIdentifiers
import HushnoteCore

struct EngineTestResult: Equatable {
    let engine: SummaryEngine
    let ok: Bool
    let text: String
}

/// Choosing and running the summary engine.
extension AppState {
    private static let settingsKey = "summarySettings", keysKey = "summaryKeysSaved"

    func loadSummarySettings() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.settingsKey), let saved = try? JSONDecoder().decode(SummarySettings.self, from: data) {
            summarySettings = saved
        }
        savedKeys = Set((defaults.stringArray(forKey: Self.keysKey) ?? []).compactMap(SummaryEngine.init(rawValue:)))
    }

    func saveSummarySettings() {
        guard !isPreview else { return }
        if let data = try? JSONEncoder().encode(summarySettings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
    }

    private static func keychainAccount(_ engine: SummaryEngine) -> String { engine.rawValue }

    func saveAPIKey(_ key: String, for engine: SummaryEngine) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try Keychain.save(trimmed, account: Self.keychainAccount(engine))
            savedKeys.insert(engine)
            UserDefaults.standard.set(savedKeys.map(\.rawValue), forKey: Self.keysKey)
            engineTest = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func removeAPIKey(for engine: SummaryEngine) {
        Keychain.delete(account: Self.keychainAccount(engine))
        savedKeys.remove(engine); engineModels[engine] = nil; engineTest = nil
        UserDefaults.standard.set(savedKeys.map(\.rawValue), forKey: Self.keysKey)
    }

    func setConsent(_ allowed: Bool, for engine: SummaryEngine) {
        var consented = Set(summarySettings.consented)
        if allowed { consented.insert(engine) } else { consented.remove(engine) }
        summarySettings.consented = SummaryEngine.allCases.filter(consented.contains)
    }

    /// Whether processing can attempt a summary without obvious missing setup.
    var summaryEngineReady: Bool {
        let s = summarySettings
        switch s.engine {
        case .bundled: return hasSummaryModel
        case .localModel: return FileManager.default.fileExists(atPath: s.modelPath)
        case .localServer: return !s.serverModel.isEmpty && URL(string: s.serverURL) != nil
        case .chatGPT: return chatGPTSignIn == .chatGPT || (chatGPTSignIn == nil && Codex.find() != nil)
        case .openAI: return savedKeys.contains(.openAI) && !s.openAIModel.isEmpty
        case .anthropic: return savedKeys.contains(.anthropic) && !s.anthropicModel.isEmpty
        }
    }

    /// Builds the selected engine, or explains in one sentence what's missing.
    func makeSummaryProvider(directory: URL) async throws -> SummaryProvider {
        let s = summarySettings
        if s.needsConsent {
            throw SummaryFailure("Allow Hushnote to send transcripts to \(s.engine.recipient) in Settings → Summaries.")
        }
        switch s.engine {
        case .bundled:
            guard hasSummaryModel else { throw SummaryFailure("Download the bundled summary model in Settings.") }
            return LlamaProvider(model: locations.models.appendingPathComponent(SummaryRunner.modelName), directory: directory,
                                 useModelTemplate: false, method: "Local Qwen 2.5 1.5B")
        case .localModel:
            let file = URL(fileURLWithPath: s.modelPath)
            guard file.pathExtension.lowercased() == "gguf", FileManager.default.fileExists(atPath: file.path) else {
                throw SummaryFailure("Choose a .gguf model file in Settings → Summaries.")
            }
            return LlamaProvider(model: file, directory: directory, useModelTemplate: true, method: "Local model \(file.deletingPathExtension().lastPathComponent)")
        case .localServer:
            guard let base = URL(string: s.serverURL), base.scheme == "http" || base.scheme == "https" else { throw SummaryFailure("Enter the model server's address, for example http://127.0.0.1:11434/v1.") }
            guard !s.serverModel.isEmpty else { throw SummaryFailure("Choose which model the server should use.") }
            return HTTPSummaryProvider(kind: .localServer, base: base, model: s.serverModel, key: nil, method: "\(s.serverModel) on \(base.host ?? "the model server")")
        case .chatGPT:
            guard let codex = Codex.find() else { throw SummaryFailure("Install the ChatGPT app or OpenAI's Codex CLI, then sign in with ChatGPT in Settings.") }
            let status = await Codex.status(codex); chatGPTSignIn = status
            switch status {
            case .chatGPT: return CodexProvider(executable: codex)
            case .apiKey: throw SummaryFailure("Codex is signed in with an API key, not ChatGPT. Sign in with ChatGPT in Settings so your plan is used.")
            default: throw SummaryFailure("Sign in with ChatGPT in Settings → Summaries.")
            }
        case .openAI, .anthropic:
            let model = s.engine == .openAI ? s.openAIModel : s.anthropicModel
            guard !model.isEmpty else { throw SummaryFailure("Choose a model in Settings → Summaries.") }
            guard let key = Keychain.load(account: Self.keychainAccount(s.engine)) else {
                throw SummaryFailure("Add your \(s.engine == .openAI ? "OpenAI" : "Anthropic") API key in Settings → Summaries.")
            }
            return s.engine == .openAI
                ? HTTPSummaryProvider(kind: .openAI, base: URL(string: "https://api.openai.com/v1")!, model: model, key: key, method: "OpenAI \(model) (API)")
                : HTTPSummaryProvider(kind: .anthropic, base: URL(string: "https://api.anthropic.com")!, model: model, key: key, method: "Claude \(model) (API)")
        }
    }

    func chooseModelFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.prompt = "Use this model"
        panel.message = "Choose a GGUF language model. It runs on this Mac with the bundled llama.cpp."
        if panel.runModal() == .OK, let url = panel.url { summarySettings.modelPath = url.path; engineTest = nil }
    }

    func refreshChatGPT() async {
        guard let codex = Codex.find() else { chatGPTSignIn = .notInstalled; return }
        chatGPTSignIn = await Codex.status(codex)
    }

    /// Runs OpenAI's own sign-in: Codex opens the ChatGPT authorization page in the browser and waits
    /// for it to finish. If the page doesn't open, its link is offered in Settings.
    func signInWithChatGPT() {
        guard !chatGPTSigningIn else { return }
        guard let codex = Codex.find() else { chatGPTSignIn = .notInstalled; return }
        chatGPTSigningIn = true; chatGPTSignInURL = nil
        let process = Process(); process.executableURL = codex; process.arguments = ["login"]
        process.environment = Codex.subscriptionEnvironment()
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        let lines = LineReader { line in
            guard let match = line.firstMatch(of: #/https://auth\.openai\.com/\S+/#) else { return }
            let link = URL(string: String(match.0))
            Task { @MainActor [weak self] in if self?.chatGPTSignInURL == nil { self?.chatGPTSignInURL = link } }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { lines.consume(data) }
        }
        Task {
            _ = try? await LlamaProvider.wait(for: process, timeout: 600)
            pipe.fileHandleForReading.readabilityHandler = nil
            chatGPTSigningIn = false; chatGPTSignInURL = nil
            await refreshChatGPT()
        }
    }

    func cancelChatGPTSignIn() { if chatGPTSigningIn { LlamaProvider.active?.terminate() } }

    func loadEngineModels() {
        let s = summarySettings
        Task {
            do {
                switch s.engine {
                case .localServer:
                    guard let base = URL(string: s.serverURL) else { throw SummaryFailure("Enter the server address first.") }
                    engineModels[.localServer] = try await HTTPSummaryProvider.models(kind: .localServer, base: base, key: nil)
                case .openAI, .anthropic:
                    guard let key = Keychain.load(account: Self.keychainAccount(s.engine)) else { throw SummaryFailure("Save an API key first.") }
                    let kind: HTTPSummaryProvider.Kind = s.engine == .openAI ? .openAI : .anthropic
                    let base = URL(string: s.engine == .openAI ? "https://api.openai.com/v1" : "https://api.anthropic.com")!
                    engineModels[s.engine] = try await HTTPSummaryProvider.models(kind: kind, base: base, key: key)
                default: return
                }
            } catch { engineTest = EngineTestResult(engine: s.engine, ok: false, text: error.localizedDescription) }
        }
    }

    /// Summarises a short, made-up exchange so the engine can be checked before a real meeting.
    func testSummaryEngine() {
        guard !engineTesting else { return }
        let engine = summarySettings.engine
        engineTesting = true; engineTest = nil
        var sample = Meeting(title: "Engine check")
        sample.transcript = [
            TranscriptSegment(start: 12, end: 20, speaker: "Speaker 1", text: "Let's ship the beta on the third of November."),
            TranscriptSegment(start: 21, end: 30, speaker: "Speaker 2", text: "Agreed. Billing waits until January, and I'll send the vendor quote by Friday."),
        ]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hushnote-engine-check-\(UUID().uuidString)")
        Task {
            defer { engineTesting = false; try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let provider = try await makeSummaryProvider(directory: folder)
                let started = Date()
                let text = try await SummaryRunner.make(sample, provider: provider)
                // One readable line: drop Markdown markers and line breaks.
                let plain = text.replacingOccurrences(of: #"[#*_`>-]+\s*"#, with: "", options: .regularExpression)
                    .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
                engineTest = EngineTestResult(engine: engine, ok: true, text: "Worked in \(Int(Date().timeIntervalSince(started).rounded())) s. \(plain.prefix(220))")
            } catch {
                engineTest = EngineTestResult(engine: engine, ok: false, text: error.localizedDescription)
            }
        }
    }
}

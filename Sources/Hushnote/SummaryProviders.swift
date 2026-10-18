import Foundation
import Security
import HushnoteCore

/// One way of turning a section of transcript into notes. `SummaryRunner` splits long transcripts into
/// `partLimit`-sized sections and combines the results, so small local models and large cloud ones share one path.
@MainActor
protocol SummaryProvider {
    /// Shown under the notes and saved with the meeting.
    var method: String { get }
    var partLimit: Int { get }
    func generate(_ source: String, combine: Bool) async throws -> String
}

/// Local GGUF models through the bundled llama.cpp. The bundled Qwen keeps its verified raw prompt;
/// a model you choose is prompted through its own chat template, so it doesn't have to be Qwen-shaped.
@MainActor
final class LlamaProvider: SummaryProvider {
    let model: URL, directory: URL, useModelTemplate: Bool, method: String
    // ~3.9 bytes per token on timestamped transcripts, so 9 KB is ~2.4k tokens: with the prompt and
    // 650 generated tokens it stays inside the 4096 context.
    let partLimit = 9_000
    static var active: Process?

    init(model: URL, directory: URL, useModelTemplate: Bool, method: String) {
        self.model = model; self.directory = directory; self.useModelTemplate = useModelTemplate; self.method = method
    }

    func generate(_ source: String, combine: Bool) async throws -> String {
        // Metal keeps the weights file-backed and is ~7x faster than the CPU path, which repacks
        // them into ~1.1 GB of anonymous memory. Fall back to CPU only if the GPU run fails.
        do { return try await run(source, combine: combine, gpu: true) }
        catch is CancellationError { throw CancellationError() }
        catch { return try await run(source, combine: combine, gpu: false) }
    }

    private func run(_ source: String, combine: Bool, gpu: Bool) async throws -> String {
        let runtime = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama/llama-completion")
        guard FileManager.default.isExecutableFile(atPath: runtime.path) else {
            throw SummaryFailure("The local summary runtime is missing from this app bundle.")
        }
        guard FileManager.default.fileExists(atPath: model.path) else { throw SummaryFailure("The model file \(model.lastPathComponent) can't be found.") }
        let prompt = directory.appendingPathComponent("summary-prompt.txt")
        let system = directory.appendingPathComponent("summary-system.txt")
        let result = directory.appendingPathComponent("summary-output.txt")
        let log = directory.appendingPathComponent("summary-log.txt")
        let instructions = SummaryPrompt.instructions(combine: combine)
        var arguments = ["--model", model.path, "--ctx-size", "4096", "--threads", "4",
                         "--batch-size", gpu ? "512" : "64", "--ubatch-size", gpu ? "256" : "64", "--n-predict", "650",
                         "--temp", "0", "--n-gpu-layers", gpu ? "99" : "0", "--no-display-prompt",
                         "--simple-io", "--no-warmup", "--repeat-penalty", "1.1"]
        if useModelTemplate {
            try Data(instructions.utf8).write(to: system, options: .atomic)
            try Data(SummaryPrompt.source(source).utf8).write(to: prompt, options: .atomic)
            arguments += ["-cnv", "-st", "--jinja", "-sysf", system.path, "--file", prompt.path]
        } else {
            let raw = "<|im_start|>system\n\(instructions)<|im_end|>\n<|im_start|>user\n\(SummaryPrompt.source(source))<|im_end|>\n<|im_start|>assistant\n"
            try Data(raw.utf8).write(to: prompt, options: .atomic)
            arguments += ["--no-conversation", "--no-escape", "--file", prompt.path]
        }
        FileManager.default.createFile(atPath: result.path, contents: nil)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: result), stderr = try FileHandle(forWritingTo: log)
        defer {
            try? stdout.close(); try? stderr.close()
            try? FileManager.default.removeItem(at: prompt); try? FileManager.default.removeItem(at: system)
        }
        let process = Process(); process.executableURL = runtime; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = stdout; process.standardError = stderr
        process.qualityOfService = .utility
        let status = try await Self.wait(for: process, timeout: 240)
        guard status == 0 else { throw SummaryFailure("The local summary process exited with status \(status).") }
        let output = SummaryPrompt.clean(try String(contentsOf: result, encoding: .utf8))
        guard !output.isEmpty else { throw SummaryFailure("The local model produced no summary.") }
        return output
    }

    static func wait(for process: Process, timeout: Double) async throws -> Int32 {
        active = process
        let timer = Task { try? await Task.sleep(for: .seconds(timeout)); if !Task.isCancelled && process.isRunning { process.terminate() } }
        defer { timer.cancel(); if active === process { active = nil } }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
            do { try process.run() } catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
        }
        try Task.checkCancellation()
        return status
    }
}

/// HTTP engines: a model server on this Mac (OpenAI-compatible chat completions), the OpenAI
/// Responses API, and the Anthropic Messages API. No SDKs; each response shape is parsed in HushnoteCore.
@MainActor
final class HTTPSummaryProvider: SummaryProvider {
    enum Kind { case localServer, openAI, anthropic }
    let kind: Kind, base: URL, model: String, key: String?, method: String
    var partLimit: Int { kind == .localServer ? 9_000 : 300_000 }   // Unknown local context vs. very large cloud context.

    init(kind: Kind, base: URL, model: String, key: String?, method: String) {
        self.kind = kind; self.base = base; self.model = model; self.key = key; self.method = method
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 240; config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    func generate(_ source: String, combine: Bool) async throws -> String {
        let instructions = SummaryPrompt.instructions(combine: combine), user = SummaryPrompt.source(source)
        var request: URLRequest
        let body: [String: Any]
        switch kind {
        case .localServer:
            request = URLRequest(url: base.appendingPathComponent("chat/completions"))
            body = ["model": model, "stream": false, "temperature": 0,
                    "messages": [["role": "system", "content": instructions], ["role": "user", "content": user]]]
            if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .openAI:
            request = URLRequest(url: base.appendingPathComponent("responses"))
            body = ["model": model, "instructions": instructions, "input": user, "store": false]
            request.setValue("Bearer \(key ?? "")", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request = URLRequest(url: base.appendingPathComponent("v1/messages"))
            var payload: [String: Any] = ["model": model, "max_tokens": 16_000, "system": instructions,
                                          "messages": [["role": "user", "content": user]]]
            // Current Claude models can decline a request on safety grounds; the server-side fallback
            // retries such a refusal on another model instead of failing the summary.
            if Self.supportsDefaultFallback(model) {
                payload["fallbacks"] = "default"
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            }
            body = payload
            request.setValue(key ?? "", forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await Self.session.data(for: request)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SummaryFailure(Self.describe(status: status, data: data, kind: kind)) }
        let text: String
        switch kind {
        case .localServer: text = try SummaryResponse.chatCompletions(data)
        case .openAI: text = try SummaryResponse.openAIResponses(data)
        case .anthropic: text = try SummaryResponse.anthropicMessages(data)
        }
        let cleaned = SummaryPrompt.clean(text)
        guard !cleaned.isEmpty else { throw SummaryFailure("The model returned an empty summary.") }
        return cleaned
    }

    static func supportsDefaultFallback(_ model: String) -> Bool {
        ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-1"].contains(model)
    }

    static func describe(status: Int, data: Data, kind: Kind) -> String {
        let detail = SummaryResponse.errorMessage(data).map { " \($0)" } ?? ""
        let who = kind == .anthropic ? "Anthropic" : kind == .openAI ? "OpenAI" : "The model server"
        switch status {
        case 401, 403: return "\(who) rejected the API key.\(detail)"
        case 404: return "\(who) doesn't know that model.\(detail)"
        case 429: return "\(who) rate limit or quota reached.\(detail)"
        default: return "\(who) returned HTTP \(status).\(detail)"
        }
    }

    /// Lists the models a key or server offers, so nobody has to guess model names.
    static func models(kind: Kind, base: URL, key: String?) async throws -> [String] {
        var request = URLRequest(url: kind == .anthropic ? base.appendingPathComponent("v1/models") : base.appendingPathComponent("models"))
        switch kind {
        case .anthropic: request.setValue(key ?? "", forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI: request.setValue("Bearer \(key ?? "")", forHTTPHeaderField: "Authorization")
        case .localServer: if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SummaryFailure(describe(status: status, data: data, kind: kind)) }
        return SummaryResponse.modelIDs(data)
    }
}

/// Your ChatGPT plan, through OpenAI's own Codex CLI and its ChatGPT sign-in. Hushnote never sees a token.
/// The CLI runs locked down (no shell, tools, browser, plugins or web search) so it can only answer,
/// and API-key variables are removed so it can never silently bill an API account instead.
@MainActor
final class CodexProvider: SummaryProvider {
    let executable: URL
    let partLimit = 300_000
    let method = "ChatGPT subscription via Codex"
    init(executable: URL) { self.executable = executable }

    static let lockdown = ["--ignore-user-config", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
                           "--disable", "shell_tool", "--disable", "apps", "--disable", "plugins", "--disable", "remote_plugin",
                           "--disable", "multi_agent", "--disable", "browser_use", "--disable", "computer_use", "--disable", "hooks",
                           "-c", "web_search=\"disabled\"", "-c", "approval_policy=\"never\""]

    func generate(_ source: String, combine: Bool) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hushnote-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("summary.md"), log = folder.appendingPathComponent("log.txt")
        let prompt = SummaryPrompt.instructions(combine: combine) + "\nAnswer with the notes only. Do not run commands or use tools.\n\n" + SummaryPrompt.source(source)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log); defer { try? logHandle.close() }
        let input = Pipe()
        let process = Process(); process.executableURL = executable
        process.arguments = ["exec"] + Self.lockdown + ["-o", output.path, "-"]
        process.currentDirectoryURL = folder
        process.environment = Codex.subscriptionEnvironment()
        process.standardInput = input; process.standardOutput = logHandle; process.standardError = logHandle
        process.qualityOfService = .utility
        // The prompt goes in on stdin, written off the main thread: a long transcript fills the pipe
        // buffer and the write waits until Codex reads it.
        DispatchQueue.global(qos: .utility).async {
            input.fileHandleForWriting.write(Data(prompt.utf8)); try? input.fileHandleForWriting.close()
        }
        let status = try await LlamaProvider.wait(for: process, timeout: 300)
        let text = (try? String(contentsOf: output, encoding: .utf8)).map(SummaryPrompt.clean) ?? ""
        guard status == 0, !text.isEmpty else {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if detail.range(of: #"usage limit|rate.limit|quota"#, options: [.regularExpression, .caseInsensitive]) != nil {
                throw SummaryFailure("Your ChatGPT usage limit was reached. No API key was used instead.")
            }
            if detail.range(of: #"login|auth|401"#, options: [.regularExpression, .caseInsensitive]) != nil {
                throw SummaryFailure("Your ChatGPT sign-in has expired. Sign in again in Settings.")
            }
            throw SummaryFailure("ChatGPT could not write the summary (status \(status)).")
        }
        return text
    }
}

/// Locating and talking to OpenAI's Codex CLI. The ChatGPT desktop app ships one.
enum Codex {
    static func find() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let candidates = path.map { "\($0)/codex" } + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
                                                     "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// Removes API keys and tokens so the CLI can only use its own ChatGPT sign-in.
    static func subscriptionEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            key.range(of: #"API_KEY|ACCESS_TOKEN|AUTH_TOKEN|_TOKEN$|OAUTH"#, options: .regularExpression) == nil
                && !["OPENAI_BASE_URL", "ANTHROPIC_BASE_URL"].contains(key)
        }
    }

    enum SignIn: Equatable { case notInstalled, signedOut, apiKey, chatGPT }

    static func status(_ executable: URL) async -> SignIn {
        let process = Process(); process.executableURL = executable; process.arguments = ["login", "status"]
        process.environment = subscriptionEnvironment()
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        guard (try? process.run()) != nil else { return .notInstalled }
        let data = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if text.range(of: "Logged in using ChatGPT", options: .caseInsensitive) != nil { return .chatGPT }
        if text.range(of: "API key", options: .caseInsensitive) != nil { return .apiKey }
        return .signedOut
    }
}

/// API keys live in the macOS Keychain, never in preferences, logs or meeting files.
enum Keychain {
    private static let service = "app.hushnote.local.summaries"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func save(_ secret: String, account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw SummaryFailure("The key couldn't be saved to the Keychain (\(status)).") }
    }
    static func load(account: String) -> String? {
        var item = query(account)
        item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(account: String) { SecItemDelete(query(account) as CFDictionary) }
}

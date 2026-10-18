import Foundation
import AppKit
import AVFoundation
import Observation
import HushnoteCore

enum Route: Hashable {
    case capture, settings
    case meeting(UUID)
}

/// Observation tracks reads per property, so the sidebar doesn't redraw while notes are typed,
/// and nothing republishes on a timer while recording.
@MainActor
@Observable
final class AppState {
    // Library: lightweight headers for the list, one fully loaded meeting at a time.
    var log: [MeetingHeader] = []
    var route: Route = .capture { didSet { if route != oldValue { routeChanged() } } }
    private(set) var current: Meeting?

    // Next recording
    var title = ""
    var project = ""
    var includeMicrophone = true { didSet { UserDefaults.standard.set(includeMicrophone, forKey: "microphone") } }
    var includeAudioInExport = true { didSet { UserDefaults.standard.set(includeAudioInExport, forKey: "includeAudio") } }
    var autoProcess = true { didSet { UserDefaults.standard.set(autoProcess, forKey: "autoProcess") } }
    var remindWhenQuiet = true { didSet { UserDefaults.standard.set(remindWhenQuiet, forKey: "remindWhenQuiet") } }
    var autoStopWhenQuiet = true { didSet { UserDefaults.standard.set(autoStopWhenQuiet, forKey: "autoStopWhenQuiet") } }
    /// Minutes of silence while a "still recording?" reminder is outstanding.
    private(set) var quietMinutes: Int?

    // Status
    var isRecording = false
    private(set) var isStarting = false
    private(set) var recordingStartedAt: Date?
    private(set) var recordingTitle: String?
    var isWorking = false
    private(set) var busyID: UUID?
    var progress = ""
    var progressFraction: Double?
    var errorMessage: String?
    var destination: URL?
    var driveLink = ""
    var lastExport: URL?
    private(set) var hasSpeechModels = false
    private(set) var hasSummaryModel = false
    // Summary engine. API keys are in the Keychain; only "a key is saved" flags live in preferences.
    var summarySettings = SummarySettings() { didSet { saveSummarySettings() } }
    var savedKeys: Set<SummaryEngine> = []
    var chatGPTSignIn: Codex.SignIn?
    var chatGPTSigningIn = false
    var chatGPTSignInURL: URL?
    var engineModels: [SummaryEngine: [String]] = [:]
    var engineTest: EngineTestResult?
    var engineTesting = false
    private(set) var storageBytes: Int64?

    let locations = AppLocations()
    @ObservationIgnored var onStatusChange: (() -> Void)?
    @ObservationIgnored private let writer = ManifestWriter()
    @ObservationIgnored private var capture: AudioCapture?
    @ObservationIgnored private var active: Meeting?
    @ObservationIgnored private var healthTimer: Timer?
    @ObservationIgnored private var healthTicks = 0
    @ObservationIgnored private var reminder = StopReminderPolicy()
    @ObservationIgnored private let notifier = RecordingNotifier()
    @ObservationIgnored private var worker: Process?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var libraryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    @ObservationIgnored private var previewStore: [UUID: Meeting]?

    init() {
        do { try locations.prepare() } catch { errorMessage = error.localizedDescription }
        let defaults = UserDefaults.standard
        driveLink = defaults.string(forKey: "driveLink") ?? ""
        if let path = defaults.string(forKey: "destination") { destination = URL(fileURLWithPath: path, isDirectory: true) }
        includeMicrophone = defaults.object(forKey: "microphone") as? Bool ?? true
        includeAudioInExport = defaults.object(forKey: "includeAudio") as? Bool ?? true
        autoProcess = defaults.object(forKey: "autoProcess") as? Bool ?? true
        remindWhenQuiet = defaults.object(forKey: "remindWhenQuiet") as? Bool ?? true
        autoStopWhenQuiet = defaults.object(forKey: "autoStopWhenQuiet") as? Bool ?? true
        notifier.onStop = { [weak self] in self?.stopRecording() }
        notifier.onKeep = { [weak self] in self?.keepRecording() }
        refreshModels()
        loadSummarySettings()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.stopRecording(warning: "The Mac went to sleep. This session ended; saved audio is recoverable.", process: false)
            }
        }
        let sessions = locations.sessions
        libraryTask = Task {
            do { log = try await Task.detached(priority: .userInitiated) { try Library.scan(sessions) }.value }
            catch { errorMessage = error.localizedDescription }
        }
    }

    #if DEBUG
    init(preview meetings: [Meeting]) {
        previewStore = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
        log = meetings.map(MeetingHeader.init)
        hasSpeechModels = true
        storageBytes = 1_284_000_000
    }
    func previewRecording(_ start: Date, title: String) { isRecording = true; recordingStartedAt = start; recordingTitle = title }
    func previewWorking(_ id: UUID, _ message: String, _ fraction: Double?) { isWorking = true; busyID = id; progress = message; progressFraction = fraction }
    #endif

    // MARK: Library

    var isPreview: Bool { previewStore != nil }

    func isLocked(_ id: UUID) -> Bool { (isWorking && busyID == id) || active?.id == id }

    private func routeChanged() {
        flushSave()
        guard case .meeting(let id) = route else { current = nil; return }
        if current?.id == id { return }
        if let active, active.id == id { current = active; return }
        current = loadMeeting(id)
        if current == nil { errorMessage = "This meeting's files could not be read." }
    }

    private func loadMeeting(_ id: UUID) -> Meeting? {
        if let previewStore { return previewStore[id] }
        // Through the writer: a save queued when this meeting was left must land before it is read back.
        guard var meeting = try? writer.read(locations.manifest(id)) else { return nil }
        meeting.transcript.sort { $0.start < $1.start }
        return meeting
    }

    /// Applies a fresh copy of a meeting to the list and, if open, the detail view.
    private func upsert(_ meeting: Meeting) {
        let header = MeetingHeader(meeting)
        if let index = log.firstIndex(where: { $0.id == meeting.id }) {
            if log[index] != header { log[index] = header }
        } else {
            log.insert(header, at: log.firstIndex { $0.startedAt < header.startedAt } ?? log.endIndex)
        }
        if current?.id == meeting.id { current = meeting; dirty = false }
    }

    /// Edits apply in memory immediately; the manifest is written once typing pauses.
    func edit(_ change: (inout Meeting) -> Void) {
        guard var meeting = current, !isLocked(meeting.id) else { return }
        change(&meeting)
        current = meeting
        if let index = log.firstIndex(where: { $0.id == meeting.id }) {
            let header = MeetingHeader(meeting)
            if log[index] != header { log[index] = header }
        }
        dirty = true
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            if !Task.isCancelled { self?.flushSave() }
        }
    }

    func flushSave() {
        pendingSave?.cancel(); pendingSave = nil
        guard dirty, let meeting = current, previewStore == nil else { return }
        dirty = false
        writer.write(meeting, to: locations.manifest(meeting.id)) { error in
            Task { @MainActor [weak self] in self?.errorMessage = error.localizedDescription }
        }
    }

    /// Flushes edits and waits for queued writes; call before another process reads manifests.
    func settle() { flushSave(); writer.drain() }

    func moveToTrash(_ id: UUID) {
        guard !isLocked(id) else { return }
        if current?.id == id { pendingSave?.cancel(); dirty = false }
        writer.drain()
        do {
            try FileManager.default.trashItem(at: locations.directory(id), resultingItemURL: nil)
            log.removeAll { $0.id == id }
            if route == .meeting(id) { route = .capture }
            refreshStorage()
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshModels() {
        let speech = locations.models.appendingPathComponent(ModelLayout.speechFolder)
        hasSpeechModels = ModelLayout.speechAssets.allSatisfy { FileManager.default.fileExists(atPath: speech.appendingPathComponent($0).path) }
        hasSummaryModel = FileManager.default.fileExists(atPath: locations.models.appendingPathComponent(SummaryRunner.modelName).path)
    }

    func refreshStorage() {
        guard previewStore == nil else { return }
        let sessions = locations.sessions
        Task {
            storageBytes = await Task.detached(priority: .utility) { Library.size(of: sessions) }.value
        }
    }

    // MARK: Recording

    func toggleRecording() {
        if isRecording { stopRecording(); return }
        guard !isStarting else { return }
        isStarting = true; onStatusChange?()
        Task {
            await libraryTask?.value
            if isWorking {
                let pending = operationTask
                cancelWork()
                await pending?.value
            }
            await startRecording()
        }
    }

    private func startRecording() async {
        defer { isStarting = false; onStatusChange?() }
        guard !isWorking, !isRecording else { return }
        flushSave()
        let name = title.trimmingCharacters(in: .whitespaces)
        var meeting = Meeting(title: name.isEmpty ? "Untitled meeting" : name, project: project.trimmingCharacters(in: .whitespaces))
        meeting.state = .recording
        let directory = locations.directory(meeting.id), manifest = locations.manifest(meeting.id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try writer.writeNow(meeting, to: manifest)
            active = meeting; upsert(meeting); route = .capture
            let capture = AudioCapture(); self.capture = capture
            let recordingID = meeting.id
            capture.onCheckpoint = { [weak self] chunk in Task { @MainActor in self?.checkpoint(chunk, recordingID: recordingID) } }
            try await capture.start(directory: directory, includeMicrophone: includeMicrophone)
            meeting.startedAt = capture.startedAt
            meeting.microphoneOffset = capture.microphoneOffset
            active = meeting; upsert(meeting)
            try writer.writeNow(meeting, to: manifest)
            recordingStartedAt = capture.startedAt
            reminder = StopReminderPolicy(); quietMinutes = nil
            if remindWhenQuiet { notifier.prepare() }
            recordingTitle = meeting.title
            isRecording = true
            title = ""
            startHealthTimer()
        } catch {
            let partial = capture?.stop()
            capture = nil; active = nil
            meeting.state = .failed
            meeting.chunks = partial?.chunks ?? []
            meeting.warnings.append(error.localizedDescription)
            try? writer.writeNow(meeting, to: manifest)
            upsert(meeting); errorMessage = error.localizedDescription
        }
    }

    private func checkpoint(_ chunk: AudioChunk, recordingID: UUID) {
        guard var meeting = active, meeting.id == recordingID,
              !meeting.chunks.contains(where: { $0.file == chunk.file }) else { return }
        meeting.chunks.append(chunk)
        active = meeting
        if current?.id == meeting.id { current = meeting }
        writer.write(meeting, to: locations.manifest(meeting.id)) { error in
            Task { @MainActor [weak self] in
                guard self?.active?.id == recordingID else { return }
                // Storage is failing: processing would write more to the same place.
                self?.stopRecording(warning: error.localizedDescription, process: false)
            }
        }
    }

    /// Health every 2 s and free space every ~30 s, with tolerance so macOS can coalesce wakeups.
    private func startHealthTimer() {
        healthTicks = 0
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func checkHealth() {
        guard isRecording else { return }
        if let error = capture?.healthError { stopRecording(warning: error); return }
        evaluateReminders()
        healthTicks += 1
        guard healthTicks % 15 == 1 else { return }
        if let values = try? locations.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage, free < 256_000_000 {
            // Models and transcripts need disk too; leave processing until space is freed.
            stopRecording(warning: "Recording stopped because less than 256 MB of storage remains. Free some space, then choose Process.", process: false)
        }
    }

    /// Quiet / long-running nudges. Runs every 2 s on numbers already measured while writing audio.
    private func evaluateReminders() {
        guard let capture else { return }
        let settings = StopReminderPolicy.Settings(remindWhenQuiet: remindWhenQuiet, autoStopWhenQuiet: autoStopWhenQuiet)
        let action = reminder.evaluate(elapsed: capture.elapsedSeconds, lastActive: capture.lastActiveSeconds, settings: settings)
        let quiet = max(0, capture.elapsedSeconds - capture.lastActiveSeconds)
        let shown: Int? = reminder.reminderOutstanding ? Int(quiet / 60) : nil
        if shown != quietMinutes {
            if shown == nil { notifier.clearQuiet() }
            quietMinutes = shown; onStatusChange?()
        }
        switch action {
        case .none: break
        case .remindQuiet(let quiet):
            notifier.postQuiet(minutes: Int(quiet / 60), stopsInMinutes: autoStopWhenQuiet ? Int(reminder.grace / 60) : nil)
        case .longRunning(let hours):
            notifier.postLong(hours: hours)
        case .autoStop(let quiet, let lastActive):
            let minutes = Int(quiet / 60)
            let note = "Stopped automatically after \(minutes) minutes without audio (quiet since \(Meeting.timestamp(lastActive))). The quiet period is included in the saved audio."
            // Keep the last half minute of silence as a natural tail; the meeting ended at lastActive.
            stopRecording(note: note, trimTo: lastActive + 30)
            notifier.postStopped(quietMinutes: minutes)
        }
    }

    /// "Keep recording": the user is still here. Stay quiet for a while and never auto-stop this lull.
    func keepRecording() {
        guard let capture else { return }
        reminder.keepRecording(at: capture.elapsedSeconds)
        quietMinutes = nil; notifier.clearQuiet(); onStatusChange?()
    }

    func stopRecording(warning: String? = nil, process: Bool = true, note: String? = nil, trimTo: TimeInterval? = nil) {
        guard var meeting = active else { return }
        healthTimer?.invalidate(); healthTimer = nil
        quietMinutes = nil; notifier.clearQuiet()
        let result = capture?.stop()
        capture = nil; active = nil; isRecording = false; recordingStartedAt = nil; recordingTitle = nil
        meeting.chunks = result?.chunks ?? meeting.chunks
        meeting.warnings += result?.warnings ?? []
        if let warning { meeting.warnings.append(warning); errorMessage = warning }
        meeting.duration = max(Date().timeIntervalSince(meeting.startedAt), meeting.chunks.map { $0.start + $0.duration }.max() ?? 0)
        if let trimTo { meeting.duration = min(meeting.duration, max(trimTo, 1)) }
        if let note { meeting.warnings.append(note) }
        meeting.state = warning == nil ? .ready : .interrupted
        do { try writer.writeNow(meeting, to: locations.manifest(meeting.id)) } catch { errorMessage = error.localizedDescription }
        upsert(meeting)
        route = .meeting(meeting.id)
        onStatusChange?()
        if CaptureProcessing.shouldStart(requested: process, automatic: autoProcess,
                                         modelsAvailable: hasSpeechModels, chunkCount: meeting.chunks.count) {
            processMeeting(meeting.id)
        }
    }

    // MARK: Destination

    func chooseDestination(drive: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Save meeting notes here"
        panel.message = drive ? "Choose the synced Google Drive folder matching your folder link. Notes work offline; Google Drive syncs them when connected." : "Markdown notes will be saved directly in this folder."
        if drive { panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage") }
        else { panel.directoryURL = destination }
        if panel.runModal() == .OK, let url = panel.url {
            destination = url; UserDefaults.standard.set(url.path, forKey: "destination")
        }
    }

    func saveDriveLink() {
        guard driveLink.isEmpty || validDriveURL != nil else { errorMessage = "Use a Google Drive folder link, such as https://drive.google.com/drive/folders/…"; return }
        UserDefaults.standard.set(driveLink, forKey: "driveLink")
    }
    var validDriveURL: URL? {
        guard let url = URL(string: driveLink), url.scheme == "https", url.host == "drive.google.com", url.path.contains("/folders/") else { return nil }
        return url
    }

    // MARK: Processing

    /// Runs one worker stage. Its stdout carries "n/total" progress lines; stderr goes to worker.log.
    func runWorker(_ args: [String], onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws {
        let bundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HushnoteWorker")
        let executable = FileManager.default.isExecutableFile(atPath: bundle.path) ? bundle : Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("HushnoteWorker")
        let process = Process(); process.executableURL = executable; process.arguments = args
        process.qualityOfService = .utility
        let log = locations.root.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let output = Pipe()
        process.standardError = handle; process.standardOutput = output
        let lines = LineReader { line in
            guard let match = line.firstMatch(of: #/(?:Diarized|Transcribed) (\d+)/(\d+)/#), let done = Int(match.1), let total = Int(match.2), total > 0 else { return }
            Task { @MainActor in onProgress?(done, total) }
        }
        output.fileHandleForReading.readabilityHandler = { reader in
            let data = reader.availableData
            if data.isEmpty { reader.readabilityHandler = nil } else { lines.consume(data) } // EOF would otherwise refire
        }
        worker = process
        defer { worker = nil; output.fileHandleForReading.readabilityHandler = nil; try? handle.close() }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
            do { try process.run() } catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            let message = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw CaptureFailure(message: "Local processing failed (\(status)). \(String(message.suffix(1400)))")
        }
    }

    func installSpeechModels() {
        perform("Downloading speech models") { [self] in
            try await runWorker(["prepare", locations.models.path])
            refreshModels()
            progress = "Speech models ready. Meetings can now be processed offline."
        }
    }

    func installSummaryModel() {
        perform("Downloading summary model · 1.12 GB") { [self] in
            try await SummaryRunner.install(in: locations.models)
            refreshModels()
            progress = "Summary model ready. Summaries will run offline."
        }
    }

    func processMeeting(_ id: UUID) {
        settle()
        perform("Preparing", lock: id) { [self] in
            guard hasSpeechModels else { throw CaptureFailure(message: "Download the speech models in Settings first.") }
            let manifest = locations.manifest(id).path, models = locations.models.path
            stage("Separating speakers")
            try await runWorker(["diarize", manifest, models]) { [weak self] done, total in self?.stage("Separating speakers", done, total) }
            stage("Transcribing")
            try await runWorker(["transcribe", manifest, models]) { [weak self] done, total in self?.stage("Transcribing", done, total) }
            guard var meeting = loadMeeting(id) else { throw CaptureFailure(message: "The processed meeting could not be read.") }
            upsert(meeting)
            // The bundled model is optional; every other engine is an explicit choice, so failures are reported.
            if summarySettings.engine != .bundled || hasSummaryModel {
                stage("Writing summary")
                do {
                    let provider = try await makeSummaryProvider(directory: locations.directory(id))
                    meeting.summary = try await SummaryRunner.make(meeting, provider: provider) { [weak self] done, total in
                        self?.stage("Writing summary", done, total)
                    }
                    meeting.summaryMethod = "\(provider.method) · AI-generated, check against the transcript"
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    meeting.warnings.append("The summary wasn't written (\(summarySettings.engine.title)): \(error.localizedDescription) Transcript excerpts were kept instead.")
                }
            }
            if meeting.summary.isEmpty {
                meeting.summary = LocalHighlights.make(meeting)
                meeting.summaryMethod = "Selected transcript excerpts (no generative model)"
            }
            meeting.state = .complete
            try writer.writeNow(meeting, to: locations.manifest(id))
            upsert(meeting)
            progress = "Ready to review and export."
        }
    }

    private func stage(_ name: String, _ done: Int? = nil, _ total: Int? = nil) {
        guard isWorking else { return }
        if let done, let total {
            progress = "\(name) · \(min(done + 1, total)) of \(total)"
            progressFraction = Double(done) / Double(total)
        } else {
            progress = name; progressFraction = nil
        }
    }

    func perform(_ message: String, lock id: UUID? = nil, operation: @escaping @MainActor () async throws -> Void) {
        guard !isWorking, !isRecording, !isStarting else { return }
        isWorking = true; busyID = id; progress = message; progressFraction = nil; onStatusChange?()
        operationTask = Task {
            defer { isWorking = false; busyID = nil; progressFraction = nil; operationTask = nil; onStatusChange?() }
            do { try await operation() }
            catch {
                if error is CancellationError || Task.isCancelled { progress = "Stopped. Saved checkpoints remain available." }
                else { errorMessage = error.localizedDescription; progress = "Needs attention" }
                if let id { reconcile(id) }
            }
        }
    }

    /// After a cancelled or failed run, mark a half-processed manifest as resumable.
    private func reconcile(_ id: UUID) {
        let manifest = locations.manifest(id)
        guard previewStore == nil, let meeting = try? writer.serially({ try Library.recover(manifest) }) else { return }
        upsert(meeting)
    }

    func cancelWork() { operationTask?.cancel(); worker?.terminate(); SummaryRunner.cancel() }

    func importAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.prompt = "Import audio"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let project = project
        perform("Importing audio") { [self] in
            var meeting = Meeting(title: url.deletingPathExtension().lastPathComponent, project: project)
            let directory = locations.directory(meeting.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            meeting.chunks = try await AudioArchive.background { try AudioArchive.importFile(url, to: directory) }
            meeting.duration = meeting.chunks.map { $0.start + $0.duration }.max() ?? 0
            try writer.writeNow(meeting, to: locations.manifest(meeting.id))
            upsert(meeting); route = .meeting(meeting.id)
            progress = "Audio imported. Choose Process to transcribe."
        }
    }

    func exportCurrent() {
        settle()
        guard let meeting = current else { return }
        if destination == nil { chooseDestination() }
        guard let destination else { return }
        let includeAudio = includeAudioInExport
        let source = locations.directory(meeting.id)
        perform("Saving Markdown", lock: meeting.id) { [self] in
            let note = try await AudioArchive.background {
                try AudioArchive.export(meeting, from: source, destination: destination, includeAudio: includeAudio)
            }
            lastExport = note; progress = "Saved \(note.lastPathComponent)"
        }
    }
}

/// Splits a byte stream into lines; called from a pipe's background reader.
final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }
    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        lines.forEach(handler)
    }
}

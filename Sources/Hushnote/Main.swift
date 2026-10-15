import AppKit
import SwiftUI
import Carbon
import HushnoteCore
import AVFoundation
import CaptureRing

@main
struct HushnoteMain {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--install-summary", args.count == 2 {
            do { try await SummaryRunner.install(in: URL(fileURLWithPath: args[1])); print("Summary model installed and SHA-256 verified.") }
            catch { print(error.localizedDescription); exit(1) }
            return
        }
        if args.first == "--audio-check", args.count == 3 {
            do { try audioCheck(fixture: URL(fileURLWithPath: args[1]), directory: URL(fileURLWithPath: args[2])); print("PASS: real-audio import, chunked PCM conversion, compressed audio export and Markdown export") }
            catch { print(error.localizedDescription); exit(1) }
            return
        }
        if args.first == "--summary-check", args.count == 3 {
            let url = URL(fileURLWithPath: args[1])
            do {
                var meeting = try MeetingFiles.read(url)
                meeting.summary = try await SummaryRunner.make(meeting, models: URL(fileURLWithPath: args[2]), session: url.deletingLastPathComponent())
                meeting.summaryMethod = "Local Qwen 2.5 1.5B"
                try MeetingFiles.save(meeting, to: url); print(meeting.summary)
            } catch { print(error.localizedDescription); exit(1) }
            return
        }
        #if DEBUG
        if args.first == "--snapshot", args.count == 2 {
            NSApplication.shared.setActivationPolicy(.prohibited)
            Snapshot.run(into: URL(fileURLWithPath: args[1])); return
        }
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func audioCheck(fixture: URL, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var meeting = Meeting(title: "Audio integration check", project: "Testing")
        meeting.chunks = try AudioArchive.importFile(fixture, to: directory)
        meeting.duration = meeting.chunks.map { $0.start + $0.duration }.max() ?? 0
        let original = try AVAudioFile(forReading: fixture)
        let originalDuration = Double(original.length)/original.processingFormat.sampleRate
        guard abs(meeting.duration-originalDuration) < 0.05 else { throw CaptureFailure(message: "Audio duration changed during conversion.") }
        // Exercise the exact capture consumer with a real recording, without opening
        // a microphone or a system tap. The producer feeds bounded buffers.
        let sink = try TrackSink(source: "capture-check", sampleRate: original.processingFormat.sampleRate, offset: 0, directory: directory)
        let input = AVAudioPCMBuffer(pcmFormat: original.processingFormat, frameCapacity: 2048)!
        sink.start()
        for _ in 0..<2 {
            original.framePosition = 0
            while original.framePosition < original.length {
                try original.read(into: input, frameCount: AVAudioFrameCount(min(2048, original.length-original.framePosition)))
                hn_ring_push(sink.ring, input.audioBufferList, input.frameLength)
                // Feed at 8x real time: fast, but within what a 4 s ring drained every 250 ms absorbs.
                Thread.sleep(forTimeInterval: Double(input.frameLength) / original.processingFormat.sampleRate / 8)
            }
        }
        let captured = sink.stop()
        guard captured.warnings.isEmpty, captured.chunks.count >= 2,
              abs(captured.chunks.reduce(0) { $0 + $1.duration }-originalDuration*2) < 0.05 else {
            throw CaptureFailure(message: "The capture ring/resampler did not preserve the real audio fixture.")
        }
        meeting.transcript = [TranscriptSegment(start: 0, end: 1, speaker: "Speaker 1", text: "Export verification fixture.")]
        let note = try AudioArchive.export(meeting, from: directory, destination: directory, includeAudio: true)
        guard FileManager.default.fileExists(atPath: note.path) else { throw CaptureFailure(message: "Markdown export missing.") }
        let contents = try String(contentsOf: note, encoding: .utf8)
        guard contents.contains("system.m4a") else { throw CaptureFailure(message: "Audio link missing.") }
        let audioRoot = directory.appendingPathComponent("Hushnote Audio")
        let exported = try FileManager.default.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: nil)[0].appendingPathComponent("system.m4a")
        let encoded = try AVAudioFile(forReading: exported)
        guard abs(Double(encoded.length)/encoded.processingFormat.sampleRate-originalDuration) < 0.2 else { throw CaptureFailure(message: "Compressed audio duration changed.") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var state: AppState!
    private var window: NSWindow!
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggleRecording), keyEquivalent: "r")
    private let importItem = NSMenuItem(title: "Import audio…", action: #selector(importAudio), keyEquivalent: "")
    private var hotkey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var wasRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildApplicationMenu()
        state = AppState()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Hushnote"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = HN.canvasNS; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView(state: state))
        if !window.setFrameUsingName("Hushnote") { window.center() }
        window.setFrameAutosaveName("Hushnote")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        buildMenu()
        state.onStatusChange = { [weak self] in self?.statusChanged() }
        statusChanged(); registerShortcut(); showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return false }

    // Closing the window leaves recording controls available in the Dock and menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func showWindow() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc private func toggleRecording() { state.toggleRecording() }
    @objc private func importAudio() { showWindow(); state.importAudio() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// A normal Dock app needs an application menu as well as its menu-bar status menu.
    private func buildApplicationMenu() {
        let appMenu = NSMenu(title: "Hushnote")
        let about = NSMenuItem(title: "About Hushnote", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp
        let hide = NSMenuItem(title: "Hide Hushnote", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        let quit = NSMenuItem(title: "Quit Hushnote", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        [about, .separator(), hide, .separator(), quit].forEach(appMenu.addItem)
        let root = NSMenuItem(); root.submenu = appMenu
        let main = NSMenu(); main.addItem(root)
        NSApp.mainMenu = main
    }

    /// Built once; titles are refreshed only when the menu opens, not on a timer.
    private func buildMenu() {
        menu.delegate = self; menu.autoenablesItems = false
        statusLine.isEnabled = false
        toggleItem.keyEquivalentModifierMask = [.command, .option]; toggleItem.target = self
        importItem.target = self
        let show = NSMenuItem(title: "Open Hushnote", action: #selector(showWindow), keyEquivalent: ""); show.target = self
        let quit = NSMenuItem(title: "Quit Hushnote", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        [statusLine, .separator(), toggleItem, show, importItem, .separator(), quit].forEach(menu.addItem)
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let start = state.recordingStartedAt {
            statusLine.title = "Recording · \(Meeting.timestamp(Date().timeIntervalSince(start)))"
        } else if state.isWorking {
            statusLine.title = state.progress.isEmpty ? "Processing locally…" : state.progress
        } else {
            statusLine.title = state.errorMessage != nil ? "Needs attention — open Hushnote" : "Hushnote · Ready"
        }
        toggleItem.title = state.isRecording ? "Stop recording" : "Start recording"
        toggleItem.isEnabled = !state.isStarting
        importItem.isEnabled = !state.isRecording && !state.isWorking
    }

    private func statusChanged() {
        item.button?.image = state.isRecording ? StatusIcon.recording : state.isWorking ? StatusIcon.working : StatusIcon.idle
        item.button?.setAccessibilityLabel(state.isRecording ? "Hushnote, recording" : state.isWorking ? "Hushnote, processing" : "Hushnote")
        item.button?.toolTip = state.isRecording ? "Hushnote is recording — ⌥⌘R to stop" : "Hushnote — ⌥⌘R to record"
        if state.isRecording && !wasRecording {
            window.orderOut(nil)
            // Stay out of the app switcher and running-app Dock section during capture.
            // A Dock shortcut the user has pinned, and macOS privacy indicators, may remain.
            NSApp.setActivationPolicy(.accessory)
        } else if !state.isRecording && wasRecording {
            // Restore the Dock icon without reopening or activating the hidden window.
            NSApp.setActivationPolicy(.regular)
        }
        wasRecording = state.isRecording
    }

    private func registerShortcut() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in delegate.state.toggleRecording() }
            return noErr
        }, 1, &event, context, &eventHandler)
        guard result == noErr else { state.errorMessage = "The global shortcut could not be registered. Use the menu bar to record."; return }
        let id = EventHotKeyID(signature: 0x48555348, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotkey)
        if status != noErr { state.errorMessage = "⌥⌘R is already in use. Use the Hushnote menu bar to start and stop." }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if state.isRecording { state.stopRecording(process: false) }
        state.cancelWork()
        state.settle()
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        return .terminateNow
    }
}

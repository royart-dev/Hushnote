import Foundation
import os
import CoreAudio
import AVFoundation
import CaptureRing
import HushnoteCore

struct CaptureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func checkAudio(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CaptureFailure(message: "\(operation) failed (\(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording.") }
}

/// The audio callbacks only copy into a fixed-size lock-free C ring. Conversion,
/// file IO and checkpoint writes happen on this consumer queue.
final class TrackSink {
    let ring: OpaquePointer
    let sampleRate: Double
    private let source: String
    private let offset: Double
    private let directory: URL
    private let queue = DispatchQueue(label: "app.hushnote.audio-writer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let converter: AVAudioConverter
    private var file: AVAudioFile?
    private var frames: Int64 = 0
    private var chunkStart: Int64 = 0
    private var chunks: [AudioChunk] = []
    private var failure: Error?
    // Mirrors `failure` so the main thread can poll health without waiting on disk writes.
    private let failureMessage = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let prefix: String
    var onCheckpoint: ((AudioChunk) -> Void)?

    init(source: String, sampleRate: Double, offset: Double, directory: URL) throws {
        guard let ring = hn_ring_create(UInt32(sampleRate * 4)),
              let native = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let normalized = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: native, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: normalized, frameCapacity: 8192),
              let converter = AVAudioConverter(from: native, to: normalized) else {
            throw CaptureFailure(message: "The audio device format is unsupported.")
        }
        self.ring = ring; self.sampleRate = sampleRate; self.source = source
        self.offset = offset; self.directory = directory
        self.input = input; self.output = output; self.converter = converter
        prefix = source + "-" + String(UUID().uuidString.prefix(8))
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // The ring holds 4 s, so a 250 ms drain keeps 16x headroom at ~4 wakeups/s instead of 25.
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.drain() }
        self.timer = timer; timer.resume()
    }

    private func drain() {
        guard failure == nil else { return }
        do {
            while true {
                let n = hn_ring_read(ring, input.floatChannelData![0], 4096)
                if n == 0 { break }
                input.frameLength = n
                var supplied = false
                var conversionError: NSError?
                output.frameLength = 0
                converter.convert(to: output, error: &conversionError) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return self.input
                }
                if let conversionError { throw conversionError }
                if output.frameLength > 0 { try write(output) }
            }
        } catch {
            failure = error
            failureMessage.withLock { $0 = error.localizedDescription }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        if file == nil {
            let name = "\(prefix)-\(chunks.count).caf"
            file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            chunkStart = frames
        }
        try file!.write(from: buffer)
        frames += Int64(buffer.frameLength)
        if frames - chunkStart >= 16_000 * 30 { closeChunk() }
    }

    private func closeChunk() {
        guard let url = file?.url else { return }
        let chunk = AudioChunk(file: url.lastPathComponent, source: source,
                              start: offset + Double(chunkStart)/16_000,
                              duration: Double(frames-chunkStart)/16_000)
        self.file = nil // Close before publishing the checkpoint.
        chunks.append(chunk)
        onCheckpoint?(chunk)
    }

    func stop() -> (chunks: [AudioChunk], warnings: [String]) {
        timer?.cancel(); timer = nil
        return queue.sync {
            drain(); closeChunk()
            var warnings: [String] = []
            let lost = hn_ring_dropped(ring)
            if lost > 0 { warnings.append("\(source) capture lost \(lost) samples because storage could not keep up. Timestamps after the gap may be inaccurate.") }
            if let failure { warnings.append("\(source) recording write failed: \(failure.localizedDescription)") }
            return (chunks, warnings)
        }
    }
    var healthError: String? {
        if let message = failureMessage.withLock({ $0 }) { return message }
        if hn_ring_dropped(ring) > 0 { return "Audio storage could not keep up; recording was stopped to preserve the saved audio." }
        return nil
    }
    deinit { hn_ring_destroy(ring) }
}

@MainActor
final class AudioCapture {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var system: TrackSink?
    private var mic: TrackSink?
    private var engine: AVAudioEngine?
    private var deviceListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var tapFormatListener: AudioObjectPropertyListenerBlock?
    private var engineObserver: NSObjectProtocol?
    private var systemGeneration: UUID?
    private var microphoneGeneration: UUID?
    private var directory: URL?
    private var sessionID: UUID?
    private var originUptime: TimeInterval = 0
    private var microphoneStarted = false
    private(set) var startedAt = Date()
    private var previousChunks: [AudioChunk] = []
    private var warnings: [String] = []
    private var recoveryBegan: [CaptureTrack: TimeInterval] = [:]
    var onCheckpoint: ((AudioChunk) -> Void)?
    var microphoneOffset: Double = 0

    private lazy var recovery = CaptureRouteRecovery(
        disconnect: { [weak self] track in self?.disconnect(track) },
        reconnect: { [weak self] track in
            guard let self, self.directory != nil else { throw CancellationError() }
            try self.reconnect(track)
        })

    private var elapsed: TimeInterval { max(0, ProcessInfo.processInfo.systemUptime - originUptime) }

    func start(directory: URL, includeMicrophone: Bool) async throws {
        if includeMicrophone {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else { throw CaptureFailure(message: "Microphone permission was declined. Enable it in System Settings or turn off Include my microphone.") }
        }
        self.directory = directory
        sessionID = UUID(); startedAt = Date(); originUptime = ProcessInfo.processInfo.systemUptime
        previousChunks = []; warnings = []; recoveryBegan = [:]
        microphoneStarted = false; microphoneOffset = 0
        recovery.begin(includeMicrophone ? [.system, .microphone] : [.system])
        do {
            try monitorDevices(includeMicrophone: includeMicrophone)
            try startSystem()
            if includeMicrophone {
                // During a Bluetooth handoff the default input may briefly be unavailable.
                // Keep system audio running and retry the microphone instead of ending the meeting.
                do { try startMicrophone() }
                catch { recovery.changed(.microphone) }
            }
        } catch {
            _ = stop()
            throw error
        }
    }

    private func monitorDevices(includeMicrophone: Bool) throws {
        guard let expected = sessionID else { return }
        var selectors = [kAudioHardwarePropertyDefaultOutputDevice]
        if includeMicrophone { selectors.append(kAudioHardwarePropertyDefaultInputDevice) }
        for selector in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let track: CaptureTrack = selector == kAudioHardwarePropertyDefaultOutputDevice ? .system : .microphone
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.sessionID == expected else { return }
                    self.recovery.changed(track)
                }
            }
            try checkAudio(AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener), "Monitoring audio device changes")
            deviceListeners.append((selector, listener))
        }
    }

    private func offset(for track: CaptureTrack) -> TimeInterval {
        CaptureTimeline.nextOffset(elapsed: elapsed, chunks: previousChunks, source: track.rawValue)
    }

    private func startSystem() throws {
        guard let directory, let expected = sessionID else { return }
        let generation = UUID(); systemGeneration = generation
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Hushnote meeting audio"; description.isPrivate = true
        description.muteBehavior = .unmuted
        try checkAudio(AudioHardwareCreateProcessTap(description, &tap), "Creating the audio tap")
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try checkAudio(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "Reading the audio format")
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mSampleRate > 0, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw CaptureFailure(message: "This output device does not expose Float32 audio.")
        }
        let sink = try TrackSink(source: "system", sampleRate: format.mSampleRate,
                                 offset: offset(for: .system), directory: directory)
        sink.onCheckpoint = onCheckpoint; system = sink
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hushnote capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        try checkAudio(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate), "Creating the audio input")
        let ring = sink.ring
        try checkAudio(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = abl.first, first.mNumberChannels > 0 else { return }
            let frames = first.mDataByteSize / (4 * first.mNumberChannels)
            hn_ring_push(ring, input, frames)
        }, "Starting the audio callback")
        sink.start()
        try checkAudio(AudioDeviceStart(aggregate, ioProc), "Starting system audio capture")

        // The same default device can change format without changing its identity.
        let expectedTap = tap
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.sessionID == expected, self.systemGeneration == generation,
                      self.tap == expectedTap else { return }
                var current = AudioStreamBasicDescription()
                var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                if AudioObjectGetPropertyData(expectedTap, &address, 0, nil, &size, &current) == noErr,
                   current.mSampleRate == format.mSampleRate, current.mChannelsPerFrame == format.mChannelsPerFrame,
                   current.mFormatFlags == format.mFormatFlags, current.mBitsPerChannel == format.mBitsPerChannel { return }
                self.recovery.changed(.system)
            }
        }
        try checkAudio(AudioObjectAddPropertyListenerBlock(tap, &address, .main, listener), "Monitoring the system audio format")
        tapFormatListener = listener
    }

    private func startMicrophone() throws {
        guard let directory, let expected = sessionID else { return }
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try checkAudio(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device), "Reading the microphone")
        guard device != kAudioObjectUnknown else { throw CaptureFailure(message: "The microphone is reconnecting.") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw CaptureFailure(message: "No usable microphone is connected.")
        }
        let start = offset(for: .microphone)
        let sink = try TrackSink(source: "microphone", sampleRate: format.sampleRate,
                                 offset: start, directory: directory)
        sink.onCheckpoint = onCheckpoint; mic = sink; self.engine = engine
        let generation = UUID(); microphoneGeneration = generation
        let sampleRate = format.sampleRate, channels = format.channelCount
        let ring = sink.ring
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            hn_ring_push(ring, buffer.audioBufferList, buffer.frameLength)
        }
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // Apple's notification can arrive on an engine queue. Never tear down there:
            // hop to the main actor and reject callbacks from an already replaced engine.
            Task { @MainActor in
                guard let self, self.sessionID == expected, self.microphoneGeneration == generation,
                      let engine = self.engine else { return }
                let current = engine.inputNode.outputFormat(forBus: 0)
                if engine.isRunning, current.sampleRate == sampleRate, current.channelCount == channels { return }
                self.recovery.changed(.microphone)
            }
        }
        sink.start(); try engine.start()
        if !microphoneStarted { microphoneOffset = start; microphoneStarted = true }
    }

    private func stopSystem() {
        systemGeneration = nil
        if let tapFormatListener, tap != 0 {
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(tap, &address, .main, tapFormatListener)
        }
        tapFormatListener = nil
        if aggregate != 0, let ioProc {
            AudioDeviceStop(aggregate, ioProc); AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        ioProc = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        if let system {
            let result = system.stop(); previousChunks += result.chunks; warnings += result.warnings
        }
        system = nil
    }

    private func stopMicrophone() {
        microphoneGeneration = nil
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        if let mic {
            let result = mic.stop(); previousChunks += result.chunks; warnings += result.warnings
        }
        mic = nil
    }

    private func disconnect(_ track: CaptureTrack) {
        if recoveryBegan[track] == nil { recoveryBegan[track] = elapsed }
        switch track {
        case .system: stopSystem()
        case .microphone: stopMicrophone()
        }
    }

    private func reconnect(_ track: CaptureTrack) throws {
        switch track {
        case .system: try startSystem()
        case .microphone: try startMicrophone()
        }
        if let began = recoveryBegan.removeValue(forKey: track), elapsed - began > 3 {
            // Honest post-meeting diagnostics for a prolonged hardware outage, never a popup.
            warnings.append("\(track.rawValue.capitalized) audio was unavailable at \(Meeting.timestamp(began)) for \(Meeting.timestamp(elapsed - began)) during a device handoff; capture resumed automatically.")
        }
    }

    func stop() -> (chunks: [AudioChunk], warnings: [String]) {
        // Invalidate callbacks and retries BEFORE stopping graphs; they cannot resurrect capture.
        sessionID = nil
        recovery.stop()
        for (selector, listener) in deviceListeners {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        deviceListeners = []
        stopMicrophone(); stopSystem()
        for (track, began) in recoveryBegan where elapsed - began > 3 {
            warnings.append("\(track.rawValue.capitalized) audio was unavailable from \(Meeting.timestamp(began)) until recording stopped; saved audio from the other track is preserved.")
        }
        recoveryBegan = [:]; directory = nil
        return (previousChunks.sorted { $0.start < $1.start }, warnings)
    }
    var healthError: String? { system?.healthError ?? mic?.healthError }
}

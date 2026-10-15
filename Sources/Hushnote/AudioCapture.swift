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
    private var routeListener: AudioObjectPropertyListenerBlock?
    private var engineObserver: NSObjectProtocol?
    private var directory: URL?
    private(set) var startedAt = Date()
    private var previousChunks: [AudioChunk] = []
    private var warnings: [String] = []
    var onCheckpoint: ((AudioChunk) -> Void)?
    var onFailure: ((String) -> Void)?
    var microphoneOffset: Double = 0

    func start(directory: URL, includeMicrophone: Bool) async throws {
        if includeMicrophone {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else { throw CaptureFailure(message: "Microphone permission was declined. Enable it in System Settings or turn off Include my microphone.") }
        }
        self.directory = directory; startedAt = Date()
        do {
            try startSystem()
            if includeMicrophone { try startMicrophone() }
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.restartSystemForRouteChange() }
            }
            routeListener = listener
            try checkAudio(AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener), "Monitoring audio device changes")
        } catch {
            _ = stop()
            throw error
        }
    }

    private func startSystem() throws {
        guard let directory else { return }
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
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw CaptureFailure(message: "This output device does not expose Float32 audio.")
        }
        if previousChunks.isEmpty && system == nil { startedAt = Date() }
        let sink = try TrackSink(source: "system", sampleRate: format.mSampleRate,
                                 offset: Date().timeIntervalSince(startedAt), directory: directory)
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
    }

    private func startMicrophone() throws {
        guard let directory else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw CaptureFailure(message: "No usable microphone is connected.")
        }
        microphoneOffset = Date().timeIntervalSince(startedAt)
        let sink = try TrackSink(source: "microphone", sampleRate: format.sampleRate,
                                 offset: microphoneOffset, directory: directory)
        sink.onCheckpoint = onCheckpoint; mic = sink; self.engine = engine
        let ring = sink.ring
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            hn_ring_push(ring, buffer.audioBufferList, buffer.frameLength)
        }
        sink.start(); try engine.start()
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onFailure?("The microphone configuration changed. Saved audio is safe; select your device and start a new recording.") }
        }
    }

    private func stopSystem() {
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

    private func restartSystemForRouteChange() {
        guard directory != nil else { return }
        stopSystem()
        warnings.append("Audio output changed at \(Meeting.timestamp(Date().timeIntervalSince(startedAt))); capture was reconnected. A short gap may occur.")
        do { try startSystem() }
        catch { onFailure?(error.localizedDescription) }
    }

    func stop() -> (chunks: [AudioChunk], warnings: [String]) {
        if let routeListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, routeListener)
        }
        routeListener = nil
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        stopSystem()
        if let mic { let result = mic.stop(); previousChunks += result.chunks; warnings += result.warnings }
        mic = nil; directory = nil
        return (previousChunks.sorted { $0.start < $1.start }, warnings)
    }
    var healthError: String? { system?.healthError ?? mic?.healthError }
}

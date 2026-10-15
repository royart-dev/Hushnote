import Foundation

public enum CaptureTrack: String, CaseIterable, Sendable {
    case system, microphone
}

/// One coalesced retry task per recording, with independent track teardown. No audio is buffered
/// here: a disconnected track is checkpointed, while the other keeps recording normally.
@MainActor
public final class CaptureRouteRecovery {
    private let disconnect: (CaptureTrack) -> Void
    private let reconnect: (CaptureTrack) throws -> Void
    private let settleDelay: Duration
    private let retryDelays: [Duration]
    private var enabled: Set<CaptureTrack> = []
    public private(set) var pending: Set<CaptureTrack> = []
    private var failures: [CaptureTrack: Int] = [:]
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(settleDelay: Duration = .milliseconds(200),
                retryDelays: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(5)],
                disconnect: @escaping (CaptureTrack) -> Void,
                reconnect: @escaping (CaptureTrack) throws -> Void) {
        self.settleDelay = settleDelay
        self.retryDelays = retryDelays.isEmpty ? [.seconds(5)] : retryDelays
        self.disconnect = disconnect; self.reconnect = reconnect
    }

    public func begin(_ tracks: Set<CaptureTrack>) {
        stop(); enabled = tracks
    }

    /// Called after the OS callback returns, never from an audio render callback.
    public func changed(_ track: CaptureTrack) {
        guard enabled.contains(track) else { return }
        if pending.insert(track).inserted { disconnect(track) }
        failures[track] = 0
        schedule(after: settleDelay)
    }

    public func stop() {
        generation &+= 1
        task?.cancel(); task = nil
        enabled.removeAll(); pending.removeAll(); failures.removeAll()
    }

    private func schedule(after delay: Duration) {
        generation &+= 1
        let expected = generation
        task?.cancel()
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, self.generation == expected else { return }
            self.task = nil
            self.attemptPending()
        }
    }

    private func attemptPending() {
        var delay: Duration?
        for track in CaptureTrack.allCases where pending.contains(track) {
            do {
                try reconnect(track)
                pending.remove(track); failures.removeValue(forKey: track)
            } catch {
                // A failed attempt may have allocated a tap, engine or sink; release it before retry.
                disconnect(track)
                let count = failures[track, default: 0]
                let next = retryDelays[min(count, retryDelays.count - 1)]
                failures[track] = min(count + 1, retryDelays.count)
                delay = min(delay ?? next, next)
            }
        }
        if !pending.isEmpty { schedule(after: delay ?? retryDelays.last!) }
    }
}

/// The recording origin never changes across device reconnects. Preserve actual handoff gaps and
/// never place a replacement track before the final sample of its previous checkpoint.
public enum CaptureTimeline {
    public static func nextOffset(elapsed: TimeInterval, chunks: [AudioChunk], source: String) -> TimeInterval {
        max(0, elapsed, chunks.lazy.filter { $0.source == source }.map { $0.start + $0.duration }.max() ?? 0)
    }
}

/// Capture failures still leave useful audio to transcribe. Quit/sleep can explicitly defer it.
public enum CaptureProcessing {
    public static func shouldStart(requested: Bool, automatic: Bool, modelsAvailable: Bool, chunkCount: Int) -> Bool {
        requested && automatic && modelsAvailable && chunkCount > 0
    }
}


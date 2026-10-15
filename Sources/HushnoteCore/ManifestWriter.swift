import Foundation

/// The single path for session manifests. Writes are off-main and ordered, so an older snapshot
/// never lands after a newer one. Reads and other manifest work run on the same queue, after every
/// write already queued, so they never see a manifest that a pending save is about to replace.
public final class ManifestWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.hushnote.manifest", qos: .utility)
    public init() {}

    public func write(_ meeting: Meeting, to url: URL, onError: @escaping @Sendable (Error) -> Void) {
        queue.async { do { try MeetingFiles.save(meeting, to: url) } catch { onError(error) } }
    }

    /// Writes after everything already queued, and returns once it is on disk.
    public func writeNow(_ meeting: Meeting, to url: URL) throws {
        try serially { try MeetingFiles.save(meeting, to: url) }
    }

    /// Reads after everything already queued.
    public func read(_ url: URL) throws -> Meeting {
        try serially { try MeetingFiles.read(url) }
    }

    /// Runs other manifest work, such as recovery, in order with queued writes.
    public func serially<T>(_ work: () throws -> T) rethrows -> T {
        try queue.sync(execute: work)
    }

    public func drain() { queue.sync {} }
}

import Foundation
import os

/// Learns when a recording last carried real sound, so "the meeting is over" can be inferred without
/// listening to content or running a model. Fed one loudness reading per drained audio chunk.
///
/// A track counts as active only after `sustain` seconds of audible sound with no gap longer than `gap`,
/// so a single notification chime or key click never resets the quiet clock, while speech or music does.
/// Either track can keep the recording alive: a silent microphone doesn't matter while others are talking.
public final class ActivityMeter: @unchecked Sendable {
    public struct Config: Sendable {
        /// RMS of 16 kHz float samples; 0.006 is about -44 dBFS, above a room's noise floor, below quiet speech.
        public var audibleRMS: Float = 0.006
        public var sustain: Double = 1.0
        public var gap: Double = 2.0
        public init() {}
    }
    private struct Run { var audible = 0.0, silent = 0.0 }
    private struct State { var lastActive: TimeInterval; var runs: [CaptureTrack: Run] = [:] }
    private let config: Config
    private let state: OSAllocatedUnfairLock<State>

    public init(config: Config = Config(), startedAt: TimeInterval = 0) {
        self.config = config
        state = OSAllocatedUnfairLock(initialState: State(lastActive: startedAt))
    }

    public func reset(at uptime: TimeInterval) { state.withLock { $0 = State(lastActive: uptime) } }

    /// `seconds` is the duration of the chunk the reading covers; `uptime` is when it was observed.
    public func observe(_ track: CaptureTrack, rms: Float, seconds: Double, at uptime: TimeInterval) {
        state.withLock { state in
            var run = state.runs[track, default: Run()]
            if rms >= config.audibleRMS {
                run.audible += seconds; run.silent = 0
                if run.audible >= config.sustain { state.lastActive = max(state.lastActive, uptime) }
            } else {
                run.silent += seconds
                if run.silent >= config.gap { run.audible = 0 }
            }
            state.runs[track] = run
        }
    }

    public var lastActive: TimeInterval { state.withLock { $0.lastActive } }
}

/// Decides when to nudge or stop a recording that has gone quiet or run very long.
/// Pure state machine over recording-elapsed seconds, so every rule is unit-testable.
///
/// Rules, in order of care:
/// - Sound resumes: any outstanding reminder is withdrawn.
/// - Quiet for `quietBefore`: remind once (unless snoozed by "Keep recording").
/// - Reminder unanswered for `grace` while still quiet: stop, if the user allowed it.
/// - Audio flowing: never stop automatically. Losing the rest of a live meeting is worse than a long
///   recording, so long sessions only get an hourly nudge.
public struct StopReminderPolicy: Sendable {
    public struct Settings: Equatable, Sendable {
        public var remindWhenQuiet: Bool
        public var autoStopWhenQuiet: Bool
        public init(remindWhenQuiet: Bool = true, autoStopWhenQuiet: Bool = true) {
            self.remindWhenQuiet = remindWhenQuiet; self.autoStopWhenQuiet = autoStopWhenQuiet
        }
    }
    public enum Action: Equatable, Sendable {
        case none
        case remindQuiet(quiet: TimeInterval)
        case autoStop(quiet: TimeInterval, lastActive: TimeInterval)
        case longRunning(hours: Int)
    }

    public static let resumeAfter: TimeInterval = 60
    public var quietBefore: TimeInterval = 10 * 60
    public var grace: TimeInterval = 20 * 60
    public var snooze: TimeInterval = 30 * 60
    public var firstLongRunning: TimeInterval = 2 * 3600

    private var reminderSentAt: TimeInterval?
    private var snoozedUntil: TimeInterval = 0
    private var lastLongHours = 0

    public init() {}

    public var reminderOutstanding: Bool { reminderSentAt != nil }

    public mutating func evaluate(elapsed: TimeInterval, lastActive: TimeInterval, settings: Settings) -> Action {
        let quiet = max(0, elapsed - lastActive)
        if quiet < Self.resumeAfter { reminderSentAt = nil }
        if let sent = reminderSentAt {
            if settings.autoStopWhenQuiet && settings.remindWhenQuiet && elapsed - sent >= grace {
                reminderSentAt = nil
                return .autoStop(quiet: quiet, lastActive: lastActive)
            }
        } else if settings.remindWhenQuiet, quiet >= quietBefore, elapsed >= snoozedUntil {
            reminderSentAt = elapsed
            return .remindQuiet(quiet: quiet)
        }
        if settings.remindWhenQuiet, elapsed >= firstLongRunning {
            let hours = Int(elapsed / 3600)
            if hours > lastLongHours { lastLongHours = hours; return .longRunning(hours: hours) }
        }
        return .none
    }

    /// The user said the recording should continue: stay silent for `snooze`, and don't auto-stop.
    public mutating func keepRecording(at elapsed: TimeInterval) {
        reminderSentAt = nil
        snoozedUntil = elapsed + snooze
    }
}

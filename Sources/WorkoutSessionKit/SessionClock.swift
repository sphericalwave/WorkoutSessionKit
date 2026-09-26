//
//  SessionClock.swift
//  WorkoutSessionKit
//
//  Where the engine gets time from. Two reasons this is a seam rather than
//  bare `Date()` and `Task.sleep`:
//
//  1. Counting a segment down by subtracting one per sleep drifts long.
//     `Task.sleep` guarantees *at least* the requested duration, and the
//     overshoot accumulates — a ninety-second hold finishes seconds late, and
//     a logged duration derived from it is wrong by the same margin. Deriving
//     what's left from elapsed wall time instead costs nothing and can't drift.
//  2. Tests can't wait out a real ninety seconds. `.virtual` runs the same
//     code path with time it controls.
//

import Foundation

public struct SessionClock: Sendable {
    let now: @Sendable () -> Date
    let sleep: @Sendable (UInt64) async -> Void

    public init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (UInt64) async -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// Real time. What the app runs on.
    public static let realtime = SessionClock(
        now: { Date() },
        sleep: { try? await Task.sleep(nanoseconds: $0) }
    )

    /// Time that only moves when the engine sleeps, by exactly the amount it
    /// asked for. `sleep` is the caller's own delay — pass `{ _ in }` to run a
    /// whole session instantly, or a real sleep to step through it.
    public static func virtual(
        sleep: @escaping @Sendable (UInt64) async -> Void
    ) -> SessionClock {
        let elapsed = VirtualElapsed()
        return SessionClock(
            now: { Date(timeIntervalSinceReferenceDate: elapsed.seconds) },
            sleep: { nanos in
                await sleep(nanos)
                elapsed.advance(by: Double(nanos) / 1_000_000_000)
            }
        )
    }
}

/// Mutable time for `SessionClock.virtual`. The engine is `@MainActor`, so the
/// lock is belt-and-braces for a `Sendable` box rather than real contention.
private final class VirtualElapsed: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var seconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value += interval
    }
}

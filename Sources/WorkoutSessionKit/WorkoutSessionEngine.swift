//
//  WorkoutSessionEngine.swift
//  WorkoutSessionKit
//
//  App-agnostic driver for a rounds × slots workout with per-segment timing
//  (hold / per-side / slices). It owns the clock, phase, and cue emission; the
//  app owns persistence + progression via the value snapshots it feeds in and
//  the log it records between `awaitingLog` and `advance()`.
//
//  Typical loop:
//    engine.start()                        // begins slot 0
//    …runs left 30s → cue(.segmentBoundary) → right 30s → cue(.slotEnd)…
//    phase == .awaitingLog                 // app shows its log sheet
//    …app persists the set + applies progression…
//    engine.advance()                      // → next slot / round / finished
//

import Foundation
import Observation

@MainActor
@Observable
public final class WorkoutSessionEngine {

    public enum Phase: Sendable, Equatable { case idle, running, awaitingLog, finished }

    public let totalRounds: Int
    public private(set) var roundIndex: Int
    public private(set) var slotIndex: Int
    public private(set) var segmentIndex: Int = 0
    public private(set) var secondsRemaining: Int = 0
    public private(set) var phase: Phase = .idle
    /// Paused mid-segment. The clock stalls where it is rather than the
    /// segment restarting, so resuming keeps the seconds that were left.
    public private(set) var isPaused: Bool = false

    /// Slots for a given 0-based round. Called each round so apps can vary the
    /// lineup by round (e.g. a family's live level).
    @ObservationIgnored private let slotsForRound: (Int) -> [WorkoutSlot]
    @ObservationIgnored private let onCue: (SessionCue) -> Void
    @ObservationIgnored private let speak: (String) -> Void
    @ObservationIgnored private let announce: (Int) -> String?
    @ObservationIgnored private let countdownLeadSeconds: Int
    /// Run the whole session unattended, without stopping for a log between
    /// slots. For a guided routine that records itself — a meditation has no
    /// log sheet to pause for.
    @ObservationIgnored public let autoAdvance: Bool
    @ObservationIgnored private let clock: SessionClock

    @ObservationIgnored private var timer: Task<Void, Never>?
    /// Wall-clock accounting for the segment in progress, less time paused.
    @ObservationIgnored private var segmentStart: Date?
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var pausedTotal: TimeInterval = 0

    /// How often the clock is sampled. Finer than a second so a pause or a
    /// finish lands promptly, while whole-second effects still fire once each.
    private static let tickNanos: UInt64 = 100_000_000

    public init(
        totalRounds: Int,
        startingRound: Int = 0,
        startingSlot: Int = 0,
        countdownLeadSeconds: Int = 3,
        autoAdvance: Bool = false,
        slotsForRound: @escaping (Int) -> [WorkoutSlot],
        onCue: @escaping (SessionCue) -> Void = { _ in },
        speak: @escaping (String) -> Void = { _ in },
        announce: @escaping (Int) -> String? = { _ in nil },
        sleepNanos: (@Sendable (UInt64) async -> Void)? = nil
    ) {
        self.totalRounds = totalRounds
        self.roundIndex = startingRound
        self.slotIndex = startingSlot
        self.countdownLeadSeconds = countdownLeadSeconds
        self.autoAdvance = autoAdvance
        self.slotsForRound = slotsForRound
        self.onCue = onCue
        self.speak = speak
        self.announce = announce
        // Supplying a sleep is the test seam: time then advances by exactly
        // what was asked for, so a session runs to completion instantly and
        // deterministically. Production takes real time.
        self.clock = sleepNanos.map { SessionClock.virtual(sleep: $0) } ?? .realtime
        if roundIndex >= totalRounds { phase = .finished }
    }

    /// For a host supplying its own clock — a preview driving the countdown
    /// by hand, say. Most callers want the initialiser above.
    public init(
        totalRounds: Int,
        startingRound: Int = 0,
        startingSlot: Int = 0,
        countdownLeadSeconds: Int = 3,
        autoAdvance: Bool = false,
        clock: SessionClock,
        slotsForRound: @escaping (Int) -> [WorkoutSlot],
        onCue: @escaping (SessionCue) -> Void = { _ in },
        speak: @escaping (String) -> Void = { _ in },
        announce: @escaping (Int) -> String? = { _ in nil }
    ) {
        self.totalRounds = totalRounds
        self.roundIndex = startingRound
        self.slotIndex = startingSlot
        self.countdownLeadSeconds = countdownLeadSeconds
        self.autoAdvance = autoAdvance
        self.slotsForRound = slotsForRound
        self.onCue = onCue
        self.speak = speak
        self.announce = announce
        self.clock = clock
        if roundIndex >= totalRounds { phase = .finished }
    }

    /// Test hook: await the in-flight segment timer to completion.
    func waitForTimerCompletion() async { await timer?.value }

    // MARK: - Derived

    public var currentSlots: [WorkoutSlot] { slotsForRound(roundIndex) }
    public var slotCount: Int { currentSlots.count }
    public var currentSlot: WorkoutSlot? {
        slotIndex < currentSlots.count ? currentSlots[slotIndex] : nil
    }
    public var isLastSlotOfRound: Bool { slotIndex == slotCount - 1 }
    public var isFinalRound: Bool { roundIndex == totalRounds - 1 }

    /// Human label for the current segment ("Left"/"Right" per-side, "Slice n"
    /// for slices, the given name for named segments, "" for a single hold).
    public var segmentLabel: String {
        currentSlot?.timing.label(forSegment: segmentIndex) ?? ""
    }

    // MARK: - Run

    public func start() { startSlot() }

    private func startSlot() {
        guard let slot = currentSlot else { return }
        phase = .running
        segmentIndex = 0
        beginSegment(seconds: slot.timing.seconds(forSegment: 0))
        if slotIndex == 0 { onCue(.roundStart) }
        announce(slot)
        runTimer()
    }

    private func beginSegment(seconds: Int) {
        secondsRemaining = seconds
        segmentStart = clock.now()
        pausedAt = nil
        pausedTotal = 0
    }

    /// Stall the clock. The segment keeps its remaining seconds; nothing is
    /// lost and nothing is restarted.
    public func pause() {
        guard phase == .running, !isPaused else { return }
        isPaused = true
        pausedAt = clock.now()
    }

    public func resume() {
        guard isPaused else { return }
        if let pausedAt { pausedTotal += clock.now().timeIntervalSince(pausedAt) }
        pausedAt = nil
        isPaused = false
    }

    /// Skip the remaining clock and go straight to logging.
    public func skipToLog() {
        stopTimer()
        phase = .awaitingLog
    }

    /// Abandon the run (app decides whether to keep/delete the session).
    public func cancel() {
        stopTimer()
        phase = .finished
    }

    /// Dismiss the pending log without recording — return to the slot's idle
    /// state so it can be re-run. No-op unless awaiting a log.
    public func returnToIdle() {
        guard phase == .awaitingLog else { return }
        phase = .idle
    }

    /// Undo a `skipToLog()` — pick the clock back up where it left off rather
    /// than restarting the segment, for the app whose "done early" button was
    /// tapped by mistake. No-op unless a log is pending with time still on the
    /// clock; a slot that ran out on its own has nothing left to resume.
    public func resumeSlot() {
        guard phase == .awaitingLog, secondsRemaining > 0 else { return }
        phase = .running
        // However long the log sheet was up, it isn't hold time — re-peg the
        // clock so the seconds left are the ones the user saw.
        reanchorSegment()
        runTimer()
    }

    /// Re-peg the segment's start so `secondsRemaining` survives a gap the
    /// clock shouldn't have counted.
    private func reanchorSegment() {
        let consumed = TimeInterval(currentSegmentSeconds - secondsRemaining)
        segmentStart = clock.now().addingTimeInterval(-consumed)
        pausedAt = nil
        pausedTotal = 0
    }

    private func runTimer() {
        stopTimer()
        timer = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.secondsRemaining > 0 {
                await self.clock.sleep(Self.tickNanos)
                if Task.isCancelled { break }
                self.tick()
            }
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    /// Recomputes what's left from elapsed wall time rather than counting
    /// down, so the segment can't drift past its target however the sleeps
    /// land. Whole-second effects fire only when the displayed second
    /// changes, since this runs several times a second.
    private func tick() {
        guard !isPaused, let start = segmentStart else { return }
        let total = secondsRemaining
        let elapsed = clock.now().timeIntervalSince(start) - pausedTotal
        let target = TimeInterval(currentSegmentSeconds)
        let left = max(0, Int((target - elapsed).rounded(.up)))
        guard left != total else { return }

        secondsRemaining = left
        if left > 0 && left <= countdownLeadSeconds { onCue(.countdownTick) }
        if let text = announce(left) { speak(text) }
        if left <= 0 { handleSegmentEnd() }
    }

    private var currentSegmentSeconds: Int {
        currentSlot?.timing.seconds(forSegment: segmentIndex) ?? 0
    }

    private func handleSegmentEnd() {
        guard let slot = currentSlot else { return }
        let next = segmentIndex + 1
        if next < slot.timing.segmentCount {
            segmentIndex = next
            beginSegment(seconds: slot.timing.seconds(forSegment: next))
            onCue(.segmentBoundary)
            announce(slot)
        } else {
            stopTimer()
            onCue(.slotEnd)
            // Unattended: record nothing, just roll straight into whatever
            // comes next. The host reads the completed slot from its cues.
            if autoAdvance {
                advance()
                if phase == .idle { startSlot() }
            } else {
                phase = .awaitingLog
            }
        }
    }

    private func announce(_ slot: WorkoutSlot) {
        let label = segmentLabel
        speak(label.isEmpty ? slot.name : "\(slot.name), \(label)")
    }

    // MARK: - Advance (app calls after it has logged the set)

    public func advance() {
        if isLastSlotOfRound { onCue(.roundEnd) }
        slotIndex += 1
        if slotIndex >= slotCount {
            slotIndex = 0
            roundIndex += 1
        }
        phase = roundIndex >= totalRounds ? .finished : .idle
    }
}

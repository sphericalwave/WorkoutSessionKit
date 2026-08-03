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

    /// Slots for a given 0-based round. Called each round so apps can vary the
    /// lineup by round (e.g. a family's live level).
    @ObservationIgnored private let slotsForRound: (Int) -> [WorkoutSlot]
    @ObservationIgnored private let onCue: (SessionCue) -> Void
    @ObservationIgnored private let speak: (String) -> Void
    @ObservationIgnored private let announce: (Int) -> String?
    @ObservationIgnored private let countdownLeadSeconds: Int
    /// Injectable per-tick delay — real time in production, immediate in tests.
    @ObservationIgnored private let sleepNanos: @Sendable (UInt64) async -> Void

    @ObservationIgnored private var timer: Task<Void, Never>?

    public init(
        totalRounds: Int,
        startingRound: Int = 0,
        startingSlot: Int = 0,
        countdownLeadSeconds: Int = 3,
        slotsForRound: @escaping (Int) -> [WorkoutSlot],
        onCue: @escaping (SessionCue) -> Void = { _ in },
        speak: @escaping (String) -> Void = { _ in },
        announce: @escaping (Int) -> String? = { _ in nil },
        sleepNanos: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) {
        self.totalRounds = totalRounds
        self.roundIndex = startingRound
        self.slotIndex = startingSlot
        self.countdownLeadSeconds = countdownLeadSeconds
        self.slotsForRound = slotsForRound
        self.onCue = onCue
        self.speak = speak
        self.announce = announce
        self.sleepNanos = sleepNanos
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
    /// for slices, "" for a single hold).
    public var segmentLabel: String {
        guard let timing = currentSlot?.timing else { return "" }
        switch timing {
        case .hold:    return ""
        case .perSide: return segmentIndex == 0 ? "Left" : "Right"
        case .slices:  return "Slice \(segmentIndex + 1)"
        }
    }

    // MARK: - Run

    public func start() { startSlot() }

    private func startSlot() {
        guard let slot = currentSlot else { return }
        phase = .running
        segmentIndex = 0
        secondsRemaining = slot.timing.seconds(forSegment: 0)
        if slotIndex == 0 { onCue(.roundStart) }
        announce(slot)
        runTimer()
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

    private func runTimer() {
        stopTimer()
        timer = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.secondsRemaining > 0 {
                await self.sleepNanos(1_000_000_000)
                if Task.isCancelled { break }
                self.tick()
            }
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        secondsRemaining -= 1
        if secondsRemaining > 0 && secondsRemaining <= countdownLeadSeconds {
            onCue(.countdownTick)
        }
        if let text = announce(secondsRemaining) { speak(text) }
        if secondsRemaining <= 0 { handleSegmentEnd() }
    }

    private func handleSegmentEnd() {
        guard let slot = currentSlot else { return }
        let next = segmentIndex + 1
        if next < slot.timing.segmentCount {
            segmentIndex = next
            secondsRemaining = slot.timing.seconds(forSegment: next)
            onCue(.segmentBoundary)
            announce(slot)
        } else {
            stopTimer()
            onCue(.slotEnd)
            phase = .awaitingLog
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

//
//  GuidedSessionTests.swift
//  WorkoutSessionKitTests
//
//  Named segments, unattended running, pause, and the clock that replaced
//  counting down one per sleep.
//

import XCTest
@testable import WorkoutSessionKit

final class GuidedSessionTests: XCTestCase {

    // MARK: - Named segments

    func testNamedSegmentsRunOneHoldPerNameInOrder() {
        let timing = TimingMode.segments(names: ["Right", "Centre", "Left"], seconds: 60)
        XCTAssertEqual(timing.segmentCount, 3)
        XCTAssertEqual(timing.totalSeconds, 180)
        XCTAssertEqual(timing.label(forSegment: 0), "Right")
        XCTAssertEqual(timing.label(forSegment: 1), "Centre")
        XCTAssertEqual(timing.label(forSegment: 2), "Left")
    }

    /// A posture with no distinct positions still has to run once, not zero
    /// times — an empty name list is a plain hold.
    func testEmptyNamesBehaveAsASingleUnnamedHold() {
        let timing = TimingMode.segments(names: [], seconds: 45)
        XCTAssertEqual(timing.segmentCount, 1)
        XCTAssertEqual(timing.totalSeconds, 45)
        XCTAssertEqual(timing.label(forSegment: 0), "")
    }

    func testExistingModesKeepTheirLabels() {
        XCTAssertEqual(TimingMode.hold(seconds: 30).label(forSegment: 0), "")
        XCTAssertEqual(TimingMode.perSide(secondsEach: 30).label(forSegment: 0), "Left")
        XCTAssertEqual(TimingMode.perSide(secondsEach: 30).label(forSegment: 1), "Right")
        XCTAssertEqual(TimingMode.slices(count: 3, seconds: 30).label(forSegment: 1), "Slice 2")
    }

    @MainActor
    func testEngineAnnouncesEachNamedPosition() async {
        var spoken: [String] = []
        let engine = WorkoutSessionEngine(
            totalRounds: 1,
            slotsForRound: { _ in
                [WorkoutSlot(id: "a", name: "Shin box",
                             timing: .segments(names: ["Right", "Centre", "Left"], seconds: 5))]
            },
            speak: { spoken.append($0) },
            sleepNanos: { _ in }
        )
        engine.start()
        await engine.waitForTimerCompletion()

        XCTAssertEqual(spoken, ["Shin box, Right", "Shin box, Centre", "Shin box, Left"])
        XCTAssertEqual(engine.phase, .awaitingLog)
    }

    // MARK: - Unattended running

    /// A guided meditation has no log sheet to stop at — it should run every
    /// slot of every round and end finished, without the host intervening.
    @MainActor
    func testAutoAdvanceRunsEveryRoundWithoutWaitingForALog() async {
        var cues: [SessionCue] = []
        let engine = WorkoutSessionEngine(
            totalRounds: 2,
            autoAdvance: true,
            slotsForRound: { _ in
                [WorkoutSlot(id: "a", name: "A", timing: .hold(seconds: 4)),
                 WorkoutSlot(id: "b", name: "B", timing: .hold(seconds: 4))]
            },
            onCue: { cues.append($0) },
            sleepNanos: { _ in }
        )
        engine.start()
        while engine.phase == .running {
            await engine.waitForTimerCompletion()
        }

        XCTAssertEqual(engine.phase, .finished)
        XCTAssertEqual(engine.roundIndex, 2)
        XCTAssertEqual(cues.filter { $0 == .slotEnd }.count, 4)
        XCTAssertEqual(cues.filter { $0 == .roundEnd }.count, 2)
    }

    /// The default is unchanged, which is what keeps the existing apps working.
    @MainActor
    func testWithoutAutoAdvanceItStillStopsForALog() async {
        let engine = WorkoutSessionEngine(
            totalRounds: 2,
            slotsForRound: { _ in [WorkoutSlot(id: "a", name: "A", timing: .hold(seconds: 3))] },
            sleepNanos: { _ in }
        )
        XCTAssertFalse(engine.autoAdvance)
        engine.start()
        await engine.waitForTimerCompletion()
        XCTAssertEqual(engine.phase, .awaitingLog)
        XCTAssertEqual(engine.roundIndex, 0)
    }

    // MARK: - Pause

    /// Time the test moves by hand, so pausing is a fact rather than a race
    /// against the engine's own ticking.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 0

        func advance(_ interval: TimeInterval) {
            lock.lock(); seconds += interval; lock.unlock()
        }

        var clock: SessionClock {
            SessionClock(
                now: { [self] in
                    lock.lock(); defer { lock.unlock() }
                    return Date(timeIntervalSinceReferenceDate: seconds)
                },
                sleep: { _ in await Task.yield() }
            )
        }
    }

    @MainActor
    func testPausedTimeIsNotHeldTime() async {
        let manual = ManualClock()
        let engine = WorkoutSessionEngine(
            totalRounds: 1,
            clock: manual.clock,
            slotsForRound: { _ in [WorkoutSlot(id: "a", name: "A", timing: .hold(seconds: 10))] }
        )
        engine.start()
        XCTAssertEqual(engine.secondsRemaining, 10)

        manual.advance(4)
        await settle(engine)
        XCTAssertEqual(engine.secondsRemaining, 6)

        engine.pause()
        XCTAssertTrue(engine.isPaused)

        // A minute goes by with the session paused.
        manual.advance(60)
        await settle(engine)
        XCTAssertEqual(engine.secondsRemaining, 6, "a paused hold must not tick down")

        engine.resume()
        XCTAssertFalse(engine.isPaused)

        // The six seconds it still owed are the six it takes, despite the
        // minute that passed in between.
        manual.advance(5)
        await settle(engine)
        XCTAssertEqual(engine.secondsRemaining, 1)

        manual.advance(1)
        await settle(engine)
        XCTAssertEqual(engine.secondsRemaining, 0)
        XCTAssertEqual(engine.phase, .awaitingLog)
    }

    /// Let the engine's timer task observe the clock we just moved.
    private func settle(_ engine: WorkoutSessionEngine) async {
        for _ in 0..<10 { await Task.yield() }
    }

    @MainActor
    func testPauseIsIgnoredUnlessRunning() {
        let engine = WorkoutSessionEngine(
            totalRounds: 1,
            slotsForRound: { _ in [WorkoutSlot(id: "a", name: "A", timing: .hold(seconds: 10))] },
            sleepNanos: { _ in try? await Task.sleep(nanoseconds: 1_000_000_000_000) }
        )
        engine.pause()
        XCTAssertFalse(engine.isPaused, "nothing is running yet")
    }

    // MARK: - Clock

    /// The reason the countdown is derived from elapsed time rather than
    /// decremented per sleep: `Task.sleep` guarantees *at least* the duration
    /// asked for, so subtracting a nominal amount each time drifts long. Here
    /// every tick overshoots by half again, and the hold must still end at
    /// its target rather than running over.
    @MainActor
    func testSegmentEndsOnTimeWhenEverySleepOvershoots() async {
        let overshooting = SessionClock.virtual(sleep: { _ in })
        var elapsedAtEnd: TimeInterval = 0
        let started = overshooting.now()

        let engine = WorkoutSessionEngine(
            totalRounds: 1,
            clock: SessionClock(
                now: overshooting.now,
                sleep: { nanos in await overshooting.sleep(nanos + nanos / 2) }
            ),
            slotsForRound: { _ in [WorkoutSlot(id: "a", name: "A", timing: .hold(seconds: 30))] },
            onCue: { if $0 == .slotEnd { elapsedAtEnd = 0 } }
        )
        engine.start()
        await engine.waitForTimerCompletion()
        elapsedAtEnd = overshooting.now().timeIntervalSince(started)

        XCTAssertEqual(engine.secondsRemaining, 0)
        // Tolerance is one over-long tick; a decrementing counter would have
        // run to ~45s of clock time for a 30s hold.
        XCTAssertEqual(elapsedAtEnd, 30, accuracy: 0.5)
    }

    @MainActor
    func testVirtualClockAdvancesOnlyWhenSlept() async {
        let clock = SessionClock.virtual(sleep: { _ in })
        let start = clock.now()
        await clock.sleep(1_000_000_000)
        XCTAssertEqual(clock.now().timeIntervalSince(start), 1.0, accuracy: 0.0001)
    }
}

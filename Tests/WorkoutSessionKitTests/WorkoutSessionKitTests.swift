import XCTest
@testable import WorkoutSessionKit

final class WorkoutSessionKitTests: XCTestCase {

    func testTimingTotals() {
        XCTAssertEqual(TimingMode.hold(seconds: 60).totalSeconds, 60)
        XCTAssertEqual(TimingMode.hold(seconds: 60).segmentCount, 1)

        XCTAssertEqual(TimingMode.perSide(secondsEach: 30).totalSeconds, 60)
        XCTAssertEqual(TimingMode.perSide(secondsEach: 30).segmentCount, 2)
        XCTAssertTrue(TimingMode.perSide(secondsEach: 30).isPerSide)

        XCTAssertEqual(TimingMode.slices(count: 5, seconds: 30).totalSeconds, 150)
        XCTAssertEqual(TimingMode.slices(count: 5, seconds: 30).segmentCount, 5)
    }

    @MainActor
    func testRoundSlotProgressionToFinish() {
        let slots = { (_ round: Int) -> [WorkoutSlot] in
            [WorkoutSlot(id: "a", name: "A", timing: .perSide(secondsEach: 30)),
             WorkoutSlot(id: "b", name: "B", timing: .perSide(secondsEach: 30))]
        }
        let engine = WorkoutSessionEngine(totalRounds: 3, slotsForRound: slots)
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(engine.slotCount, 2)

        // 3 rounds × 2 slots = 6 logged sets to finish.
        for n in 1...6 {
            engine.advance()
            XCTAssertEqual(engine.phase, n < 6 ? .idle : .finished)
        }
        XCTAssertEqual(engine.roundIndex, 3)
    }

    @MainActor
    func testRoundEndCueOnLastSlot() {
        var cues: [SessionCue] = []
        let engine = WorkoutSessionEngine(
            totalRounds: 1,
            slotsForRound: { _ in
                [WorkoutSlot(id: "a", name: "A", timing: .hold(seconds: 10)),
                 WorkoutSlot(id: "b", name: "B", timing: .hold(seconds: 10))]
            },
            onCue: { cues.append($0) }
        )
        engine.advance()               // slot 0 → 1 (not last-of-round yet)
        XCTAssertFalse(cues.contains(.roundEnd))
        engine.advance()               // slot 1 is last → roundEnd, then finished
        XCTAssertTrue(cues.contains(.roundEnd))
        XCTAssertEqual(engine.phase, .finished)
    }

    @MainActor
    func testPerSideTimerEmitsSwitchCountdownAndEnd() async {
        var cues: [SessionCue] = []
        let engine = WorkoutSessionEngine(
            totalRounds: 1,
            slotsForRound: { _ in [WorkoutSlot(id: "a", name: "A", timing: .perSide(secondsEach: 30))] },
            onCue: { cues.append($0) },
            sleepNanos: { _ in }   // run the clock instantly
        )
        engine.start()
        await engine.waitForTimerCompletion()

        XCTAssertEqual(engine.phase, .awaitingLog)
        XCTAssertEqual(cues.filter { $0 == .roundStart }.count, 1)
        XCTAssertEqual(cues.filter { $0 == .segmentBoundary }.count, 1)  // one side switch
        XCTAssertEqual(cues.filter { $0 == .slotEnd }.count, 1)
        XCTAssertEqual(cues.filter { $0 == .countdownTick }.count, 6)    // 3 per side
    }

    @MainActor
    func testAnnounceFiresAtConfiguredSecondsRemaining() async {
        var spoken: [String] = []
        let engine = WorkoutSessionEngine(
            totalRounds: 1,
            slotsForRound: { _ in [WorkoutSlot(id: "a", name: "A", timing: .hold(seconds: 5))] },
            speak: { spoken.append($0) },
            announce: { remaining in
                switch remaining {
                case 3, 2, 1: return "\(remaining)"
                default: return nil
                }
            },
            sleepNanos: { _ in }
        )
        engine.start()
        await engine.waitForTimerCompletion()

        XCTAssertEqual(spoken, ["A", "3", "2", "1"])
    }

    /// A slot whose timer never ticks, so a test can act on it mid-clock.
    @MainActor
    private func heldEngine(seconds: Int) -> WorkoutSessionEngine {
        WorkoutSessionEngine(
            totalRounds: 1,
            slotsForRound: { _ in [WorkoutSlot(id: "a", name: "A", timing: .hold(seconds: seconds))] },
            sleepNanos: { _ in try? await Task.sleep(nanoseconds: 1_000_000_000_000) }
        )
    }

    @MainActor
    func testResumeSlotPicksUpWhereItLeftOff() {
        let engine = heldEngine(seconds: 30)
        engine.start()
        XCTAssertEqual(engine.phase, .running)

        engine.skipToLog()
        XCTAssertEqual(engine.phase, .awaitingLog)
        XCTAssertEqual(engine.secondsRemaining, 30)

        engine.resumeSlot()
        XCTAssertEqual(engine.phase, .running)
        XCTAssertEqual(engine.secondsRemaining, 30)   // not restarted, not lost
        XCTAssertEqual(engine.slotIndex, 0)
    }

    @MainActor
    func testResumeSlotIsNoOpAfterNaturalExpiry() async {
        let engine = WorkoutSessionEngine(
            totalRounds: 1,
            slotsForRound: { _ in [WorkoutSlot(id: "a", name: "A", timing: .hold(seconds: 5))] },
            sleepNanos: { _ in }
        )
        engine.start()
        await engine.waitForTimerCompletion()
        XCTAssertEqual(engine.phase, .awaitingLog)
        XCTAssertEqual(engine.secondsRemaining, 0)

        engine.resumeSlot()
        XCTAssertEqual(engine.phase, .awaitingLog)
    }

    @MainActor
    func testResumeSlotIsNoOpOutsideAwaitingLog() {
        let idle = heldEngine(seconds: 30)
        idle.resumeSlot()
        XCTAssertEqual(idle.phase, .idle)

        let running = heldEngine(seconds: 30)
        running.start()
        running.resumeSlot()
        XCTAssertEqual(running.phase, .running)
        XCTAssertEqual(running.secondsRemaining, 30)

        let cancelled = heldEngine(seconds: 30)
        cancelled.start()
        cancelled.cancel()
        cancelled.resumeSlot()
        XCTAssertEqual(cancelled.phase, .finished)
    }

    @MainActor
    func testResumeStartsMidSession() {
        let engine = WorkoutSessionEngine(
            totalRounds: 3,
            startingRound: 1,
            startingSlot: 1,
            slotsForRound: { _ in [WorkoutSlot(id: "a", name: "A", timing: .hold(seconds: 30))] }
        )
        XCTAssertEqual(engine.roundIndex, 1)
        XCTAssertEqual(engine.slotIndex, 1)
    }
}

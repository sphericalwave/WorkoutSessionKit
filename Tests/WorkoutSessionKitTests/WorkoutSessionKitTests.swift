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

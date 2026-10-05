import XCTest
import UsageBarLogic

final class ThresholdEvaluatorTests: XCTestCase {
    private let standard = [50, 75, 90]

    // MARK: - Below the lowest threshold

    func test_zeroPercent_doesNothing() {
        let d = ThresholdEvaluator.evaluate(percent: 0, lastNotified: 0, thresholds: standard)
        XCTAssertNil(d.notify)
        XCTAssertEqual(d.newLastNotified, 0)
    }

    func test_belowLowestThreshold_doesNothing() {
        let d = ThresholdEvaluator.evaluate(percent: 30, lastNotified: 0, thresholds: standard)
        XCTAssertNil(d.notify)
        XCTAssertEqual(d.newLastNotified, 0)
    }

    func test_oneShortOfLowestThreshold_doesNothing() {
        let d = ThresholdEvaluator.evaluate(percent: 49, lastNotified: 0, thresholds: standard)
        XCTAssertNil(d.notify)
        XCTAssertEqual(d.newLastNotified, 0)
    }

    // MARK: - Exact threshold crossings

    func test_exactlyAt50_fires50() {
        let d = ThresholdEvaluator.evaluate(percent: 50, lastNotified: 0, thresholds: standard)
        XCTAssertEqual(d.notify, 50)
        XCTAssertEqual(d.newLastNotified, 50)
    }

    func test_exactlyAt75FromZero_firesOnlyTopCrossed() {
        // Don't double-fire 50 and 75; pick the highest newly crossed.
        let d = ThresholdEvaluator.evaluate(percent: 75, lastNotified: 0, thresholds: standard)
        XCTAssertEqual(d.notify, 75)
        XCTAssertEqual(d.newLastNotified, 75)
    }

    func test_exactlyAt90FromZero_fires90Only() {
        let d = ThresholdEvaluator.evaluate(percent: 90, lastNotified: 0, thresholds: standard)
        XCTAssertEqual(d.notify, 90)
        XCTAssertEqual(d.newLastNotified, 90)
    }

    // MARK: - Multi-threshold jumps

    func test_jumpFromZeroTo80_firesOnly75() {
        let d = ThresholdEvaluator.evaluate(percent: 80, lastNotified: 0, thresholds: standard)
        XCTAssertEqual(d.notify, 75)
        XCTAssertEqual(d.newLastNotified, 75)
    }

    func test_jumpFromZeroTo100_firesOnly90() {
        let d = ThresholdEvaluator.evaluate(percent: 100, lastNotified: 0, thresholds: standard)
        XCTAssertEqual(d.notify, 90)
        XCTAssertEqual(d.newLastNotified, 90)
    }

    // MARK: - Already notified for current band

    func test_climbingInsideBand_doesNotRefire() {
        let d = ThresholdEvaluator.evaluate(percent: 60, lastNotified: 50, thresholds: standard)
        XCTAssertNil(d.notify)
        XCTAssertEqual(d.newLastNotified, 50)
    }

    func test_stayingAtSameThreshold_doesNotRefire() {
        let d = ThresholdEvaluator.evaluate(percent: 50, lastNotified: 50, thresholds: standard)
        XCTAssertNil(d.notify)
        XCTAssertEqual(d.newLastNotified, 50)
    }

    func test_climbingPastNextThreshold_firesNext() {
        let d = ThresholdEvaluator.evaluate(percent: 75, lastNotified: 50, thresholds: standard)
        XCTAssertEqual(d.notify, 75)
        XCTAssertEqual(d.newLastNotified, 75)
    }

    func test_climbingTo90_afterPriorAt75_fires90() {
        let d = ThresholdEvaluator.evaluate(percent: 95, lastNotified: 75, thresholds: standard)
        XCTAssertEqual(d.notify, 90)
        XCTAssertEqual(d.newLastNotified, 90)
    }

    func test_atTopBand_alreadyNotified_doesNothing() {
        let d = ThresholdEvaluator.evaluate(percent: 100, lastNotified: 90, thresholds: standard)
        XCTAssertNil(d.notify)
        XCTAssertEqual(d.newLastNotified, 90)
    }

    // MARK: - Rollover

    func test_dropFar_belowLowest_resetsState() {
        // Simulates a new billing cycle: usage falls from 90+% back to single
        // digits. State should clear so the next climb re-notifies for each
        // threshold.
        let d = ThresholdEvaluator.evaluate(percent: 5, lastNotified: 90, thresholds: standard)
        XCTAssertNil(d.notify)
        XCTAssertEqual(d.newLastNotified, 0)
    }

    func test_dropJustBelowLowest_resetsState() {
        let d = ThresholdEvaluator.evaluate(percent: 49, lastNotified: 75, thresholds: standard)
        XCTAssertNil(d.notify)
        XCTAssertEqual(d.newLastNotified, 0)
    }

    func test_dropButStillAboveLowest_keepsState() {
        // The user got a small refund / refresh and usage moved 75 -> 60.
        // Don't reset; they'd be re-notified for 75 on the next climb.
        let d = ThresholdEvaluator.evaluate(percent: 60, lastNotified: 75, thresholds: standard)
        XCTAssertNil(d.notify)
        XCTAssertEqual(d.newLastNotified, 75)
    }

    // MARK: - Configurability

    func test_customThresholds_useProvidedList() {
        let d = ThresholdEvaluator.evaluate(percent: 25, lastNotified: 0, thresholds: [25, 50])
        XCTAssertEqual(d.notify, 25)
        XCTAssertEqual(d.newLastNotified, 25)
    }

    func test_unsortedThresholds_sortInternally() {
        // Caller shouldn't have to pre-sort; we still pick the highest crossed.
        let d = ThresholdEvaluator.evaluate(percent: 80, lastNotified: 0, thresholds: [75, 50, 90])
        XCTAssertEqual(d.notify, 75)
        XCTAssertEqual(d.newLastNotified, 75)
    }

    func test_emptyThresholdsList_doesNothing() {
        let d = ThresholdEvaluator.evaluate(percent: 100, lastNotified: 0, thresholds: [])
        XCTAssertNil(d.notify)
        XCTAssertEqual(d.newLastNotified, 0)
    }

    // MARK: - Full lifecycle

    func test_fullCycle_notifiesEachBandOnceThenResetsOnRollover() {
        var state = 0

        // Climb to 50 — fire 50.
        var d = ThresholdEvaluator.evaluate(percent: 52, lastNotified: state, thresholds: standard)
        XCTAssertEqual(d.notify, 50)
        state = d.newLastNotified

        // Climb inside the 50 band — no fire.
        d = ThresholdEvaluator.evaluate(percent: 65, lastNotified: state, thresholds: standard)
        XCTAssertNil(d.notify)
        state = d.newLastNotified

        // Cross 75 — fire 75.
        d = ThresholdEvaluator.evaluate(percent: 76, lastNotified: state, thresholds: standard)
        XCTAssertEqual(d.notify, 75)
        state = d.newLastNotified

        // Cross 90 — fire 90.
        d = ThresholdEvaluator.evaluate(percent: 91, lastNotified: state, thresholds: standard)
        XCTAssertEqual(d.notify, 90)
        state = d.newLastNotified

        // Top out at 100 — no extra fire.
        d = ThresholdEvaluator.evaluate(percent: 100, lastNotified: state, thresholds: standard)
        XCTAssertNil(d.notify)
        state = d.newLastNotified

        // New billing cycle: drops to 5 — state resets.
        d = ThresholdEvaluator.evaluate(percent: 5, lastNotified: state, thresholds: standard)
        XCTAssertNil(d.notify)
        XCTAssertEqual(d.newLastNotified, 0)
        state = d.newLastNotified

        // Climb back to 51 — should fire 50 again.
        d = ThresholdEvaluator.evaluate(percent: 51, lastNotified: state, thresholds: standard)
        XCTAssertEqual(d.notify, 50)
        XCTAssertEqual(d.newLastNotified, 50)
    }
}

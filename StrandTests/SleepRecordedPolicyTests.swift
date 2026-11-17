import XCTest
@testable import Strand

/// `SleepRecordedNotifier.SleepRecordedPolicy` — optional once-per-day main-sleep gate + copy.
/// No notification/UserDefaults runtime. Contract: default-off, fire at most once per local day
/// when the main sleep is detected, never for a nap or a missing performance figure.
final class SleepRecordedPolicyTests: XCTestCase {
    private typealias Policy = SleepRecordedNotifier.SleepRecordedPolicy

    func testFiresWhenEnabledMainSleepEndedWithHoursAndPerformance() {
        XCTAssertTrue(Policy.shouldNotify(
            enabled: true, asleepMinutes: 432, sleepPerformance: 92,
            isMainSleep: true, sleepEnded: true,
            lastNotifiedDay: "2026-07-17", today: "2026-07-18"))
    }

    func testSuppressedWhenDisabled() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: false, asleepMinutes: 432, sleepPerformance: 92,
            isMainSleep: true, sleepEnded: true,
            lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testSuppressedWhenAlreadyFiredToday() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, asleepMinutes: 432, sleepPerformance: 92,
            isMainSleep: true, sleepEnded: true,
            lastNotifiedDay: "2026-07-18", today: "2026-07-18"))
    }

    func testSuppressedForNap() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, asleepMinutes: 40, sleepPerformance: 88,
            isMainSleep: false, sleepEnded: true,
            lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testSuppressedWithoutHoursOrPerformance() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, asleepMinutes: nil, sleepPerformance: 92,
            isMainSleep: true, sleepEnded: true,
            lastNotifiedDay: nil, today: "2026-07-18"))
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, asleepMinutes: 0, sleepPerformance: 92,
            isMainSleep: true, sleepEnded: true,
            lastNotifiedDay: nil, today: "2026-07-18"))
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, asleepMinutes: 432, sleepPerformance: nil,
            isMainSleep: true, sleepEnded: true,
            lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testSuppressedWhileSleepStillInProgress() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, asleepMinutes: 432, sleepPerformance: 92,
            isMainSleep: true, sleepEnded: false,
            lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testHoursTextAndCopy() {
        XCTAssertEqual(Policy.hoursText(asleepMinutes: 432), "7h 12m")
        XCTAssertEqual(Policy.hoursText(asleepMinutes: 420), "7h")
        XCTAssertEqual(Policy.displayedPercent(91.6), 92)
        XCTAssertEqual(Policy.displayedPercent(91.6),
                       Int(NativeScoreMath.percentValue(NativeScoreMath.percent(91.6)) ?? -1))
        XCTAssertEqual(Policy.napMaxMinutes, RecoveryReadyNotifier.RecoveryReadyPolicy.napMaxMinutes)
        let copy = Policy.copy(asleepMinutes: 432, performancePercent: 92)
        XCTAssertEqual(copy.title, "Sleep recorded.")
        XCTAssertTrue(copy.body.contains("7h 12m"))
        XCTAssertTrue(copy.body.contains("92%"))
        XCTAssertTrue(copy.body.contains("sleep performance"))
    }
}

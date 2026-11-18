import XCTest
@testable import Strand

/// `RecoveryReadyNotifier.RecoveryReadyPolicy` — once-per-day post-wake recovery-ready gate + copy.
/// No notification/UserDefaults runtime. Contract: fire at most once per local day, only for today's
/// own recovery after the main sleep ends, never for a nap or a recomputation of an already-notified day.
final class RecoveryReadyPolicyTests: XCTestCase {
    private typealias Policy = RecoveryReadyNotifier.RecoveryReadyPolicy

    func testFiresWhenEnabledMainSleepEndedAndNotYetToday() {
        XCTAssertTrue(Policy.shouldNotify(
            enabled: true, recovery: 67, isMainSleep: true, sleepEnded: true,
            lastNotifiedDay: "2026-07-17", today: "2026-07-18"))
    }

    func testSuppressedWhenDisabled() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: false, recovery: 80, isMainSleep: true, sleepEnded: true,
            lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testSuppressedWhenAlreadyFiredToday() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, recovery: 80, isMainSleep: true, sleepEnded: true,
            lastNotifiedDay: "2026-07-18", today: "2026-07-18"))
    }

    func testSuppressedWhenRecoveryUnknown() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, recovery: nil, isMainSleep: true, sleepEnded: true,
            lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testSuppressedForNap() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, recovery: 70, isMainSleep: false, sleepEnded: true,
            lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testSuppressedWhileMainSleepStillInProgress() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, recovery: 70, isMainSleep: true, sleepEnded: false,
            lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testNapCeilingMatchesDetector() {
        XCTAssertFalse(Policy.isMainSleep(durationMinutes: 90))
        XCTAssertFalse(Policy.isMainSleep(durationMinutes: 45))
        XCTAssertTrue(Policy.isMainSleep(durationMinutes: 91))
        XCTAssertTrue(Policy.isMainSleep(durationMinutes: 480))
    }

    func testDisplayedPercentMatchesHomeRingRounding() {
        XCTAssertEqual(Policy.displayedPercent(66.4), 66)
        XCTAssertEqual(Policy.displayedPercent(66.5), 67)
        XCTAssertEqual(Policy.displayedPercent(33.4), 33)
        XCTAssertEqual(Policy.displayedPercent(33.6), 34)
        // Same integer the Home ring prints and then tints from.
        XCTAssertEqual(Policy.displayedPercent(66.5),
                       Int(NativeScoreMath.percentValue(NativeScoreMath.percent(66.5)) ?? -1))
        XCTAssertEqual(NativeChrome.recoveryBandIndex(Double(Policy.displayedPercent(33.6))), 1)
    }

    func testZoneWordMatchesHomeBandIndex() {
        XCTAssertEqual(Policy.zoneWord(percent: 33), "red")
        XCTAssertEqual(Policy.zoneWord(percent: 34), "yellow")
        XCTAssertEqual(Policy.zoneWord(percent: 66), "yellow")
        XCTAssertEqual(Policy.zoneWord(percent: 67), "green")
    }

    func testDriverOnlyWhenHrvZAtOrBelowMinusOne() {
        XCTAssertEqual(Policy.driverLine(hrvZ: -1), "HRV well below your baseline")
        XCTAssertEqual(Policy.driverLine(hrvZ: -1.4), "HRV well below your baseline")
        XCTAssertNil(Policy.driverLine(hrvZ: -0.99))
        XCTAssertNil(Policy.driverLine(hrvZ: 0))
        XCTAssertNil(Policy.driverLine(hrvZ: nil))
    }

    func testCopyStatesPercentZoneAndOptionalDriver() {
        let plain = Policy.copy(percent: 72, hrvZ: 0.2)
        XCTAssertEqual(plain.title, "Your Recovery is ready.")
        XCTAssertTrue(plain.body.contains("72%"))
        XCTAssertTrue(plain.body.contains("green"))
        XCTAssertFalse(plain.body.contains("HRV"))

        let driven = Policy.copy(percent: 28, hrvZ: -1.2)
        XCTAssertTrue(driven.body.contains("28%"))
        XCTAssertTrue(driven.body.contains("red"))
        XCTAssertTrue(driven.body.contains("HRV well below your baseline"))
    }
}

import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// `HealthMonitorNotifier.HealthMonitorPolicy` — once-per-morning Health Monitor out-of-range
/// gate + copy. Flags come from `NativeHealthRange.report`; this suite never re-judges a vital.
@MainActor
final class HealthMonitorPolicyTests: XCTestCase {
    private typealias Policy = HealthMonitorNotifier.HealthMonitorPolicy

    func testFlagsMatchTheSharedHealthMonitorReport() {
        let days = series(
            today: "2026-11-16", prior: 20,
            hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5,
            todayRhr: 80
        )
        let report = NativeHealthRange.report(days: days, todayKey: "2026-11-16")
        let flags = Policy.flags(from: report)
        XCTAssertEqual(flags.map(\.id), report.vitals.filter(\.flagged).map(\.id))
        XCTAssertEqual(flags.map(\.status), report.vitals.filter(\.flagged).map(\.status))
        XCTAssertEqual(flags, [Policy.Flag(id: "rhr", status: .above)])
        XCTAssertEqual(Policy.body(flags), "Resting HR is above your typical range.")
    }

    func testTwoAboveMetricsUseAndAre() {
        let days = series(
            today: "2026-11-16", prior: 20,
            hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5,
            todayRhr: 80, todayResp: 22
        )
        let report = NativeHealthRange.report(days: days, todayKey: "2026-11-16")
        let flags = Policy.flags(from: report)
        XCTAssertEqual(Set(flags.map(\.id)), ["rhr", "resp"])
        XCTAssertTrue(flags.allSatisfy { $0.status == .above })
        XCTAssertEqual(Policy.body(flags), "Resting HR and respiratory rate are above your typical range.")
    }

    func testLowHrvIsBelowAndHighHrvIsAbove() {
        let low = series(
            today: "2026-11-16", prior: 20,
            hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5,
            todayHrv: 20
        )
        let lowFlags = Policy.flags(from: NativeHealthRange.report(days: low, todayKey: "2026-11-16"))
        XCTAssertEqual(lowFlags, [Policy.Flag(id: "hrv", status: .below)])
        XCTAssertEqual(Policy.body(lowFlags), "HRV is below your typical range.")

        let high = series(
            today: "2026-11-16", prior: 20,
            hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5,
            todayHrv: 140
        )
        // Out of range in either direction is outside, matching the Home tile's count.
        let highReport = NativeHealthRange.report(days: high, todayKey: "2026-11-16")
        XCTAssertEqual(Policy.flags(from: highReport), [Policy.Flag(id: "hrv", status: .above)])
        XCTAssertEqual(highReport.summary.outside, 1)
    }

    func testMixedDirectionsJoinWithAnd() {
        let days = series(
            today: "2026-11-16", prior: 20,
            hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5,
            todayHrv: 20, todayRhr: 80
        )
        let flags = Policy.flags(from: NativeHealthRange.report(days: days, todayKey: "2026-11-16"))
        XCTAssertEqual(Policy.body(flags),
                       "Resting HR is above your typical range and HRV is below your typical range.")
    }

    func testFiresWhenEnabledMainSleepEndedWithFlagsAndEnoughNights() {
        XCTAssertTrue(Policy.shouldNotify(
            enabled: true, flags: [Policy.Flag(id: "rhr", status: .above)],
            isMainSleep: true, sleepEnded: true, nightsWorn: 7,
            illnessPostedToday: false, lastNotifiedDay: "2026-11-15", today: "2026-11-16"))
    }

    func testSuppressedWhenDisabledAlreadyFiredNapOrStillAsleep() {
        let flag = [Policy.Flag(id: "rhr", status: .above)]
        XCTAssertFalse(Policy.shouldNotify(
            enabled: false, flags: flag, isMainSleep: true, sleepEnded: true, nightsWorn: 14,
            illnessPostedToday: false, lastNotifiedDay: nil, today: "2026-11-16"))
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, flags: flag, isMainSleep: true, sleepEnded: true, nightsWorn: 14,
            illnessPostedToday: false, lastNotifiedDay: "2026-11-16", today: "2026-11-16"))
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, flags: flag, isMainSleep: false, sleepEnded: true, nightsWorn: 14,
            illnessPostedToday: false, lastNotifiedDay: nil, today: "2026-11-16"))
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, flags: flag, isMainSleep: true, sleepEnded: false, nightsWorn: 14,
            illnessPostedToday: false, lastNotifiedDay: nil, today: "2026-11-16"))
    }

    func testSuppressedWhileCalibratingAndWhenNothingIsFlagged() {
        XCTAssertEqual(NativeHealthMonitorMath.calibrateNights, 7)
        XCTAssertTrue(Policy.isCalibrating(nightsWorn: 6))
        XCTAssertFalse(Policy.isCalibrating(nightsWorn: 7))
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, flags: [Policy.Flag(id: "rhr", status: .above)],
            isMainSleep: true, sleepEnded: true, nightsWorn: 6,
            illnessPostedToday: false, lastNotifiedDay: nil, today: "2026-11-16"))
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, flags: [], isMainSleep: true, sleepEnded: true, nightsWorn: 14,
            illnessPostedToday: false, lastNotifiedDay: nil, today: "2026-11-16"))
        let building = NativeHealthRange.report(
            days: [sampleMetric(day: "2026-11-16", hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5)],
            todayKey: "2026-11-16")
        XCTAssertEqual(building.summary.caption, "Building baseline")
        XCTAssertTrue(Policy.flags(from: building).isEmpty)
    }

    func testYieldsWhenIllnessNotifierAlreadyPostedThisMorning() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, flags: [Policy.Flag(id: "rhr", status: .above)],
            isMainSleep: true, sleepEnded: true, nightsWorn: 14,
            illnessPostedToday: true, lastNotifiedDay: nil, today: "2026-11-16"))
    }

    func testCopyTitleIsHealthMonitor() {
        let copy = Policy.copy([Policy.Flag(id: "rhr", status: .above)])
        XCTAssertEqual(copy?.title, "Health Monitor")
        XCTAssertEqual(copy?.body, "Resting HR is above your typical range.")
        XCTAssertNil(Policy.copy([]))
    }

    private func series(
        today: String, prior: Int,
        hrv: Double, rhr: Int, resp: Double, spo2: Double, skin: Double,
        todayHrv: Double? = nil, todayRhr: Int? = nil, todayResp: Double? = nil
    ) -> [DailyMetric] {
        var days: [DailyMetric] = []
        for offset in (1...prior).reversed() {
            days.append(sampleMetric(
                day: shift(today, -offset),
                hrv: hrv, rhr: rhr, resp: resp, spo2: spo2, skin: skin
            ))
        }
        days.append(sampleMetric(
            day: today,
            hrv: todayHrv ?? hrv,
            rhr: todayRhr ?? rhr,
            resp: todayResp ?? resp, spo2: spo2, skin: skin
        ))
        return days
    }

    private func shift(_ key: String, _ days: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = formatter.date(from: key)!
        return formatter.string(from: calendar.date(byAdding: .day, value: days, to: date)!)
    }

    private func sampleMetric(day: String, hrv: Double? = nil, rhr: Int? = nil,
                              resp: Double? = nil, spo2: Double? = nil, skin: Double? = nil) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: nil,
            exerciseCount: nil, spo2Pct: spo2, skinTempDevC: skin, respRateBpm: resp
        )
    }
}

import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins the Native Home empty-store predicate and Health Monitor range summary.
@MainActor
final class NativeEmptyStateTests: XCTestCase {

    func testEmptyStoreIsTrueOnlyWhenDaysSleepsAndImportAreAllEmpty() {
        XCTAssertTrue(
            NativeDayLogic.isEmptyStore(days: [], sleeps: [], importedSleep: [:]),
            "the no-data card is the global empty: no days, no sleeps, no WHOOP import"
        )

        let day = sampleMetric(day: "2026-11-16", hrv: 66, rhr: 51)
        XCTAssertFalse(NativeDayLogic.isEmptyStore(days: [day], sleeps: [], importedSleep: [:]))

        let sleep = CachedSleepSession(
            startTs: 1, endTs: 2, efficiency: 0.9, restingHr: 50, avgHrv: 60, stagesJSON: nil
        )
        XCTAssertFalse(NativeDayLogic.isEmptyStore(days: [], sleeps: [sleep], importedSleep: [:]))

        let imported = ["2026-11-16": ImportedSleepFigures(performancePct: 87, consistencyPct: nil,
                                                           needMin: 480, debtMin: 20)]
        XCTAssertFalse(NativeDayLogic.isEmptyStore(days: [], sleeps: [], importedSleep: imported))
    }

    func testPastEmptyDayScoresAreDashNotZero() {
        let other = sampleMetric(day: "2026-11-10", hrv: 66, rhr: 51, recovery: 49, strain: 34, sleepMin: 431)
        let model = NativeDay.make(
            days: [other], sleeps: [], workouts: [],
            todayKey: "2026-11-12",
            connected: false,
            effortScale: .whoop,
            now: localDate(year: 2026, month: 11, day: 16, hour: 10, minute: 0)
        )
        XCTAssertFalse(model.sleep.known)
        XCTAssertEqual(model.sleep.value, "—")
        XCTAssertNil(model.sleep.fraction)
        XCTAssertFalse(model.recovery.known)
        XCTAssertEqual(model.recovery.value, "—")
        XCTAssertNil(model.recovery.fraction)
        XCTAssertFalse(model.strain.known)
        XCTAssertEqual(model.strain.value, "—")
        XCTAssertNil(model.strain.fraction)
    }

    func testWithinRangeCountsOnlyMetricsWithData() {
        let today = sampleMetric(
            day: "2026-11-16",
            hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5
        )
        let summary = NativeHealthRange.summary(days: [today], todayKey: today.day)
        XCTAssertEqual(summary.measured, 5)
        XCTAssertEqual(summary.judged, 0)
        XCTAssertEqual(summary.outside, 0)
        XCTAssertEqual(summary.caption, "Building baseline")
        XCTAssertEqual(summary.headerTrailing, "Building baseline")
    }

    func testWithinRangeOmitsMissingMetricsWhileBuilding() {
        let today = sampleMetric(day: "2026-11-16", hrv: 30, rhr: 51, resp: 14.7)
        let summary = NativeHealthRange.summary(days: [today], todayKey: today.day)
        XCTAssertEqual(summary.measured, 3, "skin temp and SpO2 have no value and must not count")
        XCTAssertEqual(summary.judged, 0)
        XCTAssertEqual(summary.caption, "Building baseline")
        XCTAssertEqual(summary.headerTrailing, "Building baseline")
    }

    func testWithinRangeIsNilWhenTheDayHasNoVitals() {
        let today = sampleMetric(day: "2026-11-16")
        let summary = NativeHealthRange.summary(days: [today], todayKey: today.day)
        XCTAssertEqual(summary.measured, 0)
        XCTAssertEqual(summary.inRange, 0)
        XCTAssertNil(summary.caption)
        XCTAssertNil(summary.headerTrailing)
    }

    func testHealthMonitorReportAndSummaryAreTheSameCount() {
        let today = sampleMetric(
            day: "2026-11-16",
            hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5
        )
        let report = NativeHealthRange.report(days: [today], todayKey: today.day)
        let summary = NativeHealthRange.summary(days: [today], todayKey: today.day)
        XCTAssertEqual(report.summary, summary)
        XCTAssertEqual(report.vitals.count, summary.measured)
        XCTAssertEqual(report.vitals.filter(\.inRange).count, summary.inRange)
        XCTAssertEqual(Set(report.vitals.map(\.id)), ["hrv", "rhr", "resp", "skin", "spo2"])
        XCTAssertEqual(report.vitals.map(\.route), [
            .metric("hrv"), .metric("rhr"), .metric("resp_rate"), .metric("skin_temp"), .metric("spo2"),
        ])
    }

    func testHealthMonitorHidesRowsWithoutData() {
        let today = sampleMetric(day: "2026-11-16", hrv: 66, rhr: 51)
        let report = NativeHealthRange.report(days: [today], todayKey: today.day)
        XCTAssertEqual(report.vitals.map(\.id), ["hrv", "rhr"])
        XCTAssertEqual(report.summary, NativeHealthRange.summary(days: [today], todayKey: today.day))
    }

    func testTonightSleepHidesWithoutNeedOrAlarm() {
        XCTAssertNil(NativeTonightSleep.make(needMin: nil, alarmEnabled: false, alarmMinutes: 7 * 60))
        XCTAssertNil(NativeTonightSleep.make(needMin: 0, alarmEnabled: false, alarmMinutes: 7 * 60))
    }

    func testTonightSleepBedtimeIsWakeMinusNeed() {
        let model = NativeTonightSleep.make(needMin: 480, alarmEnabled: true, alarmMinutes: 7 * 60)
        XCTAssertEqual(model?.wakeClock, "7:00 AM")
        XCTAssertEqual(model?.bedtimeClock, "11:00 PM")
        XCTAssertEqual(model?.needClock, "8 hr")
    }

    func testTonightSleepShowsNeedAloneWhenAlarmIsOff() {
        let model = NativeTonightSleep.make(needMin: 465, alarmEnabled: false, alarmMinutes: 7 * 60)
        XCTAssertNil(model?.wakeClock)
        XCTAssertNil(model?.bedtimeClock)
        XCTAssertEqual(model?.needClock, "7 hr 45 min")
    }

    func testStrainOnlyDayKeepsEmptySleepAndRecoveryRings() {
        let day = sampleMetric(day: "2026-11-16", strain: 34)
        let model = NativeDay.make(
            days: [day], sleeps: [], workouts: [],
            todayKey: day.day,
            connected: false,
            effortScale: .whoop,
            now: localDate(year: 2026, month: 11, day: 16, hour: 10, minute: 0)
        )
        XCTAssertFalse(model.sleep.known)
        XCTAssertEqual(model.sleep.value, "—")
        XCTAssertNil(model.sleep.fraction)
        XCTAssertFalse(model.recovery.known)
        XCTAssertEqual(model.recovery.value, "—")
        XCTAssertNil(model.recovery.fraction)
        XCTAssertTrue(model.strain.known)
        XCTAssertEqual(model.strain.value, NativeDayLogic.strainText(34, scale: .whoop))
        XCTAssertNil(model.dashboard.first { $0.title == "Heart Rate Variability" }.flatMap {
            NativeScoreMath.hasValue($0.value) ? $0.value : nil
        })
    }

    func testRespiratoryTrailingUnitIsRpmWithFullAccessibility() throws {
        let today = sampleMetric(day: "2026-11-16", hrv: 66, rhr: 51, resp: 14.7)
        let report = NativeHealthRange.report(days: [today], todayKey: today.day)
        let resp = try XCTUnwrap(report.vitals.first { $0.id == "resp" })
        XCTAssertEqual(resp.valueText, "14.7 breaths/min")
        XCTAssertEqual(NativeHealthMonitorFormat.trailingValue(resp), "14.7 rpm")
        let label = NativeHealthMonitorFormat.accessibilityLabel(resp)
        XCTAssertTrue(label.contains("Respiratory Rate"))
        XCTAssertTrue(label.contains("breaths/min"))
        XCTAssertTrue(label.contains("Calibrating range"))
        XCTAssertFalse(label.contains(" rpm"))
        XCTAssertFalse(label.contains("Out of Range"))
        XCTAssertFalse(label.contains("In Range"))
        let hrv = try XCTUnwrap(report.vitals.first { $0.id == "hrv" })
        XCTAssertEqual(NativeHealthMonitorFormat.trailingValue(hrv), hrv.valueText)
    }

    private func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func sampleMetric(day: String, hrv: Double? = nil, rhr: Int? = nil,
                              resp: Double? = nil, spo2: Double? = nil, skin: Double? = nil,
                              recovery: Double? = nil, strain: Double? = nil,
                              sleepMin: Double? = nil) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: sleepMin, efficiency: sleepMin == nil ? nil : 0.87,
            deepMin: sleepMin == nil ? nil : 70, remMin: sleepMin == nil ? nil : 90,
            lightMin: sleepMin == nil ? nil : 250,
            disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: recovery, strain: strain,
            exerciseCount: nil, spo2Pct: spo2, skinTempDevC: skin, respRateBpm: resp
        )
    }
}

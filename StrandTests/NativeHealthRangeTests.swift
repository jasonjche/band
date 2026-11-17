import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

@MainActor
final class NativeHealthRangeTests: XCTestCase {

    func testFourteenPriorNightsProduceATypicalRangeAndAllWithinRange() {
        let days = series(today: "2026-11-16", prior: 20, hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5)
        let report = NativeHealthRange.report(days: days, todayKey: "2026-11-16")
        XCTAssertEqual(report.summary.caption, "All within range")
        XCTAssertEqual(report.summary.headerTrailing, "All within range")
        XCTAssertEqual(report.summary.outside, 0)
        XCTAssertEqual(report.summary.judged, 5)
        XCTAssertEqual(report.vitals.count, 5)
        XCTAssertTrue(report.vitals.allSatisfy { $0.typical != nil })
        XCTAssertTrue(report.vitals.allSatisfy(\.inRange))
        XCTAssertTrue(report.vitals.allSatisfy { !$0.flagged })
        let hrv = report.vitals.first { $0.id == "hrv" }
        XCTAssertEqual(hrv?.typicalText.isEmpty, false)
        XCTAssertEqual(
            NativeTypicalRange.band(values: days.dropLast().suffix(30).map(\.avgHrv), cfg: Baselines.hrvCfg)?.lowerBound ?? -1,
            hrv?.typical?.lowerBound ?? -1,
            accuracy: 1e-9
        )
    }

    func testHighRestingHeartRateIsOutsideRange() throws {
        let days = series(
            today: "2026-11-16", prior: 20,
            hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5,
            todayRhr: 80
        )
        let report = NativeHealthRange.report(days: days, todayKey: "2026-11-16")
        XCTAssertEqual(report.summary.caption, "1 outside range")
        let rhr = report.vitals.first { $0.id == "rhr" }
        XCTAssertEqual(rhr?.flagged, true)
        XCTAssertEqual(rhr?.status, .above)
        XCTAssertEqual(rhr?.inRange, false)
        XCTAssertTrue(NativeHealthMonitorFormat.accessibilityLabel(try XCTUnwrap(rhr)).contains("Outside your typical range"))
    }

    func testLowHrvIsOutsideRangeAndHighHrvIsNot() {
        let low = series(
            today: "2026-11-16", prior: 20,
            hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5,
            todayHrv: 20
        )
        let lowReport = NativeHealthRange.report(days: low, todayKey: "2026-11-16")
        XCTAssertEqual(lowReport.vitals.first { $0.id == "hrv" }?.flagged, true)
        XCTAssertEqual(lowReport.vitals.first { $0.id == "hrv" }?.status, .below)

        let high = series(
            today: "2026-11-16", prior: 20,
            hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5,
            todayHrv: 140
        )
        let highReport = NativeHealthRange.report(days: high, todayKey: "2026-11-16")
        XCTAssertEqual(highReport.vitals.first { $0.id == "hrv" }?.flagged, false)
        XCTAssertEqual(highReport.vitals.first { $0.id == "hrv" }?.status, .above)
        XCTAssertEqual(highReport.summary.caption, "All within range")
    }

    func testSpo2AbsoluteRailFlagsEvenWithoutABaseline() {
        let today = sampleMetric(day: "2026-11-16", spo2: 88)
        let report = NativeHealthRange.report(days: [today], todayKey: today.day)
        let spo2 = report.vitals.first { $0.id == "spo2" }
        XCTAssertEqual(spo2?.flagged, true)
        XCTAssertEqual(spo2?.status, .below)
        XCTAssertEqual(report.summary.caption, "1 outside range")
    }

    func testSkinTemperatureHonoursFahrenheit() throws {
        let days = series(today: "2026-11-16", prior: 20, hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5)
        let c = NativeHealthRange.report(days: days, todayKey: "2026-11-16", temperature: .celsius)
        let f = NativeHealthRange.report(days: days, todayKey: "2026-11-16", temperature: .fahrenheit)
        let cSkin = try XCTUnwrap(c.vitals.first { $0.id == "skin" })
        let fSkin = try XCTUnwrap(f.vitals.first { $0.id == "skin" })
        XCTAssertTrue(cSkin.valueText.contains("°C"))
        XCTAssertTrue(fSkin.valueText.contains("°F"))
        XCTAssertEqual(cSkin.unit, "°C")
        XCTAssertEqual(fSkin.unit, "°F")
        XCTAssertEqual(fSkin.value, UnitFormatter.celsiusToFahrenheit(34.5), accuracy: 1e-9)
        XCTAssertNotEqual(cSkin.typicalText, fSkin.typicalText)
    }

    func testWindowIgnoresNightsOlderThanThirtyDays() {
        var days = series(today: "2026-11-16", prior: 20, hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5)
        days.insert(sampleMetric(day: "2026-09-01", hrv: 20, rhr: 90, resp: 22), at: 0)
        let report = NativeHealthRange.report(days: days, todayKey: "2026-11-16")
        XCTAssertEqual(report.summary.caption, "All within range")
        XCTAssertEqual(report.vitals.first { $0.id == "hrv" }?.flagged, false)
    }

    private func series(
        today: String, prior: Int,
        hrv: Double, rhr: Int, resp: Double, spo2: Double, skin: Double,
        todayHrv: Double? = nil, todayRhr: Int? = nil
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
            resp: resp, spo2: spo2, skin: skin
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

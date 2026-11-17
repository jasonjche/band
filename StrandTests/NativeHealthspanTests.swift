import XCTest
@testable import Strand
import WhoopStore
import StrandAnalytics

final class NativeHealthspanTests: XCTestCase {

    func testYoungerCopy() {
        XCTAssertEqual(NativeHealthspanFormat.youngerText(1.9), "1.9 years younger")
        XCTAssertEqual(NativeHealthspanFormat.youngerText(-0.8), "0.8 years older")
        XCTAssertEqual(NativeHealthspanFormat.youngerText(0), "Same as your age")
    }

    func testPaceAndAgeText() {
        XCTAssertEqual(NativeHealthspanFormat.paceText(1.3), "1.3x")
        XCTAssertEqual(NativeHealthspanFormat.ageText(21.8), "21.8")
        XCTAssertEqual(NativeHealthspanFormat.yearsImpact(0.5, available: true), "+0.5 years")
        XCTAssertEqual(NativeHealthspanFormat.yearsImpact(-1.4, available: true), "-1.4 years")
        XCTAssertEqual(NativeHealthspanFormat.yearsImpact(0.0, available: true), "0.0 years")
        XCTAssertEqual(NativeHealthspanFormat.yearsImpact(nil, available: false), "—")
    }

    func testCalibrationCopyNamesSixMonths() {
        let body = NativeHealthspanFormat.calibrationBody(days: 40)
        XCTAssertTrue(body.contains("6-month"))
        XCTAssertTrue(body.contains("30 days"))
        XCTAssertTrue(body.contains("40 days"))
        XCTAssertEqual(NativeHealthspanFormat.calibrationTitle(.calibrating, days: 40), "Calibrating Band Age")
        XCTAssertEqual(NativeHealthspanFormat.calibrationTitle(.notReady, days: 5), "Not enough data yet")
    }

    func testChronoAgeFromDOB() {
        let dob = Date(timeIntervalSince1970: 0)
        let asOf = Date(timeIntervalSince1970: 365.25 * 86_400 * 23.7)
        XCTAssertEqual(NativeHealthspanFormat.chronoAge(dob: dob, asOf: asOf), 23.7, accuracy: 0.02)
    }

    func testMergePrefersAppleStepsAndVO2() throws {
        let metric = DailyMetric(
            day: "2026-11-01", totalSleepMin: 424, efficiency: 0.9,
            deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
            restingHr: 65, avgHrv: 40, recovery: nil, strain: nil, exerciseCount: 1,
            steps: 100
        )
        let apple = AppleDaily(
            day: "2026-11-01", steps: 13_467, activeKcal: nil, basalKcal: nil,
            vo2max: 52, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: 73
        )
        var noonParts = DateComponents()
        noonParts.year = 2026; noonParts.month = 11; noonParts.day = 1; noonParts.hour = 12
        let noon = Calendar.current.date(from: noonParts)!
        let startTs = Int(noon.timeIntervalSince1970)
        let workout = WorkoutRow(
            startTs: startTs, endTs: startTs + 28 * 60, sport: "Weightlifting",
            source: "whoop", durationS: 28 * 60, energyKcal: nil, avgHr: nil,
            maxHr: nil, strain: nil, distanceM: nil,
            zonesJSON: #"{"z1":40,"z2":40,"z3":15,"z4":5,"z5":0}"#, notes: nil, steps: nil
        )
        let days = NativeHealthspanBuild.merge(
            metrics: [metric],
            sleeps: [],
            workouts: [workout],
            apple: [apple],
            sleepHoursByDay: ["2026-11-01": 7.07],
            consistencyByDay: ["2026-11-01": 66],
            stepsByDay: [:],
            vo2ByDay: [:],
            vo2EstByDay: [:],
            leanByDay: ["2026-11-01": 63],
            weightByDay: ["2026-11-01": 73],
            profileWeightKg: 73
        )
        let day = try XCTUnwrap(days.first { $0.day == "2026-11-01" })
        XCTAssertEqual(day.sleepHours ?? 0, 7.07, accuracy: 0.01)
        XCTAssertEqual(day.sleepConsistency ?? 0, 66, accuracy: 0.01)
        XCTAssertEqual(day.steps ?? 0, 13_467, accuracy: 0.5)
        XCTAssertEqual(day.vo2max ?? 0, 52, accuracy: 0.01)
        XCTAssertEqual(day.restingHR ?? 0, 65, accuracy: 0.01)
        XCTAssertGreaterThan(day.strengthMin ?? 0, 20)
        XCTAssertEqual(day.leanMassPct ?? 0, 86.3, accuracy: 0.3)
    }

    func testValueFormatsMatchWhoopUnits() {
        XCTAssertTrue(NativeHealthspanFormat.valueText(7.07, unit: "h", key: "sleep").contains("7:04"))
        XCTAssertEqual(NativeHealthspanFormat.valueText(66, unit: "%", key: "consistency"), "66%")
        XCTAssertEqual(NativeHealthspanFormat.valueText(65, unit: "bpm", key: "rhr"), "65 bpm")
    }
}

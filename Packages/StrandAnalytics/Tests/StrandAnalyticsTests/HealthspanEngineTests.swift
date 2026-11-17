import XCTest
@testable import StrandAnalytics

final class HealthspanEngineTests: XCTestCase {

    /// Patent WO2026161891A1: Years = ln(HR) / 0.1. HR 1.105 ≈ +1 year.
    func testPatentYearsConversion() {
        XCTAssertEqual(HealthspanEngine.years(fromHazard: 1.105), log(1.105) / 0.1, accuracy: 1e-12)
        XCTAssertEqual(HealthspanEngine.years(fromHazard: 1.105), 0.998, accuracy: 0.01)
        XCTAssertEqual(HealthspanEngine.years(fromHazard: 1.0), 0, accuracy: 1e-12)
        XCTAssertLessThan(HealthspanEngine.years(fromHazard: 0.85), 0)
    }

    func testOptimalLifestyleReadsAtChronoAge() {
        let six = HealthspanEngine.Window(
            sleepHours: 7.5, sleepConsistency: 70,
            weeklyZone13Min: 100, weeklyZone45Min: 10, weeklyStrengthMin: 40,
            dailySteps: 8_000, restingHR: 60, vo2max: 44, leanMassPct: 80,
            daysWithData: 180
        )
        let r = HealthspanEngine.compute(
            profile: .init(chronoAge: 30, sex: "male"),
            sixMonth: six, thirtyDay: six, coverageDays: 180
        )
        XCTAssertEqual(r.readiness, .ready)
        XCTAssertEqual(r.bandAge ?? -1, 30, accuracy: 0.35)
        XCTAssertEqual(r.deltaYears ?? -1, 0, accuracy: 0.35)
        XCTAssertEqual(r.pace ?? -1, 1.0, accuracy: 0.05)
        XCTAssertFalse(r.contributors.contains { $0.key == "hrv" })
    }

    func testSleepDurationUShapeCappuccio() {
        XCTAssertEqual(HealthspanEngine.sleepHoursHazard(7.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(HealthspanEngine.sleepHoursHazard(5.0), 1.12, accuracy: 1e-9)
        XCTAssertEqual(HealthspanEngine.sleepHoursHazard(10.0), 1.30, accuracy: 1e-9)
        let short = HealthspanEngine.years(fromHazard: 1.12)
        XCTAssertEqual(short, 1.13, accuracy: 0.05)
        XCTAssertGreaterThan(HealthspanEngine.years(fromHazard: HealthspanEngine.sleepHoursHazard(5)), 0)
        XCTAssertEqual(HealthspanEngine.years(fromHazard: HealthspanEngine.sleepHoursHazard(7.07)), 0, accuracy: 0.05)
    }

    func testSleepConsistencyWindred() {
        XCTAssertEqual(HealthspanEngine.sleepConsistencyHazard(70), 1.0, accuracy: 1e-9)
        XCTAssertEqual(HealthspanEngine.sleepConsistencyHazard(100), 0.70, accuracy: 1e-9)
        XCTAssertEqual(HealthspanEngine.sleepConsistencyHazard(40), 1.43, accuracy: 1e-9)
        let at66 = HealthspanEngine.years(fromHazard: HealthspanEngine.sleepConsistencyHazard(66))
        XCTAssertEqual(at66, 0.56, accuracy: 0.15)
        XCTAssertGreaterThan(at66, 0)
    }

    func testStepsPaluchPlateau() {
        let at8k = HealthspanEngine.stepsHazard(8_000, age: 24)
        XCTAssertEqual(at8k, 1.0, accuracy: 0.03)
        XCTAssertGreaterThan(HealthspanEngine.stepsHazard(3_000, age: 24), 1.2)
        let hi = HealthspanEngine.stepsHazard(13_467, age: 24)
        XCTAssertLessThan(hi, 1.0)
        XCTAssertEqual(HealthspanEngine.stepsTarget(age: 24), 8_000)
        XCTAssertEqual(HealthspanEngine.stepsTarget(age: 65), 6_000)
    }

    func testStrengthMommaNadir() {
        XCTAssertEqual(HealthspanEngine.strengthHazard(40), 1.0, accuracy: 1e-9)
        XCTAssertEqual(HealthspanEngine.strengthHazard(0), 1.205, accuracy: 1e-9)
        let at28 = HealthspanEngine.years(fromHazard: HealthspanEngine.strengthHazard(28))
        XCTAssertEqual(at28, 0.56, accuracy: 0.12)
        XCTAssertGreaterThan(at28, 0)
    }

    func testRestingHRZhang() {
        XCTAssertEqual(HealthspanEngine.restingHRHazard(60, sex: "male"), 1.0, accuracy: 1e-9)
        let plus10 = HealthspanEngine.restingHRHazard(70, sex: "male")
        XCTAssertEqual(plus10, 1.09, accuracy: 1e-9)
        XCTAssertEqual(HealthspanEngine.rhrTarget(sex: "female"), 64)
    }

    func testVO2KodamaPerMET() {
        let target = HealthspanEngine.vo2Target(age: 30, sex: "male")
        XCTAssertEqual(target, 44, accuracy: 0.01)
        XCTAssertEqual(HealthspanEngine.vo2Hazard(target, age: 30, sex: "male"), 1.0, accuracy: 1e-9)
        let plusMET = HealthspanEngine.vo2Hazard(target + 3.5, age: 30, sex: "male")
        XCTAssertEqual(plusMET, 0.87, accuracy: 1e-9)
        XCTAssertLessThan(HealthspanEngine.years(fromHazard: plusMET), 0)
    }

    func testLeanMassExcludedWhenMissing() {
        let six = HealthspanEngine.Window(
            sleepHours: 7.5, sleepConsistency: 70,
            weeklyZone13Min: 100, weeklyZone45Min: 10, weeklyStrengthMin: 40,
            dailySteps: 8_000, restingHR: 60, vo2max: 44, leanMassPct: nil,
            daysWithData: 180
        )
        let r = HealthspanEngine.compute(
            profile: .init(chronoAge: 30, sex: "male"),
            sixMonth: six, thirtyDay: six, coverageDays: 180
        )
        let lean = r.contributors.first { $0.key == "lean" }!
        XCTAssertFalse(lean.available)
        XCTAssertNil(lean.years)
        XCTAssertTrue(r.missing.contains { $0.lowercased().contains("lean") })
        XCTAssertEqual(r.factorsUsed, 8)
    }

    func testLeanMassPercentFromKilograms() {
        let pct = HealthspanEngine.leanMassPercent(stored: 63.0, weightKg: 73.0)
        XCTAssertEqual(pct ?? 0, 86.3, accuracy: 0.2)
        XCTAssertEqual(HealthspanEngine.leanMassPercent(stored: 86.5, weightKg: nil) ?? 0, 86.5, accuracy: 0.01)
        XCTAssertNil(HealthspanEngine.leanMassPercent(stored: 0, weightKg: 70))
    }

    func testHRVIsNotAContributor() {
        let six = HealthspanEngine.Window(
            sleepHours: 7.5, sleepConsistency: 80, weeklyZone13Min: 120,
            dailySteps: 9_000, restingHR: 55, daysWithData: 180
        )
        let rows = HealthspanEngine.contributors(window: six, profile: .init(chronoAge: 40, sex: "female"))
        XCTAssertFalse(rows.map(\.key).contains("hrv"))
        XCTAssertEqual(rows.map(\.key), [
            "consistency", "sleep", "zone13", "zone45", "strength", "steps", "vo2max", "rhr", "lean"
        ])
    }

    func testPaceIsOneWhenWindowsMatch() {
        let w = HealthspanEngine.Window(
            sleepHours: 7.2, sleepConsistency: 66,
            weeklyZone13Min: 273, weeklyZone45Min: 11, weeklyStrengthMin: 28,
            dailySteps: 13_467, restingHR: 65, vo2max: 52, leanMassPct: 86.5,
            daysWithData: 180
        )
        let r = HealthspanEngine.compute(
            profile: .init(chronoAge: 23.7, sex: "male"),
            sixMonth: w, thirtyDay: w, coverageDays: 180
        )
        XCTAssertEqual(r.pace ?? -1, 1.0, accuracy: 0.02)
    }

    func testPaceOnePointThreeFromFifteenHundredthsYearGap() {
        let base = HealthspanEngine.Window(
            sleepHours: 7.5, sleepConsistency: 70,
            weeklyZone13Min: 100, weeklyZone45Min: 10, weeklyStrengthMin: 40,
            dailySteps: 8_000, restingHR: 60, vo2max: 44, daysWithData: 180
        )
        var thirty = base
        // Zhang: years = ((RHR − 60)/10) × ln(1.09) / 0.1. 0.15 years → RHR ≈ 61.74.
        thirty.restingHR = 60 + 10 * (0.15 * 0.1 / log(1.09))
        thirty.daysWithData = 30
        let r = HealthspanEngine.compute(
            profile: .init(chronoAge: 30, sex: "male"),
            sixMonth: base, thirtyDay: thirty, coverageDays: 180
        )
        XCTAssertEqual(r.pace ?? 0, 1.3, accuracy: 0.02)
    }

    func testPaceThirteenWhenThirtyDayIsWorseByPointOneFiveYears() {
        // pace = 1 + (Δ30 − Δ180) / 0.5. A +0.15 year offset gap → 1.3×.
        let base = HealthspanEngine.Window(
            sleepHours: 7.5, sleepConsistency: 70,
            weeklyZone13Min: 100, weeklyZone45Min: 10, weeklyStrengthMin: 40,
            dailySteps: 8_000, restingHR: 60, vo2max: 44,
            daysWithData: 180
        )
        var worse = base
        worse.sleepConsistency = 40
        let r = HealthspanEngine.compute(
            profile: .init(chronoAge: 30, sex: "male"),
            sixMonth: base, thirtyDay: worse, coverageDays: 180
        )
        XCTAssertGreaterThan(r.pace ?? 0, 1.0)
        let delta180 = r.contributors.compactMap(\.years).reduce(0, +)
        let delta30 = r.contributors.compactMap(\.years30).reduce(0, +)
        let expected = HealthspanEngine.clamp(1 + (delta30 - delta180) / 0.5,
                                              HealthspanEngine.minPace, HealthspanEngine.maxPace)
        XCTAssertEqual(r.pace ?? 0, expected, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(r.pace ?? 0, HealthspanEngine.maxPace)
        XCTAssertGreaterThanOrEqual(r.pace ?? 0, HealthspanEngine.minPace)
    }

    func testCalibrationGates() {
        let w = HealthspanEngine.Window(sleepHours: 7.5, sleepConsistency: 70,
                                        weeklyZone13Min: 120, restingHR: 60, daysWithData: 10)
        let none = HealthspanEngine.compute(
            profile: .init(chronoAge: 30, sex: "male"),
            sixMonth: w, thirtyDay: w, coverageDays: 10
        )
        XCTAssertEqual(none.readiness, .notReady)

        let cal = HealthspanEngine.compute(
            profile: .init(chronoAge: 30, sex: "male"),
            sixMonth: w, thirtyDay: w, coverageDays: 40
        )
        XCTAssertEqual(cal.readiness, .calibrating)
        XCTAssertNotNil(cal.bandAge)
        XCTAssertTrue(cal.missing.contains { $0.contains("more days") })

        let ready = HealthspanEngine.compute(
            profile: .init(chronoAge: 30, sex: "male"),
            sixMonth: HealthspanEngine.Window(
                sleepHours: 7.5, sleepConsistency: 70, weeklyZone13Min: 120,
                restingHR: 60, daysWithData: 180),
            thirtyDay: w, coverageDays: 180
        )
        XCTAssertEqual(ready.readiness, .ready)
    }

    func testNilBelowMinContributors() {
        let thin = HealthspanEngine.Window(sleepHours: 7.5, restingHR: 60, daysWithData: 180)
        let r = HealthspanEngine.compute(
            profile: .init(chronoAge: 30, sex: "male"),
            sixMonth: thin, thirtyDay: thin, coverageDays: 180
        )
        XCTAssertNil(r.bandAge)
        XCTAssertEqual(r.readiness, .notReady)
        XCTAssertEqual(r.factorsUsed, 2)
    }

    func testZoneJSONAndStrengthSports() {
        let p = HealthspanEngine.zonePercents(fromJSON: #"{"z1":10,"z2":20,"z3":30,"z4":25,"z5":5}"#)!
        XCTAssertEqual(p, [10, 20, 30, 25, 5])
        let alt = HealthspanEngine.zonePercents(fromJSON: #"{"zone1":8,"zone2":22,"zone3":18,"zone4":40,"zone5":12}"#)!
        XCTAssertEqual(alt[3], 40, accuracy: 0.01)
        let mins = HealthspanEngine.zoneMinutes(percents: p, durationMin: 60)
        XCTAssertEqual(mins.z13, 36, accuracy: 0.01)
        XCTAssertEqual(mins.z45, 18, accuracy: 0.01)
        XCTAssertTrue(HealthspanEngine.isStrengthSport("Weightlifting"))
        XCTAssertTrue(HealthspanEngine.isStrengthSport("HIIT"))
        XCTAssertTrue(HealthspanEngine.isStrengthSport("Powerlifting"))
        XCTAssertTrue(HealthspanEngine.isStrengthSport("Yoga"))
        XCTAssertFalse(HealthspanEngine.isStrengthSport("Running"))
        XCTAssertFalse(HealthspanEngine.isStrengthSport("Walking"))
    }

    func testSummarizeWeeklyFromDaily() {
        var days: [HealthspanEngine.Day] = []
        for i in 0..<14 {
            let key = HealthspanEngine.isoString(HealthspanEngine.isoEpochDay("2026-11-14")! - (13 - i))!
            days.append(.init(day: key, sleepHours: 7.0, steps: 8_000, restingHR: 60,
                              zone13Min: 40, zone45Min: 2, strengthMin: i % 7 == 0 ? 40 : 0))
        }
        let w = HealthspanEngine.summarize(days, ending: "2026-11-14", windowDays: 14)
        XCTAssertEqual(w.weeklyZone13Min ?? 0, 280, accuracy: 0.5)   // 40 min/day × 7
        XCTAssertEqual(w.weeklyZone45Min ?? 0, 14, accuracy: 0.5)
        XCTAssertEqual(w.weeklyStrengthMin ?? 0, 40, accuracy: 0.5)  // one 40-min session per week
        XCTAssertEqual(w.sleepHours ?? 0, 7.0, accuracy: 0.01)
        XCTAssertEqual(w.daysWithData, 14)
    }

    func testSleepConsistencyIdenticalNightsAreHigh() {
        let nights = (0..<8).map { _ in (onsetMin: 23 * 60, wakeMin: 7 * 60) }
        let mapped = HealthspanEngine.sleepConsistency(nights: nights).filter(\.isFinite)
        XCTAssertFalse(mapped.isEmpty)
        XCTAssertGreaterThan(mapped.last ?? 0, 90)
    }

    func testWhoopScreenshotOrderOfMagnitude() {
        // WHOOP screenshot: Age 21.8, 1.9 years younger, chrono ≈ 23.7.
        // Published curves on those contributor values should land in the same ballpark,
        // not copy WHOOP's closed weights.
        let six = HealthspanEngine.Window(
            sleepHours: 7.07, sleepConsistency: 66,
            weeklyZone13Min: 273, weeklyZone45Min: 11, weeklyStrengthMin: 28,
            dailySteps: 13_467, restingHR: 65, vo2max: 52, leanMassPct: 86.5,
            daysWithData: 180
        )
        let r = HealthspanEngine.compute(
            profile: .init(chronoAge: 23.7, sex: "male"),
            sixMonth: six, thirtyDay: six, coverageDays: 180
        )
        XCTAssertNotNil(r.bandAge)
        XCTAssertGreaterThan(r.deltaYears ?? 0, 0)
        XCTAssertLessThan(r.bandAge ?? 100, 23.7)
        XCTAssertGreaterThan(r.bandAge ?? 0, 18)
        XCTAssertLessThan(abs((r.bandAge ?? 0) - 21.8), 4.0)
        let cons = r.contributors.first { $0.key == "consistency" }!
        XCTAssertGreaterThan(cons.years ?? 0, 0)
        let z13 = r.contributors.first { $0.key == "zone13" }!
        XCTAssertLessThan(z13.years ?? 0, 0)
        let sleep = r.contributors.first { $0.key == "sleep" }!
        XCTAssertEqual(sleep.years ?? 1, 0, accuracy: 0.1)
    }

    func testBuildFromDayList() {
        var days: [HealthspanEngine.Day] = []
        let end = HealthspanEngine.isoEpochDay("2026-11-14")!
        for i in 0..<180 {
            let key = HealthspanEngine.isoString(end - (179 - i))!
            days.append(.init(day: key, sleepHours: 7.5, sleepOnsetMin: 23 * 60, sleepWakeMin: 7 * 60,
                              steps: 9_000, restingHR: 58, vo2max: 48,
                              zone13Min: 20, zone45Min: 2, strengthMin: i % 7 == 0 ? 45 : 0))
        }
        let r = HealthspanEngine.compute(days: days, profile: .init(chronoAge: 28, sex: "male"),
                                         asOfDay: "2026-11-14")
        XCTAssertEqual(r.readiness, .ready)
        XCTAssertNotNil(r.bandAge)
        XCTAssertFalse(r.trend.isEmpty)
        XCTAssertEqual(r.trend.last?.day, "2026-11-14")
    }
}

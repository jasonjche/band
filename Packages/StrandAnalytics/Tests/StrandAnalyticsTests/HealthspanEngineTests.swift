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
        let age = 30.0
        let sex = "male"
        let six = HealthspanEngine.Window(
            sleepHours: HealthspanEngine.sleepHoursTarget,
            sleepConsistency: HealthspanEngine.consistencyTarget,
            weeklyZone13Min: HealthspanEngine.zone13Target(age: age),
            weeklyZone45Min: HealthspanEngine.zone45TargetMin,
            weeklyStrengthMin: HealthspanEngine.strengthTargetMin,
            dailySteps: HealthspanEngine.stepsTarget(age: age),
            restingHR: HealthspanEngine.rhrTarget(sex: sex),
            vo2max: HealthspanEngine.vo2Target(age: age, sex: sex),
            leanMassPct: HealthspanEngine.leanMassTarget(sex: sex),
            daysWithData: 180
        )
        let r = HealthspanEngine.compute(
            profile: .init(chronoAge: age, sex: sex),
            sixMonth: six, thirtyDay: six, coverageDays: 180
        )
        XCTAssertEqual(r.readiness, .ready)
        XCTAssertEqual(r.bandAge ?? -1, age, accuracy: 0.35)
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
        XCTAssertEqual(HealthspanEngine.years(fromHazard: HealthspanEngine.sleepHoursHazard(7.5)), 0, accuracy: 0.05)
    }

    func testSleepConsistencyWindred() {
        XCTAssertEqual(HealthspanEngine.sleepConsistencyHazard(70), 1.0, accuracy: 1e-9)
        XCTAssertEqual(HealthspanEngine.sleepConsistencyHazard(100), 0.70, accuracy: 1e-9)
        XCTAssertEqual(HealthspanEngine.sleepConsistencyHazard(40), 1.43, accuracy: 1e-9)
        let mid = HealthspanEngine.years(fromHazard: HealthspanEngine.sleepConsistencyHazard(55))
        XCTAssertGreaterThan(mid, 0)
        XCTAssertLessThan(mid, HealthspanEngine.years(fromHazard: 1.43))
    }

    func testStepsPaluchPlateau() {
        let at8k = HealthspanEngine.stepsHazard(8_000, age: 30)
        XCTAssertEqual(at8k, 1.0, accuracy: 0.03)
        XCTAssertGreaterThan(HealthspanEngine.stepsHazard(3_000, age: 30), 1.2)
        let hi = HealthspanEngine.stepsHazard(12_000, age: 30)
        XCTAssertEqual(hi, 0.94, accuracy: 0.01)
        XCTAssertEqual(HealthspanEngine.stepsHazard(14_000, age: 30), hi, accuracy: 1e-9)
        XCTAssertEqual(HealthspanEngine.stepsTarget(age: 30), 8_000)
        XCTAssertEqual(HealthspanEngine.stepsTarget(age: 65), 6_000)
    }

    func testStrengthMommaNadir() {
        XCTAssertEqual(HealthspanEngine.strengthHazard(40), 1.0, accuracy: 1e-9)
        XCTAssertEqual(HealthspanEngine.strengthHazard(0), 1.17, accuracy: 1e-9)
        let below = HealthspanEngine.years(fromHazard: HealthspanEngine.strengthHazard(20))
        XCTAssertGreaterThan(below, 0)
        XCTAssertLessThan(HealthspanEngine.strengthHazard(60), 1.0)
        XCTAssertGreaterThan(HealthspanEngine.strengthHazard(200), 1.0)
    }

    func testRestingHRZhang() {
        let target = HealthspanEngine.rhrTarget(sex: "male")
        XCTAssertEqual(HealthspanEngine.restingHRHazard(target, sex: "male"), 1.0, accuracy: 1e-9)
        let plus10 = HealthspanEngine.restingHRHazard(target + 10, sex: "male")
        XCTAssertEqual(plus10, 1.09, accuracy: 1e-9)
        XCTAssertEqual(
            HealthspanEngine.rhrTarget(sex: "female") - HealthspanEngine.rhrTarget(sex: "male"),
            4, accuracy: 1e-9)
    }

    func testVO2KodamaPerMET() {
        let target = HealthspanEngine.vo2Target(age: 30, sex: "male")
        XCTAssertEqual(target, 45.8, accuracy: 0.01)
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
        XCTAssertEqual(HealthspanEngine.leanMassPercent(stored: 80.0, weightKg: nil) ?? 0, 80.0, accuracy: 0.01)
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
            sleepHours: 7.2, sleepConsistency: 80,
            weeklyZone13Min: 120, weeklyZone45Min: 20, weeklyStrengthMin: 45,
            dailySteps: 9_000, restingHR: 55, vo2max: 48, leanMassPct: 82,
            daysWithData: 180
        )
        let r = HealthspanEngine.compute(
            profile: .init(chronoAge: 30, sex: "male"),
            sixMonth: w, thirtyDay: w, coverageDays: 180
        )
        XCTAssertEqual(r.pace ?? -1, 1.0, accuracy: 0.02)
    }

    func testPaceOnePointThreeFromFifteenHundredthsYearGap() {
        let sex = "male"
        let rhr0 = HealthspanEngine.rhrTarget(sex: sex)
        let base = HealthspanEngine.Window(
            sleepHours: 7.5, sleepConsistency: 70,
            weeklyZone13Min: 100, weeklyZone45Min: 10, weeklyStrengthMin: 40,
            dailySteps: 8_000, restingHR: rhr0,
            vo2max: HealthspanEngine.vo2Target(age: 30, sex: sex), daysWithData: 180
        )
        var thirty = base
        // Zhang: years = ((RHR − target)/10) × ln(1.09) / 0.1. 0.15 years → +Δ bpm.
        thirty.restingHR = rhr0 + 10 * (0.15 * 0.1 / log(1.09))
        thirty.daysWithData = 30
        let r = HealthspanEngine.compute(
            profile: .init(chronoAge: 30, sex: sex),
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

    func testBandAgeIsChronoPlusSumOfYears() {
        let six = HealthspanEngine.Window(
            sleepHours: 6.0, sleepConsistency: 80,
            weeklyZone13Min: 180, weeklyZone45Min: 20, weeklyStrengthMin: 50,
            dailySteps: 9_500, restingHR: 52, vo2max: 50, leanMassPct: 75,
            daysWithData: 180
        )
        let chrono = 32.0
        let r = HealthspanEngine.compute(
            profile: .init(chronoAge: chrono, sex: "male"),
            sixMonth: six, thirtyDay: six, coverageDays: 180
        )
        let sum = r.contributors.compactMap(\.years).reduce(0, +)
        let expected = HealthspanEngine.clamp(chrono + sum,
                                              HealthspanEngine.minBandAge,
                                              HealthspanEngine.maxBandAge)
        XCTAssertEqual(r.bandAge ?? -1, expected, accuracy: 1e-9)
        XCTAssertEqual(r.deltaYears ?? 0, chrono - expected, accuracy: 1e-9)
        XCTAssertEqual(r.factorsUsed, 9)
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
        XCTAssertEqual(r.trend.last?.bandAge ?? -1, r.bandAge ?? -1, accuracy: 1e-12)
        XCTAssertEqual(r.trend.last?.chronoAge ?? -1, r.chronoAge, accuracy: 1e-12)
        XCTAssertEqual(r.trend.last?.pace ?? -1, r.pace ?? -1, accuracy: 1e-12)
    }

    func testLastTrendPointEqualsHeroBandAge() {
        var days: [HealthspanEngine.Day] = []
        let end = HealthspanEngine.isoEpochDay("2026-11-14")!
        for i in 0..<180 {
            let key = HealthspanEngine.isoString(end - (179 - i))!
            let vo2 = i >= 173 ? 52.0 : 40.0
            days.append(.init(day: key, sleepHours: 7.5, sleepOnsetMin: 23 * 60, sleepWakeMin: 7 * 60,
                              steps: 9_000, restingHR: 58, vo2max: vo2,
                              zone13Min: 20, zone45Min: 2, strengthMin: i % 7 == 0 ? 45 : 0))
        }
        let r = HealthspanEngine.compute(days: days, profile: .init(chronoAge: 28, sex: "male"),
                                         asOfDay: "2026-11-14")
        XCTAssertEqual(r.trend.last?.day, "2026-11-14")
        XCTAssertEqual(r.trend.last?.bandAge ?? -1, r.bandAge ?? -1, accuracy: 1e-12)
        XCTAssertEqual(r.trend.last?.pace ?? -1, r.pace ?? -1, accuracy: 1e-12)
    }

    func testReferentZeroes() {
        let y: (Double) -> Double = { HealthspanEngine.years(fromHazard: $0) }
        XCTAssertEqual(y(HealthspanEngine.sleepHoursHazard(7.5)), 0, accuracy: 1e-9)
        XCTAssertEqual(y(HealthspanEngine.sleepHoursHazard(8.0)), 0, accuracy: 1e-9)
        XCTAssertEqual(y(HealthspanEngine.sleepConsistencyHazard(70)), 0, accuracy: 1e-9)
        XCTAssertEqual(y(HealthspanEngine.zone13Hazard(100)), 0, accuracy: 1e-9)
        XCTAssertEqual(y(HealthspanEngine.zone45Hazard(10)), 0, accuracy: 1e-9)
        XCTAssertEqual(y(HealthspanEngine.strengthHazard(40)), 0, accuracy: 1e-9)
        XCTAssertEqual(y(HealthspanEngine.stepsHazard(8_000, age: 30)), 0, accuracy: 0.05)
        XCTAssertEqual(y(HealthspanEngine.restingHRHazard(
            HealthspanEngine.rhrTarget(sex: "male"), sex: "male")), 0, accuracy: 1e-9)
        XCTAssertEqual(y(HealthspanEngine.vo2Hazard(
            HealthspanEngine.vo2Target(age: 40, sex: "female"), age: 40, sex: "female")), 0, accuracy: 1e-9)
        XCTAssertEqual(y(HealthspanEngine.leanMassHazard(80, sex: "male")), 0, accuracy: 1e-9)
        XCTAssertEqual(y(HealthspanEngine.leanMassHazard(90, sex: "male")), 0, accuracy: 1e-9)
        XCTAssertEqual(y(HealthspanEngine.leanMassHazard(67, sex: "female")), 0, accuracy: 1e-9)
    }

    func testEndClamps() {
        XCTAssertEqual(HealthspanEngine.sleepHoursHazard(0), HealthspanEngine.sleepHoursHazard(4), accuracy: 1e-12)
        XCTAssertEqual(HealthspanEngine.sleepHoursHazard(20), HealthspanEngine.sleepHoursHazard(12), accuracy: 1e-12)
        XCTAssertEqual(HealthspanEngine.sleepConsistencyHazard(-10), HealthspanEngine.sleepConsistencyHazard(40), accuracy: 1e-12)
        XCTAssertEqual(HealthspanEngine.sleepConsistencyHazard(140), HealthspanEngine.sleepConsistencyHazard(100), accuracy: 1e-12)
        XCTAssertEqual(HealthspanEngine.zone13Hazard(-20), HealthspanEngine.zone13Hazard(0), accuracy: 1e-12)
        XCTAssertEqual(HealthspanEngine.zone13Hazard(900), HealthspanEngine.zone13Hazard(600), accuracy: 1e-12)
        XCTAssertEqual(HealthspanEngine.zone45Hazard(-5), HealthspanEngine.zone45Hazard(0), accuracy: 1e-12)
        XCTAssertEqual(HealthspanEngine.zone45Hazard(400), HealthspanEngine.zone45Hazard(150), accuracy: 1e-12)
        XCTAssertEqual(HealthspanEngine.stepsHazard(-100, age: 30), HealthspanEngine.stepsHazard(0, age: 30), accuracy: 1e-12)
        XCTAssertEqual(HealthspanEngine.stepsHazard(20_000, age: 30), HealthspanEngine.stepsHazard(14_000, age: 30), accuracy: 1e-12)
        XCTAssertEqual(HealthspanEngine.strengthHazard(-10), HealthspanEngine.strengthHazard(0), accuracy: 1e-12)
        XCTAssertEqual(HealthspanEngine.strengthHazard(400), HealthspanEngine.strengthHazard(200), accuracy: 1e-12)
    }

    func testMonotoneWhereExpected() {
        func decreasing(_ xs: [Double], _ f: (Double) -> Double, file: StaticString = #filePath, line: UInt = #line) {
            var prev = f(xs[0])
            for x in xs.dropFirst() {
                let y = f(x)
                XCTAssertLessThanOrEqual(y, prev + 1e-12, "x=\(x)", file: file, line: line)
                prev = y
            }
        }
        func increasing(_ xs: [Double], _ f: (Double) -> Double, file: StaticString = #filePath, line: UInt = #line) {
            var prev = f(xs[0])
            for x in xs.dropFirst() {
                let y = f(x)
                XCTAssertGreaterThanOrEqual(y, prev - 1e-12, "x=\(x)", file: file, line: line)
                prev = y
            }
        }
        decreasing([40, 55, 70, 85, 100], HealthspanEngine.sleepConsistencyHazard)
        decreasing([0, 50, 100, 200, 300, 500, 600], HealthspanEngine.zone13Hazard)
        decreasing([0, 10, 40, 75, 150], HealthspanEngine.zone45Hazard)
        decreasing([0, 3_000, 6_000, 8_000, 10_000, 14_000]) { HealthspanEngine.stepsHazard($0, age: 30) }
        decreasing([30, 40, 50, 60]) { HealthspanEngine.vo2Hazard($0, age: 30, sex: "male") }
        increasing([50, 58, 65, 80]) { HealthspanEngine.restingHRHazard($0, sex: "male") }
        decreasing([60, 70, 80]) { HealthspanEngine.leanMassHazard($0, sex: "male") }
        XCTAssertEqual(HealthspanEngine.leanMassHazard(85, sex: "male"),
                       HealthspanEngine.leanMassHazard(80, sex: "male"), accuracy: 1e-12)
        // Strength stays J-shaped: down to the nadir, then up.
        decreasing([0, 20, 40, 60], HealthspanEngine.strengthHazard)
        increasing([60, 140, 200], HealthspanEngine.strengthHazard)
        // Sleep hours stay U-shaped around 7–8 h.
        decreasing([4, 5, 6, 7], HealthspanEngine.sleepHoursHazard)
        increasing([8, 9, 10, 12], HealthspanEngine.sleepHoursHazard)
    }

    func testDisplayScaleEndpoints() {
        let male = HealthspanEngine.contributors(
            window: HealthspanEngine.Window(sleepHours: 7.5, leanMassPct: 80),
            profile: .init(chronoAge: 30, sex: "male"))
        let female = HealthspanEngine.contributors(
            window: HealthspanEngine.Window(sleepHours: 7.5, leanMassPct: 70),
            profile: .init(chronoAge: 30, sex: "female"))
        XCTAssertEqual(male.first { $0.key == "sleep" }?.scaleMin, 5)
        XCTAssertEqual(male.first { $0.key == "sleep" }?.scaleMax, 8)
        XCTAssertEqual(male.first { $0.key == "consistency" }?.scaleMin, 40)
        XCTAssertEqual(male.first { $0.key == "consistency" }?.scaleMax, 100)
        XCTAssertEqual(male.first { $0.key == "zone45" }?.scaleMax, 60)
        XCTAssertEqual(male.first { $0.key == "strength" }?.scaleMin, 0)
        XCTAssertEqual(male.first { $0.key == "strength" }?.scaleMax, 120)
        XCTAssertEqual(male.first { $0.key == "vo2max" }?.scaleMin, 15)
        XCTAssertEqual(male.first { $0.key == "vo2max" }?.scaleMax, 70)
        XCTAssertEqual(male.first { $0.key == "rhr" }?.scaleMin, 40)
        XCTAssertEqual(male.first { $0.key == "rhr" }?.scaleMax, 80)
        XCTAssertEqual(male.first { $0.key == "lean" }?.scaleMin, 60)
        XCTAssertEqual(female.first { $0.key == "lean" }?.scaleMin, 50)
    }

    func testZone13PastTargetKeepsDecreasing() {
        let atTarget = HealthspanEngine.zone13Hazard(100)
        let mid = HealthspanEngine.zone13Hazard(200)
        let far = HealthspanEngine.zone13Hazard(300)
        XCTAssertEqual(atTarget, 1.0, accuracy: 1e-9)
        XCTAssertLessThan(mid, atTarget)
        XCTAssertLessThan(far, mid)
        XCTAssertEqual(far, 0.85, accuracy: 1e-9)
    }
}

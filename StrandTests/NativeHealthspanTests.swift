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

    func testOrbHueMapsYoungerToMintAndOlderToAmber() {
        XCTAssertEqual(NativeHealthspanOrbHue.resolve(deltaYears: 3.2, forming: false), .younger)
        XCTAssertEqual(NativeHealthspanOrbHue.resolve(deltaYears: -2.4, forming: false), .older)
        XCTAssertEqual(NativeHealthspanOrbHue.resolve(deltaYears: 0, forming: false), .mixed)
        XCTAssertEqual(NativeHealthspanOrbHue.resolve(deltaYears: 4, forming: true), .forming)
        XCTAssertEqual(NativeHealthspanOrbHue.progress(deltaYears: 5), 1, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanOrbHue.progress(deltaYears: -5), 0, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanOrbHue.progress(deltaYears: 0), 0.5, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanOrbHue.progress(deltaYears: nil), 0.5, accuracy: 0.001)
    }

    func testOrbMapClampsDeltaToHueAndFillFraction() {
        XCTAssertEqual(NativeHealthspanOrbMap.fillFraction(delta: 5), 1, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanOrbMap.fillFraction(delta: -5), 0, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanOrbMap.fillFraction(delta: 0), 0.5, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanOrbMap.fillFraction(delta: nil), 0.5, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanOrbMap.fillFraction(delta: 2.5), 0.75, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanOrbMap.fillFraction(delta: 12), 1, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanOrbMap.fillFraction(delta: -12), 0, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanOrbMap.tone(delta: 2.2, isLoading: false), .younger)
        XCTAssertEqual(NativeHealthspanOrbMap.tone(delta: -1.4, isLoading: false), .older)
        XCTAssertEqual(NativeHealthspanOrbMap.tone(delta: 0, isLoading: false), .neutral)
        XCTAssertEqual(NativeHealthspanOrbMap.tone(delta: 0.02, isLoading: false), .neutral)
        XCTAssertEqual(NativeHealthspanOrbMap.tone(delta: 4, isLoading: true), .loading)
        XCTAssertEqual(NativeHealthspanOrbStyle.storageKey, "band.orbStyle")
        XCTAssertEqual(NativeHealthspanOrbStyle.ring.rawValue, "ring")
        XCTAssertEqual(NativeHealthspanOrbStyle.bloom.rawValue, "bloom")
        XCTAssertEqual(NativeHealthspanOrbStyle.glass.rawValue, "glass")
    }

    func testMarkerProgressClampsToTheScale() {
        XCTAssertEqual(NativeHealthspanFormat.markerProgress(value: 70, scaleMin: 40, scaleMax: 100), 0.5, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanFormat.markerProgress(value: 40, scaleMin: 40, scaleMax: 100), 0, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanFormat.markerProgress(value: 100, scaleMin: 40, scaleMax: 100), 1, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanFormat.markerProgress(value: 10, scaleMin: 40, scaleMax: 100), 0, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanFormat.markerProgress(value: 200, scaleMin: 40, scaleMax: 100), 1, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanFormat.markerProgress(value: 50, scaleMin: 50, scaleMax: 50), 0.5, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanFormat.paceProgress(-1), 0, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanFormat.paceProgress(1), 0.5, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanFormat.paceProgress(3), 1, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanFormat.paceProgress(5), 1, accuracy: 0.001)
    }

    func testScaleLabelsMatchWhoopEnds() {
        XCTAssertEqual(NativeHealthspanFormat.scaleLabel(40, key: "consistency"), "40%")
        XCTAssertEqual(NativeHealthspanFormat.scaleLabel(5, key: "sleep"), "5h")
        XCTAssertEqual(NativeHealthspanFormat.scaleLabel(0, key: "zone13"), "0h")
        XCTAssertEqual(NativeHealthspanFormat.scaleLabel(60, key: "zone45"), "1h")
        XCTAssertEqual(NativeHealthspanFormat.scaleLabel(120, key: "strength"), "2h")
        XCTAssertEqual(NativeHealthspanFormat.scaleLabel(0, key: "steps"), "0K")
        XCTAssertEqual(NativeHealthspanFormat.scaleLabel(16_000, key: "steps"), "16K")
        XCTAssertEqual(NativeHealthspanFormat.scaleLabel(40, key: "rhr"), "40bpm")
        XCTAssertEqual(NativeHealthspanFormat.scaleLabel(15, key: "vo2max"), "15")
    }

    func testYearsFormattingStaysSigned() {
        XCTAssertEqual(NativeHealthspanFormat.yearsImpact(0.5, available: true), "+0.5 years")
        XCTAssertEqual(NativeHealthspanFormat.yearsImpact(-1.4, available: true), "-1.4 years")
        XCTAssertEqual(NativeHealthspanFormat.yearsImpact(0.0, available: true), "0.0 years")
    }

    func testPaceChipReadsLastTwoWeeklyPoints() {
        let points: [HealthspanEngine.TrendPoint] = [
            .init(day: "2026-11-01", bandAge: 27, chronoAge: 30, pace: 0.9),
            .init(day: "2026-11-08", bandAge: 27.1, chronoAge: 30, pace: 1.2)
        ]
        XCTAssertEqual(NativeHealthspanPaceChip.weekDelta(points: points) ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(NativeHealthspanPaceChip.from(weekDelta: 0.3), .faster)
        XCTAssertEqual(NativeHealthspanPaceChip.from(weekDelta: -0.2), .slower)
        XCTAssertNil(NativeHealthspanPaceChip.from(weekDelta: 0.01))
        XCTAssertEqual(NativeHealthspanPaceChip.faster.label, "faster vs last week")
        XCTAssertEqual(NativeHealthspanPaceChip.slower.label, "slower vs last week")
    }

    func testContributorNoteIsPlainLanguage() {
        let worse = HealthspanEngine.Contributor(
            key: "consistency", label: "Sleep Consistency", section: .sleep,
            value: 66, value30: 66, unit: "%", target: 70, targetLabel: "≥ 70%",
            years: 0.5, years30: 0.5, scaleMin: 40, scaleMax: 100,
            higherIsBetter: true, available: true, citation: ""
        )
        XCTAssertTrue(NativeHealthspanFormat.contributorNote(worse).contains("+0.5 years"))
        let better = HealthspanEngine.Contributor(
            key: "zone13", label: "Time in HR Zones 1–3 (Weekly)", section: .strain,
            value: 270, value30: 240, unit: "min", target: 100, targetLabel: "≥ 100 min",
            years: -1.4, years30: -1.2, scaleMin: 0, scaleMax: 360,
            higherIsBetter: true, available: true, citation: ""
        )
        XCTAssertTrue(NativeHealthspanFormat.contributorNote(better).contains("1.4 years"))
        let missing = HealthspanEngine.Contributor(
            key: "lean", label: "Lean Body Mass", section: .fitness,
            value: nil, value30: nil, unit: "%", target: 80, targetLabel: "≥ 80%",
            years: nil, years30: nil, scaleMin: 50, scaleMax: 90,
            higherIsBetter: true, available: false, citation: ""
        )
        XCTAssertTrue(NativeHealthspanFormat.contributorNote(missing).contains("Not enough"))
    }

    func testTrendScopeKeepsAMonthOfWeeklyPoints() {
        let points: [HealthspanEngine.TrendPoint] = [
            .init(day: "2026-05-16", bandAge: 26.0, chronoAge: 29.5, pace: 1.1),
            .init(day: "2026-10-01", bandAge: 26.4, chronoAge: 29.9, pace: 1.0),
            .init(day: "2026-11-01", bandAge: 26.6, chronoAge: 30.0, pace: 0.9),
            .init(day: "2026-11-15", bandAge: 26.8, chronoAge: 30.0, pace: 0.8)
        ]
        let month = NativeHealthspanTrendScope.windowed(points, scope: .month)
        XCTAssertEqual(month.map(\.day), ["2026-11-01", "2026-11-15"])
        let six = NativeHealthspanTrendScope.windowed(points, scope: .sixMonths)
        XCTAssertEqual(six.map(\.day), ["2026-10-01", "2026-11-01", "2026-11-15"])
        XCTAssertEqual(NativeHealthspanTrendScope.month.label, "M")
        XCTAssertEqual(NativeHealthspanTrendScope.sixMonths.label, "6M")
    }

    func testResolvedVO2PrefersOwnAndCarriesAcrossDays() {
        let days = (1...14).map { String(format: "2026-11-%02d", $0) }
        let apple = Dictionary(uniqueKeysWithValues: days.map { ($0, 40.0) })
        let resolved = NativeHealthspanBuild.resolvedVO2(
            vo2EstByDay: ["2026-11-08": 52],
            appleVO2ByDay: apple,
            vo2ByDay: [:],
            days: days
        )
        XCTAssertEqual(Set(resolved.keys), Set(days))
        for day in days {
            XCTAssertEqual(resolved[day] ?? 0, 52, accuracy: 0.01, day)
        }
    }

    func testResolvedVO2FallsBackToAppleWhenOwnIsMissing() {
        let resolved = NativeHealthspanBuild.resolvedVO2(
            vo2EstByDay: [:],
            appleVO2ByDay: ["2026-11-01": 40],
            vo2ByDay: ["2026-11-01": 44, "2026-11-02": 41],
            days: ["2026-11-01", "2026-11-02"]
        )
        XCTAssertEqual(resolved["2026-11-01"] ?? 0, 40, accuracy: 0.01)
        XCTAssertEqual(resolved["2026-11-02"] ?? 0, 41, accuracy: 0.01)
    }

    func testMergeOwnVO2FillsEveryDayAndLastTrendMatchesHero() throws {
        var metrics: [DailyMetric] = []
        var apple: [AppleDaily] = []
        let end = HealthspanEngine.isoEpochDay("2026-11-14")!
        for i in 0..<180 {
            let key = HealthspanEngine.isoString(end - (179 - i))!
            metrics.append(DailyMetric(
                day: key, totalSleepMin: 450, efficiency: 0.9,
                deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                restingHr: 58, avgHrv: 40, recovery: nil, strain: nil, exerciseCount: 1,
                steps: 9_000
            ))
            apple.append(AppleDaily(
                day: key, steps: 9_000, activeKcal: nil, basalKcal: nil,
                vo2max: 40, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: 73
            ))
        }
        let days = NativeHealthspanBuild.merge(
            metrics: metrics,
            sleeps: [],
            workouts: [],
            apple: apple,
            sleepHoursByDay: [:],
            consistencyByDay: [:],
            stepsByDay: [:],
            vo2ByDay: [:],
            vo2EstByDay: ["2026-11-14": 52],
            leanByDay: [:],
            weightByDay: [:],
            profileWeightKg: 73
        )
        for day in days {
            XCTAssertEqual(day.vo2max ?? 0, 52, accuracy: 0.01, day.day)
        }
        let result = HealthspanEngine.compute(
            days: days,
            profile: .init(chronoAge: 28, sex: "male"),
            asOfDay: "2026-11-14"
        )
        let last = try XCTUnwrap(result.trend.last)
        let hero = try XCTUnwrap(result.bandAge)
        XCTAssertEqual(last.day, "2026-11-14")
        XCTAssertEqual(last.bandAge, hero, accuracy: 1e-12)
        XCTAssertEqual(last.chronoAge, result.chronoAge, accuracy: 1e-12)
        XCTAssertEqual(last.pace ?? -1, result.pace ?? -1, accuracy: 1e-12)
        if let previous = result.trend.dropLast().last {
            XCTAssertEqual(previous.bandAge, hero, accuracy: 0.15)
        }
    }
}

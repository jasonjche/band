import XCTest
import WhoopStore
@testable import Strand

/// Home Sleep, Recovery, and Strain — the rings, My Day Sleep, and a contributor row that is itself
/// one of those scores — must open the new score page when the WHOOP layout is on. Other catalog
/// pushes stay on the existing detail screen. An unset effort scale displays 0–21; a stored 0–100
/// choice still displays 0–100. The ring fraction stays on the stored 0–100 value.
@MainActor
final class NativeRouteScaleTests: XCTestCase {

    func testHomeScoreRoutesOpenTheNewScorePagesWhenNativeLayoutIsOn() {
        let model = sampleDay(scale: .whoop)
        let sleepPerformance = model.recovery.rows.first { $0.title == "Sleep Performance" }

        let destinations: [(TabRoute, NativeScoreKind)] = [
            (model.sleep.route, .sleep),
            (model.recovery.route, .recovery),
            (model.strain.route, .strain),
            (.sleep, .sleep),
            (sleepPerformance?.route ?? .metric("missing"), .sleep),
        ]
        for (route, kind) in destinations {
            XCTAssertEqual(
                NativeRouteResolver.presentation(for: route, nativeLayout: true),
                .score(kind),
                "\(route) must open the new \(kind) score page"
            )
        }
    }

    func testNativeLayoutOffKeepsTheOriginalDestinations() {
        let model = sampleDay(scale: .whoop)
        XCTAssertEqual(NativeRouteResolver.presentation(for: model.sleep.route, nativeLayout: false), .unchanged)
        XCTAssertEqual(NativeRouteResolver.presentation(for: model.recovery.route, nativeLayout: false), .unchanged)
        XCTAssertEqual(NativeRouteResolver.presentation(for: model.strain.route, nativeLayout: false), .unchanged)
        XCTAssertEqual(NativeRouteResolver.presentation(for: .metric(HeroRingMetric.rest), nativeLayout: false), .unchanged)
    }

    func testOtherCatalogMetricsStayOnTheDetailScreen() {
        XCTAssertEqual(
            NativeRouteResolver.presentation(for: .metric("hrv"), nativeLayout: true),
            .metricPage("hrv")
        )
        XCTAssertEqual(
            NativeRouteResolver.presentation(for: .metric("steps"), nativeLayout: true),
            .metricPage("steps")
        )
        XCTAssertEqual(
            NativeRouteResolver.presentation(for: .stress, nativeLayout: true),
            .stressPage
        )
        XCTAssertEqual(
            NativeRouteResolver.presentation(for: .journal, nativeLayout: true),
            .journal
        )
        XCTAssertEqual(
            NativeRouteResolver.presentation(for: .journalLog, nativeLayout: true),
            .journalLog
        )
        XCTAssertEqual(
            NativeRouteResolver.presentation(for: .healthMonitor, nativeLayout: true),
            .healthMonitor
        )
    }

    func testSleepWeekIsPerformanceScaleNotMinutes() {
        let day = sampleMetric(strain: 34, efficiency: 0.87, sleepMin: 431, recovery: 49)
        let imported = whoopImport(days: [day], performance: 87)
        let points = NativeWeek.points(kind: .sleep, days: [day], todayKey: day.day, importedSleep: imported)
        let known = points.filter { !$0.value.isNaN }
        XCTAssertEqual(known.count, 1)
        XCTAssertLessThan(known[0].value, 100.5, "sleep week must be 0–100, not minutes")
        XCTAssertGreaterThan(known[0].value, 10)
        XCTAssertNotEqual(known[0].value, 431, accuracy: 0.1)
        XCTAssertEqual(known[0].value, 87, accuracy: 1e-9)
    }

    func testSleepWeekCardsIncludeHoursAndEfficiencyWhenStored() {
        let day = sampleMetric(strain: 34, efficiency: 0.87, sleepMin: 431, recovery: 49)
        let imported = whoopImport(days: [day], performance: 87)
        let cards = NativeWeek.cards(kind: .sleep, days: [day], todayKey: day.day, importedSleep: imported)
        XCTAssertEqual(cards.map(\.title), ["Sleep Performance", "Hours of Sleep", "Sleep Efficiency"])
        let hours = cards.first { $0.title == "Hours of Sleep" }?.points.filter { $0.value.isFinite }
        XCTAssertEqual(hours?.first?.value ?? -1, 410, accuracy: 0.1)
        let efficiency = cards.first { $0.title == "Sleep Efficiency" }?.points.filter { $0.value.isFinite }
        XCTAssertEqual(efficiency?.first?.value ?? -1, 87, accuracy: 0.1)
    }

    func testRecoveryWeekCardsIncludeVitalsWhenStored() {
        let day = sampleMetric(strain: 34, efficiency: 0.87, sleepMin: 431, recovery: 49)
        let imported = whoopImport(days: [day], performance: 87)
        let cards = NativeWeek.cards(kind: .recovery, days: [day], todayKey: day.day, importedSleep: imported)
        XCTAssertEqual(cards.map(\.title), [
            "Recovery", "Heart Rate Variability", "Resting Heart Rate", "Respiratory Rate",
        ])
        XCTAssertFalse(cards[0].bars == false)
        XCTAssertFalse(cards[1].bars)
    }

    func testStrainWeekCardsIncludeStepsWhenStored() {
        let day = sampleMetric(strain: 34, efficiency: 0.87, sleepMin: 431, recovery: 49)
        let cards = NativeWeek.cards(kind: .strain, days: [day], todayKey: day.day)
        XCTAssertEqual(cards.map(\.title), ["Strain", "Steps"])
        let steps = cards.first { $0.title == "Steps" }?.points.filter { $0.value.isFinite }
        XCTAssertEqual(steps?.first?.value ?? -1, 6545, accuracy: 0.1)
    }

    func testEmptyDayOmitsWeekCards() {
        let empty = DailyMetric(
            day: "2026-11-16",
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
            exerciseCount: nil
        )
        XCTAssertTrue(NativeWeek.cards(kind: .sleep, days: [empty], todayKey: empty.day).isEmpty)
        XCTAssertTrue(NativeWeek.cards(kind: .recovery, days: [empty], todayKey: empty.day).isEmpty)
        XCTAssertTrue(NativeWeek.cards(kind: .strain, days: [empty], todayKey: empty.day).isEmpty)
    }

    func testSleepStagesCarryThirtyDayTypical() {
        let priorDeep = DailyMetric(
            day: "2026-11-15",
            totalSleepMin: 400, efficiency: 0.8, deepMin: 80, remMin: 100, lightMin: 220,
            disturbances: 1, restingHr: 52, avgHrv: 60, recovery: 40, strain: 20, exerciseCount: 0
        )
        let today = DailyMetric(
            day: "2026-11-16",
            totalSleepMin: 431, efficiency: 0.87, deepMin: 70, remMin: 90, lightMin: 250,
            disturbances: 2, restingHr: 51, avgHrv: 66, recovery: 49, strain: 34, exerciseCount: 1
        )
        let model = NativeDay.make(
            days: [priorDeep, today],
            sleeps: [],
            workouts: [],
            todayKey: today.day,
            connected: true,
            effortScale: .whoop,
            now: Date(timeIntervalSince1970: 1_763_280_000)
        )
        XCTAssertEqual(model.sleepStages.map(\.name), ["Light", "Deep", "REM"])
        XCTAssertEqual(model.sleepStages.first { $0.name == "Deep" }?.typical ?? -1, 80, accuracy: 0.1)
        XCTAssertEqual(model.sleep.rows.first?.title, "Hours vs. Needed")
    }

    func testStrainWeekIsWhoopScale() {
        let day = sampleMetric(strain: 34, efficiency: 0.87, sleepMin: 431, recovery: 49)
        let points = NativeWeek.points(kind: .strain, days: [day], todayKey: day.day)
        let known = points.filter { !$0.value.isNaN }
        XCTAssertEqual(known.count, 1)
        XCTAssertEqual(known[0].value, 34 * 0.21, accuracy: 1e-9)
        XCTAssertLessThan(known[0].value, 21.01)
        let imported = whoopImport(days: [day], performance: 87)
        let recovery = NativeWeek.points(kind: .recovery, days: [day], todayKey: day.day, importedSleep: imported)
            .filter { !$0.value.isNaN }
        XCTAssertEqual(recovery[0].value, 49, accuracy: 1e-9)
    }

    func testNativeDaySelectionRoundTripKeepsTheSteppedDay() {
        // A stepped day is stored with the logical day and launch it was set on, so it can expire.
        // A bare yyyy-MM-dd is no longer a durable selection (that was the sticky-day bug).
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let stored = NativeDayLogic.persistSteppedDay(day, now: now, launchId: NativeDayLogic.launchId)
        XCTAssertEqual(
            NativeDayLogic.resolvedDayKey(stored: stored, now: now, launchId: NativeDayLogic.launchId),
            Repository.localDayKey(day)
        )
        XCTAssertEqual(
            Repository.localDayKey(NativeDaySelection.date(from: stored)),
            Repository.localDayKey(day)
        )
        XCTAssertEqual(
            NativeDayLogic.resolvedDayKey(stored: "2026-11-15", now: now),
            Repository.logicalDayKey(now),
            "a bare key without expiry metadata must fall back to logical today"
        )
    }

    func testRecovery37PercentRingEqualsWeeklyBarWithUniqueDays() throws {
        let todayKey = "2026-11-15"
        let keys = NativeWeek.lastSevenKeys(ending: todayKey)
        XCTAssertEqual(keys, [
            "2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12",
            "2026-11-13", "2026-11-14", "2026-11-15",
        ])
        XCTAssertEqual(Set(keys.map(NativeHomeCharts.axisLabel)).count, 7,
                       "Sat and Sun must not share an x label")
        XCTAssertNotEqual(NativeHomeCharts.axisLabel("2026-11-14"),
                          NativeHomeCharts.axisLabel("2026-11-15"))

        let days: [DailyMetric] = keys.enumerated().map { offset, key in
            sampleMetric(
                day: key,
                strain: 30,
                efficiency: 0.80,
                sleepMin: 400,
                recovery: key == todayKey ? 37 : Double(40 + offset)
            )
        }
        let imported = whoopImport(days: days, performance: 87)
        let model = NativeDay.make(
            days: days,
            sleeps: [],
            workouts: [],
            todayKey: todayKey,
            connected: true,
            effortScale: .whoop,
            now: Date(timeIntervalSince1970: 1_763_280_000),
            importedSleep: imported
        )
        XCTAssertEqual(model.recovery.value, "37%")
        XCTAssertEqual(model.recovery.fraction ?? 0, 0.37, accuracy: 1e-9)
        XCTAssertEqual(NativeChrome.recoveryBandIndex(37), 1, "37% is the mid WHOOP band")

        let cards = NativeWeek.cards(kind: .recovery, days: days, todayKey: todayKey, importedSleep: imported)
        let recovery = try XCTUnwrap(cards.first { $0.title == "Recovery" })
        XCTAssertTrue(recovery.bars)
        XCTAssertEqual(recovery.maxY, 100, accuracy: 1e-9)
        XCTAssertTrue(recovery.band)
        XCTAssertEqual(Set(recovery.points.map(\.key)).count, 7)
        XCTAssertEqual(Set(recovery.points.map(\.day)).count, 7)
        let todayBar = try XCTUnwrap(recovery.points.first { $0.key == todayKey })
        XCTAssertEqual(todayBar.value, 37, accuracy: 1e-9)
        XCTAssertEqual(NativeScoreMath.percent(todayBar.value), model.recovery.value)

        for title in ["Heart Rate Variability", "Resting Heart Rate", "Respiratory Rate"] {
            let card = try XCTUnwrap(cards.first { $0.title == title })
            XCTAssertFalse(card.bars, "\(title) must be a line, not Recovery bars")
        }

        let sleepCards = NativeWeek.cards(kind: .sleep, days: days, todayKey: todayKey, importedSleep: imported)
        XCTAssertEqual(Set(sleepCards.first?.points.map(\.key) ?? []).count, 7)
        let strainCards = NativeWeek.cards(kind: .strain, days: days, todayKey: todayKey)
        let strain = try XCTUnwrap(strainCards.first { $0.title == "Strain" })
        XCTAssertTrue(strain.bars)
        XCTAssertEqual(strain.maxY, 21, accuracy: 1e-9)
        XCTAssertEqual(Set(strain.points.map(\.key)).count, 7)
    }

    func testSleepStrainHomeWeekParityOnScoredWeek() throws {
        let todayKey = "2026-11-15"
        let keys = NativeWeek.lastSevenKeys(ending: todayKey)
        XCTAssertEqual(Set(keys).count, 7)
        XCTAssertNotEqual(NativeHomeCharts.axisLabel("2026-11-14"),
                          NativeHomeCharts.axisLabel("2026-11-15"))

        let prior = sampleMetric(
            day: "2026-11-14", strain: 20, efficiency: 0.80, sleepMin: 400, recovery: 40,
            deep: 80, rem: 100, light: 220, steps: 4000, kcal: nil
        )
        let scored = sampleMetric(
            day: todayKey, strain: 34, efficiency: 0.87, sleepMin: 431, recovery: 37,
            deep: 70, rem: 90, light: 250, steps: 6545, kcal: nil
        )
        let withCalories = sampleMetric(
            day: todayKey, strain: 34, efficiency: 0.87, sleepMin: 431, recovery: 37,
            deep: 70, rem: 90, light: 250, steps: 6545, kcal: 512
        )
        let days = keys.map { key -> DailyMetric in
            if key == todayKey { return scored }
            if key == "2026-11-14" { return prior }
            return sampleMetric(
                day: key, strain: 22, efficiency: 0.80, sleepMin: 400, recovery: 45,
                deep: nil, rem: nil, light: nil
            )
        }
        let imported = whoopImport(days: days, performance: 87, need: 480)
        let model = NativeDay.make(
            days: days, sleeps: [], workouts: [],
            todayKey: todayKey, connected: true, effortScale: .whoop,
            now: Date(timeIntervalSince1970: 1_763_280_000),
            importedSleep: imported
        )
        let scores = NativeBandScores.resolve(days: days, importedSleep: imported)

        let sleepBar = try XCTUnwrap(
            NativeWeek.points(kind: .sleep, days: days, todayKey: todayKey, importedSleep: imported)
                .first { $0.key == todayKey && $0.value.isFinite }
        )
        XCTAssertLessThan(sleepBar.value, 100.5)
        XCTAssertNotEqual(sleepBar.value, 431, accuracy: 0.1)
        XCTAssertEqual(NativeScoreMath.percent(sleepBar.value), model.sleep.value)
        XCTAssertEqual(sleepBar.value, NativeDay.sleepPerformance(scored, scores: scores) ?? -1, accuracy: 1e-9)

        XCTAssertEqual(model.sleepHours, NativeScoreMath.duration(410))
        XCTAssertEqual(model.asleepMinutes ?? -1, 410, accuracy: 0.1)
        XCTAssertEqual(model.sleepBlock, model.sleepHours)
        XCTAssertEqual(model.sleepStages.map(\.name), ["Light", "Deep", "REM"])
        XCTAssertEqual(model.sleepStages.first { $0.name == "Light" }?.minutes ?? -1, 250, accuracy: 0.1)
        XCTAssertEqual(model.sleepStages.first { $0.name == "Deep" }?.minutes ?? -1, 70, accuracy: 0.1)
        XCTAssertEqual(model.sleepStages.first { $0.name == "REM" }?.minutes ?? -1, 90, accuracy: 0.1)
        XCTAssertEqual(model.sleepStages.first { $0.name == "Deep" }?.typical ?? -1, 80, accuracy: 0.1)
        XCTAssertEqual(model.restorativeMinutes ?? -1, 160, accuracy: 0.1)
        XCTAssertEqual(NativeDay.restorative(from: model.sleepStages).minutes ?? -1, 160, accuracy: 0.1)
        XCTAssertEqual(model.sleep.rows.first { $0.title == "Sleep Consistency" }?.value, "80%")
        XCTAssertEqual(model.sleep.rows.first { $0.title == "High Sleep Stress" }?.value, "—")
        let hoursRow = try XCTUnwrap(model.sleep.rows.first { $0.title == "Hours vs. Needed" })
        XCTAssertEqual(hoursRow.value, NativeScoreMath.percent(scores.byDay[todayKey]?.hoursVsNeeded))
        XCTAssertEqual(
            hoursRow.value,
            NativeScoreMath.percent(
                scored.totalSleepMin.flatMap { asleep in
                    let need = scores.byDay[todayKey]?.sleepNeed
                    return (need ?? 0) > 0 ? asleep / need! * 100 : nil
                }
            )
        )

        let strainBar = try XCTUnwrap(
            NativeWeek.points(kind: .strain, days: days, todayKey: todayKey)
                .first { $0.key == todayKey && $0.value.isFinite }
        )
        XCTAssertEqual(strainBar.value, 34 * 0.21, accuracy: 1e-9)
        XCTAssertEqual(model.strain.value, String(format: "%.1f", strainBar.value))
        XCTAssertEqual(model.strain.fraction ?? 0, 0.34, accuracy: 1e-9)

        let strainCards = NativeWeek.cards(kind: .strain, days: days, todayKey: todayKey)
        XCTAssertEqual(strainCards.map(\.title), ["Strain", "Steps"])
        XCTAssertTrue(strainCards.allSatisfy(\.bars))
        XCTAssertNil(strainCards.first { $0.title == "Calories" })
        let calorieCards = NativeWeek.cards(kind: .strain, days: [withCalories], todayKey: todayKey)
        let calories = try XCTUnwrap(calorieCards.first { $0.title == "Calories" })
        XCTAssertTrue(calories.bars)
        XCTAssertEqual(calories.points.first { $0.key == todayKey }?.value ?? -1, 512, accuracy: 0.1)

        let recoveryWeek = NativeWeek.points(kind: .recovery, days: days, todayKey: todayKey, importedSleep: imported)
        let strainWeek = NativeWeek.points(kind: .strain, days: days, todayKey: todayKey)
        XCTAssertEqual(Set(recoveryWeek.map(\.key)).count, 7)
        XCTAssertEqual(Set(strainWeek.map(\.key)).count, 7)
        XCTAssertEqual(Set(recoveryWeek.map(\.day)).count, 7)
        let homeRecovery = try XCTUnwrap(recoveryWeek.first { $0.key == todayKey })
        let homeStrain = try XCTUnwrap(strainWeek.first { $0.key == todayKey })
        XCTAssertEqual(homeRecovery.value, 37, accuracy: 1e-9)
        XCTAssertEqual(homeStrain.value, 34 * 0.21, accuracy: 1e-9)
        XCTAssertLessThan(homeStrain.value, 21.01)
        XCTAssertLessThanOrEqual(homeRecovery.value, 100)
    }

    func testSleepContributorRowsUseSleepModelSeries() {
        let todayKey = "2026-11-16"
        let prior = sampleMetric(day: "2026-11-15", strain: 20, efficiency: 0.80, sleepMin: 400, recovery: 40)
        let today = sampleMetric(day: todayKey, strain: 34, efficiency: 0.87, sleepMin: 431, recovery: 49)
        let imported: [String: ImportedSleepFigures] = [
            todayKey: ImportedSleepFigures(performancePct: nil, consistencyPct: 79, needMin: 480, debtMin: nil),
            "2026-11-15": ImportedSleepFigures(performancePct: nil, consistencyPct: 82, needMin: 480, debtMin: nil),
        ]
        let model = NativeDay.make(
            days: [prior, today],
            sleeps: [],
            workouts: [],
            todayKey: todayKey,
            connected: true,
            effortScale: .whoop,
            now: Date(timeIntervalSince1970: 1_763_280_000),
            importedSleep: imported
        )
        let hours = SleepModel.hoursVsNeededSeries(days: [prior, today], importedSleep: imported)
        XCTAssertEqual(
            model.sleep.rows.first { $0.title == "Hours vs. Needed" }?.value,
            NativeScoreMath.percent(hours.series.last)
        )
        let cons = SleepModel.consistencySeries(
            days: [prior, today], sleeps: [], importedSleep: imported
        )
        XCTAssertEqual(
            model.sleep.rows.first { $0.title == "Sleep Consistency" }?.value,
            NativeScoreMath.percent(cons.series.last)
        )
        XCTAssertEqual(model.sleep.rows.first { $0.title == "Sleep Consistency" }?.value, "79%")
        XCTAssertEqual(model.sleep.rows.first { $0.title == "High Sleep Stress" }?.value, "—")
        XCTAssertEqual(
            model.sleep.rows.first { $0.title == "High Sleep Stress" }?.value,
            NativeScoreMath.percent(nil),
            "high sleep stress is display-only and stays hidden without the experimental overnight path"
        )
    }

    func testUnsetEffortScaleDisplaysWhoopAndStoredHundredStaysHundred() {
        XCTAssertEqual(UnitPrefs.resolveEffortScale(""), .whoop)
        XCTAssertEqual(UnitPrefs.resolveEffortScale("not-a-scale"), .whoop)
        XCTAssertEqual(UnitPrefs.resolveEffortScale(EffortScale.hundred.rawValue), .hundred)
        XCTAssertEqual(UnitPrefs.resolveEffortScale(EffortScale.whoop.rawValue), .whoop)

        let stored = sampleDay(scale: UnitPrefs.resolveEffortScale("")).strain
        XCTAssertEqual(stored.value, "7.1")
        XCTAssertEqual(stored.fraction ?? 0, 0.34, accuracy: 1e-9)

        let hundred = sampleDay(scale: UnitPrefs.resolveEffortScale(EffortScale.hundred.rawValue)).strain
        XCTAssertEqual(hundred.value, "34")
        XCTAssertEqual(hundred.fraction ?? 0, 0.34, accuracy: 1e-9)
    }

    private func sampleMetric(
        day: String = "2026-11-16",
        strain: Double,
        efficiency: Double,
        sleepMin: Double,
        recovery: Double,
        deep: Double? = 70,
        rem: Double? = 90,
        light: Double? = 250,
        steps: Int? = 6545,
        kcal: Double? = nil
    ) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: sleepMin,
            efficiency: efficiency,
            deepMin: deep,
            remMin: rem,
            lightMin: light,
            disturbances: 2,
            restingHr: 51,
            avgHrv: 66,
            recovery: recovery,
            strain: strain,
            exerciseCount: 1,
            respRateBpm: 14.7,
            steps: steps,
            activeKcalEst: kcal
        )
    }

    private func whoopImport(days: [DailyMetric], performance: Double? = 87,
                             need: Double? = 480) -> [String: ImportedSleepFigures] {
        Dictionary(uniqueKeysWithValues: days.map {
            ($0.day, ImportedSleepFigures(
                performancePct: performance, consistencyPct: 80, needMin: need, debtMin: 20
            ))
        })
    }

    func testImportedDayShowsWhoopAndComputedDayShowsBand() {
        let whoopDay = sampleMetric(day: "2026-11-16", strain: 34, efficiency: 0.87, sleepMin: 431, recovery: 49)
        let bandOnly = sampleMetric(day: "2026-11-15", strain: 20, efficiency: 0.80, sleepMin: 400, recovery: 40)
        let imported: [String: ImportedSleepFigures] = [
            whoopDay.day: ImportedSleepFigures(
                performancePct: 91, consistencyPct: 77, needMin: 470, debtMin: 22
            )
        ]
        let whoopModel = NativeDay.make(
            days: [bandOnly, whoopDay], sleeps: [], workouts: [],
            todayKey: whoopDay.day, connected: true, effortScale: .whoop,
            now: Date(timeIntervalSince1970: 1_763_280_000),
            importedSleep: imported
        )
        XCTAssertEqual(whoopModel.sleep.value, "91%")
        XCTAssertEqual(whoopModel.recovery.value, "49%")
        XCTAssertEqual(whoopModel.sleep.rows.first { $0.title == "Sleep Consistency" }?.value, "77%")
        XCTAssertEqual(whoopModel.sleepNeedMin ?? -1, 470, accuracy: 1e-9)
        XCTAssertEqual(whoopModel.sleepDebtMin ?? -1, 22, accuracy: 1e-9)

        let bandModel = NativeDay.make(
            days: [bandOnly], sleeps: [], workouts: [],
            todayKey: bandOnly.day, connected: true, effortScale: .whoop,
            now: Date(timeIntervalSince1970: 1_763_280_000)
        )
        let scores = NativeBandScores.resolve(days: [bandOnly], importedSleep: [:])
        XCTAssertEqual(bandModel.recovery.value, NativeScoreMath.percent(scores.byDay[bandOnly.day]?.recovery))
        XCTAssertEqual(bandModel.sleep.value, NativeScoreMath.percent(scores.byDay[bandOnly.day]?.sleepPerformance))
        XCTAssertEqual(bandModel.sleepNeedMin, scores.byDay[bandOnly.day]?.sleepNeed)
    }

    private func sampleDay(scale: EffortScale) -> NativeDay.Model {
        let day = sampleMetric(strain: 34, efficiency: 0.87, sleepMin: 431, recovery: 49)
        return NativeDay.make(
            days: [day],
            sleeps: [],
            workouts: [],
            todayKey: day.day,
            connected: true,
            effortScale: scale,
            now: Date(timeIntervalSince1970: 1_763_280_000)
        )
    }
}

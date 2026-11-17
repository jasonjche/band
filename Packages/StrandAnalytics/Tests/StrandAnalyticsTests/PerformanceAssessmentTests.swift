import XCTest
@testable import StrandAnalytics

final class PerformanceAssessmentTests: XCTestCase {

    // MARK: - Windows

    func testLastCompleteWeekOnSaturdayUsesPriorWeek() {
        // 2026-06-13 is Saturday; the week Mon 8–Sun 14 is still open.
        let w = PerformanceAssessment.lastCompleteWindow(kind: .weekly, asOfDay: "2026-06-13")!
        XCTAssertEqual(w.start, "2026-06-01")
        XCTAssertEqual(w.end, "2026-06-07")
        XCTAssertEqual(w.priorStart, "2026-05-25")
        XCTAssertEqual(w.priorEnd, "2026-05-31")
    }

    func testLastCompleteWeekOnSundayIncludesThatWeek() {
        let w = PerformanceAssessment.lastCompleteWindow(kind: .weekly, asOfDay: "2026-06-14")!
        XCTAssertEqual(w.start, "2026-06-08")
        XCTAssertEqual(w.end, "2026-06-14")
    }

    func testLastCompleteWeekOnMondayIsTheWeekJustEnded() {
        let w = PerformanceAssessment.lastCompleteWindow(kind: .weekly, asOfDay: "2026-06-15")!
        XCTAssertEqual(w.start, "2026-06-08")
        XCTAssertEqual(w.end, "2026-06-14")
    }

    func testLastCompleteMonthMidMonthIsPrevious() {
        let w = PerformanceAssessment.lastCompleteWindow(kind: .monthly, asOfDay: "2026-06-15")!
        XCTAssertEqual(w.start, "2026-05-01")
        XCTAssertEqual(w.end, "2026-05-31")
        XCTAssertEqual(w.priorStart, "2026-04-01")
        XCTAssertEqual(w.priorEnd, "2026-04-30")
    }

    func testLastCompleteMonthOnLastDayIncludesThatMonth() {
        let w = PerformanceAssessment.lastCompleteWindow(kind: .monthly, asOfDay: "2026-06-30")!
        XCTAssertEqual(w.start, "2026-06-01")
        XCTAssertEqual(w.end, "2026-06-30")
    }

    func testLastCompleteMonthOnFirstDayIsPrevious() {
        let w = PerformanceAssessment.lastCompleteWindow(kind: .monthly, asOfDay: "2026-07-01")!
        XCTAssertEqual(w.start, "2026-06-01")
        XCTAssertEqual(w.end, "2026-06-30")
    }

    func testHistoryWindowsNewestFirst() {
        let weeks = PerformanceAssessment.historyWindows(kind: .weekly, asOfDay: "2026-06-15", limit: 4)
        XCTAssertEqual(weeks.map(\.start), ["2026-06-08", "2026-06-01", "2026-05-25", "2026-05-18"])
        let months = PerformanceAssessment.historyWindows(kind: .monthly, asOfDay: "2026-06-15", limit: 2)
        XCTAssertEqual(months.map(\.start), ["2026-05-01", "2026-04-01"])
    }

    func testBadAsOfYieldsNilWindow() {
        XCTAssertNil(PerformanceAssessment.lastCompleteWindow(kind: .weekly, asOfDay: "nope"))
        XCTAssertNil(PerformanceAssessment.build(kind: .weekly, series: .init(), asOfDay: "nope"))
    }

    // MARK: - Averages

    func testAveragesVersusPriorWeek() {
        var recovery: [String: Double] = [:]
        for d in 8...14 { recovery[String(format: "2026-06-%02d", d)] = 70 }
        for d in 1...7 { recovery[String(format: "2026-06-%02d", d)] = 60 }
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(recovery: recovery),
            asOfDay: "2026-06-15"
        )!
        let row = report.average(.recovery)!
        XCTAssertEqual(row.current.mean, 70, accuracy: 1e-9)
        XCTAssertEqual(row.previous.mean, 60, accuracy: 1e-9)
        XCTAssertEqual(row.comparison.delta, 10, accuracy: 1e-9)
        XCTAssertEqual(report.daysWithData, 7)
    }

    func testMissingMetricIsOmitted() {
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(recovery: ["2026-06-08": 70]),
            asOfDay: "2026-06-15"
        )!
        XCTAssertNotNil(report.average(.recovery))
        XCTAssertNil(report.average(.hrv))
        XCTAssertNil(report.average(.stressHigh))
    }

    func testStrain21Conversion() {
        XCTAssertEqual(PerformanceAssessment.strain21(fromStored: 100), 21, accuracy: 1e-9)
        XCTAssertEqual(PerformanceAssessment.strain21(fromStored: 0), 0, accuracy: 1e-9)
    }

    func testAsleepMinutesPrefersStagesOverInflatedTotal() {
        let staged = PerformanceAssessment.asleepMinutes(
            light: 250, deep: 70, rem: 90, totalSleepMin: 980
        )
        XCTAssertEqual(staged ?? -1, 410, accuracy: 1e-9)
        let fallback = PerformanceAssessment.asleepMinutes(
            light: nil, deep: nil, rem: nil, totalSleepMin: 431
        )
        XCTAssertEqual(fallback ?? -1, 431, accuracy: 1e-9)
        XCTAssertNil(PerformanceAssessment.asleepMinutes(
            light: nil, deep: nil, rem: nil, totalSleepMin: 0
        ))
    }

    func testAsleepMinutesPrefersMainSessionOverStackedDailyStages() {
        let stacked = PerformanceAssessment.asleepMinutes(
            light: 953, deep: 72, rem: 145, totalSleepMin: 1171,
            mainSessionAsleepMin: 528
        )
        XCTAssertEqual(stacked ?? -1, 528, accuracy: 1e-9)
        let fromJSON = PerformanceAssessment.asleepMinutes(
            stagesJSON: "{\"light\":291,\"rem\":124,\"deep\":113,\"awake\":115}"
        )
        XCTAssertEqual(fromJSON ?? -1, 528, accuracy: 1e-9)
    }

    func testWorkoutsBySportAndZones() {
        let workouts = [
            PerformanceAssessment.WorkoutEvent(
                day: "2026-06-10", sport: "Running", durationMin: 40,
                zoneMinutes: [5, 10, 15, 8, 2]
            ),
            PerformanceAssessment.WorkoutEvent(
                day: "2026-06-12", sport: "Running", durationMin: 30,
                zoneMinutes: [4, 8, 10, 6, 2]
            ),
            PerformanceAssessment.WorkoutEvent(
                day: "2026-06-04", sport: "Running", durationMin: 20,
                zoneMinutes: [10, 10, 0, 0, 0]
            ),
            PerformanceAssessment.WorkoutEvent(
                day: "2026-06-11", sport: "Weightlifting", durationMin: 50
            ),
        ]
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(workouts: workouts),
            asOfDay: "2026-06-15"
        )!
        XCTAssertEqual(report.sports.count, 2)
        XCTAssertEqual(report.sports[0].sport, "Running")
        XCTAssertEqual(report.sports[0].sessions, 2)
        let lift = report.sports.first { $0.sport == "Weightlifting" }!
        XCTAssertEqual(lift.sessions, 1)
        let run = report.sports.first { $0.sport == "Running" }!
        XCTAssertEqual(run.sessions, 2)
        XCTAssertEqual(run.priorSessions, 1)
        let z13 = report.average(.zones13)!
        XCTAssertEqual(z13.current.mean, 26, accuracy: 0.01) // (30+22)/2 days with values... wait daily maps
        // Two days this week with zones: 30 and 22 → mean 26. Prior week one day 20.
        XCTAssertEqual(z13.previous.mean, 20, accuracy: 0.01)
        let z45 = report.average(.zones45)!
        XCTAssertEqual(z45.current.n, 2)
        XCTAssertEqual(z45.current.mean, 9, accuracy: 0.01) // (10+8)/2
    }

    // MARK: - Balance

    func testBalanceOptimalWhenStrainInsideTarget() {
        // Recovery 50 → generic band ~8.5–14.5. Strain 11 sits inside.
        let series = filledWeek(recovery: 50, strain: 11)
        let report = PerformanceAssessment.build(kind: .weekly, series: series, asOfDay: "2026-06-15")!
        XCTAssertEqual(report.balance.state, .optimal)
        XCTAssertEqual(report.balance.classifiedDays, 7)
        XCTAssertEqual(report.balance.optimalDays, 7)
        XCTAssertTrue(report.balance.sentence.contains("inside the recovery target"))
        XCTAssertTrue(report.balance.sentence.contains("load matched"))
    }

    func testBalanceOverreachingWhenStrainAboveTarget() {
        let series = filledWeek(recovery: 20, strain: 18)
        let report = PerformanceAssessment.build(kind: .weekly, series: series, asOfDay: "2026-06-15")!
        XCTAssertEqual(report.balance.state, .overreaching)
        XCTAssertEqual(report.balance.overreachingDays, 7)
        XCTAssertTrue(report.balance.sentence.contains("above the recovery target"))
        XCTAssertTrue(report.balance.sentence.contains("more than a third"))
    }

    func testBalanceRestoringWhenStrainBelowTarget() {
        let series = filledWeek(recovery: 80, strain: 5)
        let report = PerformanceAssessment.build(kind: .weekly, series: series, asOfDay: "2026-06-15")!
        XCTAssertEqual(report.balance.state, .restoring)
        XCTAssertEqual(report.balance.restoringDays, 7)
        XCTAssertTrue(report.balance.sentence.contains("below the recovery target"))
        XCTAssertTrue(report.balance.sentence.contains("a majority of days"))
        XCTAssertTrue(report.balance.sentence.contains("paid down load"))
    }

    func testBalance12Of29RestoringIsNotRestoring() {
        XCTAssertEqual(
            PerformanceAssessment.classifyBalance(optimal: 17, overreaching: 0, restoring: 12, minDays: 12),
            .optimal
        )
        XCTAssertEqual(
            PerformanceAssessment.classifyBalance(optimal: 0, overreaching: 0, restoring: 15, minDays: 12),
            .restoring
        )
        XCTAssertEqual(
            PerformanceAssessment.classifyBalance(optimal: 19, overreaching: 10, restoring: 0, minDays: 12),
            .overreaching
        )

        var recovery: [String: Double] = [:]
        var strain: [String: Double] = [:]
        for d in 1...30 {
            let day = String(format: "2026-09-%02d", d)
            recovery[day] = 50
            strain[day] = 11
        }
        for d in 1...12 {
            let day = String(format: "2026-10-%02d", d)
            recovery[day] = 80
            strain[day] = 5
        }
        for d in 13...29 {
            let day = String(format: "2026-10-%02d", d)
            recovery[day] = 50
            strain[day] = 11
        }
        let report = PerformanceAssessment.build(
            kind: .monthly,
            series: .init(recovery: recovery, strain21: strain),
            asOfDay: "2026-11-15"
        )!
        XCTAssertEqual(report.window.start, "2026-10-01")
        XCTAssertEqual(report.balance.restoringDays, 12)
        XCTAssertEqual(report.balance.classifiedDays, 29)
        XCTAssertEqual(report.balance.state, .optimal)
        XCTAssertTrue(report.balance.sentence.contains("17 of 29"))
        XCTAssertFalse(report.balance.sentence.contains("paid down load"))
        XCTAssertFalse(report.balance.sentence.contains("12 of 29"))
    }

    func testBalanceInsufficientWhenSparse() {
        let series = PerformanceAssessment.Series(
            recovery: ["2026-06-08": 70],
            strain21: ["2026-06-08": 10]
        )
        let report = PerformanceAssessment.build(kind: .weekly, series: series, asOfDay: "2026-06-15")!
        XCTAssertEqual(report.balance.state, .insufficient)
    }

    // MARK: - Sleep

    func testSleepBestAndWorstNight() {
        var perf: [String: Double] = [:]
        var hours: [String: Double] = [:]
        let vals = [85.0, 85, 39, 79, 78, 79, 81]
        for (i, v) in vals.enumerated() {
            let day = String(format: "2026-06-%02d", 8 + i)
            perf[day] = v
            hours[day] = 7.5
        }
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(sleepPerformance: perf, sleepHours: hours),
            asOfDay: "2026-06-15"
        )!
        XCTAssertEqual(report.sleep.best?.day, "2026-06-08")
        XCTAssertEqual(report.sleep.worst?.day, "2026-06-10")
        XCTAssertTrue(report.sleep.sentences.contains { $0.contains("Best night") && $0.contains("39%") })
    }

    func testSleepHoursSwingSentence() {
        var hours: [String: Double] = [:]
        let vals = [8.0, 5.0, 9.0, 4.5, 8.5, 5.5, 9.0]
        for (i, v) in vals.enumerated() {
            hours[String(format: "2026-06-%02d", 8 + i)] = v
        }
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(sleepHours: hours),
            asOfDay: "2026-06-15"
        )!
        XCTAssertGreaterThan(report.sleep.hoursSD ?? 0, 0.75)
        XCTAssertTrue(report.sleep.sentences.contains { $0.contains("varied by") })
    }

    func testSleepDebtGrewWhenNightsUnderNeed() {
        var hours: [String: Double] = [:]
        // 14 nights of 8h to start even, then a week of 6h.
        for day in daysBetween("2026-05-25", "2026-06-07") { hours[day] = 8 }
        for d in 8...14 { hours[String(format: "2026-06-%02d", d)] = 6 }
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(sleepHours: hours),
            asOfDay: "2026-06-15"
        )!
        XCTAssertNotNil(report.sleep.debtStartMin)
        XCTAssertNotNil(report.sleep.debtEndMin)
        XCTAssertLessThan(report.sleep.debtEndMin!, report.sleep.debtStartMin!)
        XCTAssertTrue(report.sleep.sentences.contains { $0.contains("Sleep debt grew") })
    }

    // MARK: - Drivers

    func testDriversRequireClearEffectAndPresenceInPeriod() {
        let yes = daysBetween("2026-04-01", "2026-04-10")
        let no = daysBetween("2026-05-01", "2026-05-10")
        var recovery: [String: Double] = [:]
        for d in yes { recovery[d] = 50 }
        for d in no { recovery[d] = 72 }
        // Alcohol yes also lands in the assessed week.
        recovery["2026-06-10"] = 48
        let answers =
            yes.map { JournalImpact.Answer(day: $0, behaviorId: "Alcohol", yes: true) }
            + no.map { JournalImpact.Answer(day: $0, behaviorId: "Alcohol", yes: false) }
            + [JournalImpact.Answer(day: "2026-06-10", behaviorId: "Alcohol", yes: true)]
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(recovery: recovery, journal: answers),
            asOfDay: "2026-06-15"
        )!
        XCTAssertEqual(report.drivers.count, 1)
        XCTAssertEqual(report.drivers[0].verdict, .hurts)
        XCTAssertEqual(report.drivers[0].yesInPeriod, 1)
        XCTAssertTrue(report.drivers[0].sentence.contains("lower recovery"))
        XCTAssertTrue(report.drivers[0].sentence.contains("1 night"))
    }

    func testDriversSilentWhenEvidenceIsThin() {
        let answers = [
            JournalImpact.Answer(day: "2026-06-10", behaviorId: "Caffeine", yes: true),
            JournalImpact.Answer(day: "2026-06-11", behaviorId: "Caffeine", yes: false),
        ]
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(recovery: ["2026-06-10": 70, "2026-06-11": 68], journal: answers),
            asOfDay: "2026-06-15"
        )!
        XCTAssertTrue(report.drivers.isEmpty)
    }

    func testDriversSilentWhenClearButAbsentFromPeriod() {
        let yes = daysBetween("2026-04-01", "2026-04-10")
        let no = daysBetween("2026-05-01", "2026-05-10")
        var recovery: [String: Double] = [:]
        for d in yes { recovery[d] = 50 }
        for d in no { recovery[d] = 72 }
        for d in 8...14 { recovery[String(format: "2026-06-%02d", d)] = 70 }
        let answers =
            yes.map { JournalImpact.Answer(day: $0, behaviorId: "Alcohol", yes: true) }
            + no.map { JournalImpact.Answer(day: $0, behaviorId: "Alcohol", yes: false) }
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(recovery: recovery, journal: answers),
            asOfDay: "2026-06-15"
        )!
        XCTAssertTrue(report.drivers.isEmpty)
    }

    // MARK: - Highlights

    func testOutlierHighlightNamesTheRedDay() {
        var recovery: [String: Double] = [:]
        for d in 8...14 { recovery[String(format: "2026-06-%02d", d)] = 60 }
        recovery["2026-06-10"] = 14
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(recovery: recovery),
            asOfDay: "2026-06-15"
        )!
        XCTAssertTrue(report.highlights.contains { $0.contains("only red recovery day") && $0.contains("14%") })
        XCTAssertFalse(report.highlights.contains { $0.hasPrefix("Recovery averaged") })
    }

    func testHoursVersusPerformanceSplit() {
        var hours: [String: Double] = [:]
        var perf: [String: Double] = [:]
        for d in 1...7 {
            hours[String(format: "2026-06-%02d", d)] = 7.4
            perf[String(format: "2026-06-%02d", d)] = 85
        }
        for d in 8...14 {
            hours[String(format: "2026-06-%02d", d)] = 7.4
            perf[String(format: "2026-06-%02d", d)] = 74
        }
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(sleepPerformance: perf, sleepHours: hours),
            asOfDay: "2026-06-15"
        )!
        XCTAssertTrue(report.highlights.contains { $0.contains("Hours matched") && $0.contains("sleep performance fell") })
    }

    func testFlatWeekProducesNoFillerHighlights() {
        var recovery: [String: Double] = [:]
        var strain: [String: Double] = [:]
        var hours: [String: Double] = [:]
        for d in 1...14 {
            let day = String(format: "2026-06-%02d", d)
            recovery[day] = 55
            strain[day] = 11
            hours[day] = 7.5
        }
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(recovery: recovery, strain21: strain, sleepHours: hours),
            asOfDay: "2026-06-15"
        )!
        XCTAssertTrue(report.highlights.isEmpty, "got \(report.highlights)")
        XCTAssertEqual(report.balance.state, .optimal)
    }

    func testWorkoutBunchingHighlight() {
        let workouts = [
            PerformanceAssessment.WorkoutEvent(day: "2026-06-09", sport: "Running", durationMin: 80),
            PerformanceAssessment.WorkoutEvent(day: "2026-06-10", sport: "Running", durationMin: 70),
            PerformanceAssessment.WorkoutEvent(day: "2026-06-12", sport: "Yoga", durationMin: 20),
            PerformanceAssessment.WorkoutEvent(day: "2026-06-13", sport: "Walk", durationMin: 15),
        ]
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(workouts: workouts),
            asOfDay: "2026-06-15"
        )!
        XCTAssertTrue(report.highlights.contains { $0.contains("two days") })
    }

    func testAtMostThreeHighlights() {
        var recovery: [String: Double] = [:]
        var hours: [String: Double] = [:]
        var perf: [String: Double] = [:]
        var steps: [String: Double] = [:]
        var strain: [String: Double] = [:]
        for d in 1...7 {
            let day = String(format: "2026-06-%02d", d)
            recovery[day] = 70
            hours[day] = 7.4
            perf[day] = 85
            steps[day] = 12000
            strain[day] = 8
        }
        for d in 8...14 {
            let day = String(format: "2026-06-%02d", d)
            recovery[day] = 55
            hours[day] = 7.4
            perf[day] = 74
            steps[day] = 8000
            strain[day] = 12
        }
        recovery["2026-06-10"] = 12
        let workouts = [
            PerformanceAssessment.WorkoutEvent(day: "2026-06-09", sport: "Running", durationMin: 90),
            PerformanceAssessment.WorkoutEvent(day: "2026-06-10", sport: "Running", durationMin: 80),
            PerformanceAssessment.WorkoutEvent(day: "2026-06-12", sport: "Yoga", durationMin: 15),
            PerformanceAssessment.WorkoutEvent(day: "2026-06-13", sport: "Walk", durationMin: 10),
        ]
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(recovery: recovery, strain21: strain, sleepPerformance: perf,
                          sleepHours: hours, steps: steps, workouts: workouts),
            asOfDay: "2026-06-15"
        )!
        XCTAssertLessThanOrEqual(report.highlights.count, 3)
        XCTAssertFalse(report.highlights.isEmpty)
    }

    // MARK: - Notify

    func testNotifyFiresOncePerCompletedWeek() {
        let end = PerformanceAssessment.NotifyPolicy.shouldNotify(
            enabled: true, asOfDay: "2026-06-15", lastNotifiedEnd: nil
        )
        XCTAssertEqual(end, "2026-06-14")
        XCTAssertNil(PerformanceAssessment.NotifyPolicy.shouldNotify(
            enabled: true, asOfDay: "2026-06-15", lastNotifiedEnd: "2026-06-14"
        ))
        XCTAssertNil(PerformanceAssessment.NotifyPolicy.shouldNotify(
            enabled: false, asOfDay: "2026-06-15", lastNotifiedEnd: nil
        ))
    }

    func testNotifyCopyUsesTheWeekRange() {
        let copy = PerformanceAssessment.NotifyPolicy.copy(weekStart: "2026-06-08", weekEnd: "2026-06-14")
        XCTAssertEqual(copy.title, "Weekly assessment ready")
        XCTAssertEqual(copy.body, "The week of Mon 8 Jun–14 Jun is in.")
    }

    func testRangeLabel() {
        let week = PerformanceAssessment.lastCompleteWindow(kind: .weekly, asOfDay: "2026-06-15")!
        XCTAssertEqual(PerformanceAssessment.rangeLabel(week), "Mon 8 Jun – 14 Jun")
        let month = PerformanceAssessment.lastCompleteWindow(kind: .monthly, asOfDay: "2026-06-15")!
        XCTAssertEqual(PerformanceAssessment.rangeLabel(month), "May 2026")
    }

    // MARK: - Fixtures

    private func filledWeek(recovery: Double, strain: Double) -> PerformanceAssessment.Series {
        var rec: [String: Double] = [:]
        var st: [String: Double] = [:]
        for d in 8...14 {
            rec[String(format: "2026-06-%02d", d)] = recovery
            st[String(format: "2026-06-%02d", d)] = strain
        }
        return .init(recovery: rec, strain21: st)
    }

    private func daysBetween(_ start: String, _ end: String) -> [String] {
        var out: [String] = []
        var day = start
        while day <= end {
            out.append(day)
            day = WeeklyDigestEngine.addDays(day, 1)
        }
        return out
    }
}

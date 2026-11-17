import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// Facts for the WHOOP-shaped screens. Pure. The views only format these.

struct NativeStage: Identifiable {
    var id: String { name }
    var name: String
    var minutes: Double?
    var typical: Double?
    var tint: Color
}

/// Week series the score pages plot. Sleep is 0–100 performance, not minutes.
/// Strain is the WHOOP 0–21 display scale. Tests call this same function.
enum NativeWeek {
    /// One Weekly Trends card on a score page. Only series the store can fill.
    struct Card: Identifiable {
        enum Format: Equatable { case percent, strain, duration, number, oneDecimal }
        struct Stack: Identifiable {
            var id: String { title }
            var title: String
            var points: [NativeDayPoint]
            var tint: Color
        }
        var id: String { title }
        var title: String
        var points: [NativeDayPoint]
        var maxY: Double
        var bars: Bool
        var tint: Color
        var route: TabRoute?
        var format: Format
        var band: Bool
        var stacks: [Stack] = []
    }

    static func points(kind: NativeScoreKind, days: [DailyMetric], todayKey: String,
                       effortScale: EffortScale = .whoop,
                       sleeps: [CachedSleepSession] = [],
                       workouts: [WorkoutRow] = [],
                       importedSleep: [String: ImportedSleepFigures] = [:]) -> [NativeDayPoint] {
        let scores = NativeBandScores.resolve(
            days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        let workoutMax = NativeStrain.workoutMaxByDay(workouts)
        return series(days, todayKey: todayKey) { day in
            switch kind {
            case .strain:
                return NativeStrain.day(
                    stored: day.strain, live: nil,
                    imported: NativeStrain.isImportedDay(importedSleep[day.day]),
                    workoutMax: workoutMax[day.day]
                ).map { NativeDayLogic.strainDisplayValue($0, scale: effortScale) }
            case .recovery: return scores.byDay[day.day]?.recovery
            case .sleep: return scores.byDay[day.day]?.sleepPerformance
            }
        }
    }

    /// Last seven days, weekday labels, NaN when that day has no value.
    static func series(_ days: [DailyMetric], todayKey: String, value: (DailyMetric) -> Double?) -> [NativeDayPoint] {
        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0) })
        return lastSevenKeys(ending: todayKey).map { key in
            NativeDayPoint(key: key, value: byDay[key].flatMap(value) ?? .nan)
        }
    }

    static func cards(kind: NativeScoreKind, days: [DailyMetric], todayKey: String,
                      effortScale: EffortScale = .whoop,
                      sleeps: [CachedSleepSession] = [],
                      workouts: [WorkoutRow] = [],
                      importedSleep: [String: ImportedSleepFigures] = [:]) -> [Card] {
        let filled: (Card) -> Bool = { $0.points.contains { $0.value.isFinite } }
        switch kind {
        case .sleep:
            let hours = series(days, todayKey: todayKey) {
                NativeDayLogic.asleepMinutes(light: $0.lightMin, deep: $0.deepMin, rem: $0.remMin, totalSleepMin: $0.totalSleepMin)
            }
            let efficiency = series(days, todayKey: todayKey) {
                $0.efficiency.map { $0 <= 1 ? $0 * 100 : $0 }
            }
            return [
                Card(title: "Sleep Performance", points: points(kind: .sleep, days: days, todayKey: todayKey, effortScale: effortScale, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep),
                     maxY: 100, bars: true, tint: NativeChrome.sleep, route: nil, format: .percent, band: false),
                Card(title: "Hours of Sleep", points: hours,
                     maxY: max(hours.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 480),
                     bars: true, tint: NativeChrome.sleep, route: .metric("hours_vs_needed_pct"),
                     format: .duration, band: false),
                Card(title: "Sleep Efficiency", points: efficiency,
                     maxY: 100, bars: true, tint: NativeChrome.sleep, route: .metric("sleep_efficiency"),
                     format: .percent, band: true),
            ].filter(filled)
        case .recovery:
            let hrv = series(days, todayKey: todayKey) { $0.avgHrv }
            let rhr = series(days, todayKey: todayKey) { $0.restingHr.map(Double.init) }
            let resp = series(days, todayKey: todayKey) { $0.respRateBpm }
            return [
                Card(title: "Recovery", points: points(kind: .recovery, days: days, todayKey: todayKey, effortScale: effortScale, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep),
                     maxY: 100, bars: true, tint: NativeChrome.recovery, route: nil, format: .percent, band: true),
                Card(title: "Heart Rate Variability", points: hrv,
                     maxY: max(hrv.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 40),
                     bars: false, tint: NativeChrome.recovery, route: .metric("hrv"),
                     format: .number, band: false),
                Card(title: "Resting Heart Rate", points: rhr,
                     maxY: max(rhr.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 50),
                     bars: false, tint: Color.orange, route: .metric("resting_hr"),
                     format: .number, band: false),
                Card(title: "Respiratory Rate", points: resp,
                     maxY: max(resp.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 16),
                     bars: false, tint: Color.cyan, route: .metric("resp_rate"),
                     format: .oneDecimal, band: false),
            ].filter(filled)
        case .strain:
            let steps = series(days, todayKey: todayKey) { $0.steps.map(Double.init) }
            let kcal = series(days, todayKey: todayKey) { $0.activeKcalEst }
            let z1 = workoutSeries(workouts, todayKey: todayKey) { NativeDay.zoneMinutes($0, zones: 0..<1) }
            let z2 = workoutSeries(workouts, todayKey: todayKey) { NativeDay.zoneMinutes($0, zones: 1..<2) }
            let z3 = workoutSeries(workouts, todayKey: todayKey) { NativeDay.zoneMinutes($0, zones: 2..<3) }
            let z4 = workoutSeries(workouts, todayKey: todayKey) { NativeDay.zoneMinutes($0, zones: 3..<4) }
            let z5 = workoutSeries(workouts, todayKey: todayKey) { NativeDay.zoneMinutes($0, zones: 4..<5) }
            let z13 = sumSeries(z1, z2, z3)
            let z45 = sumSeries(z4, z5)
            let strength = workoutSeries(workouts, todayKey: todayKey) { NativeDay.strengthMinutes($0) }
            return [
                Card(title: "Strain", points: points(kind: .strain, days: days, todayKey: todayKey, effortScale: effortScale, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep),
                     maxY: NativeDayLogic.strainMaxY(effortScale), bars: true, tint: NativeChrome.strain, route: nil, format: .strain, band: false),
                Card(title: "Heart Rate Zones 1–3", points: z13,
                     maxY: max(z13.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 1),
                     bars: true, tint: NativeTokens.hrZone2, route: nil, format: .duration, band: false,
                     stacks: [
                        Card.Stack(title: "Zone 1", points: z1, tint: NativeTokens.hrZone1),
                        Card.Stack(title: "Zone 2", points: z2, tint: NativeTokens.hrZone2),
                        Card.Stack(title: "Zone 3", points: z3, tint: NativeTokens.hrZone3),
                     ]),
                Card(title: "Heart Rate Zones 4–5", points: z45,
                     maxY: max(z45.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 1),
                     bars: true, tint: NativeTokens.hrZone4, route: nil, format: .duration, band: false,
                     stacks: [
                        Card.Stack(title: "Zone 4", points: z4, tint: NativeTokens.hrZone4),
                        Card.Stack(title: "Zone 5", points: z5, tint: NativeTokens.hrZone5),
                     ]),
                Card(title: "Steps", points: steps,
                     maxY: max(steps.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 1),
                     bars: true, tint: NativeChrome.activity, route: .metric("steps"),
                     format: .number, band: false),
                Card(title: "Calories", points: kcal,
                     maxY: max(kcal.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 1),
                     bars: true, tint: NativeChrome.activity, route: .metric("energy_kcal"),
                     format: .number, band: false),
                Card(title: "Strength Activity Time", points: strength,
                     maxY: max(strength.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 1),
                     bars: true, tint: NativeChrome.strain, route: nil, format: .duration, band: false),
            ].filter(filled)
        }
    }

    static func workoutSeries(_ workouts: [WorkoutRow], todayKey: String,
                              value: ([WorkoutRow]) -> Double?) -> [NativeDayPoint] {
        let byDay = Dictionary(grouping: workouts) {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs)))
        }
        return lastSevenKeys(ending: todayKey).map { key in
            NativeDayPoint(key: key, value: value(byDay[key] ?? []) ?? .nan)
        }
    }

    static func sumSeries(_ series: [NativeDayPoint]...) -> [NativeDayPoint] {
        guard let first = series.first else { return [] }
        return first.indices.map { index in
            let key = first[index].key
            let total = series.reduce(0.0) { acc, points in
                let value = points[index].value
                return acc + (value.isFinite ? value : 0)
            }
            let any = series.contains { $0[index].value.isFinite }
            return NativeDayPoint(key: key, value: any && total > 0 ? total : .nan)
        }
    }

    static func lastSevenKeys(ending todayKey: String) -> [String] {
        guard let end = NativeChartDay.date(from: todayKey) else { return [todayKey] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return (0..<7).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: end) ?? end
            return NativeChartDay.key(from: day)
        }
    }
}

enum NativeDay {
    struct Activity: Equatable, Identifiable {
        var id: Int { startTs }
        var startTs: Int
        var sport: String
        var strainText: String
        var timeRange: String
        var startClock: String
        var endClock: String
        var symbol: String
    }

    struct Model {
        var dateLine: String
        var sleep: NativeScore
        var recovery: NativeScore
        var strain: NativeScore
        var activities: [Activity]
        var sleepHours: String?
        var asleepMinutes: Double?
        var inBedMinutes: Double?
        var sleepStages: [NativeStage]
        var restorativeMinutes: Double?
        var restorativeTypical: Double?
        var sleepBlock: String?
        var sleepStart: Date?
        var sleepEnd: Date?
        var awakeTypical: Double?
        var dashboard: [NativeScore.Row]
        var journalDays: [Bool]
        var connected: Bool
        var sleepNeedMin: Double?
        var sleepDebtMin: Double?
    }

    static func make(days: [DailyMetric], sleeps: [CachedSleepSession], workouts: [WorkoutRow],
                     todayKey: String, connected: Bool, effortScale: EffortScale, now: Date = Date(),
                     journalEntries: [JournalEntry] = [],
                     importedSleep: [String: ImportedSleepFigures] = [:],
                     highSleepStress: Double? = nil,
                     liveStrain: Double? = nil) -> Model {
        let sleepSession = sleeps.last {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == todayKey
        }
        let today = days.last { $0.day == todayKey }
        let viewingToday = todayKey == NativeDayLogic.logicalToday(now: now)
        let scores = NativeBandScores.resolve(
            days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        let todayScore = scores.byDay[todayKey]
        // A day shows only its own night. A day the strap was not worn reads "No Data";
        // it never borrows an older night's sleep, HRV or recovery.
        let recoveryKey: String? = todayKey
        let hrvDay = today
        let sleepDay = today
        let sleepKey = sleepDay?.day
        let sleepScoreRow = sleepKey.flatMap { scores.byDay[$0] }
        let prior = Array(days.filter { $0.day < todayKey }.suffix(30))
        let source = days.last { $0.day == recoveryKey } ?? hrvDay ?? sleepDay
        let recovery = recoveryKey.flatMap { scores.byDay[$0]?.recovery }
        let strain = NativeStrain.day(
            stored: today?.strain,
            live: viewingToday ? liveStrain : nil,
            imported: NativeStrain.isImportedDay(importedSleep[todayKey]),
            workoutMax: NativeStrain.workoutMaxByDay(workouts)[todayKey]
        )
        let sleepScore = sleepScoreRow?.sleepPerformance
        let sleepStart = sleepSession.map { Date(timeIntervalSince1970: TimeInterval($0.effectiveStartTs)) }
        let sleepEnd = sleepSession.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) }
        let asleepMinutes = NativeDayLogic.asleepMinutes(
            light: sleepDay?.lightMin, deep: sleepDay?.deepMin, rem: sleepDay?.remMin,
            totalSleepMin: sleepDay?.totalSleepMin
        )
        let inBedMinutes = NativeDayLogic.inBedMinutes(start: sleepStart, end: sleepEnd)
        let sleepStages = stages(sleepDay, prior: prior, asleep: asleepMinutes, inBed: inBedMinutes)
        let restorative = restorative(from: sleepStages)
        let sleepDuration = asleepMinutes.map { NativeDayLogic.durationText($0) }

        return Model(
            dateLine: dateLine(for: todayKey, fallback: now),
            sleep: NativeScore(
                name: "Sleep",
                value: NativeScoreMath.percent(sleepScore),
                known: sleepScore != nil,
                fraction: sleepScore.map { $0 / 100 },
                tint: NativeChrome.sleep,
                rows: sleepRows(day: sleepDay, prior: prior, scores: scores,
                                highSleepStress: highSleepStress),
                insight: sleepInsight(sleepScore),
                route: .sleep
            ),
            recovery: NativeScore(
                name: "Recovery",
                value: NativeScoreMath.percent(recovery),
                known: recovery != nil,
                fraction: recovery.map { $0 / 100 },
                tint: recovery.map { NativeChrome.recoveryBand($0) } ?? NativeChrome.recovery,
                rows: recoveryRows(day: source, prior: prior, scores: scores),
                insight: recoveryInsight(recovery),
                route: .metric(HeroRingMetric.charge)
            ),
            strain: NativeScore(
                name: "Strain",
                value: NativeDayLogic.strainText(strain, scale: effortScale),
                known: strain != nil,
                fraction: strain.map { $0 / 100 },
                tint: NativeChrome.strain,
                rows: strainRows(today: today, prior: prior, workouts: workouts, todayKey: todayKey),
                insight: strainInsight(strain),
                route: .metric(HeroRingMetric.effort)
            ),
            activities: activities(workouts: workouts, todayKey: todayKey, scale: effortScale),
            sleepHours: sleepDuration,
            asleepMinutes: asleepMinutes,
            inBedMinutes: inBedMinutes,
            sleepStages: sleepStages,
            restorativeMinutes: restorative.minutes,
            restorativeTypical: restorative.typical,
            sleepBlock: sleepDuration,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            awakeTypical: NativeScoreMath.mean(prior.compactMap(awakeMinutes)),
            dashboard: dashboardRows(day: today ?? source, prior: prior, workouts: workouts, todayKey: todayKey),
            journalDays: NativeDayLogic.journalChecks(entries: journalEntries, todayKey: todayKey),
            connected: connected,
            sleepNeedMin: sleepScoreRow?.sleepNeed ?? todayScore?.sleepNeed,
            sleepDebtMin: sleepScoreRow?.sleepDebt ?? todayScore?.sleepDebt
        )
    }

    private static let localDayKeyParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone.current
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    static func dateLine(for key: String, fallback: Date) -> String {
        let date = localDayKeyParser.date(from: key) ?? fallback
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(AppLanguage.activeLocale)).uppercased()
    }

    private static func dashboardRows(day: DailyMetric?, prior: [DailyMetric],
                                      workouts: [WorkoutRow], todayKey: String) -> [NativeScore.Row] {
        let todayWorkouts = workouts.filter {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) == todayKey
        }
        let z13 = zoneMinutes(todayWorkouts, zones: 0..<3)
        let z45 = zoneMinutes(todayWorkouts, zones: 3..<5)
        let strength = strengthMinutes(todayWorkouts)
        let priorByDay = Dictionary(grouping: workouts) {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs)))
        }
        let priorKeys = Set(prior.map(\.day))
        let priorZ13 = priorKeys.compactMap { zoneMinutes(priorByDay[$0] ?? [], zones: 0..<3) }
        let priorZ45 = priorKeys.compactMap { zoneMinutes(priorByDay[$0] ?? [], zones: 3..<5) }
        let priorStrength = priorKeys.compactMap { strengthMinutes(priorByDay[$0] ?? []) }
        return [
            metric("Heart Rate Variability", day?.avgHrv, prior.compactMap(\.avgHrv), "", "waveform.path.ecg", .metric("hrv")),
            metric("Resting Heart Rate", day?.restingHr.map(Double.init),
                   prior.compactMap { $0.restingHr.map(Double.init) }, "", "heart", .metric("resting_hr"), decimals: 0),
            metric("Respiratory Rate", day?.respRateBpm, prior.compactMap(\.respRateBpm), "breaths/min", "lungs", .metric("resp_rate"), decimals: 1),
            metric("Steps", day?.steps.map(Double.init), prior.compactMap { $0.steps.map(Double.init) }, "", "figure.walk", .metric("steps"), grouped: true),
            durationRow("Heart Rate Zones 1–3", z13, priorZ13, "heart", .metric("hr_zones13_min")),
            durationRow("Heart Rate Zones 4–5", z45, priorZ45, "heart.fill", .metric("hr_zones45_min")),
            durationRow("Strength Activity Time", strength, priorStrength, "dumbbell", .metric("strength_min")),
            metric("Calories", day?.activeKcalEst, prior.compactMap(\.activeKcalEst), "", "flame", .metric("energy_kcal"), grouped: true),
        ]
    }

    private static func recoveryRows(day: DailyMetric?, prior: [DailyMetric],
                                     scores: NativeBandScores.Snapshot) -> [NativeScore.Row] {
        let sleepPerf = day.flatMap { scores.byDay[$0.day]?.sleepPerformance }
        let priorPerf = prior.compactMap { scores.byDay[$0.day]?.sleepPerformance }
        return [
            metric("Heart Rate Variability", day?.avgHrv, prior.compactMap(\.avgHrv), "ms", "waveform.path.ecg", .metric("hrv")),
            metric("Resting Heart Rate", day?.restingHr.map(Double.init),
                   prior.compactMap { $0.restingHr.map(Double.init) }, "BPM", "heart", .metric("resting_hr"), decimals: 0),
            metric("Respiratory Rate", day?.respRateBpm, prior.compactMap(\.respRateBpm), "breaths/min", "lungs", .metric("resp_rate"), decimals: 1),
            NativeScore.Row(
                title: "Sleep Performance",
                value: NativeScoreMath.percent(sleepPerf),
                prior: NativeScoreMath.priorText(priorPerf, unit: "%"),
                symbol: "moon",
                delta: NativeScoreMath.delta(sleepPerf, priorPerf),
                route: .metric(HeroRingMetric.rest)
            ),
        ]
    }

    private static func strainRows(today: DailyMetric?, prior: [DailyMetric],
                                   workouts: [WorkoutRow], todayKey: String) -> [NativeScore.Row] {
        let todayWorkouts = workouts.filter {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) == todayKey
        }
        let z13 = zoneMinutes(todayWorkouts, zones: 0..<3)
        let z45 = zoneMinutes(todayWorkouts, zones: 3..<5)
        let strength = strengthMinutes(todayWorkouts)
        let priorByDay = Dictionary(grouping: workouts) {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs)))
        }
        let priorKeys = Set(prior.map(\.day))
        let priorZ13 = priorKeys.compactMap { zoneMinutes(priorByDay[$0] ?? [], zones: 0..<3) }
        let priorZ45 = priorKeys.compactMap { zoneMinutes(priorByDay[$0] ?? [], zones: 3..<5) }
        let priorStrength = priorKeys.compactMap { strengthMinutes(priorByDay[$0] ?? []) }
        return [
            durationRow("Heart Rate Zones 1–3", z13, priorZ13, "heart", .metric("hr_zones13_min")),
            durationRow("Heart Rate Zones 4–5", z45, priorZ45, "heart.fill", .metric("hr_zones45_min")),
            durationRow("Strength Activity Time", strength, priorStrength, "dumbbell", .metric("strength_min")),
            metric("Steps", today?.steps.map(Double.init), prior.compactMap { $0.steps.map(Double.init) }, "", "figure.walk", .metric("steps"), grouped: true),
        ]
    }

    private static func sleepRows(day: DailyMetric?, prior: [DailyMetric],
                                  scores: NativeBandScores.Snapshot,
                                  highSleepStress: Double?) -> [NativeScore.Row] {
        let efficiency = day?.efficiency.map { $0 <= 1 ? $0 * 100 : $0 }
        let priorEfficiency = prior.compactMap { $0.efficiency.map { $0 <= 1 ? $0 * 100 : $0 } }
        let hours = day.flatMap { scores.byDay[$0.day]?.hoursVsNeeded }
        let hoursPrior = prior.compactMap { scores.byDay[$0.day]?.hoursVsNeeded }
        let consValue = day.flatMap { scores.byDay[$0.day]?.sleepConsistency }
        let consPrior = prior.compactMap { scores.byDay[$0.day]?.sleepConsistency }
        return [
            NativeScore.Row(
                title: "Hours vs. Needed",
                value: NativeScoreMath.percent(hours),
                prior: NativeScoreMath.priorText(hoursPrior, unit: "%"),
                symbol: "clock",
                delta: NativeScoreMath.delta(hours, hoursPrior),
                route: .metric("hours_vs_needed_pct")
            ),
            NativeScore.Row(
                title: "Sleep Consistency",
                value: NativeScoreMath.percent(consValue),
                prior: NativeScoreMath.priorText(consPrior, unit: "%"),
                symbol: "calendar",
                delta: NativeScoreMath.delta(consValue, consPrior),
                route: .metric("sleep_consistency")
            ),
            metric("Sleep Efficiency", efficiency, priorEfficiency, "%", "bed.double", .metric("sleep_efficiency"), decimals: 0),
            NativeScore.Row(
                title: "High Sleep Stress",
                value: NativeScoreMath.percent(highSleepStress),
                prior: "—",
                symbol: "waveform.path",
                delta: .none,
                route: .stress
            ),
        ]
    }

    private static func metric(_ title: String, _ value: Double?, _ prior: [Double], _ unit: String,
                               _ symbol: String, _ route: TabRoute, decimals: Int = 0,
                               grouped: Bool = false) -> NativeScore.Row {
        NativeScore.Row(
            title: title,
            value: NativeScoreMath.labeled(value, unit: unit, decimals: decimals, grouped: grouped),
            prior: NativeScoreMath.priorText(prior, unit: unit, decimals: decimals, grouped: grouped),
            symbol: symbol,
            delta: NativeScoreMath.delta(value, prior),
            route: route
        )
    }

    private static func durationRow(_ title: String, _ minutes: Double?, _ prior: [Double],
                                    _ symbol: String, _ route: TabRoute) -> NativeScore.Row {
        NativeScore.Row(
            title: title,
            value: minutes.map { NativeDayLogic.durationText($0) } ?? "—",
            prior: NativeScoreMath.mean(prior).map { NativeDayLogic.durationText($0) } ?? "—",
            symbol: symbol,
            delta: NativeScoreMath.delta(minutes, prior),
            route: route
        )
    }

    /// Minutes in `zones` (0-based Z1…Z5) for the day's workouts. Nil when none of those zones have time.
    static func zoneMinutes(_ workouts: [WorkoutRow], zones: Range<Int>) -> Double? {
        guard let summary = WorkoutZones.summary(from: workouts) else { return nil }
        let minutes = zones.reduce(0.0) { $0 + summary.minutes[$1] }
        return minutes > 0 ? minutes : nil
    }

    static func strengthMinutes(_ workouts: [WorkoutRow]) -> Double? {
        let minutes = workouts.reduce(0.0) { acc, workout in
            guard isStrength(workout.sport) else { return acc }
            let seconds = workout.durationS ?? Double(max(0, workout.endTs - workout.startTs))
            return acc + seconds / 60
        }
        return minutes > 0 ? minutes : nil
    }

    static func isStrength(_ sport: String) -> Bool {
        let name = sport.lowercased()
        return name.contains("strength") || name.contains("weight") || name.contains("lift")
    }

    /// Sleep ring and Sleep Performance week bars share this 0–100 value.
    /// Prefer the resolved Band/WHOOP snapshot; the DailyMetric-only form is the imported/WHOOP
    /// figure when the caller already picked it, else nil (Band needs the causal history).
    static func sleepPerformance(_ day: DailyMetric?, scores: NativeBandScores.Snapshot) -> Double? {
        day.flatMap { scores.byDay[$0.day]?.sleepPerformance }
    }

    /// Last-night restorative is Deep + REM when those stages exist.
    static func restorative(from stages: [NativeStage]) -> (minutes: Double?, typical: Double?) {
        let deep = stages.first { $0.name == "Deep" }
        let rem = stages.first { $0.name == "REM" }
        let minutes = (deep?.minutes ?? 0) + (rem?.minutes ?? 0)
        let typical = (deep?.typical ?? 0) + (rem?.typical ?? 0)
        return (minutes > 0 ? minutes : nil, typical > 0 ? typical : nil)
    }

    /// Awake minutes from efficiency: in-bed − asleep. Nil when efficiency is missing or 100%.
    private static func awakeMinutes(_ day: DailyMetric?) -> Double? {
        guard let asleep = day?.totalSleepMin, let raw = day?.efficiency, asleep > 0, raw > 0 else { return nil }
        let eff = raw <= 1 ? raw : raw / 100
        guard eff > 0, eff < 1 else { return nil }
        let awake = asleep / eff - asleep
        return awake > 0 ? awake : nil
    }

    private static func stages(_ day: DailyMetric?, prior: [DailyMetric],
                               asleep: Double?, inBed: Double?) -> [NativeStage] {
        var rows = [
            NativeStage(name: "Light", minutes: day?.lightMin, typical: NativeScoreMath.mean(prior.compactMap(\.lightMin)), tint: .blue),
            NativeStage(name: "Deep", minutes: day?.deepMin, typical: NativeScoreMath.mean(prior.compactMap(\.deepMin)), tint: .indigo),
            NativeStage(name: "REM", minutes: day?.remMin, typical: NativeScoreMath.mean(prior.compactMap(\.remMin)), tint: .purple),
        ]
        if let inBed, let asleep, inBed > asleep {
            let awake = inBed - asleep
            let typical = NativeScoreMath.mean(prior.compactMap(awakeMinutes))
            rows.insert(
                NativeStage(name: "Awake", minutes: awake, typical: typical, tint: NativeTokens.sleepAwake),
                at: 0
            )
        }
        return rows.filter { ($0.minutes ?? 0) > 0 || ($0.typical ?? 0) > 0 }
    }

    private static func activities(workouts: [WorkoutRow], todayKey: String, scale: EffortScale) -> [Activity] {
        let today = workouts.filter {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) == todayKey
        }
        return HomeActivityDedupe.collapse(today)
            .sorted { $0.startTs > $1.startTs }
            .map { workout in
                Activity(
                    startTs: workout.startTs,
                    sport: workout.sport.uppercased(),
                    strainText: NativeDayLogic.strainText(NativeStrain.workout(workout), scale: scale),
                    timeRange: timeRange(workout.startTs, workout.endTs),
                    startClock: clockTime(workout.startTs),
                    endClock: clockTime(workout.endTs),
                    symbol: symbol(for: workout.sport)
                )
            }
    }

    static func clockTime(_ ts: Int) -> String {
        AppClock.hourMinuteFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    static func timeRange(_ start: Int, _ end: Int) -> String {
        "\(clockTime(start)) – \(clockTime(end))"
    }

    static func symbol(for sport: String) -> String {
        let name = sport.lowercased()
        if name.contains("run") { return "figure.run" }
        if name.contains("cycl") || name.contains("bike") { return "figure.outdoor.cycle" }
        if name.contains("swim") { return "figure.pool.swim" }
        if name.contains("strength") || name.contains("weight") || name.contains("lift") { return "dumbbell.fill" }
        if name.contains("walk") { return "figure.walk" }
        return "figure.mixed.cardio"
    }

    private static func recoveryInsight(_ value: Double?) -> String {
        guard let value else { return "Import a history or wear the strap overnight to fill this in." }
        if value >= 67 { return "Recovery is in a good range. The rows below are what moved it." }
        if value >= 34 { return "Recovery is moderate. Keep today steady." }
        return "Recovery is low. An easier day matches the data."
    }

    private static func strainInsight(_ value: Double?) -> String {
        guard let value else { return "Strain fills in as the day goes on." }
        if value >= 70 { return "Strain in this range is a hard day." }
        if value >= 40 { return "Strain in this range is a moderate day." }
        return "Strain in this range is a light day."
    }

    private static func sleepInsight(_ value: Double?) -> String {
        guard let value else { return "No sleep recorded yet." }
        if value >= 85 { return "Sleep performance is in a strong range." }
        if value >= 70 { return "Sleep performance is sufficient, with room to improve." }
        return "Sleep is in. The rows below are what made the score."
    }
}

enum NativeActivity {
    struct Zone: Equatable, Identifiable {
        var id: Int { zone }
        var zone: Int
        var minutes: Double
        var label: String
    }

    struct Stat: Equatable, Identifiable {
        var id: String { title }
        var title: String
        var value: String
        var comparison: String
        var symbol: String
    }

    struct Model: Equatable {
        var sport: String
        var symbol: String
        var timeRange: String
        var strainText: String
        var strainDelta: NativeScore.Delta
        var duration: String
        var zones: [Zone]
        var stats: [Stat]
        var hasRoute: Bool
    }

    static func make(_ workout: WorkoutRow, prior: [WorkoutRow], scale: EffortScale) -> Model {
        let same = prior.filter { $0.sport == workout.sport && $0.startTs != workout.startTs }
        let strain = NativeStrain.workout(workout)
        return Model(
            sport: workout.sport.uppercased(),
            symbol: NativeDay.symbol(for: workout.sport),
            timeRange: NativeDay.timeRange(workout.startTs, workout.endTs),
            strainText: NativeDayLogic.strainText(strain, scale: scale),
            strainDelta: NativeScoreMath.delta(strain, same.compactMap(NativeStrain.workout)),
            duration: duration(workout),
            zones: zones(workout.zonesJSON, durationS: workout.durationS ?? Double(max(0, workout.endTs - workout.startTs))),
            stats: stats(workout, same: same),
            hasRoute: (workout.distanceM ?? 0) > 0 && workout.sport.lowercased().contains("run")
        )
    }

    private static func duration(_ workout: WorkoutRow) -> String {
        let seconds = workout.durationS ?? Double(max(0, workout.endTs - workout.startTs))
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func zones(_ json: String?, durationS: Double) -> [Zone] {
        guard let percents = WorkoutZones.percents(json), durationS > 0 else { return [] }
        let minutes = durationS / 60
        return (1...5).map { zone in
            Zone(zone: zone, minutes: minutes * percents[zone - 1] / 100, label: "Zone \(zone)")
        }
    }

    private static func stats(_ workout: WorkoutRow, same: [WorkoutRow]) -> [Stat] {
        var rows: [Stat] = []
        if let kcal = workout.energyKcal {
            rows.append(stat("Calories", "\(Int(kcal.rounded())) kcal", kcal, same.compactMap(\.energyKcal), "flame"))
        }
        if let hr = workout.avgHr {
            rows.append(stat("Avg HR", "\(hr) BPM", Double(hr), same.compactMap { $0.avgHr.map(Double.init) }, "heart"))
        }
        if let hr = workout.maxHr {
            rows.append(stat("Max HR", "\(hr) BPM", Double(hr), same.compactMap { $0.maxHr.map(Double.init) }, "heart.fill"))
        }
        rows.append(Stat(title: "Duration", value: duration(workout), comparison: "—", symbol: "timer"))
        if let meters = workout.distanceM, meters > 0 {
            let imperial = UserDefaults.standard.string(forKey: UnitPrefs.distanceSystemKey) != UnitSystem.metric.rawValue
            let perUnit = imperial ? 1609.344 : 1000.0
            let unit = imperial ? "mi" : "km"
            rows.append(Stat(
                title: "Distance",
                value: String(format: "%.2f \(unit)", meters / perUnit),
                comparison: "—",
                symbol: "point.topleft.down.to.point.bottomright.curvepath"
            ))
        }
        if let steps = workout.steps {
            rows.append(Stat(title: "Steps", value: "\(steps)", comparison: "—", symbol: "figure.walk"))
        }
        return rows
    }

    private static func stat(_ title: String, _ value: String, _ current: Double, _ prior: [Double], _ symbol: String) -> Stat {
        let comparison: String
        if let mean = NativeScoreMath.mean(prior) {
            comparison = "vs \(Int(mean.rounded()))"
        } else {
            comparison = "—"
        }
        return Stat(title: title, value: value, comparison: comparison, symbol: symbol)
    }
}

/// Health Monitor flags: HRV, resting HR, respiratory rate, skin temp, SpO2 judged by
/// `TypicalVitalRange` (the same function as the metric-page typical band). Missing metrics
/// are omitted. Home's header and the Health Monitor page both read `report`.
enum NativeHealthRange {
    /// Respiratory Rate, SpO₂, RHR, HRV, Skin Temp — Home tile and the page share this count.
    static let metricSlots = 5

    struct Summary: Equatable {
        var inRange: Int
        var measured: Int
        var outside: Int
        var judged: Int

        var caption: String? {
            guard measured > 0 else { return nil }
            if judged == 0 { return "Building baseline" }
            if outside == 0 { return "All within range" }
            if outside == 1 { return "1 outside range" }
            return "\(outside) outside range"
        }

        /// Same wording as `caption` — the Home card header.
        var headerTrailing: String? { caption }

        /// Home tile headline. Green path is only "Within Range"; any out-of-range metric is red.
        var tileHeadline: String {
            guard measured > 0 else { return "No Data" }
            if judged == 0 { return "Building baseline" }
            if outside == 0 { return "Within Range" }
            if outside == 1 { return "1 metric outside range" }
            return "\(outside) metrics outside range"
        }

        /// WHOOP Home tile subline, e.g. "5/5 Metrics". Always of 5 slots.
        var tileDetail: String {
            guard measured > 0 else { return "" }
            return "\(inRange)/\(NativeHealthRange.metricSlots) Metrics"
        }

        var tileWithinRange: Bool { measured > 0 && judged > 0 && outside == 0 }
    }

    struct Vital: Equatable, Identifiable {
        var id: String
        var title: String
        var symbol: String
        var value: Double
        var valueText: String
        var typical: ClosedRange<Double>?
        var typicalText: String
        var inRange: Bool
        var flagged: Bool
        var status: TypicalVitalRange.Status
        var unit: String
        var heartFamily: Bool
        var route: TabRoute

        var building: Bool { status == .building && !flagged }

        var flagDelta: NativeScore.Delta {
            guard flagged else { return .none }
            let name = "Outside your typical range"
            if status == .above {
                return NativeScore.Delta(symbol: "arrow.up", tint: NativeTokens.recoveryLow, name: name)
            }
            return NativeScore.Delta(symbol: "arrow.down", tint: NativeTokens.recoveryLow, name: name)
        }
    }

    struct Report: Equatable {
        var vitals: [Vital]

        var summary: Summary {
            let outside = vitals.filter { $0.status == .above || $0.status == .below }.count
            let judged = vitals.filter { $0.status != .building }.count
            return Summary(
                inRange: vitals.filter(\.inRange).count,
                measured: vitals.count,
                outside: outside,
                judged: judged
            )
        }
    }

    static func summary(
        days: [DailyMetric], todayKey: String, temperature: TemperatureUnit = .celsius
    ) -> Summary {
        report(days: days, todayKey: todayKey, temperature: temperature).summary
    }

    static func report(
        days: [DailyMetric], todayKey: String, temperature: TemperatureUnit = .celsius
    ) -> Report {
        let today = days.last { $0.day == todayKey }
        let cutoff = Baselines.cutoffKey(todayKey: todayKey, carryDays: TypicalVitalRange.windowDays)
        let prior = days.filter { $0.day < todayKey && $0.day >= cutoff }
        var vitals: [Vital] = []

        func append(
            id: String, title: String, symbol: String,
            value: Double?, history: [Double?],
            metric: TypicalVitalRange.Metric,
            unit: String, decimals: Int,
            heartFamily: Bool, route: TabRoute
        ) {
            guard let value else { return }
            let judged = TypicalVitalRange.evaluate(history: history, today: value, metric: metric)
            vitals.append(Vital(
                id: id,
                title: title,
                symbol: symbol,
                value: value,
                valueText: format(value, decimals: decimals, unit: unit),
                typical: judged.range,
                typicalText: judged.range.map { formatRange($0, decimals: decimals) } ?? "",
                inRange: judged.status == .inRange,
                flagged: judged.flagged,
                status: judged.status,
                unit: unit,
                heartFamily: heartFamily,
                route: route
            ))
        }

        append(
            id: "hrv", title: "Heart Rate Variability", symbol: "waveform.path.ecg",
            value: today?.avgHrv,
            history: prior.map(\.avgHrv),
            metric: .hrv, unit: "ms", decimals: 0,
            heartFamily: true, route: .metric("hrv")
        )
        append(
            id: "rhr", title: "Resting Heart Rate", symbol: "heart.fill",
            value: today?.restingHr.map(Double.init),
            history: prior.map { $0.restingHr.map(Double.init) },
            metric: .rhr, unit: "BPM", decimals: 0,
            heartFamily: true, route: .metric("rhr")
        )
        append(
            id: "resp", title: "Respiratory Rate", symbol: "lungs.fill",
            value: today?.respRateBpm,
            history: prior.map(\.respRateBpm),
            metric: .resp, unit: "breaths/min", decimals: 1,
            heartFamily: false, route: .metric("resp_rate")
        )

        let skinValue = today?.skinTempC ?? today?.skinTempDevC
        let skinHistoryRaw = prior.map { $0.skinTempC ?? $0.skinTempDevC }
        if let skinValue {
            let absolute = VitalBands.isAbsoluteSkinTemp(skinValue)
            let judged = TypicalVitalRange.evaluate(
                history: VitalBands.skinTempHistory(matching: skinValue, in: skinHistoryRaw),
                today: skinValue,
                metric: .skin
            )
            let shown = displaySkin(skinValue, range: judged.range, absolute: absolute, temperature: temperature)
            vitals.append(Vital(
                id: "skin",
                title: "Skin Temperature",
                symbol: "thermometer.medium",
                value: shown.value,
                valueText: shown.valueText,
                typical: shown.range,
                typicalText: shown.range.map { formatRange($0, decimals: 1) } ?? "",
                inRange: judged.status == .inRange,
                flagged: judged.flagged,
                status: judged.status,
                unit: shown.unit,
                heartFamily: true,
                route: .metric("skin_temp")
            ))
        }

        append(
            id: "spo2", title: "Blood Oxygen", symbol: "drop.fill",
            value: today?.spo2Pct,
            history: prior.map(\.spo2Pct),
            metric: .spo2, unit: "%", decimals: 0,
            heartFamily: true, route: .metric("spo2")
        )

        return Report(vitals: vitals)
    }

    private static func displaySkin(
        _ celsius: Double,
        range: ClosedRange<Double>?,
        absolute: Bool,
        temperature: TemperatureUnit
    ) -> (value: Double, range: ClosedRange<Double>?, valueText: String, unit: String) {
        let value: Double
        let shownRange: ClosedRange<Double>?
        if absolute {
            value = temperature == .fahrenheit ? UnitFormatter.celsiusToFahrenheit(celsius) : celsius
            shownRange = range.map { lohi in
                let lo = temperature == .fahrenheit ? UnitFormatter.celsiusToFahrenheit(lohi.lowerBound) : lohi.lowerBound
                let hi = temperature == .fahrenheit ? UnitFormatter.celsiusToFahrenheit(lohi.upperBound) : lohi.upperBound
                return min(lo, hi)...max(lo, hi)
            }
        } else {
            value = temperature == .fahrenheit ? UnitFormatter.celsiusDeltaToFahrenheit(celsius) : celsius
            shownRange = range.map { lohi in
                let lo = temperature == .fahrenheit ? UnitFormatter.celsiusDeltaToFahrenheit(lohi.lowerBound) : lohi.lowerBound
                let hi = temperature == .fahrenheit ? UnitFormatter.celsiusDeltaToFahrenheit(lohi.upperBound) : lohi.upperBound
                return min(lo, hi)...max(lo, hi)
            }
        }
        let unit = temperature == .fahrenheit ? "°F" : "°C"
        let valueText = absolute
            ? UnitFormatter.temperatureFromCelsius(celsius, unit: temperature)
            : UnitFormatter.temperatureDeltaFromCelsius(celsius, unit: temperature)
        return (value, shownRange, valueText, unit)
    }

    private static func format(_ value: Double, decimals: Int, unit: String) -> String {
        let number = decimals == 0
            ? String(Int(value.rounded()))
            : String(format: "%.\(decimals)f", value)
        if unit == "%" { return "\(number)%" }
        return "\(number) \(unit)"
    }

    private static func formatRange(_ range: ClosedRange<Double>, decimals: Int) -> String {
        func n(_ v: Double) -> String {
            decimals == 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v)
        }
        return "\(n(range.lowerBound))–\(n(range.upperBound))"
    }
}

/// Tonight's Sleep card facts. Hidden when there is no sleep need and no armed smart alarm.
/// Bedtime is wake − need. Never arms or writes the strap alarm.
enum NativeTonightSleep {
    struct Model: Equatable {
        var bedtimeClock: String?
        var wakeClock: String?
        var needClock: String?
        var alarmArmed: Bool
        var alarmLabel: String?
    }

    static func make(needMin: Double?, alarmEnabled: Bool, alarmMinutes: Int) -> Model? {
        let need = needMin.flatMap { $0 > 0 ? $0 : nil }
        if need == nil && !alarmEnabled { return nil }
        var bedtime: String?
        var wake: String?
        if alarmEnabled {
            wake = clock(alarmMinutes)
            if let need {
                bedtime = clock(alarmMinutes - Int(need.rounded()))
            }
        }
        return Model(
            bedtimeClock: bedtime,
            wakeClock: wake,
            needClock: need.map { needText($0) },
            alarmArmed: alarmEnabled,
            alarmLabel: alarmEnabled ? "Alarm \(clock(alarmMinutes))" : nil
        )
    }

    /// Sleep-need duration in the Tonight card. Uses `8 hr` / `7 hr 45 min` so it cannot
    /// be read as a clock next to Bedtime and Wake.
    static func needText(_ minutes: Double) -> String {
        let parts = NativeScoreMath.clockParts(minutes)
        if parts.minutes == 0 { return "\(parts.hours) hr" }
        return "\(parts.hours) hr \(parts.minutes) min"
    }

    private static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static func clock(_ minutes: Int) -> String {
        var total = minutes % (24 * 60)
        if total < 0 { total += 24 * 60 }
        var comps = DateComponents()
        comps.year = 2000
        comps.month = 1
        comps.day = 1
        comps.hour = total / 60
        comps.minute = total % 60
        let date = Calendar(identifier: .gregorian).date(from: comps) ?? Date()
        return hourMinute.string(from: date)
    }
}

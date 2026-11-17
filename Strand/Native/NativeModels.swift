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
        var id: String { title }
        var title: String
        var points: [NativeDayPoint]
        var maxY: Double
        var bars: Bool
        var tint: Color
        var route: TabRoute?
        var format: Format
        var band: Bool
    }

    static func points(kind: NativeScoreKind, days: [DailyMetric], todayKey: String,
                       effortScale: EffortScale = .whoop,
                       sleeps: [CachedSleepSession] = [],
                       workouts: [WorkoutRow] = [],
                       importedSleep: [String: ImportedSleepFigures] = [:]) -> [NativeDayPoint] {
        let scores = NativeBandScores.resolve(
            days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        return series(days, todayKey: todayKey) { day in
            switch kind {
            case .strain: return day.strain.map { NativeDayLogic.strainDisplayValue($0, scale: effortScale) }
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
            let hours = series(days, todayKey: todayKey) { $0.totalSleepMin }
            let efficiency = series(days, todayKey: todayKey) {
                $0.efficiency.map { $0 <= 1 ? $0 * 100 : $0 }
            }
            return [
                Card(title: "Sleep Performance", points: points(kind: .sleep, days: days, todayKey: todayKey, effortScale: effortScale, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep),
                     maxY: 100, bars: true, tint: NativeChrome.sleep, route: nil, format: .percent, band: true),
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
            return [
                Card(title: "Strain", points: points(kind: .strain, days: days, todayKey: todayKey, effortScale: effortScale, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep),
                     maxY: NativeDayLogic.strainMaxY(effortScale), bars: true, tint: NativeChrome.strain, route: nil, format: .strain, band: false),
                Card(title: "Steps", points: steps,
                     maxY: max(steps.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 1),
                     bars: true, tint: NativeChrome.strain, route: .metric("steps"),
                     format: .number, band: false),
                Card(title: "Calories", points: kcal,
                     maxY: max(kcal.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 1),
                     bars: true, tint: Color.orange, route: .metric("energy_kcal"),
                     format: .number, band: false),
            ].filter(filled)
        }
    }

    static func lastSevenKeys(ending todayKey: String) -> [String] {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        guard let end = parser.date(from: todayKey) else { return [todayKey] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return (0..<7).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: end) ?? end
            return parser.string(from: day)
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
                     highSleepStress: Double? = nil) -> Model {
        let sleepSession = sleeps.last {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == todayKey
        }
        let today = days.last { $0.day == todayKey }
        let viewingToday = todayKey == Repository.localDayKey(now)
        let scores = NativeBandScores.resolve(
            days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        let todayScore = scores.byDay[todayKey]
        // Carry last night's recovery only while looking at today before the overnight scores.
        let recoveryKey: String?
        if todayScore?.recovery == nil && viewingToday {
            recoveryKey = days.last { scores.byDay[$0.day]?.recovery != nil && $0.day < todayKey }?.day
        } else {
            recoveryKey = todayKey
        }
        let hrvDay = today?.avgHrv == nil && viewingToday ? DailyMetric.lastHrvDay(days: days, todayKey: todayKey) : today
        let sleepDay = today?.totalSleepMin == nil && viewingToday
            ? days.last { $0.totalSleepMin != nil && $0.day < todayKey }
            : today
        let sleepKey = sleepDay?.day
        let sleepScoreRow = sleepKey.flatMap { scores.byDay[$0] }
        let prior = Array(days.filter { $0.day < todayKey }.suffix(30))
        let source = days.last { $0.day == recoveryKey } ?? hrvDay ?? sleepDay
        let recovery = recoveryKey.flatMap { scores.byDay[$0]?.recovery }
        let strain = today?.strain
        let sleepScore = sleepScoreRow?.sleepPerformance
        let sleepStages = stages(sleepDay, prior: prior)
        let restorative = restorative(from: sleepStages)

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
                rows: strainRows(today: today, prior: prior),
                insight: strainInsight(strain),
                route: .metric(HeroRingMetric.effort)
            ),
            activities: activities(workouts: workouts, todayKey: todayKey, scale: effortScale),
            sleepHours: sleepDay?.totalSleepMin.map { NativeScoreMath.duration($0) },
            sleepStages: sleepStages,
            restorativeMinutes: restorative.minutes,
            restorativeTypical: restorative.typical,
            sleepBlock: sleepDay?.totalSleepMin.map { NativeScoreMath.duration($0) },
            sleepStart: sleepSession.map { Date(timeIntervalSince1970: TimeInterval($0.effectiveStartTs)) },
            sleepEnd: sleepSession.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) },
            awakeTypical: NativeScoreMath.mean(prior.compactMap(awakeMinutes)),
            dashboard: dashboardRows(day: today ?? source, prior: prior),
            journalDays: NativeDayLogic.journalChecks(entries: journalEntries, todayKey: todayKey),
            connected: connected,
            sleepNeedMin: sleepScoreRow?.sleepNeed ?? todayScore?.sleepNeed,
            sleepDebtMin: sleepScoreRow?.sleepDebt ?? todayScore?.sleepDebt
        )
    }

    static func dateLine(for key: String, fallback: Date) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone.current
        parser.dateFormat = "yyyy-MM-dd"
        let date = parser.date(from: key) ?? fallback
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(AppLanguage.activeLocale)).uppercased()
    }

    private static func dashboardRows(day: DailyMetric?, prior: [DailyMetric]) -> [NativeScore.Row] {
        [
            metric("Heart Rate Variability", day?.avgHrv, prior.compactMap(\.avgHrv), "", "waveform.path.ecg", .metric("hrv")),
            metric("Resting Heart Rate", day?.restingHr.map(Double.init),
                   prior.compactMap { $0.restingHr.map(Double.init) }, "", "heart", .metric("resting_hr"), decimals: 0),
            metric("Steps", day?.steps.map(Double.init), prior.compactMap { $0.steps.map(Double.init) }, "", "figure.walk", .metric("steps"), decimals: 0),
            metric("Heart Rate Zones 1–3", nil, [], "", "heart", .metric("hr_zones13_min")),
            metric("Heart Rate Zones 4–5", nil, [], "", "heart.fill", .metric("hr_zones45_min")),
            metric("Strength Activity Time", nil, [], "", "dumbbell", .metric("strength_min")),
            metric("Calories", day?.activeKcalEst, prior.compactMap(\.activeKcalEst), "", "flame", .metric("energy_kcal"), decimals: 0),
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

    private static func strainRows(today: DailyMetric?, prior: [DailyMetric]) -> [NativeScore.Row] {
        [
            metric("Heart Rate Zones 1–3", nil, [], "", "heart", .metric("hr_zones13_min")),
            metric("Heart Rate Zones 4–5", nil, [], "", "heart.fill", .metric("hr_zones45_min")),
            metric("Strength Activity Time", nil, [], "", "dumbbell", .metric("strength_min")),
            metric("Steps", today?.steps.map(Double.init), prior.compactMap { $0.steps.map(Double.init) }, "", "figure.walk", .metric("steps"), decimals: 0),
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
                               _ symbol: String, _ route: TabRoute, decimals: Int = 0) -> NativeScore.Row {
        NativeScore.Row(
            title: title,
            value: NativeScoreMath.labeled(value, unit: unit, decimals: decimals),
            prior: NativeScoreMath.priorText(prior, unit: unit, decimals: decimals),
            symbol: symbol,
            delta: NativeScoreMath.delta(value, prior),
            route: route
        )
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

    private static func stages(_ day: DailyMetric?, prior: [DailyMetric]) -> [NativeStage] {
        let rows = [
            NativeStage(name: "Light", minutes: day?.lightMin, typical: NativeScoreMath.mean(prior.compactMap(\.lightMin)), tint: .blue),
            NativeStage(name: "Deep", minutes: day?.deepMin, typical: NativeScoreMath.mean(prior.compactMap(\.deepMin)), tint: .indigo),
            NativeStage(name: "REM", minutes: day?.remMin, typical: NativeScoreMath.mean(prior.compactMap(\.remMin)), tint: .purple),
        ]
        return rows.filter { ($0.minutes ?? 0) > 0 || ($0.typical ?? 0) > 0 }
    }

    private static func activities(workouts: [WorkoutRow], todayKey: String, scale: EffortScale) -> [Activity] {
        workouts
            .filter { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) == todayKey }
            .sorted { $0.startTs > $1.startTs }
            .map { workout in
                Activity(
                    startTs: workout.startTs,
                    sport: workout.sport.uppercased(),
                    strainText: NativeDayLogic.strainText(workout.strain, scale: scale),
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
        let strain = workout.strain
        return Model(
            sport: workout.sport.uppercased(),
            symbol: NativeDay.symbol(for: workout.sport),
            timeRange: NativeDay.timeRange(workout.startTs, workout.endTs),
            strainText: NativeDayLogic.strainText(strain, scale: scale),
            strainDelta: NativeScoreMath.delta(strain, same.compactMap(\.strain)),
            duration: duration(workout),
            zones: zones(workout.zonesJSON),
            stats: stats(workout, same: same),
            hasRoute: (workout.distanceM ?? 0) > 0 && workout.sport.lowercased().contains("run")
        )
    }

    private static func duration(_ workout: WorkoutRow) -> String {
        let seconds = workout.durationS ?? Double(max(0, workout.endTs - workout.startTs))
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func zones(_ json: String?) -> [Zone] {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (1...5).map { zone in
            let raw = object["zone\(zone)"]
            let minutes = (raw as? Double) ?? (raw as? Int).map(Double.init) ?? 0
            return Zone(zone: zone, minutes: minutes, label: "Zone \(zone)")
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
            rows.append(Stat(title: "Distance", value: String(format: "%.2f km", meters / 1000), comparison: "—", symbol: "point.topleft.down.to.point.bottomright.curvepath"))
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

/// Health Monitor "Within Range N of M": HRV, resting HR, respiratory rate, skin temp, SpO2
/// whose latest value for the selected day sits in the user's typical band. Missing metrics
/// are omitted from M. Reuses `VitalBands` (personal baseline when trusted, else population).
enum NativeHealthRange {
    struct Summary: Equatable {
        var inRange: Int
        var measured: Int

        var caption: String? {
            guard measured > 0 else { return nil }
            return "Within Range \(inRange) of \(measured)"
        }
    }

    static func summary(days: [DailyMetric], todayKey: String) -> Summary {
        let today = days.last { $0.day == todayKey }
        let prior = days.filter { $0.day < todayKey }
        var inRange = 0
        var measured = 0

        func count(value: Double?, history: [Double?], range: ClosedRange<Double>, cfg: MetricCfg?) {
            let result = VitalBands.band(value: value, history: history, populationRange: range, cfg: cfg)
            guard result.band != .noData else { return }
            measured += 1
            if result.band == .inRange { inRange += 1 }
        }

        count(
            value: today?.avgHrv,
            history: VitalBands.calendarSeries(prior.map { ($0.day, $0.avgHrv) }),
            range: 40...120,
            cfg: Baselines.hrvCfg
        )
        count(
            value: today?.restingHr.map(Double.init),
            history: VitalBands.calendarSeries(prior.map { ($0.day, $0.restingHr.map(Double.init)) }),
            range: 40...60,
            cfg: Baselines.restingHRCfg
        )
        count(
            value: today?.respRateBpm,
            history: VitalBands.calendarSeries(prior.map { ($0.day, $0.respRateBpm) }),
            range: 12...20,
            cfg: Baselines.respCfg
        )

        let skinValue = today?.skinTempC ?? today?.skinTempDevC
        let skinHistoryRaw = VitalBands.calendarSeries(prior.map { ($0.day, $0.skinTempC ?? $0.skinTempDevC) })
        if let skinValue {
            let absolute = VitalBands.isAbsoluteSkinTemp(skinValue)
            count(
                value: skinValue,
                history: VitalBands.skinTempHistory(matching: skinValue, in: skinHistoryRaw),
                range: absolute ? 33...36 : (-0.6)...0.6,
                cfg: absolute ? Baselines.metricCfg["skin_temp"] : VitalBands.skinTempDeviationCfg
            )
        }

        count(
            value: today?.spo2Pct,
            history: VitalBands.calendarSeries(prior.map { ($0.day, $0.spo2Pct) }),
            range: 95...100,
            cfg: nil
        )

        return Summary(inRange: inRange, measured: measured)
    }
}

/// Tonight's Sleep card facts. Hidden when there is no sleep need and no armed smart alarm.
/// Bedtime is wake − need. Never arms or writes the strap alarm.
enum NativeTonightSleep {
    struct Model: Equatable {
        var bedtimeClock: String?
        var wakeClock: String?
        var needClock: String?
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
            needClock: need.map { NativeScoreMath.duration($0) }
        )
    }

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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

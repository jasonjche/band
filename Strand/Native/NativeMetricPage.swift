import SwiftUI
import WhoopStore
import StrandDesign

/// Apple Health chart page: D/W/M/6M aggregation, hero, chart, Latest capsule, Trend.
struct NativeMetricPage: View {
    var key: String
    var showsNavigationTitle: Bool = true
    @AppStorage(NativeDaySelection.storageKey) private var nativeDayKey = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @State private var repoHandle: Repository?
    @State private var refreshSeq = 0
    @State private var handlesReady = false
    @State private var scope: NativeMetricScope = .week
    @State private var series: NativeScopeSeries = .empty
    @State private var hourPoints: [NativeHourPoint] = []
    @State private var latest: NativeDayPoint?
    @State private var sourceCaption: String?

    private var selectedDay: Date {
        NativeDaySelection.date(from: nativeDayKey)
    }

    private var dayKey: String { NativeDayLogic.resolvedDayKey(stored: nativeDayKey) }

    private var metric: MetricDescriptor? {
        MetricCatalog.all.first { $0.key == key }
    }

    private var title: String {
        NativeTrendsCatalog.title(for: key)
    }

    private var taskID: String {
        handlesReady ? "\(key)|\(scope.rawValue)|\(dayKey)|\(refreshSeq)" : "boot"
    }

    var body: some View {
        let pageTitle = title
        let pageBars = usesBars
        let pageTint = tint
        let pageUnit = displayUnit
        let pageColor = bandColor
        NativeMetricChartPage(
            title: pageTitle,
            scope: scope,
            onScope: { new in
                if allowedScopes.contains(new) { scope = new }
            },
            series: series,
            hourPoints: hourPoints,
            bars: pageBars,
            tint: pageTint,
            format: format,
            unit: pageUnit,
            highlightKey: dayKey,
            higherIsBetter: NativeMetricDirection.higherIsBetter(key),
            latest: latest,
            color: pageColor,
            sourceCaption: sourceCaption,
            scopes: allowedScopes,
            showsNavigationTitle: showsNavigationTitle
        )
        .background {
            NativeRepoSink(refreshSeq: $refreshSeq, ready: $handlesReady) { repoHandle = $0 }
        }
        .task(id: taskID) {
            guard handlesReady else { return }
            if !allowedScopes.contains(scope) {
                scope = allowedScopes.first ?? .week
            }
            await reload()
        }
    }

    private var allowedScopes: [NativeMetricScope] {
        NativeMetricScope.pickerCases(for: key)
    }

    private var usesBars: Bool {
        NativeScopeKindMap.kind(for: key) == .total
    }

    private var tint: Color {
        switch key {
        case "hrv", "rhr", "resting_hr", "avg_hr", "max_hr": return NativeTokens.heart
        case "resp_rate": return NativeTokens.respiratory
        case "steps", "energy_kcal", "active_kcal", "strength_min",
             "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min":
            return NativeTokens.activity
        case "vo2max", "vo2max_est": return NativeTokens.respiratory
        case "strain", "stress": return NativeTokens.strain
        case "recovery": return NativeTokens.recoveryHigh
        default: return NativeTokens.sleep
        }
    }

    private var bandColor: ((Double) -> Color)? {
        if key == "recovery" { return { NativeTokens.recoveryBand($0) } }
        if key == "sleep_performance" || key == "sleep_efficiency" { return { NativeTokens.sleepBand($0) } }
        return nil
    }

    private var displayUnit: String? {
        switch key {
        case "hrv": return "ms"
        case "rhr", "resting_hr", "avg_hr", "max_hr": return "BPM"
        case "resp_rate": return "breaths/min"
        case "steps":
            return "steps"  // the hero caption already says Avg/day on 6M
        case "energy_kcal", "active_kcal":
            return "cal"
        case "vo2max", "vo2max_est": return "ml/kg·min"
        case "restorative_min", "hours_vs_needed_hours": return "hr"
        case "stress": return nil
        default:
            let unit = metric?.unit ?? ""
            return unit.isEmpty ? nil : unit
        }
    }

    private func reload() async {
        guard let repo = repoHandle else { return }
        let calendar = Calendar.current
        let ending = NativeScopeSeries.date(from: dayKey, calendar: calendar) ?? selectedDay
        if key == "vo2max" || key == "vo2max_est" {
            await reloadVo2(repo: repo, calendar: calendar, ending: ending)
            return
        }
        if key == "stress" {
            await reloadStress(repo: repo, calendar: calendar, ending: ending)
            return
        }
        let scale = UnitPrefs.resolveEffortScale(effortScaleRaw)
        let points: [NativeDayPoint]
        if Self.scoredKeys.contains(key) {
            points = await reloadScored(repo: repo, calendar: calendar, ending: ending, scale: scale)
        } else {
            points = await reloadSeries(repo: repo, calendar: calendar, ending: ending, scale: scale)
        }
        guard !Task.isCancelled else { return }
        series = NativeScopeSeries.make(
            points: points,
            scope: scope,
            kind: NativeScopeKindMap.kind(for: key),
            calendar: calendar,
            now: ending,
            ending: ending,
            cfg: NativeTypicalRange.cfg(for: key)
        )
        latest = points.last
        sourceCaption = nil
        hourPoints = []
        if scope == .day, key == "avg_hr" || key == "max_hr" {
            let start = calendar.startOfDay(for: ending)
            let from = Int(start.timeIntervalSince1970)
            let buckets = await repo.hrSamples(from: from, to: from + 86_400, bucketSeconds: 300)
            hourPoints = buckets.map { bucket in
                NativeHourPoint(
                    time: Date(timeIntervalSince1970: TimeInterval(bucket.ts)),
                    value: key == "max_hr" ? bucket.maxBpm : bucket.bpm
                )
            }
        } else if scope == .day, key == "steps" {
            await reloadStepHours(
                repo: repo, calendar: calendar, ending: ending,
                mergedDaily: points.last { $0.key == dayKey }?.value
            )
        }
    }

    private func reloadScored(
        repo: Repository, calendar: Calendar, ending: Date, scale: EffortScale
    ) async -> [NativeDayPoint] {
        _ = (calendar, ending)
        let days = repo.days
        let sleeps = repo.sleeps
        let imported = repo.importedSleep
        let key = key, dayKey = dayKey
        return await Task.detached(priority: .userInitiated) {
            let scores = NativeBandScores.resolve(days: days, sleeps: sleeps, importedSleep: imported)
            return days.filter { $0.day <= dayKey }.compactMap { day in
                Self.displayValue(
                    Self.resolvedValue(key: key, day: day, scores: scores), key: key, scale: scale
                ).map { NativeDayPoint(key: day.day, value: $0) }
            }
        }.value
    }

    private func reloadSeries(
        repo: Repository, calendar: Calendar, ending: Date, scale: EffortScale
    ) async -> [NativeDayPoint] {
        _ = (calendar, ending)
        let source = metric?.source ?? "my-whoop"
        let rows = await repo.exploreSeries(key: key, source: source)
        var byDay: [String: Double] = [:]
        for row in rows where row.day <= dayKey {
            if let value = Self.displayValue(row.value, key: key, scale: scale) {
                byDay[row.day] = value
            }
        }
        for day in repo.days where day.day <= dayKey && byDay[day.day] == nil {
            if let value = Self.displayValue(Self.derivedValue(key: key, day: day), key: key, scale: scale) {
                byDay[day.day] = value
            }
        }
        if Self.workoutKeys.contains(key) {
            let workouts = await repo.workoutRows(days: 400)
            for point in Self.workoutPoints(key: key, workouts: workouts, ending: dayKey) {
                if byDay[point.key] == nil { byDay[point.key] = point.value }
            }
        }
        if key == "weight" {
            for reading in NativeWeight.readings(await repo.appleDailyRows()) where reading.day <= dayKey {
                if byDay[reading.day] == nil { byDay[reading.day] = reading.kg }
            }
        }
        return byDay.keys.sorted().compactMap { day in
            byDay[day].map { NativeDayPoint(key: day, value: $0) }
        }
    }

    private func reloadStress(repo: Repository, calendar: Calendar, ending: Date) async {
        let days = repo.days
        let dayKey = dayKey, scope = scope
        // Same per-day funnel as the Stress Monitor's W/M/6M view, so Trends and Stress agree.
        let workouts = await repo.workoutRows(days: 28)
        var means = await NativeStressHistory.minuteMeans(
            repo: repo, days: days, ending: dayKey, scope: scope,
            workouts: workouts, calendar: calendar
        )
        if let start = NativeScopeSeries.date(from: dayKey, calendar: calendar) {
            let today = await NativeDerivedSeries.stressDay(
                repo: repo, dayKey: dayKey, dayStart: calendar.startOfDay(for: start),
                days: days, sleeps: repo.sleeps, workouts: workouts, calendar: calendar
            )
            if let mean = NativeScopeSeries.mean(
                NativeStressHistory.excluding(today.hours, today.exclusions).map(\.value)
            ) { means[dayKey] = mean }
        }
        guard !Task.isCancelled else { return }
        let minuteMeans = means
        let points = await Task.detached(priority: .userInitiated) {
            NativeStressHistory.daily(days: days, ending: dayKey, minuteMeans: minuteMeans)
        }.value
        guard !Task.isCancelled else { return }
        series = NativeScopeSeries.make(
            points: points,
            scope: scope,
            kind: .rate,
            calendar: calendar,
            now: ending,
            ending: ending
        )
        latest = points.last
        sourceCaption = nil
        hourPoints = []
    }

    private func reloadVo2(repo: Repository, calendar: Calendar, ending: Date) async {
        let rows = await repo.appleDailyRows()
        let points = NativeVo2Max.points(rows).filter { $0.key <= dayKey }
        series = NativeScopeSeries.make(
            points: points,
            scope: scope,
            kind: .rate,
            calendar: calendar,
            now: ending,
            ending: ending
        )
        if let reading = NativeVo2Max.latest(rows), reading.day <= dayKey {
            latest = NativeDayPoint(key: reading.day, value: reading.value)
            sourceCaption = NativeVo2Max.sourceLabel
        } else {
            latest = nil
            sourceCaption = nil
        }
        hourPoints = []
    }

    private func reloadStepHours(
        repo: Repository, calendar: Calendar, ending: Date, mergedDaily: Double?
    ) async {
        let start = calendar.startOfDay(for: ending)
        hourPoints = await NativeDerivedSeries.hourlySteps(
            repo: repo, dayKey: dayKey, dayStart: start, mergedDaily: mergedDaily, calendar: calendar
        )
    }

    /// Keys whose value comes from `NativeBandScores` rather than a stored daily column.
    private static let scoredKeys: Set<String> = [
        "recovery", "sleep_performance", "hours_vs_needed_pct", "hours_vs_needed_hours",
        "sleep_consistency", "sleep_need_min", "sleep_debt_min",
    ]

    private static let workoutKeys: Set<String> = [
        "strength_min", "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min",
    ]

    private static func resolvedValue(key: String, day: DailyMetric, scores: NativeBandScores.Snapshot?) -> Double? {
        let scored = scores?.byDay[day.day]
        switch key {
        case "recovery": return scored?.recovery
        case "sleep_performance": return scored?.sleepPerformance
        case "hours_vs_needed_pct": return scored?.hoursVsNeeded
        case "hours_vs_needed_hours":
            guard let asleep = day.totalSleepMin, let need = scored?.sleepNeed, need > 0 else { return nil }
            return (asleep - need) / 60
        case "sleep_consistency": return scored?.sleepConsistency
        case "sleep_need_min": return scored?.sleepNeed
        case "sleep_debt_min": return scored?.sleepDebt
        default: return Repository.dailyColumn(key: key, day: day)
        }
    }

    /// Cheap daily fill when `exploreSeries` has no row for the day.
    private static func derivedValue(key: String, day: DailyMetric) -> Double? {
        switch key {
        case "restorative_min":
            if let deep = day.deepMin, let rem = day.remMin {
                let sum = deep + rem
                return sum > 0 ? sum : nil
            }
            return nil
        case "restorative_pct":
            if let deep = day.deepMin, let rem = day.remMin,
               let asleep = day.totalSleepMin, asleep > 0 {
                return (deep + rem) / asleep * 100
            }
            return nil
        case "in_bed_min":
            guard let asleep = day.totalSleepMin, let efficiency = day.efficiency, efficiency > 0 else {
                return nil
            }
            let pct = efficiency > 1 ? efficiency / 100 : efficiency
            guard pct > 0 else { return nil }
            return asleep / pct
        default:
            return Repository.dailyColumn(key: key, day: day)
        }
    }

    private static func workoutPoints(key: String, workouts: [WorkoutRow], ending: String) -> [NativeDayPoint] {
        let grouped = Dictionary(grouping: workouts) {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs)))
        }
        return grouped.keys.sorted().compactMap { day in
            guard day <= ending else { return nil }
            let rows = grouped[day] ?? []
            let value: Double?
            switch key {
            case "strength_min": value = NativeDay.strengthMinutes(rows)
            case "hr_zones13_min": value = NativeDay.zoneMinutes(rows, zones: 0..<3)
            case "hr_zones45_min": value = NativeDay.zoneMinutes(rows, zones: 3..<5)
            case "hr_zones_all_min": value = NativeDay.zoneMinutes(rows, zones: 0..<5)
            default: value = nil
            }
            return value.map { NativeDayPoint(key: day, value: $0) }
        }
    }

    private static func displayValue(_ raw: Double?, key: String, scale: EffortScale) -> Double? {
        guard let raw else { return nil }
        if key == "strain" {
            return NativeDayLogic.strainDisplayValue(raw, scale: scale)
        }
        if key == "sleep_efficiency", raw <= 1 { return raw * 100 }
        if key == "restorative_min" { return raw / 60 }
        return raw
    }

    private func format(_ value: Double) -> String {
        if key == "strain" {
            return UnitPrefs.resolveEffortScale(effortScaleRaw) == .whoop
                ? String(format: "%.1f", value)
                : String(Int(value.rounded()))
        }
        if key == "resp_rate" || key == "vo2max" || key == "vo2max_est"
            || key == "hours_vs_needed_hours" || key == "restorative_min" || key == "stress"
            || key == "weight" || key == "lean_mass" {
            return String(format: "%.1f", value)
        }
        if key == "steps" || key == "energy_kcal" || key == "active_kcal" {
            return NativeCountFormat.integer(value)
        }
        return "\(Int(value.rounded()))"
    }
}

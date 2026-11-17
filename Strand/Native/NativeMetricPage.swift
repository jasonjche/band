import SwiftUI
import WhoopStore
import StrandDesign

/// Apple Health chart page: D/W/M/6M aggregation, hero, chart, Latest capsule, Trend.
struct NativeMetricPage: View {
    var key: String
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
        if key == "vo2max" || key == "vo2max_est" { return "VO₂ Max" }
        return metric?.title ?? key.replacingOccurrences(of: "_", with: " ").capitalized
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
            onScope: { scope = $0 },
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
            sourceCaption: sourceCaption
        )
        .background {
            NativeRepoSink(refreshSeq: $refreshSeq, ready: $handlesReady) { repoHandle = $0 }
        }
        .task(id: taskID) {
            guard handlesReady else { return }
            await reload()
        }
    }

    private var usesBars: Bool {
        NativeScopeKindMap.kind(for: key) == .total
    }

    private var tint: Color {
        switch key {
        case "hrv", "rhr", "resting_hr", "avg_hr", "max_hr": return NativeTokens.heart
        case "resp_rate": return NativeTokens.respiratory
        case "steps", "energy_kcal", "active_kcal": return NativeTokens.activity
        case "vo2max", "vo2max_est": return NativeTokens.respiratory
        case "strain": return NativeTokens.strain
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
        case "steps": return "steps"
        case "energy_kcal", "active_kcal": return "cal"
        case "vo2max", "vo2max_est": return "ml/kg·min"
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
        let scores = NativeBandScores.resolve(
            days: repo.days, sleeps: repo.sleeps, importedSleep: repo.importedSleep
        )
        let points: [NativeDayPoint] = repo.days.filter { $0.day <= dayKey }.compactMap { day in
            displayValue(resolvedValue(key: key, day: day, scores: scores)).map {
                NativeDayPoint(key: day.day, value: $0)
            }
        }
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
        let from = Int(start.timeIntervalSince1970)
        let appleHours = await repo.appleStepHours(from: from, to: from + 86_400 - 1)
        let appleSum = appleHours.reduce(0) { $0 + $1.steps }
        let appleDaily = (await repo.appleDailyRows(days: 3)).first { $0.day == dayKey }?.steps
        let preferApple = NativeResolvedSteps.preferAppleHours(
            appleSum: appleSum,
            appleDaily: appleDaily,
            mergedDaily: mergedDaily.map { Int($0.rounded()) }
        )
        hourPoints = NativeResolvedSteps.hourPoints(
            appleHours: appleHours,
            dayStart: start,
            calendar: calendar,
            preferApple: preferApple
        )
    }

    private func resolvedValue(key: String, day: DailyMetric, scores: NativeBandScores.Snapshot) -> Double? {
        let scored = scores.byDay[day.day]
        switch key {
        case "recovery": return scored?.recovery
        case "sleep_performance": return scored?.sleepPerformance
        case "hours_vs_needed_pct": return scored?.hoursVsNeeded
        case "sleep_consistency": return scored?.sleepConsistency
        case "sleep_need_min": return scored?.sleepNeed
        case "sleep_debt_min": return scored?.sleepDebt
        default: return Repository.dailyColumn(key: key, day: day)
        }
    }

    private func displayValue(_ raw: Double?) -> Double? {
        guard let raw else { return nil }
        if key == "strain" {
            return NativeDayLogic.strainDisplayValue(raw, scale: UnitPrefs.resolveEffortScale(effortScaleRaw))
        }
        if key == "sleep_efficiency", raw <= 1 { return raw * 100 }
        return raw
    }

    private func format(_ value: Double) -> String {
        if key == "strain" {
            return UnitPrefs.resolveEffortScale(effortScaleRaw) == .whoop
                ? String(format: "%.1f", value)
                : String(Int(value.rounded()))
        }
        if key == "resp_rate" || key == "vo2max" || key == "vo2max_est" {
            return String(format: "%.1f", value)
        }
        if key == "steps" || key == "energy_kcal" || key == "active_kcal" {
            return NativeCountFormat.integer(value)
        }
        return "\(Int(value.rounded()))"
    }
}

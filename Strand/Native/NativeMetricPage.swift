import SwiftUI
import WhoopStore
import StrandDesign

/// Apple Health chart page: time scope, AVERAGE hero, chart, Latest capsule.
struct NativeMetricPage: View {
    var key: String
    @EnvironmentObject private var repo: Repository
    @AppStorage(NativeDaySelection.storageKey) private var nativeDayKey = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @State private var scope: NativeMetricScope = .week

    private var selectedDay: Date {
        NativeDaySelection.date(from: nativeDayKey)
    }

    private var dayKey: String { NativeDayLogic.resolvedDayKey(stored: nativeDayKey) }

    private var metric: MetricDescriptor? {
        MetricCatalog.all.first { $0.key == key }
    }

    private var title: String {
        metric?.title ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var series: [NativeDayPoint] {
        let limit: Int
        switch scope {
        case .week: limit = 7
        case .month: limit = 30
        case .sixMonths: limit = 180
        }
        let scores = NativeBandScores.resolve(
            days: repo.days, sleeps: repo.sleeps, importedSleep: repo.importedSleep
        )
        return repo.days.filter { $0.day <= dayKey }.suffix(limit).compactMap { day in
            displayValue(resolvedValue(key: key, day: day, scores: scores)).map {
                NativeDayPoint(key: day.day, value: $0)
            }
        }
    }

    private var availableScopes: [NativeMetricScope] {
        let scores = NativeBandScores.resolve(
            days: repo.days, sleeps: repo.sleeps, importedSleep: repo.importedSleep
        )
        let count = repo.days.filter {
            $0.day <= dayKey && displayValue(resolvedValue(key: key, day: $0, scores: scores)) != nil
        }.count
        var scopes: [NativeMetricScope] = [.week, .month]
        if count > 35 { scopes.append(.sixMonths) }
        return scopes
    }

    private var latestPoint: NativeDayPoint? { series.last }

    var body: some View {
        NativeChrome.screen {
            if availableScopes.count > 1 {
                Picker("Range", selection: $scope) {
                    ForEach(availableScopes) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Time range")
            }

            NativeChartBlock(
                points: paddedSeries,
                bars: usesBars,
                tint: tint,
                format: format,
                unit: displayUnit,
                maxY: usesBars ? max(paddedSeries.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 1) : 1,
                highlightKey: dayKey,
                plotHeight: 280,
                accessibilityName: title
            )

            if let latestPoint {
                NativeLatestCapsule(
                    label: "Latest: \(NativeChartDay.mediumDate(latestPoint.key))",
                    value: "\(format(latestPoint.value))\(displayUnit.map { " \($0)" } ?? "")"
                )
            } else {
                NativeLatestCapsule(label: "Latest", value: "Unavailable")
            }
        }
        .navigationTitle(title)
        .modifier(NativeInlineTitle())
        .onAppear {
            if !availableScopes.contains(scope) {
                scope = availableScopes.first ?? .week
            }
        }
    }

    /// Week charts keep a slot for every day so a missing day is a gap, not a shifted bar.
    private var paddedSeries: [NativeDayPoint] {
        guard scope == .week else { return series }
        let byKey = Dictionary(uniqueKeysWithValues: series.map { ($0.key, $0) })
        return NativeWeek.lastSevenKeys(ending: dayKey).map { key in
            byKey[key] ?? NativeDayPoint(key: key, value: .nan)
        }
    }

    private var usesBars: Bool {
        switch key {
        case "steps", "energy_kcal", "active_kcal", "strain": return true
        default: return false
        }
    }

    private var tint: Color {
        switch key {
        case "hrv", "rhr", "resting_hr": return NativeTokens.heart
        case "resp_rate": return NativeTokens.respiratory
        case "steps", "energy_kcal", "active_kcal": return NativeTokens.activity
        case "strain": return NativeTokens.strain
        default: return NativeTokens.sleep
        }
    }

    private var displayUnit: String? {
        switch key {
        case "hrv": return "ms"
        case "rhr", "resting_hr": return "BPM"
        case "resp_rate": return "breaths/min"
        case "steps": return "steps"
        case "energy_kcal", "active_kcal": return "cal"
        default:
            let unit = metric?.unit ?? ""
            return unit.isEmpty ? nil : unit
        }
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
        if key == "resp_rate" { return String(format: "%.1f", value) }
        if key == "steps" || key == "energy_kcal" || key == "active_kcal" {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
        }
        return "\(Int(value.rounded()))"
    }
}

enum NativeMetricScope: String, CaseIterable, Identifiable, Hashable {
    case week
    case month
    case sixMonths

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: return "W"
        case .month: return "M"
        case .sixMonths: return "6M"
        }
    }
}

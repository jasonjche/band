import SwiftUI
import Charts
import WhoopStore
import StrandDesign
import StrandAnalytics

/// WHOOP-style Healthspan: Band Age (6-month) and Pace of Aging (30-day).
struct NativeHealthspanPage: View {
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""
    @State private var repoHandle: Repository?
    @State private var refreshSeq = 0
    @State private var handlesReady = false
    @State private var result: HealthspanEngine.Result?

    private var selectedDay: Date { NativeDaySelection.date(from: selectedDayKey) }
    private var dayKey: String { NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }
    private var taskID: String { handlesReady ? "\(dayKey)|\(refreshSeq)" : "boot" }

    var body: some View {
        Group {
            if let result {
                NativeHealthspanBody(result: result)
            } else {
                NativeChrome.screen {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        }
        .navigationTitle("Healthspan")
        .modifier(NativeInlineTitle())
        .background {
            NativeRepoSink(refreshSeq: $refreshSeq, ready: $handlesReady) { repoHandle = $0 }
        }
        .task(id: taskID) {
            guard handlesReady, let repo = repoHandle else { return }
            await reload(repo: repo)
        }
    }

    private func reload(repo: Repository) async {
        let metrics = repo.days
        let sleeps = repo.sleeps
        async let workoutRows = repo.workoutRows(days: 400)
        async let appleRows = repo.appleDailyRows(days: 400)
        async let sleepMin = repo.exploreSeries(key: "sleep_total_min", source: "my-whoop", days: 400)
        async let cons = repo.exploreSeries(key: "sleep_consistency", source: "my-whoop", days: 400)
        async let stepsS = repo.exploreSeries(key: "steps", source: "my-whoop", days: 400)
        async let vo2S = repo.exploreSeries(key: "vo2max", source: "my-whoop", days: 400)
        async let vo2e = repo.exploreSeries(key: "vo2max_est", source: "my-whoop", days: 400)
        async let leanS = repo.exploreSeries(key: "lean_mass", source: "my-whoop", days: 400)
        async let weightS = repo.exploreSeries(key: "weight", source: "my-whoop", days: 400)
        let workouts = await workoutRows
        if Task.isCancelled { return }
        let apple = await appleRows
        if Task.isCancelled { return }
        let days = NativeHealthspanBuild.merge(
            metrics: metrics,
            sleeps: sleeps,
            workouts: workouts,
            apple: apple,
            sleepHoursByDay: NativeHealthspanBuild.hoursFromMinutes(await sleepMin),
            consistencyByDay: NativeHealthspanBuild.map(await cons),
            stepsByDay: NativeHealthspanBuild.map(await stepsS),
            vo2ByDay: NativeHealthspanBuild.map(await vo2S),
            vo2EstByDay: NativeHealthspanBuild.map(await vo2e),
            leanByDay: NativeHealthspanBuild.map(await leanS),
            weightByDay: NativeHealthspanBuild.map(await weightS),
            profileWeightKg: profile.weightKg > 0 ? profile.weightKg : nil
        )
        if Task.isCancelled { return }
        let asOf = dayKey
        let chrono = NativeHealthspanFormat.chronoAge(dob: profile.dateOfBirth, asOf: selectedDay)
        let computed = HealthspanEngine.compute(
            days: days,
            profile: .init(chronoAge: chrono, sex: profile.sex),
            asOfDay: asOf
        )
        if Task.isCancelled { return }
        result = computed
    }
}

struct NativeHealthspanBody: View {
    var result: HealthspanEngine.Result
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.screen {
            hero
            NativeHealthspanPaceCard(pace: result.pace)
            if result.readiness != .ready {
                calibration
            }
            section("Sleep", .sleep)
            section("Strain", .strain)
            section("Fitness", .fitness)
            if !result.trend.isEmpty {
                NativeChrome.section("Trend")
                NativeHealthspanTrendCard(points: result.trend)
            }
            NativeChrome.footnote(
                "Band Age is a wellness comparison from published mortality research, not a medical or biological age. Lean mass is omitted when the device has none. HRV is not used."
            )
        }
    }

    private var hero: some View {
        NativeChrome.panel {
            VStack(spacing: 8) {
                Text(result.bandAge.map(NativeHealthspanFormat.ageText) ?? "—")
                    .font(NativePaint.number(56, weight: .bold, style: style))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                Text("BAND AGE")
                    .font(style == .whoop ? NativeTokens.whoopCaps(12) : .footnote.weight(.semibold))
                    .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 1.2)
                    .foregroundStyle(.secondary)
                if let delta = result.deltaYears {
                    Text(NativeHealthspanFormat.youngerText(delta))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(delta >= 0 ? NativePaint.positiveDelta(style) : NativePaint.negativeDelta(style))
                }
                Text(String(format: "Chronological age %.1f", result.chronoAge))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private var calibration: some View {
        NativeChrome.panel {
            VStack(alignment: .leading, spacing: 8) {
                Text(NativeHealthspanFormat.calibrationTitle(result.readiness, days: result.coverageDays))
                    .font(.headline)
                Text(NativeHealthspanFormat.calibrationBody(days: result.coverageDays))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(result.missing, id: \.self) { item in
                    Text("• \(item)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ section: HealthspanEngine.Section) -> some View {
        let rows = result.contributors.filter { $0.section == section }
        NativeChrome.section(title)
        NativeChrome.panel {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(rows, id: \.key) { row in
                    NativeHealthspanContributorRow(row: row)
                }
            }
        }
    }
}

struct NativeHealthspanPaceCard: View {
    var pace: Double?
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("PACE OF AGING")
                        .font(style == .whoop ? NativeTokens.whoopCaps(12) : .footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(pace.map(NativeHealthspanFormat.paceText) ?? "—")
                        .font(NativePaint.number(22, weight: .bold, style: style))
                        .monospacedDigit()
                }
                NativeHealthspanPaceMeter(pace: pace ?? 1)
                HStack {
                    Text("Slow")
                    Spacer()
                    Text("−1.0x")
                    Spacer()
                    Text("1.0x")
                    Spacer()
                    Text("3.0x")
                    Spacer()
                    Text("Fast")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct NativeHealthspanPaceMeter: View {
    var pace: Double
    @Environment(\.nativeStyle) private var style

    var body: some View {
        GeometryReader { geo in
            let t = CGFloat(HealthspanEngine.clamp(pace, -1, 3) + 1) / 4
            let x = max(2, min(geo.size.width - 2, t * geo.size.width))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(NativePaint.separator(style).opacity(0.35))
                    .frame(height: 6)
                Capsule()
                    .fill(NativePaint.recovery(style))
                    .frame(width: max(6, x), height: 6)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary)
                    .frame(width: 3, height: 18)
                    .offset(x: x - 1.5)
            }
        }
        .frame(height: 18)
        .accessibilityLabel("Pace of aging \(NativeHealthspanFormat.paceText(pace))")
    }
}

struct NativeHealthspanContributorRow: View {
    var row: HealthspanEngine.Contributor
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label.uppercased())
                    .font(style == .whoop ? NativeTokens.whoopCaps(11) : .caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(NativeHealthspanFormat.yearsImpact(row.years, available: row.available))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(yearsColor)
                    .monospacedDigit()
            }
            if row.available, let value = row.value {
                NativeHealthspanRangeBar(
                    value: value,
                    value30: row.value30,
                    scaleMin: row.scaleMin,
                    scaleMax: row.scaleMax,
                    higherIsBetter: row.higherIsBetter
                )
                HStack {
                    Text(NativeHealthspanFormat.valueText(value, unit: row.unit, key: row.key))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Spacer()
                    Text(row.targetLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Not available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NativeHealthspanFormat.accessibility(row))
    }

    private var yearsColor: Color {
        guard row.available, let years = row.years else { return .secondary }
        if years < -0.05 { return NativePaint.positiveDelta(style) }
        if years > 0.05 { return NativePaint.negativeDelta(style) }
        return .secondary
    }
}

struct NativeHealthspanRangeBar: View {
    var value: Double
    var value30: Double?
    var scaleMin: Double
    var scaleMax: Double
    var higherIsBetter: Bool
    @Environment(\.nativeStyle) private var style

    var body: some View {
        GeometryReader { geo in
            let span = max(scaleMax - scaleMin, 1)
            let x: (Double) -> CGFloat = { v in
                CGFloat(HealthspanEngine.clamp((v - scaleMin) / span, 0, 1)) * geo.size.width
            }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: higherIsBetter
                                ? [NativeTokens.bandPoor, NativeTokens.bandSufficient, NativeTokens.bandOptimal]
                                : [NativeTokens.bandOptimal, NativeTokens.bandSufficient, NativeTokens.bandPoor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 8)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 8))
                    .offset(x: x(value) - 5, y: -10)
                if let value30 {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 8))
                        .offset(x: x(value30) - 5, y: 10)
                }
            }
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }
}

struct NativeHealthspanTrendCard: View {
    var points: [HealthspanEngine.TrendPoint]
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            VStack(alignment: .leading, spacing: 16) {
                Text("BAND AGE TREND")
                    .font(style == .whoop ? NativeTokens.whoopCaps(11) : .caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Chart {
                    ForEach(points, id: \.day) { p in
                        LineMark(
                            x: .value("Day", p.day),
                            y: .value("Age", p.bandAge),
                            series: .value("Kind", "Band Age")
                        )
                        .foregroundStyle(NativePaint.recovery(style))
                        LineMark(
                            x: .value("Day", p.day),
                            y: .value("Age", p.chronoAge),
                            series: .value("Kind", "Chronological")
                        )
                        .foregroundStyle(Color.primary.opacity(0.45))
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: 160)

                Text("PACE OF AGING TREND")
                    .font(style == .whoop ? NativeTokens.whoopCaps(11) : .caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                Chart {
                    ForEach(points, id: \.day) { p in
                        if let pace = p.pace {
                            LineMark(
                                x: .value("Day", p.day),
                                y: .value("Pace", pace)
                            )
                            .foregroundStyle(NativePaint.strain(style))
                        }
                    }
                    RuleMark(y: .value("1x", 1.0))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                }
                .chartYScale(domain: -1...3)
                .chartXAxis(.hidden)
                .frame(height: 140)
            }
        }
    }
}

enum NativeHealthspanFormat {
    static func chronoAge(dob: Date, asOf: Date) -> Double {
        max(0, asOf.timeIntervalSince(dob) / (365.25 * 86_400))
    }

    static func ageText(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func paceText(_ value: Double) -> String {
        String(format: "%.1fx", value)
    }

    static func yearsImpact(_ years: Double?, available: Bool) -> String {
        guard available, let years else { return "—" }
        if abs(years) < 0.05 { return "0.0 years" }
        return String(format: "%+.1f years", years)
    }

    static func youngerText(_ delta: Double) -> String {
        if abs(delta) < 0.05 { return "Same as your age" }
        if delta > 0 { return String(format: "%.1f years younger", delta) }
        return String(format: "%.1f years older", -delta)
    }

    static func valueText(_ value: Double, unit: String, key: String) -> String {
        switch key {
        case "sleep": return NativeScoreMath.duration(value * 60) + " h"
        case "zone13", "zone45", "strength": return NativeScoreMath.duration(value) + " h"
        case "steps": return NativeScoreMath.count(value)
        case "consistency", "lean": return String(format: "%.0f%%", value)
        case "rhr": return String(format: "%.0f bpm", value)
        case "vo2max": return String(format: "%.0f ml/kg/min", value)
        default:
            if unit.isEmpty { return String(format: "%.0f", value) }
            return String(format: "%.0f %@", value, unit)
        }
    }

    static func calibrationTitle(_ readiness: HealthspanEngine.Readiness, days: Int) -> String {
        switch readiness {
        case .notReady: return "Not enough data yet"
        case .calibrating: return "Calibrating Band Age"
        case .ready: return "Calibrated"
        }
    }

    static func calibrationBody(days: Int) -> String {
        let remain = max(0, HealthspanEngine.minDaysForAge - days)
        return "Band Age uses a 6-month average. \(days) days on record. Pace of Aging uses 30 days.\(remain > 0 ? " About \(remain) more days until Band Age is calibrated." : "")"
    }

    static func accessibility(_ row: HealthspanEngine.Contributor) -> String {
        let value = row.value.map { valueText($0, unit: row.unit, key: row.key) } ?? "not available"
        let years = yearsImpact(row.years, available: row.available)
        return "\(row.label), \(value), target \(row.targetLabel), \(years)"
    }
}

enum NativeHealthspanBuild {
    static func map(_ rows: [(day: String, value: Double)]) -> [String: Double] {
        Dictionary(rows.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    static func hoursFromMinutes(_ rows: [(day: String, value: Double)]) -> [String: Double] {
        Dictionary(rows.map { ($0.day, $0.value / 60) }, uniquingKeysWith: { _, last in last })
    }

    static func clockMin(_ ts: Int) -> Int {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let cal = Calendar.current
        return cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
    }

    static func merge(
        metrics: [DailyMetric],
        sleeps: [CachedSleepSession],
        workouts: [WorkoutRow],
        apple: [AppleDaily],
        sleepHoursByDay: [String: Double],
        consistencyByDay: [String: Double],
        stepsByDay: [String: Double],
        vo2ByDay: [String: Double],
        vo2EstByDay: [String: Double],
        leanByDay: [String: Double],
        weightByDay: [String: Double],
        profileWeightKg: Double?
    ) -> [HealthspanEngine.Day] {
        var byDay: [String: HealthspanEngine.Day] = [:]
        func slot(_ day: String) -> HealthspanEngine.Day {
            byDay[day] ?? HealthspanEngine.Day(day: day)
        }

        for m in metrics {
            var row = slot(m.day)
            if let min = m.totalSleepMin, min >= 120, min <= 840 {
                row.sleepHours = min / 60
            }
            if let hr = m.restingHr, hr > 0 { row.restingHR = Double(hr) }
            if let s = m.steps, s > 0 { row.steps = Double(s) }
            byDay[m.day] = row
        }

        let sleepsByDay = Dictionary(grouping: sleeps) {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs)))
        }
        for (day, sessions) in sleepsByDay {
            guard let night = sessions.max(by: { ($0.endTs - $0.effectiveStartTs) < ($1.endTs - $1.effectiveStartTs) })
            else { continue }
            var row = slot(day)
            row.sleepOnsetMin = clockMin(night.effectiveStartTs)
            row.sleepWakeMin = clockMin(night.endTs)
            byDay[day] = row
        }

        let workoutsByDay = Dictionary(grouping: workouts) {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs)))
        }
        for (day, rows) in workoutsByDay {
            var z13 = 0.0, z45 = 0.0, strength = 0.0
            for w in rows {
                let durMin = (w.durationS ?? Double(max(0, w.endTs - w.startTs))) / 60
                if let p = HealthspanEngine.zonePercents(fromJSON: w.zonesJSON) {
                    let z = HealthspanEngine.zoneMinutes(percents: p, durationMin: durMin)
                    z13 += z.z13
                    z45 += z.z45
                }
                if HealthspanEngine.isStrengthSport(w.sport) { strength += durMin }
            }
            var row = slot(day)
            if z13 > 0 { row.zone13Min = z13 }
            if z45 > 0 { row.zone45Min = z45 }
            if strength > 0 { row.strengthMin = strength }
            byDay[day] = row
        }

        for a in apple {
            var row = slot(a.day)
            if let s = a.steps, s > 0 { row.steps = Double(s) }
            if let v = a.vo2max, v > 0 { row.vo2max = v }
            byDay[a.day] = row
        }

        for (day, hours) in sleepHoursByDay where hours > 2 && hours < 14 {
            var row = slot(day)
            row.sleepHours = hours
            byDay[day] = row
        }
        for (day, c) in consistencyByDay where c > 0 {
            var row = slot(day)
            row.sleepConsistency = c
            byDay[day] = row
        }
        for (day, s) in stepsByDay where s > 0 {
            var row = slot(day)
            if row.steps == nil { row.steps = s }
            byDay[day] = row
        }
        for (day, v) in vo2ByDay where v > 0 {
            var row = slot(day)
            if row.vo2max == nil { row.vo2max = v }
            byDay[day] = row
        }
        for (day, v) in vo2EstByDay where v > 0 {
            var row = slot(day)
            if row.vo2max == nil { row.vo2max = v }
            byDay[day] = row
        }
        for (day, stored) in leanByDay {
            var row = slot(day)
            let weight = weightByDay[day] ?? profileWeightKg
            row.leanMassPct = HealthspanEngine.leanMassPercent(stored: stored, weightKg: weight)
            byDay[day] = row
        }

        return byDay.values.sorted { $0.day < $1.day }
    }
}

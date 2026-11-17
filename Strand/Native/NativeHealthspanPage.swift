import SwiftUI
import WhoopStore
import StrandDesign
import StrandAnalytics

/// WHOOP-style Healthspan: Band Age (6-month) and Pace of Aging (30-day).
struct NativeHealthspanPage: View {
    /// Rows shown under Pace of Aging when this page is the Health tab root (Trends, Reports).
    var links: [NativeHealthItem] = []
    var title: String = "Healthspan"
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var repoHandle: Repository?
    @State private var profileHandle: ProfileStore?
    @State private var refreshSeq = 0
    @State private var handlesReady = false
    @State private var result: HealthspanEngine.Result?

    private var selectedDay: Date { NativeDaySelection.date(from: selectedDayKey) }
    private var dayKey: String { NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }
    private var taskID: String { handlesReady ? "\(dayKey)|\(refreshSeq)" : "boot" }

    var body: some View {
        NativeHealthspanBody(result: result, links: links)
            .navigationTitle(title)
            .modifier(NativeInlineTitle())
            .navigationDestination(for: NativeHealthspanTrendKind.self) { kind in
                NativeHealthspanTrendPage(kind: kind, points: result?.trend ?? [])
            }
            .background {
                NativeRepoSink(refreshSeq: $refreshSeq, ready: $handlesReady) { repoHandle = $0 }
                NativeProfileSink { profileHandle = $0 }
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
            profileWeightKg: {
                guard let kg = profileHandle?.weightKg, kg > 0 else { return nil }
                return kg
            }()
        )
        if Task.isCancelled { return }
        let asOf = dayKey
        let chrono = profileHandle.map {
            NativeHealthspanFormat.chronoAge(dob: $0.dateOfBirth, asOf: selectedDay)
        } ?? 0
        let sex = profileHandle?.sex ?? ""
        let computed = await Task.detached(priority: .userInitiated) {
            HealthspanEngine.compute(
                days: days,
                profile: .init(chronoAge: chrono, sex: sex),
                asOfDay: asOf
            )
        }.value
        if Task.isCancelled { return }
        let still = motion.poseStill(reduceMotion)
        if still {
            result = computed
        } else {
            withAnimation(NoopMotion.card) {
                result = computed
            }
        }
    }
}

struct NativeHealthspanBody: View {
    var result: HealthspanEngine.Result?
    var links: [NativeHealthItem] = []
    @Environment(\.nativeStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var compactProgress: CGFloat = 0

    private var forming: Bool { result == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: style == .whoop ? 12 : 10) {
                NativeHealthspanOrb(
                    value: result?.bandAge,
                    delta: result?.deltaYears,
                    isLoading: forming,
                    compact: false,
                    reduceMotion: reduceMotion
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .opacity(1 - compactProgress)
                .modifier(NativeHealthspanHeroPhaseFade())
                .background(NativeHealthspanHeroAnchor())
                if let result {
                    NativeHealthspanPaceCard(
                        pace: result.pace,
                        weekDelta: NativeHealthspanPaceChip.weekDelta(points: result.trend)
                    )
                }
                if !links.isEmpty {
                    NativeHealthLinks(items: links)
                }
                if let result {
                    if result.readiness != .ready {
                        calibration(result)
                    }
                    NativeHealthspanSectionBlock(
                        title: "Sleep",
                        rows: result.contributors.filter { $0.section == .sleep }
                    )
                    NativeHealthspanSectionBlock(
                        title: "Strain",
                        rows: result.contributors.filter { $0.section == .strain }
                    )
                    NativeHealthspanSectionBlock(
                        title: "Fitness",
                        rows: result.contributors.filter { $0.section == .fitness }
                    )
                    if !result.trend.isEmpty {
                        NativeChrome.section("Trend")
                        NativeHealthspanTrendCard(points: result.trend, kind: .bandAge)
                        NativeHealthspanTrendCard(points: result.trend, kind: .pace)
                    }
                    NativeChrome.footnote(
                        "Band Age is a wellness comparison from published mortality research, not a medical or biological age. Lean mass is omitted when the device has none. HRV is not used."
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 160)
        }
        .coordinateSpace(name: NativeHealthspanScroll.name)
        .background(NativePageFill().ignoresSafeArea())
        .modifier(NativeHealthspanScrollCompact(progress: $compactProgress))
        .onPreferenceChange(NativeHealthspanHeroMinYKey.self) { minY in
            if #available(iOS 18.0, macOS 15.0, *) { return }
            let next = NativeHealthspanScroll.progress(heroMinY: minY)
            if abs(next - compactProgress) > 0.01 {
                compactProgress = next
            }
        }
        .overlay(alignment: .top) {
            if let result {
                NativeHealthspanCompactHeader(
                    bandAge: result.bandAge,
                    deltaYears: result.deltaYears,
                    pace: result.pace,
                    forming: false
                )
                .opacity(compactProgress)
                .allowsHitTesting(false)
            }
        }
    }

    private func calibration(_ result: HealthspanEngine.Result) -> some View {
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
}

enum NativeHealthspanScroll {
    static let name = "healthspan"
    static let fadeStart: CGFloat = 24
    static let fadeSpan: CGFloat = 140

    static func progress(offset: CGFloat) -> CGFloat {
        min(1, max(0, (offset - fadeStart) / fadeSpan))
    }

    static func progress(heroMinY: CGFloat) -> CGFloat {
        progress(offset: -heroMinY)
    }
}

private struct NativeHealthspanHeroMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct NativeHealthspanHeroAnchor: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: NativeHealthspanHeroMinYKey.self,
                value: geo.frame(in: .named(NativeHealthspanScroll.name)).minY
            )
        }
    }
}

private struct NativeHealthspanHeroPhaseFade: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.scrollTransition { view, phase in
                view.scaleEffect(phase.isIdentity ? 1 : 0.92)
            }
        } else {
            content
        }
    }
}

private struct NativeHealthspanScrollCompact: ViewModifier {
    @Binding var progress: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, y in
                let next = min(1, max(0, (y - NativeHealthspanScroll.fadeStart) / NativeHealthspanScroll.fadeSpan))
                if abs(next - progress) > 0.01 {
                    progress = next
                }
            }
        } else {
            content
        }
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

import SwiftUI
import Charts
import StrandDesign
import WhoopStore

// Native Home: WHOOP order, Apple Health chrome.
// Sections take plain value models so snapshots can render without Repository.

struct NativeHomeView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState
    @Environment(\.nativeNavigationPath) private var path
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @State private var workouts: [WorkoutRow] = []
    @State private var journalEntries: [JournalEntry] = []
    @State private var sampleHours: [NativeHourPoint] = []
    @State private var vo2max: Double?
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""
    @AppStorage("behavior.smartAlarmEnabled") private var smartAlarmEnabled = false
    @AppStorage("behavior.smartAlarmMinutes") private var smartAlarmMinutes = 7 * 60

    private var selectedDay: Date {
        get { NativeDaySelection.date(from: selectedDayKey) }
        nonmutating set { selectedDayKey = NativeDaySelection.key(from: newValue) }
    }

    private var selectedKey: String { NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }

    private var model: NativeDay.Model {
        NativeDay.make(
            days: repo.days,
            sleeps: repo.sleeps,
            workouts: workouts,
            todayKey: selectedKey,
            connected: live.connected,
            effortScale: UnitPrefs.resolveEffortScale(effortScaleRaw),
            journalEntries: journalEntries,
            importedSleep: repo.importedSleep
        )
    }

    private var storeEmpty: Bool {
        NativeDayLogic.isEmptyStore(
            days: repo.days, sleeps: repo.sleeps, importedSleep: repo.importedSleep
        )
    }

    private var healthRange: NativeHealthRange.Summary {
        NativeHealthRange.summary(days: repo.days, todayKey: selectedKey)
    }

    private var tonightSleep: NativeTonightSleep.Model? {
        guard selectedKey == NativeDayLogic.logicalToday() else { return nil }
        return NativeTonightSleep.make(
            needMin: model.sleepNeedMin,
            alarmEnabled: smartAlarmEnabled,
            alarmMinutes: smartAlarmMinutes
        )
    }

    private var stressLevel: Double? {
        NativeHomeCharts.stressLevel(hours: sampleHours, days: repo.days, todayKey: selectedKey)
    }

    var body: some View {
        NativeChrome.screen {
            #if os(iOS)
            HomeDateStepper(
                title: HomeDayTitle.text(for: selectedDay),
                canGoBack: canGoBack,
                canGoForward: canGoForward,
                onBack: { shiftDay(-1) },
                onForward: { shiftDay(1) }
            )
            .frame(maxWidth: .infinity)
            #endif
            if live.backfilling {
                HomeSyncingCaption()
            }
            if !repo.loaded {
                HomeLoadingSkeleton()
            } else if storeEmpty {
                NativeNoDataCard(
                    onImport: { path.wrappedValue.append(TabRoute.dataSources) },
                    onPair: { path.wrappedValue.append(NativePairRoute()) }
                )
            } else {
                homeContent
            }
        }
        .navigationTitle("Home")
        .environment(\.nativeSelectedDay, selectedDay)
        .nativeStyleBridge()
        .refreshable { await reload() }
        .task(id: "\(repo.refreshSeq)-\(selectedKey)") { await reload() }
        .navigationDestination(for: NativePairRoute.self) { _ in
            DevicesView()
        }
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .principal) {
                HomeDateStepper(
                    title: HomeDayTitle.text(for: selectedDay),
                    canGoBack: canGoBack,
                    canGoForward: canGoForward,
                    onBack: { shiftDay(-1) },
                    onForward: { shiftDay(1) }
                )
            }
            #endif
        }
        .accessibilityElement(children: .contain)
    }

    private var canGoBack: Bool {
        HomeDayNav.canGoBack(selectedKey: selectedKey, firstDay: repo.days.first?.day)
    }

    private var canGoForward: Bool {
        HomeDayNav.canGoForward(selectedKey: selectedKey)
    }

    private func shiftDay(_ delta: Int) {
        guard let next = HomeDayNav.shift(from: selectedDay, delta: delta, firstDay: repo.days.first?.day) else { return }
        selectedDay = next
    }

    private func reload() async {
        workouts = await repo.workoutRows(days: 120)
        journalEntries = await repo.journalEntries(days: 40)
        let start = Calendar.current.startOfDay(for: selectedDay)
        let from = Int(start.timeIntervalSince1970)
        let raw = await repo.hrSamples(from: from, to: from + 86_400, limit: 12_000)
        sampleHours = NativeHomeCharts.stressSeries(samples: raw.map { (ts: $0.ts, bpm: $0.bpm) })
        let vo2 = await repo.exploreSeries(key: "vo2max_est", source: "my-whoop")
        vo2max = vo2.last?.value
    }

    @ViewBuilder private var homeContent: some View {
        HomeRingsRow(
            sleep: model.sleep,
            recovery: model.recovery,
            strain: model.strain,
            onOpen: { path.wrappedValue.append($0) },
            dayKey: selectedKey
        )
        if let tonightSleep {
            HomeTonightSleepCard(model: tonightSleep)
        }
        HomeMonitorPair(
            hrv: HomeMonitorValue.from(model.dashboard, title: "Heart Rate Variability", unit: "ms"),
            rhr: HomeMonitorValue.from(model.dashboard, title: "Resting Heart Rate", unit: "BPM"),
            stressLevel: stressLevel,
            stressHours: sampleHours,
            rangeCaption: healthRange.headerTrailing,
            onHealth: { path.wrappedValue.append(TabRoute.metric("hrv")) },
            onStress: { path.wrappedValue.append(TabRoute.stress) }
        )
        if let vo2max {
            HomeVO2Card(value: vo2max)
        }
        NativeChrome.section("My Day")
        HomeActivitiesCard(
            items: HomeActivityItem.make(from: model),
            onSleep: { path.wrappedValue.append(TabRoute.sleep) },
            onActivity: { path.wrappedValue.append(NativeActivityRoute(startTs: $0)) }
        )
        HomeJournalCard(
            dots: NativeHomeCharts.journalDots(filled: model.journalDays, todayKey: selectedKey),
            onOpen: { path.wrappedValue.append(TabRoute.journal) }
        )
        HomeWeekCard(
            recovery: NativeWeek.points(
                kind: .recovery, days: repo.days, todayKey: selectedKey,
                sleeps: repo.sleeps, workouts: workouts, importedSleep: repo.importedSleep
            ).filter { $0.value.isFinite },
            strain: NativeWeek.points(
                kind: .strain, days: repo.days, todayKey: selectedKey,
                effortScale: UnitPrefs.resolveEffortScale(effortScaleRaw),
                sleeps: repo.sleeps, workouts: workouts, importedSleep: repo.importedSleep
            ).filter { $0.value.isFinite },
            highlightKey: selectedKey
        )
        ForEach(HomeMetricItem.make(dashboard: model.dashboard, days: repo.days, todayKey: selectedKey)) { item in
            Button {
                path.wrappedValue.append(item.route)
            } label: {
                HomeMetricCard(item: item, highlightKey: selectedKey)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Date stepper

enum HomeDayTitle {
    static func text(for date: Date, now: Date = Date()) -> String {
        if Repository.localDayKey(date) == NativeDayLogic.logicalToday(now: now) { return "Today" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }
}

enum HomeDayNav {
    static func canGoBack(selectedKey: String, firstDay: String?) -> Bool {
        guard let first = firstDay else { return false }
        return selectedKey > first
    }

    @MainActor
    static func canGoForward(selectedKey: String, todayKey: String? = nil) -> Bool {
        selectedKey < (todayKey ?? NativeDayLogic.logicalToday())
    }

    @MainActor
    static func shift(from date: Date, delta: Int, firstDay: String?) -> Date? {
        guard let next = Calendar.current.date(byAdding: .day, value: delta, to: date) else { return nil }
        let key = Repository.localDayKey(next)
        if delta > 0, key > NativeDayLogic.logicalToday() { return nil }
        if delta < 0, let first = firstDay, key < first { return nil }
        return Calendar.current.startOfDay(for: next)
    }
}

struct HomeDateStepper: View {
    var title: String
    var canGoBack: Bool
    var canGoForward: Bool
    var onBack: () -> Void
    var onForward: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(!canGoBack)
            .opacity(canGoBack ? 1 : 0.35)

            Text(title)
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 120)

            Button(action: onForward) {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(!canGoForward)
            .opacity(canGoForward ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint("Steps through days")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onForward()
            case .decrement: onBack()
            @unknown default: break
            }
        }
    }
}

// MARK: - Rings

struct HomeRingsRow: View {
    var sleep: NativeScore
    var recovery: NativeScore
    var strain: NativeScore
    var onOpen: (TabRoute) -> Void
    var dayKey: String = ""
    @Environment(\.nativeStyle) private var style

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ring(sleep, tint: NativePaint.sleep(style))
            ring(recovery, tint: recoveryTint)
            ring(strain, tint: NativePaint.strain(style))
        }
        .padding(.top, 8)
        .id(dayKey)
    }

    private var recoveryTint: Color {
        if let percent = NativeScoreMath.percentValue(recovery.value) {
            return NativePaint.recoveryBand(percent, style: style)
        }
        return NativePaint.recovery(style)
    }

    private func ring(_ score: NativeScore, tint: Color) -> some View {
        Button {
            onOpen(score.route)
        } label: {
            NativeRing(
                fraction: score.fraction,
                tint: tint,
                value: score.value,
                caption: score.name,
                diameter: 96
            )
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(score.name)")
    }
}

// MARK: - Health + Stress monitors

struct HomeMonitorValue {
    var value: String
    var unit: String
    var typical: String?

    static func from(_ rows: [NativeScore.Row], title: String, unit: String) -> HomeMonitorValue? {
        guard let row = rows.first(where: { $0.title == title }), NativeScoreMath.hasValue(row.value) else {
            return nil
        }
        let typical = NativeScoreMath.hasValue(row.prior) ? row.prior : nil
        return HomeMonitorValue(value: row.value, unit: unit, typical: typical)
    }
}

struct HomeMonitorPair: View {
    var hrv: HomeMonitorValue?
    var rhr: HomeMonitorValue?
    var stressLevel: Double?
    var stressHours: [NativeHourPoint]
    var rangeCaption: String? = nil
    var onHealth: () -> Void
    var onStress: () -> Void

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 0) {
            GridRow(alignment: .top) {
                Button(action: onHealth) {
                    HomeHealthMonitorCard(hrv: hrv, rhr: rhr, rangeCaption: rangeCaption)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                Button(action: onStress) {
                    HomeStressMonitorCard(level: stressLevel, hours: stressHours)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

private struct HomeHealthMonitorCard: View {
    var hrv: HomeMonitorValue?
    var rhr: HomeMonitorValue?
    var rangeCaption: String? = nil
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel(expands: true) {
            NativeCardHeader(
                title: "Health Monitor",
                symbol: "heart.fill",
                tint: NativePaint.heart(style),
                trailing: rangeCaption,
                chevron: true
            )
            if hrv == nil && rhr == nil {
                NativeEmptyState(text: "No Data", symbol: "heart")
                    .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if let hrv {
                        NativeContributorRow(
                            symbol: "waveform.path.ecg",
                            title: "HRV",
                            value: labeled(hrv.value, hrv.unit),
                            prior: hrv.typical.map { labeled($0, hrv.unit) },
                            tint: NativePaint.heart(style)
                        )
                    }
                    if hrv != nil && rhr != nil {
                        Divider().padding(.leading, 32)
                    }
                    if let rhr {
                        NativeContributorRow(
                            symbol: "heart.fill",
                            title: "RHR",
                            value: labeled(rhr.value, rhr.unit),
                            prior: rhr.typical.map { labeled($0, rhr.unit) },
                            tint: NativePaint.heart(style)
                        )
                    }
                }
            }
        }
    }

    private func labeled(_ value: String, _ unit: String) -> String {
        if unit.isEmpty || value.localizedCaseInsensitiveContains(unit) { return value }
        return "\(value) \(unit)"
    }
}

private struct HomeStressMonitorCard: View {
    var level: Double?
    var hours: [NativeHourPoint]
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel(expands: true) {
            NativeCardHeader(
                title: "Stress Monitor",
                symbol: "chart.xyaxis.line",
                tint: level.map { NativePaint.stressBand($0, style: style) } ?? NativeChrome.stress,
                chevron: true
            )
            if let level {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    NativeValueText(value: String(format: "%.1f", level), size: 22)
                    Text(NativeHomeCharts.stressBandWord(level))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NativePaint.stressBand(level, style: style))
                }
                if hours.isEmpty {
                    NativeEmptyState(text: "No Data", symbol: "chart.xyaxis.line")
                        .frame(maxHeight: .infinity)
                } else {
                    HomeStressSparkline(hours: hours, tint: NativePaint.stressBand(level, style: style))
                        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: .infinity, alignment: .bottom)
                }
            } else {
                NativeValueText(value: "No Data", size: 22)
                NativeEmptyState(text: "No Data", symbol: "chart.xyaxis.line")
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

private struct HomeStressSparkline: View {
    var hours: [NativeHourPoint]
    var tint: Color

    private var yDomain: ClosedRange<Double> {
        let fitted = NativeChartDay.fittedDomain(hours.map(\.value), fallback: 0...3)
        let lo = min(max(fitted.lowerBound, 0), 2.7)
        let hi = max(min(fitted.upperBound, 3), lo + 0.3)
        return lo...hi
    }

    var body: some View {
        Chart(hours) { point in
            LineMark(
                x: .value("Time", point.time),
                y: .value("Stress", point.value)
            )
            .foregroundStyle(tint)
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: yDomain)
        .chartPlotStyle { plot in
            plot.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - My Day

struct HomeActivityItem: Identifiable {
    enum Kind { case sleep, strain }
    var id: String
    var symbol: String
    var kind: Kind
    var title: String
    var startClock: String
    var endClock: String
    var trailing: String
    var startTs: Int?

    static func make(from model: NativeDay.Model) -> [HomeActivityItem] {
        var items: [HomeActivityItem] = []
        if let duration = model.sleepBlock {
            let startClock = model.sleepStart.map { NativeDay.clockTime(Int($0.timeIntervalSince1970)) } ?? ""
            let endClock = model.sleepEnd.map { NativeDay.clockTime(Int($0.timeIntervalSince1970)) } ?? ""
            items.append(HomeActivityItem(
                id: "sleep",
                symbol: "moon.fill",
                kind: .sleep,
                title: "Sleep",
                startClock: startClock,
                endClock: endClock,
                trailing: duration,
                startTs: nil
            ))
        }
        for activity in model.activities {
            items.append(HomeActivityItem(
                id: "\(activity.startTs)",
                symbol: activity.symbol,
                kind: .strain,
                title: activity.sport.localizedCapitalized,
                startClock: activity.startClock,
                endClock: activity.endClock,
                trailing: activity.strainText,
                startTs: activity.startTs
            ))
        }
        return items
    }
}

struct HomeActivitiesCard: View {
    var items: [HomeActivityItem]
    var onSleep: () -> Void
    var onActivity: (Int) -> Void

    var body: some View {
        NativeChrome.panel {
            NativeCardHeader(title: "Activities", symbol: "figure.run", tint: NativeChrome.strain)
            if items.isEmpty {
                Text("No activities")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider().padding(.vertical, 4)
                        }
                        Button {
                            if let startTs = item.startTs {
                                onActivity(startTs)
                            } else {
                                onSleep()
                            }
                        } label: {
                            HomeActivityRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct HomeActivityRow: View {
    var item: HomeActivityItem
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeActivityRow(
            symbol: item.symbol,
            tint: item.kind == .sleep ? NativePaint.sleep(style) : NativePaint.strain(style),
            title: item.title,
            trailing: item.trailing,
            startClock: item.startClock,
            endClock: item.endClock
        )
    }
}

struct HomeJournalDot: Identifiable, Equatable {
    var key: String
    var filled: Bool
    var id: String { key }
}

private struct HomeJournalDayDot: View {
    var dot: HomeJournalDot
    @Environment(\.nativeStyle) private var style

    var body: some View {
        let fill = style == .whoop ? NativeTokens.whoopRecoveryHigh : NativeChrome.sleep
        VStack(spacing: 6) {
            Text(NativeChartDay.weekday(dot.key).uppercased())
                .font(style == .whoop ? NativeTokens.whoopCaps(9) : .caption2)
                .foregroundStyle(.secondary)
            if style == .whoop {
                if dot.filled {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(fill)
                } else {
                    Circle()
                        .strokeBorder(NativeTokens.whoopTrack, lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                }
            } else {
                Circle()
                    .strokeBorder(dot.filled ? fill : Color.secondary.opacity(0.45), lineWidth: 1.5)
                    .background(Circle().fill(dot.filled ? fill : Color.clear))
                    .frame(width: 10, height: 10)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct HomeJournalCard: View {
    var dots: [HomeJournalDot]
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            NativeChrome.panel {
                NativeCardHeader(
                    title: "Journal",
                    symbol: "book.closed.fill",
                    tint: NativeChrome.sleep,
                    chevron: true
                )
                HStack(spacing: 0) {
                    ForEach(dots) { dot in
                        HomeJournalDayDot(dot: dot)
                    }
                }
                .padding(.top, 4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Journal")
    }
}

// MARK: - Weekly Strain & Recovery

struct HomeWeekCard: View {
    var recovery: [NativeDayPoint]
    var strain: [NativeDayPoint]
    var highlightKey: String

    var body: some View {
        NativeChrome.panel {
            HomeDualSeriesHeader()
            if recovery.isEmpty && strain.isEmpty {
                NativeEmptyState(text: "No Data")
                    .frame(height: 160)
            } else {
                NativeStrainRecoveryChart(
                    recovery: recovery,
                    strain: strain,
                    highlightKey: highlightKey,
                    showsHero: true
                )
                .frame(height: 220)
            }
        }
    }
}

private struct HomeDualSeriesHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
            Text("Strain")
                .foregroundStyle(NativeChrome.strain)
            Text("&")
                .foregroundStyle(.secondary)
            Text("Recovery")
                .foregroundStyle(NativeChrome.recovery)
            Spacer(minLength: 8)
        }
        .font(.footnote.weight(.semibold))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Strain and Recovery")
    }
}

// MARK: - Metric cards

struct HomeMetricItem: Identifiable {
    var id: String { title }
    var title: String
    var value: String
    var unit: String?
    var prior: String?
    var delta: NativeScore.Delta
    var symbol: String
    var tint: Color
    var points: [NativeDayPoint]
    var bars: Bool
    var route: TabRoute

    static func make(dashboard: [NativeScore.Row], days: [DailyMetric], todayKey: String) -> [HomeMetricItem] {
        dashboard.compactMap { row in
            guard NativeScoreMath.hasValue(row.value) else { return nil }
            let prior = NativeScoreMath.hasValue(row.prior) ? row.prior : nil
            switch row.title {
            case "Heart Rate Variability":
                return HomeMetricItem(
                    title: row.title,
                    value: row.value,
                    unit: "ms",
                    prior: prior,
                    delta: row.delta,
                    symbol: "waveform.path.ecg",
                    tint: NativeChrome.heart,
                    points: NativeHomeCharts.points(days, todayKey: todayKey, keyPath: \.avgHrv),
                    bars: false,
                    route: row.route
                )
            case "Resting Heart Rate":
                return HomeMetricItem(
                    title: row.title,
                    value: row.value,
                    unit: "BPM",
                    prior: prior,
                    delta: row.delta,
                    symbol: "heart.fill",
                    tint: NativeChrome.heart,
                    points: NativeWeek.series(days, todayKey: todayKey) { $0.restingHr.map(Double.init) },
                    bars: false,
                    route: row.route
                )
            case "Steps":
                return HomeMetricItem(
                    title: row.title,
                    value: row.value,
                    unit: "steps",
                    prior: prior,
                    delta: row.delta,
                    symbol: "figure.walk",
                    tint: NativeChrome.activity,
                    points: NativeWeek.series(days, todayKey: todayKey) { $0.steps.map(Double.init) },
                    bars: true,
                    route: row.route
                )
            case "Calories":
                return HomeMetricItem(
                    title: row.title,
                    value: row.value,
                    unit: "cal",
                    prior: prior,
                    delta: row.delta,
                    symbol: "flame.fill",
                    tint: NativeChrome.activity,
                    points: NativeHomeCharts.points(days, todayKey: todayKey, keyPath: \.activeKcalEst),
                    bars: true,
                    route: row.route
                )
            default:
                return nil
            }
        }
    }
}

struct HomeMetricCard: View {
    var item: HomeMetricItem
    var highlightKey: String

    var body: some View {
        NativeChrome.panel {
            NativeContributorRow(
                symbol: item.symbol,
                title: item.title,
                value: displayValue,
                prior: item.prior,
                delta: item.delta,
                tint: item.tint
            )
            if item.points.contains(where: { $0.value.isFinite }) {
                Group {
                    if item.bars {
                        NativeScoreWeekBars(
                            points: item.points,
                            tint: item.tint,
                            format: Self.axisFormat,
                            maxY: max(item.points.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 1, 1),
                            highlightKey: highlightKey,
                            compactYAxis: true
                        )
                    } else {
                        NativeLabeledLine(
                            points: item.points,
                            tint: item.tint,
                            domain: 0...max(item.points.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 1, 1),
                            format: Self.axisFormat,
                            accessibilityName: item.title,
                            highlightKey: highlightKey,
                            compactYAxis: true
                        )
                    }
                }
                .frame(height: 72)
                .allowsHitTesting(false)
            }
        }
    }

    private var displayValue: String {
        if let unit = item.unit, !unit.isEmpty, item.value.localizedCaseInsensitiveContains(unit) == false {
            return "\(item.value) \(unit)"
        }
        return item.value
    }

    private static func axisFormat(_ value: Double) -> String {
        if abs(value) >= 1000 {
            return "\(Int((value / 1000).rounded()))k"
        }
        return "\(Int(value.rounded()))"
    }
}

// MARK: - Charts / stress series

enum NativeHomeCharts {
    static func points(_ days: [DailyMetric], todayKey: String, keyPath: KeyPath<DailyMetric, Double?>) -> [NativeDayPoint] {
        NativeWeek.series(days, todayKey: todayKey) { $0[keyPath: keyPath] }
            .filter { $0.value.isFinite }
    }

    /// Same 0–3 derivation Stress Monitor uses, over the last 7 days that have HRV or resting heart rate.
    static func stress(_ days: [DailyMetric], todayKey: String) -> [NativeDayPoint] {
        let window = days.filter { $0.day <= todayKey }.suffix(37)
        let baseline = Array(window.dropLast(7))
        let recent = Array(window.suffix(7))
        let meanRHR = StressMath.mean(baseline.compactMap { $0.restingHr }.map(Double.init))
        let sdRHR = StressMath.std(baseline.compactMap { $0.restingHr }.map(Double.init), mean: meanRHR)
        let meanHRV = StressMath.mean(baseline.compactMap(\.avgHrv))
        let sdHRV = StressMath.std(baseline.compactMap(\.avgHrv), mean: meanHRV)
        return recent.compactMap { day in
            let raw = StressMath.rawScore(
                rhrToday: day.restingHr.map(Double.init), meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: day.avgHrv, meanHRV: meanHRV, sdHRV: sdHRV
            )
            guard day.restingHr != nil || day.avgHrv != nil else { return nil }
            return NativeDayPoint(key: day.day, value: StressMath.squash(raw))
        }
    }

    /// Maps HR samples onto the 0–3 series. Empty input → empty series. Never invents a curve.
    static func stressSeries(samples: [(ts: Int, bpm: Int)], stride: Int = 3) -> [NativeHourPoint] {
        samples.enumerated().compactMap { index, sample in
            guard stride <= 1 || index % stride == 0 else { return nil }
            return NativeHourPoint(
                time: Date(timeIntervalSince1970: TimeInterval(sample.ts)),
                value: stressValue(bpm: Double(sample.bpm))
            )
        }
    }

    static func stressValue(bpm: Double) -> Double {
        min(3, max(0, (bpm - 48) / 38))
    }

    /// Last sample if the series exists, else the daily HRV/RHR score, else nil. Never 1.0 or 0 as a stand-in.
    static func stressLevel(hours: [NativeHourPoint], days: [DailyMetric], todayKey: String) -> Double? {
        hours.last?.value ?? stress(days, todayKey: todayKey).last?.value
    }

    /// NativeStressMonitor calls this when `sampleHours` is empty. Returns nothing so Home
    /// and the pushed page cannot disagree via a synthetic sleep/workout curve.
    static func stressHours(dayStart: Date, now: Date, sleepStart: Date?, sleepEnd: Date?,
                            workouts: [(Date, Date)], daily: Double) -> [NativeHourPoint] {
        _ = (dayStart, now, sleepStart, sleepEnd, workouts, daily)
        return []
    }

    static func journalDots(filled: [Bool], todayKey: String) -> [HomeJournalDot] {
        zip(NativeWeek.lastSevenKeys(ending: todayKey), filled).map {
            HomeJournalDot(key: $0.0, filled: $0.1)
        }
    }

    /// Two-line x-axis label for a `yyyy-MM-dd` key: weekday abbreviation over
    /// day-of-month ("Thu" / "12"). Unique across a week, including Sat/Sun.
    static func axisLabel(_ key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else {
            let tail = String(key.suffix(2)).drop { $0 == "0" }
            return tail.isEmpty ? key : String(tail)
        }
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "en_US_POSIX")
        weekday.timeZone = TimeZone(secondsFromGMT: 0)
        weekday.dateFormat = "EEE"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "d"
        return "\(weekday.string(from: date))\n\(day.string(from: date))"
    }

    static func weekday(_ key: String) -> String { axisLabel(key) }

    static func stressBand(_ value: Double) -> String {
        stressBandWord(value).uppercased()
    }

    static func stressBandWord(_ value: Double) -> String {
        if value < 1 { return "Low" }
        if value < 2 { return "Medium" }
        return "High"
    }
}

struct NativeActivityRoute: Hashable {
    var startTs: Int
}

struct NativePairRoute: Hashable {}

struct HomeSyncingCaption: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Syncing…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Syncing")
    }
}

struct NativeNoDataCard: View {
    var onImport: () -> Void
    var onPair: () -> Void
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(NativePaint.sleep(style))
            Text("No Data Yet")
                .font(style == .whoop ? NativeTokens.whoopNumber(22, weight: .bold) : .title2.bold())
            Text("Pair your strap or import a WHOOP export to see Recovery, Sleep and Strain.")
                .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline)
                .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
            HStack(spacing: 10) {
                Button("Import WHOOP Export", action: onImport)
                    .buttonStyle(.borderedProminent)
                Button("Pair Strap", action: onPair)
                    .buttonStyle(.bordered)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("No Data Yet")
    }
}

struct HomeLoadingSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(spacing: 8) {
                        Circle()
                            .fill(NativeTokens.card)
                            .frame(width: 96, height: 96)
                        Text("Score")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
            Grid(horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow {
                    skeletonCard
                    skeletonCard
                }
            }
        }
        .redacted(reason: .placeholder)
        .nativeShimmer()
        .accessibilityLabel("Loading")
    }

    private var skeletonCard: some View {
        NativeChrome.panel {
            Text("Monitor")
                .font(.footnote.weight(.semibold))
            Text("88")
                .font(StrandFont.rounded(22, weight: .bold))
            Text("Typical")
                .font(.footnote)
        }
        .frame(minHeight: 140, alignment: .top)
    }
}

struct HomeTonightSleepCard: View {
    var model: NativeTonightSleep.Model
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: "Tonight's Sleep",
                symbol: "moon.fill",
                tint: NativePaint.sleep(style)
            )
            HStack(alignment: .top, spacing: 16) {
                if let bedtime = model.bedtimeClock {
                    clockBlock(caption: "Bedtime", value: bedtime)
                }
                if let wake = model.wakeClock {
                    clockBlock(caption: "Wake", value: wake)
                }
                Spacer(minLength: 0)
            }
            if let need = model.needClock {
                Text("Sleep need \(need)")
                    .font(style == .whoop ? NativeTokens.whoopNumber(13, weight: .regular) : .subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    private func clockBlock(caption: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(style == .whoop ? caption.uppercased() : caption)
                .font(style == .whoop ? NativeTokens.whoopCaps(11) : .caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(style == .whoop ? NativeTokens.whoopNumber(22, weight: .bold) : StrandFont.rounded(22, weight: .bold))
                .monospacedDigit()
        }
    }

    private var accessibility: String {
        var parts = ["Tonight's Sleep"]
        if let bedtime = model.bedtimeClock { parts.append("Bedtime \(bedtime)") }
        if let wake = model.wakeClock { parts.append("Wake \(wake)") }
        if let need = model.needClock { parts.append("Sleep need \(need)") }
        return parts.joined(separator: ", ")
    }
}

struct HomeVO2Card: View {
    var value: Double
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            NativeContributorRow(
                symbol: "lungs.fill",
                title: "VO₂ Max",
                value: String(format: "%.1f", value),
                tint: NativePaint.heart(style)
            )
        }
        .accessibilityLabel("VO2 Max, \(String(format: "%.1f", value))")
    }
}

#if DEBUG
enum HomeSnapshot {
    struct Section: Identifiable {
        var id: String { name }
        var name: String
        var padded: Bool = true
        var view: AnyView
    }

    static let weekKeys = NativeGallerySnapshot.weekKeys
    static let highlightKey = NativeGallerySnapshot.highlightKey
    static let dayStart = Date(timeIntervalSince1970: 1_763_164_800)

    static var sleepScore: NativeScore { NativeGallerySnapshot.sleepScore }
    static var recoveryScore: NativeScore { NativeGallerySnapshot.recoveryScore }

    static var strainScore: NativeScore {
        NativeScore(
            name: "Strain",
            value: "7.1",
            known: true,
            fraction: 7.1 / 21.0,
            tint: NativeTokens.strain,
            rows: [],
            insight: "",
            route: .metric("strain")
        )
    }

    static var activities: [HomeActivityItem] {
        [
            HomeActivityItem(
                id: "sleep",
                symbol: "moon.fill",
                kind: .sleep,
                title: "Sleep",
                startClock: "12:37 AM",
                endClock: "8:00 AM",
                trailing: "6:35",
                startTs: nil
            ),
            HomeActivityItem(
                id: "run",
                symbol: "figure.run",
                kind: .strain,
                title: "Running",
                startClock: "8:27 AM",
                endClock: "8:55 AM",
                trailing: "13.6",
                startTs: 1
            ),
        ]
    }

    static var journalDots: [HomeJournalDot] {
        zip(weekKeys, [true, true, false, true, true, true, false]).map {
            HomeJournalDot(key: $0.0, filled: $0.1)
        }
    }

    static var stressHours: [NativeHourPoint] {
        stride(from: 0, through: 18 * 60, by: 15).map { minute in
            let t = Double(minute)
            let wave = 0.75 + 0.5 * sin(t / 170)
            let bout = 0.65 * exp(-pow((t - 820) / 85, 2))
            return NativeHourPoint(
                time: dayStart.addingTimeInterval(t * 60),
                value: min(3, max(0.15, wave + bout))
            )
        }
    }

    static var hrvMetric: HomeMetricItem {
        HomeMetricItem(
            title: "Heart Rate Variability",
            value: "66",
            unit: "ms",
            prior: "60 ms",
            delta: .up,
            symbol: "waveform.path.ecg",
            tint: NativeChrome.heart,
            points: NativeGallerySnapshot.hrvLine,
            bars: false,
            route: .metric("hrv")
        )
    }

    static var stepsMetric: HomeMetricItem {
        HomeMetricItem(
            title: "Steps",
            value: "6,545",
            unit: "steps",
            prior: nil,
            delta: .none,
            symbol: "figure.walk",
            tint: NativeChrome.activity,
            points: NativeGallerySnapshot.points([4120, 8800, 6545, nil, 10210, 7340, 1147]),
            bars: true,
            route: .metric("steps")
        )
    }

    static var homePage: some View {
        NativeChrome.stack {
            HomeRingsRow(
                sleep: sleepScore, recovery: recoveryScore, strain: strainScore, onOpen: { _ in }
            )
            HomeMonitorPair(
                hrv: HomeMonitorValue(value: "66", unit: "ms", typical: "60"),
                rhr: HomeMonitorValue(value: "51", unit: "BPM", typical: "52"),
                stressLevel: 1.2,
                stressHours: stressHours,
                onHealth: {},
                onStress: {}
            )
            NativeChrome.section("My Day")
            HomeActivitiesCard(items: activities, onSleep: {}, onActivity: { _ in })
            HomeJournalCard(dots: journalDots, onOpen: {})
            HomeWeekCard(
                recovery: NativeGallerySnapshot.recoveryBars,
                strain: NativeGallerySnapshot.strainBars,
                highlightKey: highlightKey
            )
            HomeMetricCard(item: hrvMetric, highlightKey: highlightKey)
            HomeMetricCard(item: stepsMetric, highlightKey: highlightKey)
        }
    }

    static var journalAnswers: [HomeJournalAnswer] {
        [
            HomeJournalAnswer(question: "Ate food close to bedtime?", value: "No"),
            HomeJournalAnswer(question: "Consumed caffeine?", value: "Yes"),
            HomeJournalAnswer(question: "Felt stressed?", value: "No"),
        ]
    }

    static var emptyPage: some View {
        NativeChrome.stack {
            NativeNoDataCard(onImport: {}, onPair: {})
        }
    }

    static var loadingPage: some View {
        NativeChrome.stack {
            HomeLoadingSkeleton()
        }
    }

    static var sections: [Section] {
        [
            Section(name: "page", padded: false, view: AnyView(homePage)),
            Section(name: "empty", padded: false, view: AnyView(emptyPage)),
            Section(name: "loading", padded: false, view: AnyView(loadingPage)),
            Section(name: "rings", view: AnyView(HomeRingsRow(
                sleep: sleepScore, recovery: recoveryScore, strain: strainScore, onOpen: { _ in }
            ))),
            Section(name: "myday", view: AnyView(VStack(spacing: 10) {
                HomeMonitorPair(
                    hrv: HomeMonitorValue(value: "66", unit: "ms", typical: "60"),
                    rhr: HomeMonitorValue(value: "51", unit: "BPM", typical: "52"),
                    stressLevel: 1.2,
                    stressHours: stressHours,
                    onHealth: {},
                    onStress: {}
                )
                HomeActivitiesCard(items: activities, onSleep: {}, onActivity: { _ in })
                HomeJournalCard(dots: journalDots, onOpen: {})
            })),
            Section(name: "monitors", view: AnyView(HomeMonitorPair(
                hrv: HomeMonitorValue(value: "66", unit: "ms", typical: "60"),
                rhr: HomeMonitorValue(value: "51", unit: "BPM", typical: "52"),
                stressLevel: 1.2,
                stressHours: stressHours,
                onHealth: {},
                onStress: {}
            ))),
            Section(name: "activities", view: AnyView(HomeActivitiesCard(
                items: activities, onSleep: {}, onActivity: { _ in }
            ))),
            Section(name: "journal", view: AnyView(HomeJournalCard(dots: journalDots, onOpen: {}))),
            Section(name: "week", view: AnyView(HomeWeekCard(
                recovery: NativeGallerySnapshot.recoveryBars,
                strain: NativeGallerySnapshot.strainBars,
                highlightKey: highlightKey
            ))),
            Section(name: "metrics", view: AnyView(VStack(spacing: 10) {
                HomeMetricCard(item: hrvMetric, highlightKey: highlightKey)
                HomeMetricCard(item: stepsMetric, highlightKey: highlightKey)
            })),
            Section(name: "stress", view: AnyView(HomeStressBody(
                level: 1.2,
                date: "Thu, Nov 12",
                hours: stressHours,
                sleepStart: dayStart.addingTimeInterval(37 * 60),
                sleepEnd: dayStart.addingTimeInterval(8 * 3600),
                workouts: [(start: dayStart.addingTimeInterval(8.45 * 3600), end: dayStart.addingTimeInterval(8.92 * 3600))],
                dayStart: dayStart,
                now: dayStart.addingTimeInterval(16 * 3600),
                scrubValue: .constant(1.2),
                scrubTime: .constant(nil)
            ))),
            Section(name: "stress-empty", view: AnyView(HomeStressBody(
                level: nil,
                date: "Thu, Nov 12",
                hours: [],
                sleepStart: nil,
                sleepEnd: nil,
                workouts: [],
                dayStart: dayStart,
                now: dayStart.addingTimeInterval(16 * 3600),
                scrubValue: .constant(0),
                scrubTime: .constant(nil)
            ))),
            Section(name: "journal-list", view: AnyView(HomeJournalList(
                answers: journalAnswers,
                notes: "Late dinner after the run."
            ))),
            Section(name: "journal-empty", view: AnyView(HomeJournalList(answers: [], notes: nil))),
        ]
    }
}
#endif

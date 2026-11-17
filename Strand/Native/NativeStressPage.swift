import SwiftUI
import WhoopStore
import StrandDesign
import StrandAnalytics

/// Stress Monitor. D/W/M/6M like Apple Health. Small gauge. No Sessions.
struct NativeStressPage: View {
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""
    @State private var repoHandle: Repository?
    @State private var refreshSeq = 0
    @State private var handlesReady = false

    private var selectedDay: Date {
        get { NativeDaySelection.date(from: selectedDayKey) }
        nonmutating set { selectedDayKey = NativeDaySelection.key(from: newValue) }
    }

    @State private var scope: NativeMetricScope = .day
    @State private var workouts: [WorkoutRow] = []
    @State private var scrubValue: Double = 0
    @State private var scrubTime: Date?
    @State private var sampleHours: [NativeHourPoint] = []
    @State private var series: NativeScopeSeries = .empty
    @State private var timeInHighMinutes: Double?
    @State private var level: Double?
    @State private var sleepStart: Date?
    @State private var sleepEnd: Date?
    @State private var bouts: [(start: Date, end: Date)] = []
    @State private var todayDurations = NativeStressBandDurations.zero
    @State private var typicalDurations: NativeStressBandDurations?
    @State private var typicalSameWeekday = false

    private var dayKey: String { NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }

    private var taskID: String {
        handlesReady ? "\(scope.rawValue)|\(dayKey)|\(refreshSeq)" : "boot"
    }

    var body: some View {
        let dayStart = Calendar.current.startOfDay(for: selectedDay)
        let now = min(
            Date(),
            Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? Date()
        )
        NativeStressChartPage(
            scope: scope,
            onScope: { scope = $0 },
            series: series,
            hours: sampleHours,
            level: level,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            workouts: bouts,
            dayStart: dayStart,
            now: now,
            scrubValue: $scrubValue,
            scrubTime: $scrubTime,
            timeInHighMinutes: timeInHighMinutes,
            highlightKey: dayKey,
            todayDurations: todayDurations,
            typicalDurations: typicalDurations,
            typicalSameWeekday: typicalSameWeekday
        )
        .navigationTitle("Stress Monitor")
        .modifier(NativeInlineTitle())
        .nativeDateSubtitle(selectedDay)
        .background {
            NativeRepoSink(refreshSeq: $refreshSeq, ready: $handlesReady) { repoHandle = $0 }
        }
        .task(id: taskID) {
            guard handlesReady else { return }
            await reload()
        }
    }

    private func reload() async {
        guard let repo = repoHandle else { return }
        let key = dayKey
        let nextWorkouts = await repo.workoutRows(days: 28)
        if Task.isCancelled { return }
        let calendar = Calendar.current
        let ending = NativeScopeSeries.date(from: key, calendar: calendar) ?? selectedDay
        let start = calendar.startOfDay(for: ending)
        let from = Int(start.timeIntervalSince1970)
        let buckets = await repo.hrSamples(from: from, to: from + 86_400, bucketSeconds: 300)
        if Task.isCancelled { return }
        let rr = await repo.rrIntervals(from: from, to: from + 86_400, limit: 50_000)
        if Task.isCancelled { return }
        guard key == dayKey else { return }
        let sleep = repo.sleeps.last {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == key
        }
        let nextSleepStart = sleep.map { Date(timeIntervalSince1970: TimeInterval($0.effectiveStartTs)) }
        let nextSleepEnd = sleep.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) }
        let nextBouts: [(start: Date, end: Date)] = nextWorkouts.compactMap { row in
            let boutStart = Date(timeIntervalSince1970: TimeInterval(row.startTs))
            guard NativeDayLogic.sleepSessionDayKey(boutStart) == key else { return nil }
            return (boutStart, Date(timeIntervalSince1970: TimeInterval(row.endTs)))
        }
        let days = repo.days
        let rrPairs = rr.map { (ts: $0.ts, ms: Double($0.rrMs)) }
        let baselines = NativeHomeCharts.stressBaselines(days: days, todayKey: key)
        let rmssd = await Task.detached(priority: .utility) {
            BandStress.rmssdByBucket(rr: rrPairs)
        }.value
        if Task.isCancelled { return }
        let nextHours = NativeHomeCharts.stressSeries(
            buckets: buckets,
            baselines: baselines,
            sleepStart: nextSleepStart,
            sleepEnd: nextSleepEnd,
            workouts: nextBouts,
            rmssdByBucket: rmssd
        )
        guard key == dayKey else { return }
        let nextLevel = NativeStressResolver.level(hours: nextHours, days: days, todayKey: key)
        let nextHigh = NativeStressHistory.timeInHighMinutes(nextHours)
        let daily = NativeStressHistory.daily(days: days, ending: key)
        let nextSeries = NativeScopeSeries.make(
            points: daily,
            scope: scope,
            kind: .rate,
            calendar: calendar,
            now: ending,
            ending: ending
        )
        workouts = nextWorkouts
        sleepStart = nextSleepStart
        sleepEnd = nextSleepEnd
        bouts = nextBouts
        sampleHours = nextHours
        level = nextLevel
        if let latest = nextLevel {
            scrubValue = latest
        }
        scrubTime = nil
        timeInHighMinutes = nextHigh
        series = nextSeries
        let nextToday = NativeStressBandTime.durations(nextHours)
        todayDurations = nextToday
        let history = await NativeStressBandTime.loadHistory(
            repo: repo,
            calendar: calendar,
            ending: start,
            days: days,
            workouts: nextWorkouts,
            todayKey: key
        )
        if Task.isCancelled { return }
        guard key == dayKey else { return }
        let weekday = calendar.component(.weekday, from: start)
        if let typical = NativeStressBandTime.typical(daily: history, todayWeekday: weekday) {
            typicalDurations = typical.durations
            typicalSameWeekday = typical.sameWeekday
        } else {
            typicalDurations = nil
            typicalSameWeekday = false
        }
    }
}

/// Presentational stress page for the live screen and snapshots.
struct NativeStressChartPage: View {
    var scope: NativeMetricScope
    var onScope: (NativeMetricScope) -> Void
    var series: NativeScopeSeries
    var hours: [NativeHourPoint]
    var level: Double?
    var sleepStart: Date?
    var sleepEnd: Date?
    var workouts: [(start: Date, end: Date)]
    var dayStart: Date
    var now: Date
    @Binding var scrubValue: Double
    @Binding var scrubTime: Date?
    var timeInHighMinutes: Double?
    var highlightKey: String
    var previewSelected: String? = nil
    var previewTime: Date? = nil
    var todayDurations: NativeStressBandDurations = .zero
    var typicalDurations: NativeStressBandDurations? = nil
    var typicalSameWeekday: Bool = false

    var body: some View {
        NativeChrome.screen {
            Picker("Range", selection: Binding(get: { scope }, set: onScope)) {
                ForEach(NativeMetricScope.pickerCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Time range")

            if scope == .day {
                dayBody
            } else {
                NativeScopeChart(
                    series: series,
                    bars: true,
                    tint: NativeTokens.stressHigh,
                    format: { String(format: "%.1f", $0) },
                    highlightKey: highlightKey,
                    higherIsBetter: NativeMetricDirection.higherIsBetter("stress"),
                    previewSelected: previewSelected,
                    accessibilityName: "Stress",
                    color: { NativeChrome.stressBandColor($0) },
                    title: "Stress"
                )
            }
        }
    }

    @ViewBuilder private var dayBody: some View {
        NativeHeroValue(
            caption: NativeStressHero.caption(scrubbing: scrubTime != nil),
            value: shownLevel.map { String(format: "%.1f", $0) } ?? "No Data",
            date: scrubTime.map { NativeScopeFormat.time($0) } ?? NativeScopeFormat.weekdayDate(dayStart, calendar: .current)
        )
        .frame(height: 76, alignment: .topLeading)

        NativeStressGauge(value: shownLevel, lastUpdated: gaugeCaption)
            .frame(width: 152, height: 96)
            .frame(maxWidth: .infinity)

        NativeChrome.panel {
            NativeStressDayChart(
                level: shownLevel,
                hours: hours,
                sleepStart: sleepStart,
                sleepEnd: sleepEnd,
                workouts: workouts,
                dayStart: dayStart,
                now: now,
                height: NativeStressDayChart.heightPage,
                previewSelected: previewTime,
                scrubValue: $scrubValue,
                scrubTime: $scrubTime
            )
        }

        if todayDurations.total > 0 {
            NativeStressDayBreakdown(
                date: dayStart,
                today: todayDurations,
                typical: typicalDurations,
                typicalSameWeekday: typicalSameWeekday
            )
        }
    }

    private var shownLevel: Double? {
        scrubTime == nil ? level : scrubValue
    }

    private var gaugeCaption: String {
        if let time = scrubTime ?? hours.last?.time {
            return NativeScopeFormat.time(time)
        }
        return NativeScopeFormat.weekdayDate(dayStart, calendar: .current)
    }
}

enum NativeStressHero {
    /// Idle hero is AVERAGE; a held point is STRESS (Apple Health uppercases the caption).
    static func caption(scrubbing: Bool) -> String {
        scrubbing ? "Stress" : "Average"
    }
}

/// One number for Home and the Stress page. Last sample, else the daily HRV/RHR score, else nil.
enum NativeStressResolver {
    static func level(hours: [NativeHourPoint], days: [DailyMetric], todayKey: String) -> Double? {
        NativeHomeCharts.stressLevel(hours: hours, days: days, todayKey: todayKey)
    }
}

/// Same 0–3 day chart Home and the Stress page draw. Empty series keeps the axes and says "No Data".
struct NativeStressDayChart: View {
    var level: Double?
    var hours: [NativeHourPoint]
    var sleepStart: Date?
    var sleepEnd: Date?
    var workouts: [(start: Date, end: Date)]
    var dayStart: Date
    var now: Date
    var height: CGFloat
    var previewSelected: Date? = nil
    @Binding var scrubValue: Double
    @Binding var scrubTime: Date?

    static let heightPage: CGFloat = 260
    static let heightHome: CGFloat = 168

    var body: some View {
        ZStack {
            NativeStressMonitor(
                score: level ?? hours.last?.value ?? 0,
                sleepStart: sleepStart,
                sleepEnd: sleepEnd,
                workouts: workouts,
                dayStart: dayStart,
                now: now,
                sampleHours: hours,
                previewSelected: previewSelected,
                scrubValue: $scrubValue,
                scrubTime: $scrubTime
            )
            if hours.isEmpty {
                Text("No Data")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }
}

enum NativeStressHistory {
    static func daily(days: [DailyMetric], ending: String) -> [NativeDayPoint] {
        let ordered = days.filter { $0.day <= ending }
        return ordered.compactMap { day in
            let prior = Array(ordered.filter { $0.day < day.day }.suffix(30))
            let meanRHR = StressMath.mean(prior.compactMap { $0.restingHr }.map(Double.init))
            let sdRHR = StressMath.std(prior.compactMap { $0.restingHr }.map(Double.init), mean: meanRHR)
            let meanHRV = StressMath.mean(prior.compactMap(\.avgHrv))
            let sdHRV = StressMath.std(prior.compactMap(\.avgHrv), mean: meanHRV)
            guard day.restingHr != nil || day.avgHrv != nil else { return nil }
            let raw = StressMath.rawScore(
                rhrToday: day.restingHr.map(Double.init), meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: day.avgHrv, meanHRV: meanHRV, sdHRV: sdHRV
            )
            return NativeDayPoint(key: day.day, value: StressMath.squash(raw))
        }
    }

    /// Duration in the High band (≥ 2.0). Each high point contributes only the gap to the next
    /// point when that gap is one chart bucket (5 min ± slack). A hole in stored HR is not High.
    static let highBucketMaxGap: TimeInterval = 6 * 60

    static func timeInHighMinutes(_ hours: [NativeHourPoint]) -> Double? {
        guard hours.count >= 2 else { return nil }
        var total: TimeInterval = 0
        for index in 0..<(hours.count - 1) where hours[index].value >= 2 {
            let dt = hours[index + 1].time.timeIntervalSince(hours[index].time)
            guard dt > 0, dt <= highBucketMaxGap else { continue }
            total += dt
        }
        let minutes = total / 60
        return minutes > 0 ? minutes : nil
    }
}

struct NativeStressBandDurations: Equatable {
    var low: TimeInterval
    var mid: TimeInterval
    var high: TimeInterval

    var total: TimeInterval { low + mid + high }

    static let zero = NativeStressBandDurations(low: 0, mid: 0, high: 0)

    func fraction(_ keyPath: KeyPath<NativeStressBandDurations, TimeInterval>) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(self[keyPath: keyPath] / total)
    }
}

enum NativeStressBandTime {
    static let historyDays = 28

    enum Band: Equatable {
        case low, mid, high
    }

    static func band(_ value: Double) -> Band {
        if value < 1 { return .low }
        if value < 2 { return .mid }
        return .high
    }

    static func durations(_ hours: [NativeHourPoint]) -> NativeStressBandDurations {
        guard hours.count >= 2 else { return .zero }
        var low: TimeInterval = 0
        var mid: TimeInterval = 0
        var high: TimeInterval = 0
        for index in 0..<(hours.count - 1) {
            let dt = hours[index + 1].time.timeIntervalSince(hours[index].time)
            guard dt > 0, dt <= NativeStressHistory.highBucketMaxGap else { continue }
            switch band(hours[index].value) {
            case .low: low += dt
            case .mid: mid += dt
            case .high: high += dt
            }
        }
        return NativeStressBandDurations(low: low, mid: mid, high: high)
    }

    static func mean(_ samples: [NativeStressBandDurations]) -> NativeStressBandDurations? {
        guard !samples.isEmpty else { return nil }
        let n = Double(samples.count)
        return NativeStressBandDurations(
            low: samples.reduce(0) { $0 + $1.low } / n,
            mid: samples.reduce(0) { $0 + $1.mid } / n,
            high: samples.reduce(0) { $0 + $1.high } / n
        )
    }

    /// Same weekday when at least two prior days exist; otherwise the last 7 days.
    static func typical(
        daily: [(weekday: Int, durations: NativeStressBandDurations)],
        todayWeekday: Int
    ) -> (durations: NativeStressBandDurations, sameWeekday: Bool)? {
        let same = daily.filter { $0.weekday == todayWeekday }.map(\.durations)
        if same.count >= 2, let mean = mean(same) {
            return (mean, true)
        }
        let last7 = Array(daily.suffix(7)).map(\.durations)
        if let mean = mean(last7) {
            return (mean, false)
        }
        return nil
    }

    static func deltaPercent(current: TimeInterval, typical: TimeInterval) -> Double? {
        guard typical > 30 else { return nil }
        return (current - typical) / typical
    }

    static func clock(_ seconds: TimeInterval) -> String {
        NativeScoreMath.duration(seconds / 60)
    }

    static func weekdayName(_ date: Date, calendar: Calendar) -> String {
        alignedWeekday.calendar = calendar
        alignedWeekday.timeZone = calendar.timeZone
        return alignedWeekday.string(from: date)
    }

    static func loadHistory(
        repo: Repository,
        calendar: Calendar,
        ending: Date,
        days: [DailyMetric],
        workouts: [WorkoutRow],
        todayKey: String
    ) async -> [(weekday: Int, durations: NativeStressBandDurations)] {
        let start = calendar.date(byAdding: .day, value: -historyDays, to: ending) ?? ending
        let from = Int(start.timeIntervalSince1970)
        let to = Int(ending.timeIntervalSince1970)
        guard to > from else { return [] }
        let buckets = await repo.hrSamples(from: from, to: to, bucketSeconds: 300)
        guard !buckets.isEmpty else { return [] }
        var byDay: [String: [HRBucket]] = [:]
        for bucket in buckets {
            let date = Date(timeIntervalSince1970: TimeInterval(bucket.ts))
            let key = NativeScopeSeries.key(from: date, calendar: calendar)
            if key == todayKey { continue }
            byDay[key, default: []].append(bucket)
        }
        var sleepByDay: [String: (Date, Date)] = [:]
        let sleeps = await MainActor.run { repo.sleeps }
        for sleep in sleeps {
            let end = Date(timeIntervalSince1970: TimeInterval(sleep.endTs))
            let key = NativeDayLogic.sleepSessionDayKey(end)
            guard key < todayKey else { continue }
            sleepByDay[key] = (
                Date(timeIntervalSince1970: TimeInterval(sleep.effectiveStartTs)),
                end
            )
        }
        var result: [(weekday: Int, durations: NativeStressBandDurations)] = []
        for key in byDay.keys.sorted() {
            guard let dayDate = NativeScopeSeries.date(from: key, calendar: calendar) else { continue }
            let sleep = sleepByDay[key]
            let bouts: [(start: Date, end: Date)] = workouts.compactMap { row in
                let boutStart = Date(timeIntervalSince1970: TimeInterval(row.startTs))
                guard NativeDayLogic.sleepSessionDayKey(boutStart) == key else { return nil }
                return (boutStart, Date(timeIntervalSince1970: TimeInterval(row.endTs)))
            }
            let hours = NativeHomeCharts.stressSeries(
                buckets: byDay[key] ?? [],
                baselines: NativeHomeCharts.stressBaselines(days: days, todayKey: key),
                sleepStart: sleep?.0,
                sleepEnd: sleep?.1,
                workouts: bouts
            )
            let dur = durations(hours)
            guard dur.total > 0 else { continue }
            result.append((calendar.component(.weekday, from: dayDate), dur))
        }
        return result
    }

    private static let alignedWeekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE"
        return formatter
    }()
}

/// WHOOP-style Total day Low / Medium / High vs typical same weekday.
struct NativeStressDayBreakdown: View {
    var date: Date
    var today: NativeStressBandDurations
    var typical: NativeStressBandDurations?
    var typicalSameWeekday: Bool
    var calendar: Calendar = .current

    var body: some View {
        NativeChrome.panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Total day")
                    .font(.headline)
                Text(comparisonCaption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                stackedBar(today, muted: false)
                if let typical {
                    stackedBar(typical, muted: true)
                }
                HStack(alignment: .top, spacing: 12) {
                    bandColumn(
                        title: "Low",
                        seconds: today.low,
                        typical: typical?.low,
                        tint: NativeTokens.stressLow
                    )
                    bandColumn(
                        title: "Medium",
                        seconds: today.mid,
                        typical: typical?.mid,
                        tint: NativeTokens.stressMid
                    )
                    bandColumn(
                        title: "High",
                        seconds: today.high,
                        typical: typical?.high,
                        tint: NativeTokens.stressHigh
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var comparisonCaption: String {
        let todayText = NativeScopeFormat.weekdayDate(date, calendar: calendar)
        if typical == nil {
            return "\(todayText) stress"
        }
        if typicalSameWeekday {
            return "\(todayText) stress vs. typical \(NativeStressBandTime.weekdayName(date, calendar: calendar))"
        }
        return "\(todayText) stress vs. last 7 days"
    }

    private var accessibilityText: String {
        let low = NativeStressBandTime.clock(today.low)
        let mid = NativeStressBandTime.clock(today.mid)
        let high = NativeStressBandTime.clock(today.high)
        return "Total day. Low \(low), Medium \(mid), High \(high). \(comparisonCaption)"
    }

    private func stackedBar(_ durations: NativeStressBandDurations, muted: Bool) -> some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                NativeTokens.stressLow.opacity(muted ? 0.45 : 1)
                    .frame(width: max(0, geo.size.width * durations.fraction(\.low)))
                NativeTokens.stressMid.opacity(muted ? 0.45 : 1)
                    .frame(width: max(0, geo.size.width * durations.fraction(\.mid)))
                NativeTokens.stressHigh.opacity(muted ? 0.45 : 1)
                    .frame(width: max(0, geo.size.width * durations.fraction(\.high)))
            }
        }
        .frame(height: muted ? 6 : 8)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private func bandColumn(
        title: String,
        seconds: TimeInterval,
        typical: TimeInterval?,
        tint: Color
    ) -> some View {
        let percent = typical.flatMap { NativeStressBandTime.deltaPercent(current: seconds, typical: $0) }
        let delta: NativeScore.Delta = {
            guard let percent, abs(percent) > 0.03 else { return .flat }
            return NativeMetricDirection.delta(
                current: seconds,
                previous: typical ?? seconds,
                higherIsBetter: false
            )
        }()
        return VStack(alignment: .leading, spacing: 2) {
            Text(NativeStressBandTime.clock(seconds))
                .font(StrandFont.rounded(22, weight: .semibold))
                .monospacedDigit()
            if let percent, delta != .flat, delta != .none {
                HStack(spacing: 2) {
                    NativeDelta(delta: delta)
                    Text("\(Int((abs(percent) * 100).rounded()))%")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(delta.tint)
                        .monospacedDigit()
                }
            }
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Level hero + 24 h chart. Shared with Home snapshots so the series cannot drift.
struct HomeStressBody: View {
    var level: Double?
    var date: String
    var hours: [NativeHourPoint]
    var sleepStart: Date?
    var sleepEnd: Date?
    var workouts: [(start: Date, end: Date)]
    var dayStart: Date
    var now: Date
    @Binding var scrubValue: Double
    @Binding var scrubTime: Date?

    private var lastUpdated: String {
        if let time = scrubTime ?? hours.last?.time {
            return NativeScopeFormat.time(time)
        }
        return date
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeStressGauge(value: shownLevel, lastUpdated: lastUpdated)
                .frame(width: 152, height: 96)
                .frame(maxWidth: .infinity)

            NativeChrome.panel {
                NativeStressDayChart(
                    level: shownLevel,
                    hours: hours,
                    sleepStart: sleepStart,
                    sleepEnd: sleepEnd,
                    workouts: workouts,
                    dayStart: dayStart,
                    now: now,
                    height: NativeStressDayChart.heightPage,
                    scrubValue: $scrubValue,
                    scrubTime: $scrubTime
                )
            }
        }
    }

    private var shownLevel: Double? {
        scrubTime == nil ? level : scrubValue
    }
}

/// WHOOP-shaped 0–3 semicircle with band colours. Drawn with Apple type.
struct NativeStressGauge: View {
    var value: Double?
    var lastUpdated: String
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                NativeStressArc(progress: 1, color: track)
                if let value {
                    NativeStressArc(progress: min(1, max(0, value / 3)), color: NativePaint.stressBand(value, style: style))
                }
                VStack(spacing: 1) {
                    if let value {
                        Text(String(format: "%.1f", value))
                            .font(NativePaint.number(28, style: style))
                            .monospacedDigit()
                        Text(NativeHomeCharts.stressBandWord(value))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(NativePaint.stressBand(value, style: style))
                    } else {
                        Text("No Data")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(lastUpdated)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .offset(y: 10)
            }
            .frame(height: 80)
            HStack {
                Text("0.0")
                Spacer()
                Text("3.0")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { "Stress \($0), last updated \(lastUpdated)" } ?? "No stress data")
    }

    private var track: Color {
        style == .whoop ? NativeTokens.whoopTrack : NativeTokens.separator.opacity(0.55)
    }
}

private struct NativeStressArc: View {
    var progress: Double
    var color: Color

    var body: some View {
        Canvas { context, size in
            let line: CGFloat = 10
            let rect = CGRect(
                x: line / 2,
                y: line / 2,
                width: size.width - line,
                height: (size.height - line) * 2
            )
            var path = Path()
            path.addArc(
                center: CGPoint(x: rect.midX, y: rect.minY + rect.width / 2),
                radius: rect.width / 2,
                startAngle: .degrees(180),
                endAngle: .degrees(180 + 180 * min(1, max(0, progress))),
                clockwise: false
            )
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: line, lineCap: .round)
            )
        }
    }
}

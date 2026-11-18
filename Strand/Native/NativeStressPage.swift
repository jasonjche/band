import SwiftUI
import Charts
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
    @State private var boutSymbols: [String] = []
    @State private var todayDurations = NativeStressBandDurations.zero
    @State private var typicalDurations: NativeStressBandDurations?
    @State private var typicalSameWeekday = false

    private var dayKey: String { NativeDaySelection.resolvedKey(from: selectedDayKey) }

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
            workoutSymbols: boutSymbols,
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
        guard key == dayKey else { return }
        let sleep = repo.sleeps.last {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == key
        }
        let nextSleepStart = sleep.map { Date(timeIntervalSince1970: TimeInterval($0.effectiveStartTs)) }
        let nextSleepEnd = sleep.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) }
        let nextActivities: [(start: Date, end: Date, symbol: String)] = nextWorkouts.compactMap { row in
            let boutStart = Date(timeIntervalSince1970: TimeInterval(row.startTs))
            guard NativeDayLogic.sleepSessionDayKey(boutStart) == key else { return nil }
            return (
                boutStart,
                Date(timeIntervalSince1970: TimeInterval(row.endTs)),
                NativeDay.symbol(for: row.sport)
            )
        }
        let nextBouts = nextActivities.map { (start: $0.start, end: $0.end) }
        let nextSymbols = nextActivities.map(\.symbol)
        let days = repo.days
        let timeline = await NativeDerivedSeries.stressDay(
            repo: repo, dayKey: key, dayStart: start, days: days,
            sleeps: repo.sleeps, workouts: nextWorkouts, calendar: calendar
        )
        if Task.isCancelled { return }
        let nextHours = timeline.hours
        guard key == dayKey else { return }
        let nextLevel = NativeStressResolver.level(hours: nextHours, days: days, todayKey: key)
        let nextHigh = NativeStressHistory.timeInHighMinutes(nextHours)
        var minuteMeans: [String: Double] = [:]
        if let mean = NativeScopeSeries.mean(nextHours.map(\.value)) {
            minuteMeans[key] = mean
        }
        if scope != .day {
            let others = await NativeStressHistory.minuteMeans(
                repo: repo, days: days, ending: key, scope: scope,
                workouts: nextWorkouts, calendar: calendar
            )
            if Task.isCancelled { return }
            minuteMeans.merge(others) { current, _ in current }
        }
        let daily = NativeStressHistory.daily(days: days, ending: key, minuteMeans: minuteMeans)
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
        boutSymbols = nextSymbols
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
    var workoutSymbols: [String] = []
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
                NativeStressRangeChart(
                    series: series,
                    highlightKey: highlightKey,
                    previewSelected: previewSelected
                )
            }
        }
    }

    @ViewBuilder private var dayBody: some View {
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
                workoutSymbols: workoutSymbols,
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

/// Same 0–3 day chart Home and the Stress page draw. Empty series keeps the axes and says "No data".
struct NativeStressDayChart: View {
    var level: Double?
    var hours: [NativeHourPoint]
    var sleepStart: Date?
    var sleepEnd: Date?
    var workouts: [(start: Date, end: Date)]
    var workoutSymbols: [String] = []
    var dayStart: Date
    var now: Date
    var height: CGFloat
    var previewSelected: Date? = nil
    @Binding var scrubValue: Double
    @Binding var scrubTime: Date?

    static let heightPage: CGFloat = 260
    static let heightHome: CGFloat = 168

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                NativeStressDayPlotHost(
                    score: level ?? hours.last?.value ?? 0,
                    hours: hours,
                    sleepStart: sleepStart,
                    sleepEnd: sleepEnd,
                    workouts: workouts,
                    workoutSymbols: workoutSymbols,
                    dayStart: dayStart,
                    now: now,
                    previewSelected: previewSelected,
                    scrubValue: $scrubValue,
                    scrubTime: $scrubTime
                )
                .equatable()
                if hours.isEmpty {
                    Text("No data")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: height)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Rebuilds the stress plot model only when the series or day window changes.
private struct NativeStressDayPlotHost: View, Equatable {
    var score: Double
    var hours: [NativeHourPoint]
    var sleepStart: Date?
    var sleepEnd: Date?
    var workouts: [(start: Date, end: Date)]
    var workoutSymbols: [String]
    var dayStart: Date
    var now: Date
    var previewSelected: Date?
    @Binding var scrubValue: Double
    @Binding var scrubTime: Date?

    static func == (lhs: NativeStressDayPlotHost, rhs: NativeStressDayPlotHost) -> Bool {
        lhs.score == rhs.score
            && lhs.hours == rhs.hours
            && lhs.sleepStart == rhs.sleepStart
            && lhs.sleepEnd == rhs.sleepEnd
            && lhs.dayStart == rhs.dayStart
            && lhs.now == rhs.now
            && lhs.previewSelected == rhs.previewSelected
            && lhs.workoutSymbols == rhs.workoutSymbols
            && lhs.workouts.count == rhs.workouts.count
            && zip(lhs.workouts, rhs.workouts).allSatisfy {
                $0.start == $1.start && $0.end == $1.end
            }
    }

    var body: some View {
        NativeStressDayPlot(
            model: NativeStressDayPlotModel.make(
                score: score,
                hours: hours,
                sleepStart: sleepStart,
                sleepEnd: sleepEnd,
                workouts: workouts,
                workoutSymbols: workoutSymbols,
                dayStart: dayStart,
                now: now
            ),
            previewSelected: previewSelected,
            scrubValue: $scrubValue,
            scrubTime: $scrubTime
        )
    }
}

struct NativeStressChartHeader: View {
    var level: Double?
    var updated: String?
    @Environment(\.nativeStyle) private var style

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(updated ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .opacity(updated == nil ? 0 : 1)
            Spacer(minLength: 8)
            if let level {
                Text(NativeHomeCharts.stressBand(level))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NativePaint.stressBand(level, style: style))
                Text(String(format: "%.1f", level))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        var parts: [String] = []
        if let updated { parts.append(updated) }
        if let level {
            parts.append(NativeHomeCharts.stressBandWord(level))
            parts.append(String(format: "%.1f", level))
        }
        return parts.joined(separator: ", ")
    }
}

enum NativeStressHistory {
    /// Each day's minute-series stress mean over the scope's look-back window, before `ending`.
    /// The one source for a day's stress value on Stress W/M/6M and on Trends' Total Day Stress, so the
    /// two can never disagree. Days without a minute series fall back to the daily score in `daily`.
    static func minuteMeans(
        repo: Repository,
        days: [DailyMetric],
        ending key: String,
        scope: NativeMetricScope,
        workouts: [WorkoutRow],
        calendar: Calendar
    ) async -> [String: Double] {
        let lookback: Int = {
            switch scope {
            case .day: return 1
            case .week: return 14
            case .month: return 60
            case .sixMonths: return 26 * 7
            case .year: return 365
            }
        }()
        guard let endDate = NativeScopeSeries.date(from: key, calendar: calendar) else { return [:] }
        let start = calendar.startOfDay(for: endDate)
        let oldest = calendar.date(byAdding: .day, value: -lookback, to: start) ?? start
        var out: [String: Double] = [:]
        for day in days where day.day < key {
            guard let dayDate = NativeScopeSeries.date(from: day.day, calendar: calendar),
                  dayDate >= oldest else { continue }
            let built = await NativeDerivedSeries.stressDay(
                repo: repo, dayKey: day.day, dayStart: calendar.startOfDay(for: dayDate),
                days: days, sleeps: repo.sleeps, workouts: workouts, calendar: calendar
            )
            if Task.isCancelled { return out }
            if let mean = NativeScopeSeries.mean(built.hours.map(\.value)) {
                out[day.day] = mean
            }
        }
        return out
    }

    /// One funnel for the Day-view average and that day's W/M/6M bar.
    /// Prefer the mean of `NativeDerivedSeries.stressDay` hours (and its cache).
    /// Fall back to the daily HRV/RHR score only when that day has no minute series;
    /// the Day view uses the same fallback.
    static func dayAverage(hours: [NativeHourPoint], days: [DailyMetric], dayKey: String) -> Double? {
        if let mean = NativeScopeSeries.mean(hours.map(\.value).filter(\.isFinite)) {
            return mean
        }
        return dailyScore(days: days, dayKey: dayKey)
    }

    static func dailyScore(days: [DailyMetric], dayKey: String) -> Double? {
        let ordered = days.filter { $0.day <= dayKey }
        guard let day = ordered.last(where: { $0.day == dayKey }) else { return nil }
        return dailyScore(day: day, prior: Array(ordered.filter { $0.day < dayKey }.suffix(30)))
    }

    static func dailyScore(day: DailyMetric, prior: [DailyMetric]) -> Double? {
        let meanRHR = StressMath.mean(prior.compactMap { $0.restingHr }.map(Double.init))
        let sdRHR = StressMath.std(prior.compactMap { $0.restingHr }.map(Double.init), mean: meanRHR)
        let meanHRV = StressMath.mean(prior.compactMap(\.avgHrv))
        let sdHRV = StressMath.std(prior.compactMap(\.avgHrv), mean: meanHRV)
        guard day.restingHr != nil || day.avgHrv != nil else { return nil }
        let raw = StressMath.rawScore(
            rhrToday: day.restingHr.map(Double.init), meanRHR: meanRHR, sdRHR: sdRHR,
            hrvToday: day.avgHrv, meanHRV: meanHRV, sdHRV: sdHRV
        )
        return StressMath.squash(raw)
    }

    static func daily(
        days: [DailyMetric],
        ending: String,
        minuteMeans: [String: Double] = [:]
    ) -> [NativeDayPoint] {
        let ordered = days.filter { $0.day <= ending }
        return ordered.compactMap { day in
            if let mean = minuteMeans[day.day] {
                return NativeDayPoint(key: day.day, value: mean)
            }
            let prior = Array(ordered.filter { $0.day < day.day }.suffix(30))
            return dailyScore(day: day, prior: prior).map { NativeDayPoint(key: day.day, value: $0) }
        }
    }

    /// Duration in the High band (≥ 2.0). Each high point contributes only the gap to the next
    /// point when that gap is one chart bucket (1 min ± slack). A hole in stored HR is not High.
    static let highBucketMaxGap: TimeInterval = TimeInterval(BandStress.chartGapSeconds)

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
        let sleeps = await MainActor.run { repo.sleeps }
        var result: [(weekday: Int, durations: NativeStressBandDurations)] = []
        var missing: [String] = []
        var cursor = start
        while cursor < ending {
            let key = NativeScopeSeries.key(from: cursor, calendar: calendar)
            if key != todayKey {
                missing.append(key)
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? ending
        }
        for key in missing {
            guard let dayDate = NativeScopeSeries.date(from: key, calendar: calendar) else { continue }
            let dayStart = calendar.startOfDay(for: dayDate)
            let built = await NativeDerivedSeries.stressDay(
                repo: repo, dayKey: key, dayStart: dayStart, days: days,
                sleeps: sleeps, workouts: workouts, calendar: calendar
            )
            let dur = durations(built.hours)
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
                ViewThatFits(in: .horizontal) {
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
                    VStack(alignment: .leading, spacing: 10) {
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
                        }
                        bandColumn(
                            title: "High",
                            seconds: today.high,
                            typical: typical?.high,
                            tint: NativeTokens.stressHigh
                        )
                    }
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
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .allowsTightening(true)
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
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        Text(NativeHomeCharts.stressBandWord(value))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(NativePaint.stressBand(value, style: style))
                    } else {
                        Text("No data")
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

// MARK: - Week / month bars (0–3, band colours, gaps stay gaps)

/// W / M / 6M stress: fixed 0–3 axis, per-bucket bars, average in the hero.
struct NativeStressRangeChart: View {
    var series: NativeScopeSeries
    var highlightKey: String
    var previewSelected: String? = nil
    var calendar: Calendar = .current

    @State private var scrub = NativeScopeScrub()

    private var window: [NativeScopeBucket] { series.latestWindow() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeStressRangeHero(
                series: series,
                window: window,
                scrub: scrub,
                calendar: calendar
            )
            NativeChrome.panel {
                NativeStressRangePlot(
                    series: series,
                    window: window,
                    highlightKey: highlightKey,
                    calendar: calendar,
                    scrub: scrub
                )
                .frame(height: NativeStressDayChart.heightPage)
            }
        }
        .onAppear {
            if scrub.key == nil { scrub.key = previewSelected }
        }
        .onChangeCompat(of: series.scope) { _ in
            scrub.key = nil
            scrub.time = nil
        }
        .onChangeCompat(of: highlightKey) { _ in
            scrub.key = nil
            scrub.time = nil
        }
    }
}

private struct NativeStressRangeHero: View {
    var series: NativeScopeSeries
    var window: [NativeScopeBucket]
    @ObservedObject var scrub: NativeScopeScrub
    var calendar: Calendar
    @Environment(\.nativeStyle) private var style

    private var selected: NativeScopeBucket? {
        guard let key = scrub.key else { return nil }
        return window.first { $0.key == key && $0.value != nil }
            ?? series.buckets.first { $0.key == key && $0.value != nil }
    }

    var body: some View {
        NativeHeroValue(
            caption: NativeStressHero.caption(scrubbing: selected != nil),
            value: valueText,
            date: dateText,
            valueTint: selected.flatMap(\.value).map { NativePaint.stressBand($0, style: style) } ?? .primary
        )
        .frame(height: 76, alignment: .topLeading)
        .modifier(NativeSelectionFeedback(trigger: scrub.key ?? ""))
    }

    private var valueText: String {
        if let value = selected?.value {
            return String(format: "%.1f", value)
        }
        if let average = series.aggregate(of: window) {
            return String(format: "%.1f", average)
        }
        return "No data"
    }

    private var dateText: String? {
        if let selected {
            return series.selectionDateText(for: selected, calendar: calendar)
        }
        return series.heroDateText(of: window, calendar: calendar)
    }
}

private struct NativeStressRangePlot: View {
    var series: NativeScopeSeries
    var window: [NativeScopeBucket]
    var highlightKey: String
    var calendar: Calendar
    @ObservedObject var scrub: NativeScopeScrub
    @Environment(\.nativeStyle) private var style

    private var barUnit: Calendar.Component { NativeScopePlotMath.barUnit(scope: series.scope) }

    private var xDomain: ClosedRange<Date> {
        NativeScopePlotMath.paddedXDomain(buckets: window, bars: true)
    }

    private var columnKey: String { scrub.key ?? highlightKey }

    private var timeBinding: Binding<Date?> {
        Binding(
            get: { scrub.time },
            set: { time in
                if let snapped = NativeChartScrubMath.snapBucket(date: time, buckets: window, bars: true) {
                    scrub.time = snapped.time
                    scrub.key = snapped.key
                } else {
                    scrub.time = nil
                    scrub.key = nil
                }
            }
        )
    }

    private var dayHighlight: Color {
        style == .whoop ? NativeTokens.whoopHighlight : NativeTokens.highlight
    }

    var body: some View {
        Chart {
            if window.allSatisfy({ $0.value == nil }) {
                BarMark(
                    x: .value("Day", xDomain.lowerBound, unit: barUnit),
                    y: .value("Stress", 0)
                )
                .foregroundStyle(NativePaint.separator(style).opacity(0.001))
                .accessibilityHidden(true)
            }
            if let highlighted = window.first(where: { $0.key == columnKey }) {
                RectangleMark(
                    xStart: .value("Highlight start", highlighted.start),
                    xEnd: .value("Highlight end", highlighted.end),
                    yStart: .value("Low", 0),
                    yEnd: .value("High", 3)
                )
                .foregroundStyle(dayHighlight)
                .accessibilityHidden(true)
            }
            ForEach(window.filter { $0.start >= xDomain.lowerBound && $0.start <= xDomain.upperBound }) { bucket in
                if let value = bucket.value {
                    BarMark(
                        x: .value("Day", bucket.start, unit: barUnit),
                        y: .value("Stress", value),
                        width: .ratio(0.58)
                    )
                    .foregroundStyle(NativePaint.stressBand(value, style: style))
                    .cornerRadius(4)
                    .opacity(NativeChartScrubMath.barOpacity(
                        isSelected: bucket.key == scrub.key,
                        hasSelection: scrub.key != nil
                    ))
                    .accessibilityLabel(series.selectionDateText(for: bucket, calendar: calendar))
                    .accessibilityValue(String(format: "%.1f", value))
                }
            }
        }
        .chartYScale(domain: 0...3)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .trailing, values: [0.0, 1.0, 2.0, 3.0]) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativePaint.separator(style))
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(NativeStressMonitorMath.yLabel(raw))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: labelDates) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(date))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        }
        .nativeClippedChartPlot()
        .modifier(NativeTimeSelect(
            selected: timeBinding,
            snap: { NativeChartScrubMath.snapBucket(date: $0, buckets: window, bars: true)?.time },
            onChange: { _ in }
        ))
        .accessibilityLabel("Stress")
    }

    private var labelDates: [Date] {
        switch series.scope {
        case .day, .week:
            return window.map(\.start)
        case .month:
            return window.map(\.start).filter {
                calendar.component(.weekday, from: $0) == calendar.firstWeekday
            }
        case .sixMonths, .year:
            var seen = Set<Int>()
            return window.map(\.start).filter { date in
                let month = calendar.component(.month, from: date)
                    + calendar.component(.year, from: date) * 12
                return seen.insert(month).inserted
            }
        }
    }

    private func axisLabel(_ date: Date) -> String {
        switch series.scope {
        case .day, .week:
            return NativeChartDay.weekday(NativeScopeSeries.key(from: date, calendar: calendar))
        case .month:
            return NativeScopeFormat.monthDay(date, calendar: calendar)
        case .sixMonths, .year:
            return NativeScopeFormat.month(date, calendar: calendar)
        }
    }
}

// MARK: - Day plot (full-height activity columns + plot-frame icons)

struct NativeStressDayPlotModel: Equatable {
    struct Activity: Equatable {
        var start: Date
        var end: Date
        var symbol: String
    }

    struct VisibleSpan: Equatable {
        var start: Date
        var end: Date
    }

    var score: Double
    var hours: [NativeHourPoint]
    var hourSegments: [[NativeHourPoint]]
    var dayStart: Date
    var now: Date
    var plotEnd: Date
    var xDomain: ClosedRange<Date>
    var showsNow: Bool
    var sleepVisible: VisibleSpan?
    var workoutVisible: [VisibleSpan]
    var activities: [Activity]
    var laneItems: [NativeStressLaneIcon.Item]
    var hourLabels: [Date]
    var hourLabelText: [TimeInterval: String]
    var pointTimeText: [TimeInterval: String]
    var maxGap: TimeInterval?

    static func make(
        score: Double,
        hours sampleHours: [NativeHourPoint],
        sleepStart: Date?,
        sleepEnd: Date?,
        workouts: [(start: Date, end: Date)],
        workoutSymbols: [String],
        dayStart: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> NativeStressDayPlotModel {
        let plotEnd = NativeStressMonitorMath.plotEnd(dayStart: dayStart, now: now)
        let hours = NativeScopePlotMath.clippedHours(sampleHours, start: dayStart, end: plotEnd)
        let hourSegments = NativeStressMonitorMath.segments(hours).map { NativeStressMonitorMath.drawPoints($0) }
        let activities = NativeStressMonitorMath.activities(workouts: workouts, symbols: workoutSymbols)
        var laneItems: [NativeStressLaneIcon.Item] = []
        if let sleepStart, let sleepEnd, sleepEnd > sleepStart {
            laneItems.append(
                NativeStressLaneIcon.Item(
                    id: "sleep",
                    start: sleepStart,
                    end: sleepEnd,
                    symbol: "moon.fill",
                    kind: .sleep
                )
            )
        }
        for (index, bout) in activities.enumerated() {
            laneItems.append(
                NativeStressLaneIcon.Item(
                    id: "activity-\(index)",
                    start: bout.start,
                    end: bout.end,
                    symbol: bout.symbol,
                    kind: .workout
                )
            )
        }
        let sleepVisible = sleepStart.flatMap { start in
            sleepEnd.flatMap { end in
                NativeStressLaneIcon.clip(start, end, plotStart: dayStart, plotEnd: plotEnd)
                    .map { VisibleSpan(start: $0.start, end: $0.end) }
            }
        }
        let workoutVisible: [VisibleSpan] = activities.compactMap { bout in
            NativeStressLaneIcon.clip(bout.start, bout.end, plotStart: dayStart, plotEnd: plotEnd)
                .map { VisibleSpan(start: $0.start, end: $0.end) }
        }
        let hourLabels = NativeCountTicks.roundHourLabels(dayStart: dayStart, plotEnd: plotEnd, calendar: calendar)
        var hourLabelText: [TimeInterval: String] = [:]
        for date in hourLabels {
            hourLabelText[date.timeIntervalSince1970] = NativeScopeFormat.hourClock(date, calendar: calendar)
        }
        var pointTimeText: [TimeInterval: String] = [:]
        for segment in hourSegments {
            for point in segment {
                pointTimeText[point.time.timeIntervalSince1970] = NativeScopeFormat.time(point.time, calendar: calendar)
            }
        }
        return NativeStressDayPlotModel(
            score: score,
            hours: hours,
            hourSegments: hourSegments,
            dayStart: dayStart,
            now: now,
            plotEnd: plotEnd,
            xDomain: NativeScopePlotMath.paddedXDomain(start: dayStart, end: plotEnd),
            showsNow: NativeStressMonitorMath.showsNow(dayStart: dayStart, now: now),
            sleepVisible: sleepVisible,
            workoutVisible: workoutVisible,
            activities: activities.map { Activity(start: $0.start, end: $0.end, symbol: $0.symbol) },
            laneItems: laneItems,
            hourLabels: hourLabels,
            hourLabelText: hourLabelText,
            pointTimeText: pointTimeText,
            maxGap: NativeChartScrubMath.inferredMaxGap(in: hours)
        )
    }
}

/// 0–3 day plot. Sleep/workout columns fill the plot; icons sit on the pixel
/// midpoint of each visible span so they cannot drift from the highlight.
struct NativeStressDayPlot: View {
    var model: NativeStressDayPlotModel
    var previewSelected: Date? = nil
    @Environment(\.nativeStyle) private var style
    @Binding var scrubValue: Double
    @Binding var scrubTime: Date?
    @State private var selectedTime: Date?

    private var lineGradient: LinearGradient {
        let stops = NativeStressMonitorMath.lineStops(style: style).map {
            Gradient.Stop(color: $0.color, location: $0.value / 3)
        }
        return LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top)
    }

    private var sleepFill: Color { NativePaint.separator(style).opacity(0.22) }
    private var sleepAccent: Color { NativePaint.separator(style) }
    private var workoutFill: Color { NativePaint.strain(style).opacity(0.22) }
    private var workoutAccent: Color { NativePaint.strain(style) }

    var body: some View {
        Chart {
            if let visible = model.sleepVisible {
                RectangleMark(
                    xStart: .value("Sleep shade start", visible.start),
                    xEnd: .value("Sleep shade end", visible.end),
                    yStart: .value("Plot", 0),
                    yEnd: .value("Top", 3)
                )
                .foregroundStyle(sleepFill)
                .accessibilityHidden(true)
                RectangleMark(
                    xStart: .value("Sleep accent start", visible.start),
                    xEnd: .value("Sleep accent end", visible.end),
                    yStart: .value("Accent", NativeStressLaneIcon.accentLow),
                    yEnd: .value("Accent top", NativeStressLaneIcon.accentHigh)
                )
                .foregroundStyle(sleepAccent)
                .accessibilityLabel("Sleep")
            }
            ForEach(Array(model.workoutVisible.enumerated()), id: \.offset) { _, visible in
                RectangleMark(
                    xStart: .value("Activity shade start", visible.start),
                    xEnd: .value("Activity shade end", visible.end),
                    yStart: .value("Plot", 0),
                    yEnd: .value("Top", 3)
                )
                .foregroundStyle(workoutFill)
                .accessibilityHidden(true)
                RectangleMark(
                    xStart: .value("Activity accent start", visible.start),
                    xEnd: .value("Activity accent end", visible.end),
                    yStart: .value("Accent", NativeStressLaneIcon.accentLow),
                    yEnd: .value("Accent top", NativeStressLaneIcon.accentHigh)
                )
                .foregroundStyle(workoutAccent)
                .accessibilityLabel("Activity")
            }
            ForEach(Array(model.hourSegments.enumerated()), id: \.offset) { index, segment in
                ForEach(segment) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Stress", point.value),
                        series: .value("Segment", index)
                    )
                    .foregroundStyle(lineGradient)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                    .accessibilityLabel(model.pointTimeText[point.time.timeIntervalSince1970] ?? NativeScopeFormat.time(point.time))
                    .accessibilityValue(String(format: "%.1f", point.value))
                }
            }
            if model.showsNow {
                RuleMark(x: .value("Now", model.now))
                    .foregroundStyle(NativePaint.separator(style))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .accessibilityHidden(true)
                PointMark(x: .value("Now dot", model.now), y: .value("Base", 0))
                    .foregroundStyle(Color.primary)
                    .symbolSize(28)
                    .accessibilityHidden(true)
            }
            if let selectedTime,
               let point = NativeChartScrubMath.nearestHour(
                to: selectedTime,
                in: model.hours,
                maxGap: model.maxGap
               ) {
                PointMark(x: .value("Scrub", point.time), y: .value("Stress", point.value))
                    .foregroundStyle(NativePaint.stressBand(point.value, style: style))
                    .symbol { NativeSelectedVertex(tint: NativePaint.stressBand(point.value, style: style)) }
                    .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: 0...3)
        .chartXScale(domain: model.xDomain)
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .trailing, values: NativeStressMonitorMath.yAxisValues) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativePaint.separator(style))
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(NativeStressMonitorMath.yLabel(raw))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: model.hourLabels) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativePaint.separator(style))
                AxisValueLabel(anchor: NativeDayAxisLabel.anchor(for: value.as(Date.self) ?? .distantPast, in: model.hourLabels)) {
                    if let date = value.as(Date.self) {
                        Text(model.hourLabelText[date.timeIntervalSince1970] ?? NativeScopeFormat.hourClock(date, calendar: .current))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .nativeClippedChartPlot(top: NativeStressLaneIcon.iconLane)
        .chartOverlay { proxy in
            NativeStressLaneOverlay(
                proxy: proxy,
                items: model.laneItems,
                dayStart: model.dayStart,
                plotEnd: model.plotEnd
            )
        }
        .modifier(NativeTimeSelect(selected: $selectedTime, onChange: { time in
            if let time, let point = NativeChartScrubMath.nearestHour(
                to: time,
                in: model.hours,
                maxGap: model.maxGap
            ) {
                scrubTime = point.time
                scrubValue = point.value
            } else {
                scrubTime = nil
            }
        }))
        .onAppear { if selectedTime == nil { selectedTime = previewSelected } }
        .modifier(NativeSelectionFeedback(trigger: selectedTime ?? .distantPast))
        .accessibilityLabel("Stress monitor \(String(format: "%.1f", model.score))")
        .nativeChartDescriptor(
            NativeChartDescriptor(
                title: "Stress",
                unit: "",
                xKind: .date,
                points: model.hours.map {
                    NativeChartDescriptor.Point(
                        xLabel: model.pointTimeText[$0.time.timeIntervalSince1970] ?? NativeScopeFormat.time($0.time),
                        xValue: $0.time.timeIntervalSince1970,
                        y: $0.value
                    )
                },
                yRange: 0...3
            )
        )
    }
}

enum NativeStressLaneIcon {
    static let iconLane: CGFloat = 24
    static let accentLow: Double = 2.94
    static let accentHigh: Double = 3.0
    static let minSeparation: CGFloat = 22

    enum Kind: Equatable {
        case sleep
        case workout
    }

    struct Item: Identifiable, Equatable {
        var id: String
        var start: Date
        var end: Date
        var symbol: String
        var kind: Kind
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    struct Placed: Equatable {
        var item: Item
        var x: CGFloat
    }

    static func clip(
        _ start: Date,
        _ end: Date,
        plotStart: Date,
        plotEnd: Date
    ) -> (start: Date, end: Date)? {
        let lo = max(start, plotStart)
        let hi = min(end, plotEnd)
        guard hi > lo else { return nil }
        return (lo, hi)
    }

    /// Larger spans keep the span midpoint. A neighbour closer than
    /// `minSeparation` is nudged; if it still collides it is dropped.
    static func placed(
        items: [Item],
        plotStart: Date,
        plotEnd: Date,
        minSeparation: CGFloat = minSeparation,
        xRange: ClosedRange<CGFloat>?,
        xFor: (Date) -> CGFloat?
    ) -> [Placed] {
        let mids: [(Item, CGFloat)] = items.compactMap { item in
            guard let visible = clip(item.start, item.end, plotStart: plotStart, plotEnd: plotEnd),
                  let x0 = xFor(visible.start),
                  let x1 = xFor(visible.end)
            else { return nil }
            return (item, (x0 + x1) / 2)
        }
        let ranked = mids.sorted { lhs, rhs in
            if lhs.0.duration == rhs.0.duration { return lhs.1 < rhs.1 }
            return lhs.0.duration > rhs.0.duration
        }
        var kept: [Placed] = []
        for (item, natural) in ranked {
            var x = natural
            if let blocker = kept.min(by: { abs($0.x - x) < abs($1.x - x) }),
               abs(blocker.x - x) < minSeparation {
                let dir: CGFloat = natural >= blocker.x ? 1 : -1
                x = blocker.x + dir * minSeparation
            }
            if let xRange {
                let inset = minSeparation / 2
                x = min(max(x, xRange.lowerBound + inset), xRange.upperBound - inset)
            }
            if kept.contains(where: { abs($0.x - x) < minSeparation }) {
                continue
            }
            kept.append(Placed(item: item, x: x))
        }
        return kept.sorted { $0.x < $1.x }
    }
}

private struct NativeStressLaneOverlay: View {
    var proxy: ChartProxy
    var items: [NativeStressLaneIcon.Item]
    var dayStart: Date
    var plotEnd: Date

    var body: some View {
        GeometryReader { geo in
            let plot = proxy.plotRectCompat(in: geo)
            ZStack(alignment: .topLeading) {
                if plot.width > 1 {
                    let placed = NativeStressLaneIcon.placed(
                        items: items,
                        plotStart: dayStart,
                        plotEnd: plotEnd,
                        xRange: plot.minX...plot.maxX,
                        xFor: { date in
                            guard let relative = proxy.position(forX: date) else { return nil }
                            return plot.origin.x + relative
                        }
                    )
                    ForEach(placed, id: \.item.id) { row in
                        Image(systemName: row.item.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                            .position(x: row.x, y: max(8, plot.minY - 11))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

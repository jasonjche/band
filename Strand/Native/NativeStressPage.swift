import SwiftUI
import WhoopStore
import StrandDesign

/// Stress Monitor. D/W/M/6M like Apple Health. Small gauge. No Sessions.
struct NativeStressPage: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""

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

    private var dayKey: String { NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }

    private var taskID: String { "\(scope.rawValue)|\(dayKey)|\(repo.refreshSeq)" }

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
            highlightKey: dayKey
        )
        .navigationTitle("Stress Monitor")
        .modifier(NativeInlineTitle())
        .nativeDateSubtitle(selectedDay)
        .task(id: taskID) { await reload() }
    }

    private func reload() async {
        workouts = await repo.workoutRows(days: 14)
        let calendar = Calendar.current
        let ending = NativeScopeSeries.date(from: dayKey, calendar: calendar) ?? selectedDay
        let start = calendar.startOfDay(for: ending)
        let from = Int(start.timeIntervalSince1970)
        let buckets = await repo.hrSamples(from: from, to: from + 86_400, bucketSeconds: 300)
        sampleHours = NativeHomeCharts.stressSeries(buckets: buckets)
        level = NativeStressResolver.level(hours: sampleHours, days: repo.days, todayKey: dayKey)
        if let latest = level {
            scrubValue = latest
        }
        scrubTime = nil
        timeInHighMinutes = NativeStressHistory.timeInHighMinutes(sampleHours)
        let sleep = repo.sleeps.last {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == dayKey
        }
        sleepStart = sleep.map { Date(timeIntervalSince1970: TimeInterval($0.effectiveStartTs)) }
        sleepEnd = sleep.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) }
        bouts = workouts.compactMap { row in
            let boutStart = Date(timeIntervalSince1970: TimeInterval(row.startTs))
            guard NativeDayLogic.sleepSessionDayKey(boutStart) == dayKey else { return nil }
            return (boutStart, Date(timeIntervalSince1970: TimeInterval(row.endTs)))
        }
        let daily = NativeStressHistory.daily(days: repo.days, ending: dayKey)
        series = NativeScopeSeries.make(
            points: daily,
            scope: scope,
            kind: .rate,
            calendar: calendar,
            now: ending,
            ending: ending
        )
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
                    color: { NativeChrome.stressBandColor($0) }
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

        if let minutes = timeInHighMinutes, minutes > 0, scrubTime == nil {
            NativeChrome.panel {
                NativeContributorRow(
                    symbol: "gauge.with.dots.needle.67percent",
                    title: "Time in High",
                    value: NativeScoreMath.duration(minutes),
                    tint: NativeTokens.stressHigh
                )
            }
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

    static func timeInHighMinutes(_ hours: [NativeHourPoint]) -> Double? {
        guard hours.count >= 2 else { return nil }
        var total: TimeInterval = 0
        for index in 0..<(hours.count - 1) where hours[index].value >= 2 {
            total += hours[index + 1].time.timeIntervalSince(hours[index].time)
        }
        let minutes = total / 60
        return minutes > 0 ? minutes : nil
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

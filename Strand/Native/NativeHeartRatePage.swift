import SwiftUI
import Charts
import StrandDesign
import WhoopStore

/// Pushed from Health Monitor's heart-rate card. Deeper than a tab-root hop, so a
/// Hashable value on the existing stack is enough — no new `TabRoute` case.
struct NativeHeartRateRoute: Hashable {}

/// Full-day heart rate: midnight→now (or the selected day), scrub, min/avg/max, resting HR.
struct NativeHeartRatePage: View {
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""
    @State private var repoHandle: Repository?
    @State private var refreshSeq = 0
    @State private var handlesReady = false
    @State private var model = NativeHeartRateMath.Model.empty
    @State private var liveBpm: Int?
    @State private var liveSamples: [NativeHourPoint] = []
    @State private var scrub = NativeScopeScrub()

    private var selectedDay: Date {
        NativeDaySelection.date(from: selectedDayKey)
    }

    private var dayKey: String { NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }
    private var viewingToday: Bool { dayKey == NativeDayLogic.logicalToday() }

    private var taskID: String {
        handlesReady ? "\(dayKey)|\(refreshSeq)" : "boot"
    }

    private var displayModel: NativeHeartRateMath.Model {
        guard viewingToday else { return model }
        return NativeHeartRateMath.appendLive(
            to: model,
            bpm: liveBpm,
            at: liveSamples.last?.time ?? Date()
        )
    }

    var body: some View {
        NativeChrome.screen {
            NativeHeartRateBody(
                model: displayModel,
                liveBpm: viewingToday ? liveBpm : nil,
                scrub: scrub
            )
        }
        .navigationTitle("Heart Rate")
        .modifier(NativeInlineTitle())
        .nativeDateSubtitle(selectedDay)
        .background {
            NativeRepoSink(refreshSeq: $refreshSeq, ready: $handlesReady) { repoHandle = $0 }
            if viewingToday {
                NativeLiveHRArm(bpm: $liveBpm, samples: $liveSamples)
            }
        }
        .task(id: taskID) {
            guard handlesReady, let repo = repoHandle else { return }
            await load(repo: repo)
        }
        .onChangeCompat(of: dayKey) { key in
            if key != NativeDayLogic.logicalToday() {
                liveBpm = nil
                liveSamples = []
            }
        }
    }

    private func load(repo: Repository) async {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: selectedDay)
        let from = Int(dayStart.timeIntervalSince1970)
        let now = Date()
        let end = min(from + 86_400, Int(now.timeIntervalSince1970))
        let key = dayKey
        let viewingToday = viewingToday
        let buckets = await repo.hrSamples(from: from, to: end, bucketSeconds: 60)
        if Task.isCancelled || key != dayKey { return }
        let sleep = repo.sleeps.last {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == key
        }
        let resting = repo.days.last { $0.day == key }?.restingHr
        let points = buckets.map {
            NativeHourPoint(time: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm)
        }
        let minBpm = buckets.map(\.minBpm).min()
        let maxBpm = buckets.map(\.maxBpm).max()
        let avgBpm = NativeScoreMath.mean(buckets.map(\.bpm))
        let sleepStart = sleep.map { Date(timeIntervalSince1970: TimeInterval($0.effectiveStartTs)) }
        let sleepEnd = sleep.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) }
        let built = await Task.detached(priority: .utility) {
            NativeHeartRateMath.make(
                points: points,
                minBpm: minBpm,
                maxBpm: maxBpm,
                avgBpm: avgBpm,
                restingBpm: resting,
                sleepStart: sleepStart,
                sleepEnd: sleepEnd,
                dayStart: dayStart,
                now: now,
                viewingToday: viewingToday
            )
        }.value
        if Task.isCancelled || key != dayKey { return }
        model = built
    }
}

private struct NativeHeartRateBody: View {
    var model: NativeHeartRateMath.Model
    var liveBpm: Int?
    var scrub: NativeScopeScrub
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
            NativeHeartRateHero(
                model: model,
                liveBpm: liveBpm,
                scrub: scrub
            )
            NativeChrome.panel {
                NativeHeartRatePlot(
                    model: model,
                    tint: NativePaint.heart(style),
                    scrub: scrub
                )
                .frame(height: 280)
            }
            stats
        }
    }

    private var stats: some View {
        NativeChrome.panel {
            NativeContributorRow(
                symbol: "arrow.down",
                title: "Min",
                value: bpmText(model.stats.minBpm),
                tint: NativePaint.heart(style)
            )
            Divider().padding(.leading, 34)
            NativeContributorRow(
                symbol: "minus",
                title: "Average",
                value: bpmText(model.stats.avgBpm),
                tint: NativePaint.heart(style)
            )
            Divider().padding(.leading, 34)
            NativeContributorRow(
                symbol: "arrow.up",
                title: "Max",
                value: bpmText(model.stats.maxBpm),
                tint: NativePaint.heart(style)
            )
            Divider().padding(.leading, 34)
            NativeContributorRow(
                symbol: "heart.fill",
                title: "Resting HR",
                value: model.stats.restingBpm.map { "\($0) BPM" } ?? "—",
                tint: NativePaint.heart(style)
            )
        }
    }

    private func bpmText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded())) BPM"
    }
}

private struct NativeHeartRateHero: View {
    var model: NativeHeartRateMath.Model
    var liveBpm: Int?
    @ObservedObject var scrub: NativeScopeScrub

    var body: some View {
        if let time = scrub.time,
           let point = NativeChartScrubMath.nearestHour(
            to: time,
            in: model.plot,
            maxGap: NativeChartScrubMath.inferredMaxGap(in: model.plot)
           ) {
            NativeHeroValue(
                caption: "Heart Rate",
                value: "\(Int(point.value.rounded()))",
                unit: "BPM",
                date: NativeHeartRateMath.heroDate(isScrubbing: true, time: point.time)
            )
        } else if let liveBpm {
            NativeHeroValue(
                caption: "Heart Rate",
                value: "\(liveBpm)",
                unit: "BPM",
                date: NativeHeartRateMath.latestLabel
            )
        } else if let last = model.plot.last {
            NativeHeroValue(
                caption: "Heart Rate",
                value: "\(Int(last.value.rounded()))",
                unit: "BPM",
                date: NativeHeartRateMath.latestLabel
            )
        } else {
            NativeHeroValue(caption: "Heart Rate", value: "No data")
        }
    }
}

private struct NativeHeartRatePlot: View {
    var model: NativeHeartRateMath.Model
    var tint: Color
    @ObservedObject var scrub: NativeScopeScrub
    @Environment(\.nativeStyle) private var style

    private var timeBinding: Binding<Date?> {
        Binding(
            get: { scrub.time },
            set: { scrub.time = $0 }
        )
    }

    private var xDomain: ClosedRange<Date> { model.dayStart...model.plotEnd }

    private var plot: [NativeHourPoint] {
        NativeHeartRateMath.clippedPlot(model.plot, xDomain: xDomain, yDomain: model.yDomain)
    }

    var body: some View {
        Group {
            if plot.count < 2 {
                NativeEmptyState(text: "No data", symbol: "heart")
            } else {
                Chart {
                    if let sleep = NativeHeartRateMath.clippedSleep(
                        start: model.sleepStart,
                        end: model.sleepEnd,
                        xDomain: xDomain
                    ) {
                        RectangleMark(
                            xStart: .value("Sleep shade start", sleep.0),
                            xEnd: .value("Sleep shade end", sleep.1),
                            yStart: .value("Plot", model.yDomain.lowerBound),
                            yEnd: .value("Top", model.yDomain.upperBound)
                        )
                        .foregroundStyle(NativePaint.separator(style).opacity(0.16))
                        .accessibilityHidden(true)
                    }
                    ForEach(plot) { point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("BPM", point.value)
                        )
                        .foregroundStyle(tint)
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .accessibilityLabel(NativeScopeFormat.time(point.time))
                        .accessibilityValue("\(Int(point.value.rounded()))")
                    }
                    if model.showsNow, let last = plot.last,
                       last.time >= xDomain.lowerBound, last.time <= xDomain.upperBound,
                       scrub.time == nil {
                        RuleMark(x: .value("Now", last.time))
                            .foregroundStyle(NativePaint.separator(style))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .accessibilityHidden(true)
                        PointMark(
                            x: .value("Now dot", last.time),
                            y: .value("BPM", last.value)
                        )
                        .foregroundStyle(tint)
                        .symbol { NativeSelectedVertex(tint: tint, size: 8) }
                        .accessibilityHidden(true)
                    }
                    if let time = scrub.time,
                       let point = NativeChartScrubMath.nearestHour(
                        to: time,
                        in: plot,
                        maxGap: NativeChartScrubMath.inferredMaxGap(in: plot)
                       ),
                       point.time >= xDomain.lowerBound, point.time <= xDomain.upperBound {
                        PointMark(
                            x: .value("Scrub", point.time),
                            y: .value("BPM", point.value)
                        )
                        .foregroundStyle(tint)
                        .symbol { NativeSelectedVertex(tint: tint) }
                        .accessibilityHidden(true)
                    }
                }
                .chartYScale(domain: model.yDomain)
                .chartXScale(domain: xDomain)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: NativeChartTicks.values(in: model.yDomain, maxCount: 3)) { _ in
                        AxisGridLine(stroke: NativeChrome.gridStroke)
                            .foregroundStyle(NativeChrome.hairline)
                        AxisValueLabel()
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: NativeHeartRateMath.xAxisDates(dayStart: model.dayStart, plotEnd: model.plotEnd)) { value in
                        AxisGridLine(stroke: NativeChrome.gridStroke)
                            .foregroundStyle(NativeChrome.hairline)
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(NativeScopeFormat.hourClock(date, calendar: .current))
                                    .font(.caption2)
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                    }
                }
                .chartPlotStyle { $0.clipped() }
                .modifier(NativeTimeSelect(
                    selected: timeBinding,
                    snap: { time in
                        guard let time else { return nil }
                        return NativeChartScrubMath.nearestHour(
                            to: time,
                            in: plot,
                            maxGap: NativeChartScrubMath.inferredMaxGap(in: plot)
                        )?.time
                    },
                    onChange: { _ in }
                ))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Heart rate")
        .nativeChartDescriptor(
            NativeChartDescriptor(
                title: "Heart rate",
                unit: "BPM",
                xKind: .date,
                points: plot.map {
                    NativeChartDescriptor.Point(
                        xLabel: NativeScopeFormat.time($0.time),
                        xValue: $0.time.timeIntervalSince1970,
                        y: $0.value
                    )
                },
                yRange: model.yDomain
            )
        )
    }
}



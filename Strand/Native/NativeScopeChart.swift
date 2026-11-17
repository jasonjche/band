import SwiftUI
import Charts
import StrandDesign

/// Apple Health-style metric plot: fixed-height hero, D/W/M/6M aggregation, scrub, scroll.
struct NativeScopeChart: View {
    var series: NativeScopeSeries
    var hourPoints: [NativeHourPoint] = []
    var bars: Bool
    var tint: Color
    var format: (Double) -> String
    var unit: String? = nil
    var highlightKey: String? = nil
    var higherIsBetter: Bool? = nil
    var previewSelected: String? = nil
    var previewTime: Date? = nil
    var calendar: Calendar = .current
    var accessibilityName: String = "Chart"
    var color: ((Double) -> Color)? = nil
    var plotHeight: CGFloat = 280
    var scrolls: Bool = true

    @State private var selectedKey: String?
    @State private var selectedTime: Date?
    @State private var scrollDate: Date?

    private let heroHeight: CGFloat = 76

    private var usesHours: Bool { series.scope == .day && !hourPoints.isEmpty }

    private var visible: [NativeScopeBucket] {
        if usesHours { return series.latestWindow() }
        if let scrollDate {
            return series.window(leading: scrollDate, calendar: calendar)
        }
        return series.latestWindow()
    }

    private var selectedBucket: NativeScopeBucket? {
        guard let selectedKey else { return nil }
        return series.buckets.first { $0.key == selectedKey && $0.value != nil }
    }

    private var selectedHour: NativeHourPoint? {
        guard let selectedTime else { return nil }
        return hourPoints.min(by: {
            abs($0.time.timeIntervalSince(selectedTime)) < abs($1.time.timeIntervalSince(selectedTime))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            hero
                .frame(height: heroHeight, alignment: .topLeading)
            plot
                .frame(height: plotHeight)
            NativeTrendRows(
                trend: series.trend(visible: visible, higherIsBetter: higherIsBetter),
                format: format,
                unit: unit,
                tint: tint,
                calendar: calendar
            )
        }
        .onAppear {
            if selectedKey == nil { selectedKey = previewSelected }
            if selectedTime == nil { selectedTime = previewTime }
            if scrollDate == nil {
                scrollDate = series.latestWindow().first?.start
            }
        }
        .modifier(NativeSelectionFeedback(trigger: selectedKey ?? selectedTime.map { "\($0.timeIntervalSince1970)" } ?? ""))
    }

    @ViewBuilder private var hero: some View {
        if usesHours, let hour = selectedHour {
            NativeHeroValue(
                caption: series.caption,
                value: format(hour.value),
                unit: unit,
                date: NativeScopeFormat.time(hour.time, calendar: calendar)
            )
        } else if let bucket = selectedBucket, let value = bucket.value {
            NativeHeroValue(
                caption: series.caption,
                value: format(value),
                unit: unit,
                date: series.selectionDateText(for: bucket, calendar: calendar)
            )
        } else if usesHours, let average = NativeScoreMath.mean(hourPoints.map(\.value)),
                  let range = series.heroDateText(of: visible, calendar: calendar) {
            NativeHeroValue(caption: series.caption, value: format(average), unit: unit, date: range)
        } else if let average = series.aggregate(of: visible),
                  let range = series.heroDateText(of: visible, calendar: calendar) {
            NativeHeroValue(caption: series.caption, value: format(average), unit: unit, date: range)
        } else {
            NativeHeroValue(
                caption: series.caption,
                value: "No Data",
                date: series.heroDateText(of: visible, calendar: calendar)
            )
        }
    }

    @ViewBuilder private var plot: some View {
        if usesHours {
            NativeOvernightLine(
                points: hourPoints,
                tint: tint,
                selectedTime: $selectedTime,
                previewSelected: previewTime
            )
        } else if series.known.isEmpty {
            NativeEmptyState(text: "No Data")
        } else if scrolls, #available(iOS 17.0, macOS 14.0, *) {
            datePlot(series.buckets)
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: series.scope.visibleSeconds)
                .chartScrollPosition(x: Binding(
                    get: { scrollDate ?? series.latestWindow().first?.start ?? Date() },
                    set: { scrollDate = $0 }
                ))
                .chartXSelection(value: $selectedTime)
                .onChange(of: selectedTime) { _, time in
                    selectedKey = time.flatMap { nearestBucket(to: $0)?.key }
                }
        } else {
            datePlot(series.latestWindow())
        }
    }

    private func datePlot(_ buckets: [NativeScopeBucket]) -> some View {
        let known = buckets.filter { $0.value != nil }
        let values = known.compactMap(\.value)
        let barCeiling = max(values.max() ?? 1, 1)
        let lineDomain = NativeChartDay.fittedDomain(values, fallback: 0...1)
        let yDomain: ClosedRange<Double> = bars ? 0...(barCeiling * 1.22) : lineDomain
        let segments = NativeChartDay.linePoints(buckets.map(\.point))
        return Chart {
            ForEach(buckets) { bucket in
                if bars {
                    if let value = bucket.value {
                        BarMark(
                            x: .value("Day", bucket.start),
                            y: .value("Value", value),
                            width: .ratio(0.6)
                        )
                        .foregroundStyle(color?(value) ?? tint)
                        .cornerRadius(4)
                        .accessibilityLabel(series.selectionDateText(for: bucket, calendar: calendar))
                        .accessibilityValue(format(value))
                    }
                } else if let low = bucket.low, let high = bucket.high, let value = bucket.value {
                    BarMark(
                        x: .value("Day", bucket.start),
                        yStart: .value("Low", low),
                        yEnd: .value("High", high),
                        width: 7
                    )
                    .foregroundStyle(tint)
                    .clipShape(Capsule())
                    .accessibilityLabel(series.selectionDateText(for: bucket, calendar: calendar))
                    .accessibilityValue(format(value))
                }
            }
            if !bars, buckets.allSatisfy({ $0.low == nil && $0.high == nil }) {
                ForEach(segments) { point in
                    if let date = NativeScopeSeries.date(from: point.key, calendar: calendar) {
                        LineMark(
                            x: .value("Day", date),
                            y: .value("Value", point.value),
                            series: .value("Segment", point.segment)
                        )
                        .foregroundStyle(tint)
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .accessibilityHidden(true)
                        PointMark(x: .value("Day", date), y: .value("Value", point.value))
                            .foregroundStyle(tint)
                            .symbol { NativeScopeVertex(tint: tint) }
                            .accessibilityLabel(NativeChartDay.longLabel(point.key))
                            .accessibilityValue(format(point.value))
                    }
                }
            }
            if let selected = selectedBucket {
                RuleMark(x: .value("Day", selected.start))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .trailing, values: NativeChartTicks.values(in: bars ? 0...barCeiling : lineDomain, maxCount: 3)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeTokens.separator)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(format(raw))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: labelDates(in: buckets)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeTokens.separator)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(date))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }

    private func labelDates(in buckets: [NativeScopeBucket]) -> [Date] {
        switch series.scope {
        case .day, .week:
            return buckets.map(\.start)
        case .month:
            return buckets.map(\.start).filter { calendar.component(.weekday, from: $0) == calendar.firstWeekday }
        case .sixMonths, .year:
            var seen = Set<Int>()
            return buckets.map(\.start).filter { date in
                let month = calendar.component(.month, from: date) + calendar.component(.year, from: date) * 12
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

    private func nearestBucket(to date: Date) -> NativeScopeBucket? {
        series.buckets.min(by: {
            abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date))
        }).flatMap { $0.value == nil ? nil : $0 }
    }
}

private struct NativeScopeVertex: View {
    var tint: Color
    var body: some View {
        ZStack {
            Circle().fill(NativeTokens.card)
            Circle().strokeBorder(tint, lineWidth: 2)
        }
        .frame(width: 8, height: 8)
    }
}

/// Highlights-like trend rows. Hidden unless both periods have ≥ 3 values.
struct NativeTrendRows: View {
    var trend: NativeScopeTrend?
    var format: (Double) -> String
    var unit: String?
    var tint: Color
    var calendar: Calendar

    var body: some View {
        if let trend {
            NativeChrome.section("Trend")
            NativeChrome.panel {
                NativeContributorRow(
                    symbol: "chart.line.uptrend.xyaxis",
                    title: "Average",
                    value: labeled(trend.currentMean),
                    prior: labeled(trend.previousMean),
                    delta: trend.delta,
                    tint: tint
                )
                Divider().padding(.leading, 32)
                NativeContributorRow(
                    symbol: "arrow.up.to.line",
                    title: "High",
                    value: labeled(trend.maxValue),
                    prior: NativeScopeFormat.weekdayDate(trend.maxDate, calendar: calendar),
                    delta: .none,
                    tint: tint
                )
                Divider().padding(.leading, 32)
                NativeContributorRow(
                    symbol: "arrow.down.to.line",
                    title: "Low",
                    value: labeled(trend.minValue),
                    prior: NativeScopeFormat.weekdayDate(trend.minDate, calendar: calendar),
                    delta: .none,
                    tint: tint
                )
            }
        }
    }

    private func labeled(_ value: Double) -> String {
        guard let unit, !unit.isEmpty else { return format(value) }
        return "\(format(value)) \(unit)"
    }
}

/// Presentational metric page used by NativeMetricPage and snapshots.
struct NativeMetricChartPage: View {
    var title: String
    var scope: NativeMetricScope
    var onScope: (NativeMetricScope) -> Void
    var series: NativeScopeSeries
    var hourPoints: [NativeHourPoint] = []
    var bars: Bool
    var tint: Color
    var format: (Double) -> String
    var unit: String?
    var highlightKey: String?
    var higherIsBetter: Bool?
    var latest: NativeDayPoint?
    var previewSelected: String? = nil
    var previewTime: Date? = nil
    var calendar: Calendar = .current
    var color: ((Double) -> Color)? = nil
    var scrolls: Bool = true

    var body: some View {
        NativeChrome.screen {
            Picker("Range", selection: Binding(get: { scope }, set: onScope)) {
                ForEach(NativeMetricScope.pickerCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Time range")

            NativeScopeChart(
                series: series,
                hourPoints: hourPoints,
                bars: bars,
                tint: tint,
                format: format,
                unit: unit,
                highlightKey: highlightKey,
                higherIsBetter: higherIsBetter,
                previewSelected: previewSelected,
                previewTime: previewTime,
                calendar: calendar,
                accessibilityName: title,
                color: color,
                scrolls: scrolls
            )

            if let latest, latest.value.isFinite {
                NativeLatestCapsule(
                    label: "Latest: \(NativeChartDay.mediumDate(latest.key))",
                    value: "\(format(latest.value))\(unit.map { " \($0)" } ?? "")"
                )
            } else {
                NativeLatestCapsule(label: "Latest", value: "Unavailable")
            }
        }
        .navigationTitle(title)
        .modifier(NativeInlineTitle())
    }
}

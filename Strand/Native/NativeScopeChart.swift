import SwiftUI
import Charts
import StrandDesign

/// Apple Health-style metric plot: fixed-height hero, D/W/M/6M aggregation, scrub, scroll.
///
/// Scrub lives on a reference-type box the hero (and selected marker) observe. The chart marks
/// do not, so dragging does not rebuild LineMarks. Dense scopes are LineMark-only;
/// hollow vertices are week-scale. 6M is weekly buckets from `NativeScopeSeries.make`.
/// Selection is a filled vertex (or dimmed bars). There is no vertical rule.
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

    /// Class in `@State` so publishes do not rebuild this view (or the Chart).
    @State private var scrub = NativeScopeScrub()
    @State private var scrollDate: Date?

    private var usesHours: Bool { series.scope == .day && !hourPoints.isEmpty }

    private var visible: [NativeScopeBucket] {
        if usesHours { return series.latestWindow() }
        if let scrollDate {
            return series.window(leading: scrollDate, calendar: calendar)
        }
        return series.latestWindow()
    }

    var body: some View {
        let window = visible
        VStack(alignment: .leading, spacing: 4) {
            NativeScopeHeroView(
                series: series,
                visible: window,
                hourPoints: hourPoints,
                usesHours: usesHours,
                scrub: scrub,
                format: format,
                unit: unit,
                higherIsBetter: higherIsBetter,
                calendar: calendar,
                color: color
            )
            NativeScopePlotHost(
                series: series,
                visible: window,
                hourPoints: hourPoints,
                bars: bars,
                tint: tint,
                format: format,
                calendar: calendar,
                color: color,
                plotHeight: plotHeight,
                scrolls: scrolls,
                usesHours: usesHours,
                previewTime: previewTime,
                scrub: scrub,
                scrollDate: $scrollDate
            )
            NativeTrendRows(
                trend: series.trend(visible: window, higherIsBetter: higherIsBetter),
                format: format,
                unit: unit,
                tint: tint,
                calendar: calendar
            )
        }
        .onAppear {
            if scrollDate == nil {
                scrollDate = series.latestWindow().first?.start
            }
            if scrub.key == nil { scrub.key = previewSelected }
            if scrub.time == nil { scrub.time = previewTime }
        }
        .modifier(NativeScopeResetOnScope(scope: series.scope) {
            scrub.key = nil
            scrub.time = nil
            scrollDate = series.latestWindow().first?.start
        })
    }
}

private struct NativeScopeResetOnScope: ViewModifier {
    var scope: NativeMetricScope
    var onReset: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.onChange(of: scope) { _, _ in onReset() }
        } else {
            content
        }
    }
}

/// Caption / value / date / period-delta / typical range. Height depends on the
/// series (typical + trend), never on the scrub tick.
private struct NativeScopeHeroView: View {
    var series: NativeScopeSeries
    var visible: [NativeScopeBucket]
    var hourPoints: [NativeHourPoint]
    var usesHours: Bool
    @ObservedObject var scrub: NativeScopeScrub
    var format: (Double) -> String
    var unit: String?
    var higherIsBetter: Bool?
    var calendar: Calendar
    var color: ((Double) -> Color)?

    private let footnoteHeight: CGFloat = 18

    private var selectedBucket: NativeScopeBucket? {
        guard let key = scrub.key else { return nil }
        return series.buckets.first { $0.key == key && $0.value != nil }
    }

    private var selectedHour: NativeHourPoint? {
        guard let time = scrub.time else { return nil }
        return NativeChartScrubMath.nearestHour(
            to: time,
            in: hourPoints,
            maxGap: NativeChartScrubMath.inferredMaxGap(in: hourPoints)
        )
    }

    private var isScrubbing: Bool {
        selectedBucket != nil || (usesHours && selectedHour != nil)
    }

    private var deltaCaption: String? {
        series.periodDeltaCaption(of: visible, higherIsBetter: higherIsBetter)
    }

    private var typicalCaption: String? {
        guard let typical = series.typical else { return nil }
        return NativeTypicalRange.caption(range: typical, format: format, unit: unit)
    }

    private var heroHeight: CGFloat {
        var height: CGFloat = 76
        if deltaCaption != nil { height += footnoteHeight }
        if typicalCaption != nil { height += footnoteHeight }
        return height
    }

    private var valueTint: Color {
        if let bucket = selectedBucket, let value = bucket.value, let color {
            return color(value)
        }
        return .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeHeroValue(
                caption: isScrubbing ? nil : series.caption,
                value: valueText,
                unit: unit,
                date: dateText,
                valueTint: valueTint
            )
            if deltaCaption != nil {
                periodDeltaRow
                    .frame(height: footnoteHeight, alignment: .leading)
            }
            if let typicalCaption {
                Text(typicalCaption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(height: footnoteHeight, alignment: .leading)
                    .accessibilityLabel(typicalCaption)
            }
        }
        .frame(maxWidth: .infinity, minHeight: heroHeight, maxHeight: heroHeight, alignment: .topLeading)
        .modifier(NativeSelectionFeedback(trigger: scrub.key ?? scrub.time.map { "\($0.timeIntervalSince1970)" } ?? ""))
    }

    private var valueText: String {
        if usesHours, let hour = selectedHour {
            return format(hour.value)
        }
        if let bucket = selectedBucket, let value = bucket.value {
            return format(value)
        }
        if usesHours, let average = NativeScoreMath.mean(hourPoints.map(\.value)) {
            return format(average)
        }
        if let average = series.aggregate(of: visible) {
            return format(average)
        }
        return "No Data"
    }

    private var dateText: String? {
        if usesHours, let hour = selectedHour {
            return NativeScopeFormat.time(hour.time, calendar: calendar)
        }
        if let bucket = selectedBucket {
            return series.selectionDateText(for: bucket, calendar: calendar)
        }
        return series.heroDateText(of: visible, calendar: calendar)
    }

    @ViewBuilder private var periodDeltaRow: some View {
        if let deltaCaption, !isScrubbing, let trend = series.trend(visible: visible, higherIsBetter: higherIsBetter) {
            HStack(spacing: 4) {
                NativeDelta(delta: trend.delta)
                Text(deltaCaption)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(trend.delta == .flat ? Color.secondary : trend.delta.tint)
                    .monospacedDigit()
            }
        } else {
            Color.clear
        }
    }
}

/// Chart host. Does not observe `scrub`, so mark building is not on the scrub path.
private struct NativeScopePlotHost: View {
    var series: NativeScopeSeries
    var visible: [NativeScopeBucket]
    var hourPoints: [NativeHourPoint]
    var bars: Bool
    var tint: Color
    var format: (Double) -> String
    var calendar: Calendar
    var color: ((Double) -> Color)?
    var plotHeight: CGFloat
    var scrolls: Bool
    var usesHours: Bool
    var previewTime: Date?
    var scrub: NativeScopeScrub
    @Binding var scrollDate: Date?

    var body: some View {
        Group {
            if usesHours {
                NativeOvernightLine(
                    points: hourPoints,
                    tint: tint,
                    selectedTime: timeBinding,
                    previewSelected: previewTime
                )
            } else if series.known.isEmpty {
                NativeEmptyState(text: "No Data")
            } else {
                scopedChart
            }
        }
        .frame(height: plotHeight)
    }

    private var timeBinding: Binding<Date?> {
        Binding(
            get: { scrub.time },
            set: { time in
                scrub.time = time
                if usesHours {
                    scrub.key = nil
                } else {
                    scrub.key = time.flatMap { nearestBucket(to: $0)?.key }
                }
            }
        )
    }

    private var marks: NativeScopeStaticChart {
        NativeScopeStaticChart(
            series: series,
            plotBuckets: scrolls ? series.buckets : series.latestWindow(),
            visible: visible,
            bars: bars,
            tint: tint,
            format: format,
            calendar: calendar,
            color: color
        )
    }

    @ViewBuilder private var scopedChart: some View {
        if scrolls, #available(iOS 17.0, macOS 14.0, *) {
            marks
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: series.scope.visibleSeconds)
                .chartScrollPosition(x: Binding(
                    get: { scrollDate ?? series.latestWindow().first?.start ?? Date() },
                    set: { scrollDate = $0 }
                ))
                .chartXSelection(value: timeBinding)
                .chartOverlay { proxy in
                    NativeScopeHairline(
                        proxy: proxy, series: series, scrub: scrub, tint: tint, color: color, bars: bars
                    )
                }
        } else if #available(iOS 17.0, macOS 14.0, *) {
            marks
                .chartXSelection(value: timeBinding)
                .chartOverlay { proxy in
                    NativeScopeHairline(
                        proxy: proxy, series: series, scrub: scrub, tint: tint, color: color, bars: bars
                    )
                }
        } else {
            marks
        }
    }

    private func nearestBucket(to date: Date) -> NativeScopeBucket? {
        NativeChartScrubMath.nearestBucket(to: date, in: series.buckets)
    }
}

/// Selected vertex (line) or dimmed neighbours (bars). Observes `scrub`; the LineMarks do not.
private struct NativeScopeHairline: View {
    var proxy: ChartProxy
    var series: NativeScopeSeries
    @ObservedObject var scrub: NativeScopeScrub
    var tint: Color
    var color: ((Double) -> Color)?
    var bars: Bool

    var body: some View {
        GeometryReader { geo in
            if let key = scrub.key,
               let bucket = series.buckets.first(where: { $0.key == key && $0.value != nil }),
               let value = bucket.value,
               let x = proxy.position(forX: bucket.start) {
                if bars {
                    NativeScopeBarDim(x: x, height: geo.size.height, width: geo.size.width)
                } else if let y = proxy.position(forY: value) {
                    NativeSelectedVertex(tint: color?(value) ?? tint)
                        .position(x: x, y: y)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct NativeScopeBarDim: View {
    var x: CGFloat
    var height: CGFloat
    var width: CGFloat
    @Environment(\.nativeStyle) private var style

    private let half: CGFloat = 8

    var body: some View {
        let left = max(x - half, 0)
        let right = max(width - x - half, 0)
        ZStack(alignment: .topLeading) {
            NativePaint.card(style)
                .opacity(0.55)
                .frame(width: left, height: height)
            NativePaint.card(style)
                .opacity(0.55)
                .frame(width: right, height: height)
                .offset(x: x + half)
        }
        .allowsHitTesting(false)
    }
}

/// Chart marks. No selection. Typical band + period average line live here.
private struct NativeScopeStaticChart: View {
    var series: NativeScopeSeries
    var plotBuckets: [NativeScopeBucket]
    var visible: [NativeScopeBucket]
    var bars: Bool
    var tint: Color
    var format: (Double) -> String
    var calendar: Calendar
    var color: ((Double) -> Color)?

    var body: some View {
        let known = plotBuckets.filter { $0.value != nil }
        let visibleKnown = visible.filter { $0.value != nil }
        let values = visibleKnown.compactMap(\.value)
        let barCeiling = max(values.max() ?? known.compactMap(\.value).max() ?? 1, 1)
        let domainValues: [Double] = {
            var list = values
            if let typical = series.typical {
                list.append(typical.lowerBound)
                list.append(typical.upperBound)
            }
            return list
        }()
        let lineDomain = NativeChartDay.fittedDomain(domainValues, fallback: 0...1)
        let yDomain: ClosedRange<Double> = bars ? 0...(barCeiling * 1.22) : lineDomain
        let segments = lineSegments(plotBuckets)
        let visibleKeys = Set(visibleKnown.map(\.key))
        let showVertices = series.scope == .week || series.scope == .day
        let average = series.showsTrendLine ? series.aggregate(of: visible) : nil
        let lineTint = color == nil ? tint : Color.secondary
        return Chart {
            if let typical = series.typical, let first = plotBuckets.first, let last = plotBuckets.last {
                RectangleMark(
                    xStart: .value("Range start", first.start),
                    xEnd: .value("Range end", last.end),
                    yStart: .value("Typical low", typical.lowerBound),
                    yEnd: .value("Typical high", typical.upperBound)
                )
                .foregroundStyle(tint.opacity(0.14))
                .accessibilityLabel("Typical range")
                .accessibilityValue(NativeTypicalRange.caption(range: typical, format: format, unit: nil))
            }
            if bars {
                ForEach(plotBuckets) { bucket in
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
                }
            } else if plotBuckets.contains(where: { $0.low != nil && $0.high != nil }) {
                ForEach(plotBuckets) { bucket in
                    if let low = bucket.low, let high = bucket.high, let value = bucket.value {
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
            } else {
                ForEach(segments) { point in
                    LineMark(
                        x: .value("Day", point.date),
                        y: .value("Value", point.value),
                        series: .value("Segment", point.segment)
                    )
                    .foregroundStyle(lineTint)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .accessibilityHidden(true)
                }
                if showVertices {
                    ForEach(segments.filter { visibleKeys.contains($0.key) }) { point in
                        PointMark(x: .value("Day", point.date), y: .value("Value", point.value))
                            .foregroundStyle(color?(point.value) ?? tint)
                            .symbol {
                                NativeScopeVertex(tint: color?(point.value) ?? tint)
                            }
                            .accessibilityLabel(NativeChartDay.longLabel(point.key))
                            .accessibilityValue(format(point.value))
                    }
                }
            }
            if let average {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .accessibilityLabel("Period average")
                    .accessibilityValue(format(average))
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
            AxisMarks(values: labelDates(in: plotBuckets)) { value in
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

    private struct LinePoint: Identifiable {
        var date: Date
        var value: Double
        var segment: Int
        var key: String
        var id: String { "\(segment)-\(key)" }
    }

    private func lineSegments(_ buckets: [NativeScopeBucket]) -> [LinePoint] {
        var segment = 0
        var lastFinite = false
        var result: [LinePoint] = []
        for bucket in buckets {
            if let value = bucket.value, value.isFinite {
                if !lastFinite, !result.isEmpty { segment += 1 }
                result.append(LinePoint(date: bucket.start, value: value, segment: segment, key: bucket.key))
                lastFinite = true
            } else {
                lastFinite = false
            }
        }
        return result
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

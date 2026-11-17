import SwiftUI
import Charts
import StrandDesign

/// Apple Health-style metric plot: fixed-height hero, D/W/M/6M aggregation, scrub, scroll.
///
/// Scrub lives on a reference-type box the hero (and selected marker) observe. LineMarks stay
/// static; a plot-frame overlay draws the vertex and a thin rule. BarMarks observe the
/// selection so the highlighted bar is the same mark, at the same x and width.
/// Dense scopes are LineMark-only; hollow vertices are week-scale. 6M is weekly buckets
/// from `NativeScopeSeries.make`.
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
    var title: String = ""

    /// Class in `@State` so publishes do not rebuild this view (or the Chart).
    @State private var scrub = NativeScopeScrub()
    @State private var scrollDate: Date?

    private var usesHours: Bool { series.scope == .day && !hourPoints.isEmpty }
    private var hourBars: Bool { usesHours && bars }

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
                hourBars: hourBars,
                scrub: scrub,
                format: format,
                unit: unit,
                higherIsBetter: higherIsBetter,
                calendar: calendar,
                color: color,
                title: title
            )
            if series.typical != nil, !usesHours {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 14, height: 8)
                    Text("Typical range")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Typical range")
            }
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
                hourBars: hourBars,
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

/// Caption / value / date / period-delta chip / one-sentence summary.
/// Height depends on the series (delta + summary), never on the scrub tick.
private struct NativeScopeHeroView: View {
    var series: NativeScopeSeries
    var visible: [NativeScopeBucket]
    var hourPoints: [NativeHourPoint]
    var usesHours: Bool
    var hourBars: Bool
    @ObservedObject var scrub: NativeScopeScrub
    var format: (Double) -> String
    var unit: String?
    var higherIsBetter: Bool?
    var calendar: Calendar
    var color: ((Double) -> Color)?
    var title: String

    private let footnoteHeight: CGFloat = 22
    private let summaryHeight: CGFloat = 44

    private var selectedBucket: NativeScopeBucket? {
        guard let key = scrub.key else { return nil }
        return series.buckets.first { $0.key == key && $0.value != nil }
    }

    private var selectedHour: NativeHourPoint? {
        guard let time = scrub.time else { return nil }
        if hourBars {
            return NativeChartScrubMath.nearestCentered(
                to: time,
                in: hourPoints,
                duration: NativeChartScrubMath.hourDuration
            )
        }
        return NativeChartScrubMath.nearestHour(
            to: time,
            in: hourPoints,
            maxGap: NativeChartScrubMath.inferredMaxGap(in: hourPoints)
        )
    }

    private var isScrubbing: Bool {
        selectedBucket != nil || (usesHours && selectedHour != nil)
    }

    private var trend: NativeScopeTrend? {
        series.trend(visible: visible, higherIsBetter: higherIsBetter)
    }

    private var deltaCaption: String? {
        series.periodDeltaCaption(of: visible, higherIsBetter: higherIsBetter)
    }

    private var summaryText: String? {
        NativeScopeSummary.sentence(
            title: title,
            scope: series.scope,
            kind: series.kind,
            current: series.aggregate(of: visible),
            previous: trend?.previousMean,
            format: format,
            higherIsBetter: higherIsBetter
        )
    }

    private var heroHeight: CGFloat {
        var height: CGFloat = 76
        if deltaCaption != nil { height += 6 + footnoteHeight }
        if summaryText != nil { height += 6 + summaryHeight }
        return height
    }

    private var valueTint: Color {
        if let bucket = selectedBucket, let value = bucket.value, let color {
            return color(value)
        }
        return .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            if summaryText != nil {
                summaryRow
                    .frame(minHeight: summaryHeight, alignment: .topLeading)
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
        if series.kind == .total, let total = series.aggregate(of: visible) {
            return format(total)
        }
        if usesHours, let average = NativeScoreMath.mean(hourPoints.map(\.value)) {
            return format(average)
        }
        if let average = series.aggregate(of: visible) {
            return format(average)
        }
        return "—"
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
        if let deltaCaption, !isScrubbing, let trend {
            HStack(spacing: 4) {
                NativeDelta(delta: trend.delta)
                Text(deltaCaption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(trend.delta == .flat ? Color.secondary : trend.delta.tint)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    (trend.delta == .flat ? Color.secondary : trend.delta.tint).opacity(0.14)
                )
            )
            .accessibilityLabel(deltaCaption)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var summaryRow: some View {
        if let summaryText, !isScrubbing {
            Text(summaryText)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(summaryText)
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
    var hourBars: Bool
    var previewTime: Date?
    var scrub: NativeScopeScrub
    @Binding var scrollDate: Date?

    var body: some View {
        Group {
            if hourBars {
                NativeHourBarChart(
                    points: hourPoints,
                    tint: tint,
                    format: format,
                    calendar: calendar,
                    previewTime: previewTime,
                    scrub: scrub
                )
            } else if usesHours {
                NativeOvernightLine(
                    points: hourPoints,
                    tint: tint,
                    selectedTime: timeBinding,
                    previewSelected: previewTime
                )
            } else if series.known.isEmpty {
                NativeScopeEmptyChart(bars: bars, tint: tint, format: format)
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
                if usesHours {
                    scrub.time = time
                    scrub.key = nil
                } else if let snapped = NativeChartScrubMath.snapBucket(
                    date: time, buckets: series.buckets, bars: bars
                ) {
                    scrub.time = snapped.time
                    scrub.key = snapped.key
                } else {
                    scrub.time = nil
                    scrub.key = nil
                }
            }
        )
    }

    private var plotBuckets: [NativeScopeBucket] {
        scrolls ? series.buckets : series.latestWindow()
    }

    @ViewBuilder private var scopedChart: some View {
        if bars {
            NativeScopeBarSelectingChart(
                series: series,
                plotBuckets: plotBuckets,
                visible: visible,
                tint: tint,
                format: format,
                calendar: calendar,
                color: color,
                scrolls: scrolls,
                scrub: scrub,
                scrollDate: $scrollDate,
                timeBinding: timeBinding
            )
        } else if scrolls, #available(iOS 17.0, macOS 14.0, *) {
            lineMarks
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: series.scope.visibleSeconds)
                .chartScrollPosition(x: Binding(
                    get: { scrollDate ?? series.latestWindow().first?.start ?? Date() },
                    set: { scrollDate = $0 }
                ))
                .chartXSelection(value: timeBinding)
                .chartOverlay { proxy in
                    NativeScopeHairline(
                        proxy: proxy, series: series, scrub: scrub, tint: tint, color: color
                    )
                }
        } else if #available(iOS 17.0, macOS 14.0, *) {
            lineMarks
                .chartXSelection(value: timeBinding)
                .chartOverlay { proxy in
                    NativeScopeHairline(
                        proxy: proxy, series: series, scrub: scrub, tint: tint, color: color
                    )
                }
        } else {
            lineMarks
        }
    }

    private var lineMarks: NativeScopeStaticChart {
        NativeScopeStaticChart(
            series: series,
            plotBuckets: plotBuckets,
            visible: visible,
            bars: false,
            tint: tint,
            format: format,
            calendar: calendar,
            color: color
        )
    }
}

/// Bar plot that observes scrub so opacity is the same BarMark, at the same x and width.
private struct NativeScopeBarSelectingChart: View {
    var series: NativeScopeSeries
    var plotBuckets: [NativeScopeBucket]
    var visible: [NativeScopeBucket]
    var tint: Color
    var format: (Double) -> String
    var calendar: Calendar
    var color: ((Double) -> Color)?
    var scrolls: Bool
    @ObservedObject var scrub: NativeScopeScrub
    @Binding var scrollDate: Date?
    var timeBinding: Binding<Date?>

    var body: some View {
        let marks = NativeScopeStaticChart(
            series: series,
            plotBuckets: plotBuckets,
            visible: visible,
            bars: true,
            tint: tint,
            format: format,
            calendar: calendar,
            color: color,
            selectedKey: scrub.key
        )
        Group {
            if scrolls, #available(iOS 17.0, macOS 14.0, *) {
                marks
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: series.scope.visibleSeconds)
                    .chartScrollPosition(x: Binding(
                        get: { scrollDate ?? series.latestWindow().first?.start ?? Date() },
                        set: { scrollDate = $0 }
                    ))
                    .chartXSelection(value: timeBinding)
            } else if #available(iOS 17.0, macOS 14.0, *) {
                marks.chartXSelection(value: timeBinding)
            } else {
                marks
            }
        }
    }
}

/// Selected vertex plus a thin rule. Observes `scrub`; the LineMarks do not.
/// `ChartProxy.position` is plot-relative — add the plot-frame origin or the dot sits off the line.
private struct NativeScopeHairline: View {
    var proxy: ChartProxy
    var series: NativeScopeSeries
    @ObservedObject var scrub: NativeScopeScrub
    var tint: Color
    var color: ((Double) -> Color)?

    var body: some View {
        GeometryReader { geo in
            let origin = plotOrigin(geo: geo)
            if let key = scrub.key,
               let bucket = series.buckets.first(where: { $0.key == key && $0.value != nil }),
               let value = bucket.value,
               let xRel = proxy.position(forX: bucket.start),
               let yRel = proxy.position(forY: value) {
                let point = NativeChartScrubMath.overlayPoint(plotOrigin: origin, x: xRel, y: yRel)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(NativeTokens.separator)
                        .frame(width: 1, height: geo.size.height)
                        .position(x: point.x, y: geo.size.height / 2)
                    NativeSelectedVertex(tint: color?(value) ?? tint)
                        .position(x: point.x, y: point.y)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func plotOrigin(geo: GeometryProxy) -> CGPoint {
        if #available(iOS 17.0, macOS 14.0, *), let anchor = proxy.plotFrame {
            return geo[anchor].origin
        }
        return geo[proxy.plotAreaFrame].origin
    }
}

/// Chart marks. Bar opacity follows `selectedKey`; line selection is the overlay hairline.
private struct NativeScopeStaticChart: View {
    var series: NativeScopeSeries
    var plotBuckets: [NativeScopeBucket]
    var visible: [NativeScopeBucket]
    var bars: Bool
    var tint: Color
    var format: (Double) -> String
    var calendar: Calendar
    var color: ((Double) -> Color)?
    var selectedKey: String? = nil

    var body: some View {
        let known = plotBuckets.filter { $0.value != nil }
        let visibleKnown = visible.filter { $0.value != nil }
        let values = visibleKnown.compactMap(\.value)
        let barCeiling = max(values.max() ?? known.compactMap(\.value).max() ?? 1, 1)
        let barTop = NativeCountTicks.niceCeiling(barCeiling)
        let domainValues: [Double] = {
            var list = values.isEmpty ? known.compactMap(\.value) : values
            if let typical = series.typical, !bars {
                list.append(typical.lowerBound)
                list.append(typical.upperBound)
            }
            return list
        }()
        let yDomain: ClosedRange<Double> = bars
            ? 0...barTop
            : NativeScopeYTicks.niceDomain(domainValues, fallback: 0...1)
        let yTicks = bars
            ? NativeCountTicks.values(ceiling: barCeiling)
            : NativeScopeYTicks.values(in: yDomain)
        let segments = NativeScopePlotMath.lineSegments(plotBuckets)
        let visibleKeys = Set(visibleKnown.map(\.key))
        let showVertices = NativeScopePlotMath.showsVertices(
            scope: series.scope, knownCount: visibleKnown.count
        )
        let average = series.showsTrendLine ? series.aggregate(of: visible) : nil
        let lineTint = color == nil ? tint : Color.secondary
        let band = NativeScopePlotMath.clippedTypical(series.typical, yDomain: yDomain)
        let lastKnown = segments.last
        let barUnit = NativeScopePlotMath.barUnit(scope: series.scope)
        return Chart {
            if let band, let first = plotBuckets.first, let last = plotBuckets.last {
                RectangleMark(
                    xStart: .value("Range start", first.start),
                    xEnd: .value("Range end", last.end),
                    yStart: .value("Typical low", band.lowerBound),
                    yEnd: .value("Typical high", band.upperBound)
                )
                .foregroundStyle(Color.secondary.opacity(0.12))
                .accessibilityLabel("Typical range")
                .accessibilityValue(NativeTypicalRange.caption(range: band, format: format, unit: nil))
            }
            if bars {
                ForEach(plotBuckets) { bucket in
                    if let value = bucket.value {
                        BarMark(
                            x: .value("Day", bucket.start, unit: barUnit),
                            y: .value("Value", value),
                            width: .ratio(0.62)
                        )
                        .foregroundStyle(color?(value) ?? tint)
                        .cornerRadius(3)
                        .opacity(NativeChartScrubMath.barOpacity(
                            isSelected: bucket.key == selectedKey,
                            hasSelection: selectedKey != nil
                        ))
                        .accessibilityLabel(series.selectionDateText(for: bucket, calendar: calendar))
                        .accessibilityValue(format(value))
                    }
                }
            } else if plotBuckets.contains(where: { $0.low != nil && $0.high != nil }) {
                ForEach(plotBuckets) { bucket in
                    if let low = bucket.low, let high = bucket.high, let value = bucket.value {
                        BarMark(
                            x: .value("Day", bucket.start, unit: barUnit),
                            yStart: .value("Low", low),
                            yEnd: .value("High", high)
                        )
                        .foregroundStyle(tint)
                        .clipShape(Capsule())
                        .opacity(NativeChartScrubMath.barOpacity(
                            isSelected: bucket.key == selectedKey,
                            hasSelection: selectedKey != nil
                        ))
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
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                    .accessibilityHidden(true)
                }
                if showVertices {
                    ForEach(segments.filter { visibleKeys.contains($0.key) || $0.key == lastKnown?.key }) { point in
                        PointMark(x: .value("Day", point.date), y: .value("Value", point.value))
                            .foregroundStyle(color?(point.value) ?? tint)
                            .symbol {
                                NativeScopeVertex(
                                    tint: color?(point.value) ?? tint,
                                    size: visibleKnown.count <= 4 ? 10 : 8
                                )
                            }
                            .accessibilityLabel(NativeChartDay.longLabel(point.key))
                            .accessibilityValue(format(point.value))
                    }
                }
                if let lastKnown {
                    PointMark(x: .value("Day", lastKnown.date), y: .value("Value", lastKnown.value))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, spacing: 4) {
                            Text(format(lastKnown.value))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.primary)
                                .monospacedDigit()
                                .padding(.horizontal, 2)
                        }
                        .accessibilityHidden(true)
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
            AxisMarks(position: .trailing, values: yTicks) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeTokens.separator)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(bars ? NativeCountFormat.compact(raw) : format(raw))
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
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot
                .padding(.leading, NativeScopePlotMath.plotLeading)
                .padding(.trailing, NativeScopePlotMath.plotTrailing)
                .padding(.top, NativeScopePlotMath.plotTop)
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
}

/// Day-scope step/calorie bars. 24 slots; the selected bar is the same mark, dimmed neighbours.
private struct NativeHourBarChart: View {
    var points: [NativeHourPoint]
    var tint: Color
    var format: (Double) -> String
    var calendar: Calendar
    var previewTime: Date?
    @ObservedObject var scrub: NativeScopeScrub

    private var selectedPoint: NativeHourPoint? {
        guard let time = scrub.time else { return nil }
        return NativeChartScrubMath.nearestCentered(
            to: time,
            in: points,
            duration: NativeChartScrubMath.hourDuration
        )
    }

    private var timeBinding: Binding<Date?> {
        Binding(
            get: { scrub.time },
            set: { time in
                scrub.time = NativeChartScrubMath.snapHour(date: time, points: points, calendar: calendar)
                scrub.key = nil
            }
        )
    }

    var body: some View {
        let ceiling = max(points.map(\.value).max() ?? 0, 1)
        let top = NativeCountTicks.niceCeiling(ceiling)
        let labels = NativeCountTicks.hourLabelDates(
            dayStart: points.first?.time ?? Date(), calendar: calendar
        )
        let selectedTime = selectedPoint?.time
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Hour", point.time, unit: .hour),
                    y: .value("Value", point.value),
                    width: .ratio(0.72)
                )
                .foregroundStyle(tint)
                .cornerRadius(3)
                .opacity(NativeChartScrubMath.barOpacity(
                    isSelected: point.time == selectedTime,
                    hasSelection: selectedTime != nil
                ))
                .accessibilityLabel(NativeScopeFormat.hourClock(point.time, calendar: calendar))
                .accessibilityValue(format(point.value))
            }
        }
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .trailing, values: NativeCountTicks.values(ceiling: ceiling)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeTokens.separator)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(NativeCountFormat.compact(raw))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: labels) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeTokens.separator)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(NativeScopeFormat.hourClock(date, calendar: calendar))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot
                .padding(.leading, NativeScopePlotMath.plotLeading)
                .padding(.trailing, NativeScopePlotMath.plotTrailing)
                .padding(.top, NativeScopePlotMath.plotTop)
        }
        .modifier(NativeTimeSelect(
            selected: timeBinding,
            snap: { NativeChartScrubMath.snapHour(date: $0, points: points, calendar: calendar) },
            onChange: { _ in }
        ))
        .onAppear { if scrub.time == nil { scrub.time = previewTime } }
    }
}

/// Axes with no samples so a missing day is a blank plot, not a broken empty-state card.
private struct NativeScopeEmptyChart: View {
    var bars: Bool
    var tint: Color
    var format: (Double) -> String

    var body: some View {
        let top = bars ? NativeCountTicks.niceCeiling(1) : 1.0
        Chart {
            if bars {
                BarMark(x: .value("Day", Date()), y: .value("Value", 0))
                    .foregroundStyle(tint.opacity(0.001))
                    .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .trailing, values: bars ? NativeCountTicks.values(ceiling: 1) : [0, 1]) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeTokens.separator)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(bars ? NativeCountFormat.compact(raw) : format(raw))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis(.hidden)
        .accessibilityLabel("No data")
    }
}

private struct NativeScopeVertex: View {
    var tint: Color
    var size: CGFloat = 8
    var body: some View {
        ZStack {
            Circle().fill(NativeTokens.card)
            Circle().strokeBorder(tint, lineWidth: 2)
        }
        .frame(width: size, height: size)
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
    var sourceCaption: String? = nil
    var scopes: [NativeMetricScope] = NativeMetricScope.pickerCases
    var showsNavigationTitle: Bool = true

    var body: some View {
        NativeChrome.screen {
            Picker("Range", selection: Binding(get: { scope }, set: onScope)) {
                ForEach(scopes) { item in
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
                scrolls: scrolls,
                title: title
            )

            if let latest, latest.value.isFinite {
                NativeLatestCapsule(
                    label: "Latest: \(NativeChartDay.mediumDate(latest.key))",
                    value: "\(format(latest.value))\(unit.map { " \($0)" } ?? "")"
                )
            } else {
                NativeLatestCapsule(label: "Latest", value: "Unavailable")
            }
            if let sourceCaption {
                Text(sourceCaption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(sourceCaption)
            }
        }
        .modifier(NativeMetricNavigationTitle(title: title, enabled: showsNavigationTitle))
    }
}

private struct NativeMetricNavigationTitle: ViewModifier {
    var title: String
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .navigationTitle(title)
                .modifier(NativeInlineTitle())
        } else {
            content
        }
    }
}

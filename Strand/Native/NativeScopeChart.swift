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
    var clockHero: Bool = false
    var isDuration: Bool = false
    var highlightKey: String? = nil
    var higherIsBetter: Bool? = nil
    var previewSelected: String? = nil
    var previewTime: Date? = nil
    var calendar: Calendar = .current
    var accessibilityName: String = "Chart"
    var color: ((Double) -> Color)? = nil
    var plotHeight: CGFloat = 280
    var scrolls: Bool = false
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
        VStack(alignment: .leading, spacing: 8) {
            NativeScopeHeroView(
                series: series,
                visible: window,
                hourPoints: hourPoints,
                usesHours: usesHours,
                hourBars: hourBars,
                scrub: scrub,
                format: format,
                unit: unit,
                clockHero: clockHero,
                higherIsBetter: higherIsBetter,
                calendar: calendar,
                color: color,
                title: title
            )
            NativeChrome.panel {
                if series.typical != nil, !usesHours {
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.secondary.opacity(0.18))
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
                    isDuration: isDuration,
                    calendar: calendar,
                    color: color,
                    plotHeight: plotHeight,
                    scrolls: scrolls,
                    usesHours: usesHours,
                    hourBars: hourBars,
                    previewTime: previewTime,
                    scrub: scrub,
                    scrollDate: $scrollDate,
                    chartTitle: accessibilityName,
                    chartUnit: unit ?? ""
                )
            }
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
            if scrub.key == nil,
               let preview = previewSelected,
               window.contains(where: { $0.key == preview && $0.value != nil }) {
                scrub.key = preview
            }
            if scrub.time == nil { scrub.time = previewTime }
        }
        .modifier(NativeScopeResetOnScope(scope: series.scope) {
            scrub.key = nil
            scrub.time = nil
            scrollDate = series.latestWindow().first?.start
        })
    }
}

extension View {
    /// Clip marks to the plot. Swift Charts already lays axis labels outside the plot.
    ///
    /// Do not pad inside `chartPlotStyle`: padding there moves the marks and gridlines but not the
    /// axis labels, so the labels drift off their gridlines and the x labels land inside the plot.
    /// Extra room above the plot (the stress chart's icon lane) goes on the chart view instead.
    func nativeClippedChartPlot(top: CGFloat = 0) -> some View {
        chartPlotStyle { plot in plot.clipped() }
            .padding(.top, top)
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

/// Caption / value / date / period-delta chip.
/// Height depends on the series (delta), never on the scrub tick.
private struct NativeScopeHeroView: View {
    var series: NativeScopeSeries
    var visible: [NativeScopeBucket]
    var hourPoints: [NativeHourPoint]
    var usesHours: Bool
    var hourBars: Bool
    @ObservedObject var scrub: NativeScopeScrub
    var format: (Double) -> String
    var unit: String?
    var clockHero: Bool
    var higherIsBetter: Bool?
    var calendar: Calendar
    var color: ((Double) -> Color)?
    var title: String

    private let footnoteHeight: CGFloat = 22

    private var selectedBucket: NativeScopeBucket? {
        NativeScopeVisible.selected(key: scrub.key, in: visible)
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

    private var heroHeight: CGFloat {
        var height: CGFloat = 76
        if deltaCaption != nil { height += 6 + footnoteHeight }
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
            if clockHero, let minutes = heroMinutes {
                NativeClockHero(
                    caption: isScrubbing ? nil : series.caption,
                    minutes: minutes,
                    date: dateText
                )
            } else {
                NativeHeroValue(
                    caption: isScrubbing ? nil : series.caption,
                    value: valueText,
                    unit: unit,
                    date: dateText,
                    valueTint: valueTint
                )
            }
            if deltaCaption != nil {
                periodDeltaRow
                    .frame(height: footnoteHeight, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: heroHeight, maxHeight: heroHeight, alignment: .topLeading)
        .modifier(NativeSelectionFeedback(trigger: scrub.key ?? scrub.time.map { "\($0.timeIntervalSince1970)" } ?? ""))
    }

    private var heroMinutes: Double? {
        if usesHours, let hour = selectedHour {
            return hour.value
        }
        if let bucket = selectedBucket, let value = bucket.value {
            return value
        }
        if series.kind == .total, let total = series.aggregate(of: visible) {
            return total
        }
        if usesHours, let average = NativeScoreMath.mean(hourPoints.map(\.value)) {
            return average
        }
        return series.aggregate(of: visible)
    }

    private var valueText: String {
        heroMinutes.map(format) ?? "—"
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

}

/// Chart host. Does not observe `scrub`, so mark building is not on the scrub path.
private struct NativeScopePlotHost: View {
    var series: NativeScopeSeries
    var visible: [NativeScopeBucket]
    var hourPoints: [NativeHourPoint]
    var bars: Bool
    var tint: Color
    var format: (Double) -> String
    var isDuration: Bool
    var calendar: Calendar
    var color: ((Double) -> Color)?
    var plotHeight: CGFloat
    var scrolls: Bool
    var usesHours: Bool
    var hourBars: Bool
    var previewTime: Date?
    @ObservedObject var scrub: NativeScopeScrub
    @Binding var scrollDate: Date?
    var chartTitle: String
    var chartUnit: String

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
                NativeScopeHourLineChart(
                    points: hourPoints,
                    tint: tint,
                    format: format,
                    calendar: calendar,
                    previewTime: previewTime,
                    scrub: scrub,
                    timeBinding: timeBinding
                )
            } else if series.known.isEmpty {
                NativeScopeEmptyChart(bars: bars, tint: tint, format: format, isDuration: isDuration)
            } else {
                scopedChart
            }
        }
        .onChangeCompat(of: series.scope) { _ in selectedTime = nil }
        .frame(height: plotHeight)
        .nativeChartDescriptor(scopeDescriptor)
    }

    private var scopeDescriptor: NativeChartDescriptor {
        if usesHours {
            let values = hourPoints.map(\.value)
            return NativeChartDescriptor(
                title: chartTitle,
                unit: chartUnit,
                xKind: .date,
                points: hourPoints.map {
                    NativeChartDescriptor.Point(
                        xLabel: NativeScopeFormat.time($0.time),
                        xValue: $0.time.timeIntervalSince1970,
                        y: $0.value
                    )
                },
                yRange: NativeChartDescriptor.yRange(of: values)
            )
        }
        let known = series.buckets.compactMap { bucket -> NativeChartDescriptor.Point? in
            guard let value = bucket.value else { return nil }
            return NativeChartDescriptor.Point(
                xLabel: series.selectionDateText(for: bucket, calendar: calendar),
                xValue: bucket.start.timeIntervalSince1970,
                y: value
            )
        }
        return NativeChartDescriptor(
            title: chartTitle,
            unit: chartUnit,
            xKind: series.scope == .day ? .date : .category,
            points: known,
            yRange: NativeChartDescriptor.yRange(of: known.map(\.y))
        )
    }

    @State private var selectedTime: Date?

    private var timeBinding: Binding<Date?> {
        Binding(
            get: { selectedTime },
            set: { time in
                if usesHours {
                    selectedTime = time
                    scrub.time = time
                    scrub.key = nil
                } else if let snapped = NativeChartScrubMath.snapBucket(
                    date: time, buckets: visible, bars: bars
                ) {
                    selectedTime = snapped.time
                    scrub.time = snapped.time
                    scrub.key = snapped.key
                } else {
                    selectedTime = nil
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
        let windowDomain = NativeScopePlotMath.paddedXDomain(buckets: visible, bars: bars)
        let visibleLength = windowDomain.upperBound.timeIntervalSince(windowDomain.lowerBound)
        let leading = scrollDate ?? windowDomain.lowerBound
        if bars {
            NativeScopeBarSelectingChart(
                series: series,
                plotBuckets: plotBuckets,
                visible: visible,
                tint: tint,
                format: format,
                isDuration: isDuration,
                calendar: calendar,
                color: color,
                scrolls: scrolls,
                scrub: scrub,
                scrollDate: $scrollDate,
                timeBinding: timeBinding,
                visibleLength: visibleLength,
                leading: leading
            )
        } else if scrolls, #available(iOS 17.0, macOS 14.0, *) {
            lineMarks
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: visibleLength)
                .chartScrollPosition(x: Binding(
                    get: { leading },
                    set: { scrollDate = $0 }
                ))
                .chartXSelection(value: timeBinding)
                .chartOverlay { proxy in
                    NativeScopeHairline(
                        proxy: proxy, visible: visible, scrub: scrub, tint: tint, format: format, color: color
                    )
                }
        } else if #available(iOS 17.0, macOS 14.0, *) {
            lineMarks
                .chartXSelection(value: timeBinding)
                .chartOverlay { proxy in
                    NativeScopeHairline(
                        proxy: proxy, visible: visible, scrub: scrub, tint: tint, format: format, color: color
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
            isDuration: isDuration,
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
    var isDuration: Bool
    var calendar: Calendar
    var color: ((Double) -> Color)?
    var scrolls: Bool
    @ObservedObject var scrub: NativeScopeScrub
    @Binding var scrollDate: Date?
    var timeBinding: Binding<Date?>
    var visibleLength: TimeInterval
    var leading: Date

    var body: some View {
        let marks = NativeScopeStaticChart(
            series: series,
            plotBuckets: plotBuckets,
            visible: visible,
            bars: true,
            tint: tint,
            format: format,
            isDuration: isDuration,
            calendar: calendar,
            color: color,
            selectedKey: scrub.key
        )
        Group {
            if scrolls, #available(iOS 17.0, macOS 14.0, *) {
                marks
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: visibleLength)
                    .chartScrollPosition(x: Binding(
                        get: { leading },
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
    var visible: [NativeScopeBucket]
    @ObservedObject var scrub: NativeScopeScrub
    var tint: Color
    var format: (Double) -> String
    var color: ((Double) -> Color)?

    var body: some View {
        GeometryReader { geo in
            if let key = scrub.key,
               let bucket = NativeScopeVisible.selected(key: key, in: visible),
               let value = bucket.value {
                let frame = NativeChartScrubMath.plotFrame(proxy: proxy, geo: geo)
                let activeTint = color?(value) ?? tint
                ZStack(alignment: .topLeading) {
                    NativeChartTimeScrubGuide(
                        proxy: proxy,
                        time: bucket.start,
                        y: value,
                        tint: activeTint
                    )
                    if let xRel = proxy.position(forX: bucket.start) {
                        let rawX = frame.origin.x + xRel
                        let clampedX = min(max(rawX, frame.minX + 20), frame.maxX - 20)
                        Text(format(value))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .monospacedDigit()
                            .position(x: clampedX, y: max(10, frame.minY - 11))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Hour-line scrub cursor. Observes `scrub` so LineMarks stay on the static chart.
private struct NativeScopeHourScrub: View {
    var proxy: ChartProxy
    var points: [NativeHourPoint]
    @ObservedObject var scrub: NativeScopeScrub
    var tint: Color

    var body: some View {
        if let time = scrub.time,
           let point = NativeChartScrubMath.nearestHour(
            to: time,
            in: points,
            maxGap: NativeChartScrubMath.inferredMaxGap(in: points)
           ) {
            NativeChartTimeScrubGuide(
                proxy: proxy,
                time: point.time,
                y: point.value,
                tint: tint
            )
        }
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
    var isDuration: Bool
    var calendar: Calendar
    var color: ((Double) -> Color)?
    var selectedKey: String? = nil

    var body: some View {
        let known = plotBuckets.filter { $0.value != nil }
        let visibleKnown = visible.filter { $0.value != nil }
        let values = visibleKnown.compactMap(\.value)
        let barCeiling = max(values.max() ?? known.compactMap(\.value).max() ?? 1, 1)
        let durationTop = NativeMetricFormat.durationCeiling(maxMinutes: barCeiling)
        let barTop = isDuration ? durationTop : NativeCountTicks.niceCeiling(barCeiling)
        let domainValues = values.isEmpty ? known.compactMap(\.value) : values
        let yDomain: ClosedRange<Double>
        if isDuration {
            yDomain = 0...barTop
        } else if bars {
            yDomain = 0...barTop
        } else {
            yDomain = NativeScopeYTicks.niceDomain(domainValues, fallback: 0...1)
        }
        let yTicks: [Double]
        if isDuration {
            yTicks = NativeMetricFormat.durationAxisTicks(maxMinutes: barCeiling)
        } else if bars {
            yTicks = NativeCountTicks.values(ceiling: barCeiling)
        } else {
            yTicks = NativeScopeYTicks.values(in: yDomain)
        }
        let xDomain = NativeScopePlotMath.paddedXDomain(buckets: plotBuckets, bars: bars)
        let segments = NativeScopePlotMath.lineSegments(plotBuckets).filter {
            $0.date >= xDomain.lowerBound && $0.date <= xDomain.upperBound
        }
        let visibleKeys = Set(visibleKnown.map(\.key))
        let showVertices = NativeScopePlotMath.showsVertices(
            scope: series.scope, knownCount: visibleKnown.count
        )
        let average = series.showsTrendLine ? series.aggregate(of: visible) : nil
        let lineTint = color == nil ? tint : Color.secondary
        let band = NativeScopePlotMath.clippedTypical(series.typical, yDomain: yDomain)
        let visibleSegments = NativeScopeVisible.vertexSegments(segments, visibleKeys: visibleKeys)
        let lastKnown = visibleSegments.last
        let barUnit = NativeScopePlotMath.barUnit(scope: series.scope)
        let bandStart = visible.first?.start ?? plotBuckets.first?.start
        let bandEnd = visible.last?.end ?? plotBuckets.last?.end
        return Chart {
            typicalBandMarks(band: band, start: bandStart, end: bandEnd)
            valueMarks(
                xDomain: xDomain, barUnit: barUnit, segments: segments,
                visibleKeys: visibleKeys, showVertices: showVertices,
                lastKnown: lastKnown, lineTint: lineTint, visibleKnownCount: visibleKnown.count
            )
            if let average {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .accessibilityLabel("Period average")
                    .accessibilityValue(format(average))
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .trailing, values: yTicks) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeTokens.separator)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text((bars && !isDuration) ? NativeCountFormat.compact(raw) : format(raw))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: labelDates(in: visible)) { value in
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
        .nativeClippedChartPlot(top: 22)
    }

    @ChartContentBuilder
    private func typicalBandMarks(
        band: ClosedRange<Double>?, start: Date?, end: Date?
    ) -> some ChartContent {
        if let band, let start, let end, end > start {
            RectangleMark(
                xStart: .value("Range start", start),
                xEnd: .value("Range end", end),
                yStart: .value("Typical low", band.lowerBound),
                yEnd: .value("Typical high", band.upperBound)
            )
            .foregroundStyle(Color.secondary.opacity(0.08))
            .accessibilityLabel("Typical range")
            .accessibilityValue(NativeTypicalRange.caption(range: band, format: format, unit: nil))
        }
    }

    @ChartContentBuilder
    private func valueMarks(
        xDomain: ClosedRange<Date>,
        barUnit: Calendar.Component,
        segments: [NativeScopePlotMath.LinePoint],
        visibleKeys: Set<String>,
        showVertices: Bool,
        lastKnown: NativeScopePlotMath.LinePoint?,
        lineTint: Color,
        visibleKnownCount: Int
    ) -> some ChartContent {
        if bars {
            ForEach(plotBuckets.filter { $0.start >= xDomain.lowerBound && $0.start <= xDomain.upperBound }) { bucket in
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
                    .nativeValueLabel(trailing: bucket.key == visible.last?.key) {
                        if bucket.key == selectedKey {
                            Text(format(value))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.primary)
                                .monospacedDigit()
                        }
                    }
                    .accessibilityLabel(series.selectionDateText(for: bucket, calendar: calendar))
                    .accessibilityValue(format(value))
                }
            }
        } else if plotBuckets.contains(where: { $0.low != nil && $0.high != nil }) {
            ForEach(plotBuckets.filter { $0.start >= xDomain.lowerBound && $0.start <= xDomain.upperBound }) { bucket in
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
                ForEach(NativeScopeVisible.vertexSegments(segments, visibleKeys: visibleKeys)) { point in
                    PointMark(x: .value("Day", point.date), y: .value("Value", point.value))
                        .foregroundStyle(color?(point.value) ?? tint)
                        .symbol {
                            NativeScopeVertex(
                                tint: color?(point.value) ?? tint,
                                size: visibleKnownCount <= 4 ? 10 : 8
                            )
                        }
                        .accessibilityLabel(NativeChartDay.longLabel(point.key))
                        .accessibilityValue(format(point.value))
                }
            }
            if let lastKnown, visibleKeys.contains(lastKnown.key) {
                PointMark(x: .value("Day", lastKnown.date), y: .value("Value", lastKnown.value))
                    .foregroundStyle(.clear)
                    .nativeValueLabel(trailing: NativeScopeVisible.isTrailing(lastKnown, visible: visible)) {
                        Text(format(lastKnown.value))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .monospacedDigit()
                            .padding(.horizontal, 2)
                    }
                    .accessibilityHidden(true)
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
            return NativeScopeAxis.monthLabelDates(
                buckets.map(\.start), scope: series.scope, calendar: calendar
            )
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
        let dayStart = calendar.startOfDay(for: points.first?.time ?? Date())
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let xDomain = NativeScopePlotMath.paddedXDomain(start: dayStart, end: dayEnd)
        let drawn = NativeScopePlotMath.clippedHours(points, start: xDomain.lowerBound, end: xDomain.upperBound)
        let ceiling = max(drawn.map(\.value).max() ?? 0, 1)
        let top = NativeCountTicks.niceCeiling(ceiling)
        let labels = NativeCountTicks.roundHourLabels(
            dayStart: dayStart, plotEnd: dayEnd, calendar: calendar
        )
        let selectedTime = selectedPoint?.time
        Chart {
            ForEach(drawn) { point in
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
                .nativeValueLabel(trailing: point.time == drawn.last?.time) {
                    if point.time == selectedTime {
                        Text(format(point.value))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .monospacedDigit()
                    }
                }
                .accessibilityLabel(NativeScopeFormat.hourClock(point.time, calendar: calendar))
                .accessibilityValue(format(point.value))
            }
        }
        .chartYScale(domain: 0...top)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .trailing, values: NativeCountTicks.values(ceiling: ceiling)) { value in
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
            AxisMarks(preset: .aligned, values: labels) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeTokens.separator)
                AxisValueLabel(anchor: NativeDayAxisLabel.anchor(for: value.as(Date.self) ?? .distantPast, in: labels)) {
                    if let date = value.as(Date.self) {
                        Text(NativeScopeFormat.hourClock(date, calendar: calendar))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .nativeClippedChartPlot(top: 22)
        .modifier(NativeTimeSelect(
            selected: timeBinding,
            snap: { NativeChartScrubMath.snapHour(date: $0, points: points, calendar: calendar) },
            onChange: { _ in }
        ))
        .onAppear { if scrub.time == nil { scrub.time = previewTime } }
    }
}

/// Day-scope line (HR). Same clip / domain / outside-axis contract as the bar and range plots.
private struct NativeScopeHourLineChart: View {
    var points: [NativeHourPoint]
    var tint: Color
    var format: (Double) -> String
    var calendar: Calendar
    var previewTime: Date?
    @ObservedObject var scrub: NativeScopeScrub
    var timeBinding: Binding<Date?>

    var body: some View {
        let dayStart = calendar.startOfDay(for: points.first?.time ?? Date())
        let last = points.last?.time ?? dayStart
        let plotEnd = max(last, dayStart)
        let xDomain = NativeScopePlotMath.paddedXDomain(start: dayStart, end: plotEnd)
        let drawn = NativeScopePlotMath.clippedHours(points, start: xDomain.lowerBound, end: xDomain.upperBound)
        let yDomain = NativeScopeYTicks.niceDomain(drawn.map(\.value), fallback: 40...90)
        let labels = NativeCountTicks.roundHourLabels(
            dayStart: dayStart, plotEnd: plotEnd, calendar: calendar
        )
        Chart {
            ForEach(drawn) { point in
                LineMark(x: .value("Time", point.time), y: .value("Value", point.value))
                    .foregroundStyle(tint)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                    .accessibilityLabel(NativeScopeFormat.time(point.time))
                    .accessibilityValue(format(point.value))
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .trailing, values: NativeScopeYTicks.values(in: yDomain)) { value in
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
            AxisMarks(preset: .aligned, values: labels) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeTokens.separator)
                AxisValueLabel(anchor: NativeDayAxisLabel.anchor(for: value.as(Date.self) ?? .distantPast, in: labels)) {
                    if let date = value.as(Date.self) {
                        Text(NativeScopeFormat.hourClock(date, calendar: calendar))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .nativeClippedChartPlot()
        .chartOverlay { proxy in
            NativeScopeHourScrub(proxy: proxy, points: drawn, scrub: scrub, tint: tint)
        }
        .modifier(NativeTimeSelect(
            selected: timeBinding,
            snap: { NativeChartScrubMath.snapTime($0, in: points) },
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
    var isDuration: Bool

    var body: some View {
        let top = isDuration
            ? NativeMetricFormat.durationCeiling(maxMinutes: 1)
            : (bars ? NativeCountTicks.niceCeiling(1) : 1.0)
        let ticks = isDuration
            ? NativeMetricFormat.durationAxisTicks(maxMinutes: 1)
            : (bars ? NativeCountTicks.values(ceiling: 1) : [0, 1])
        Chart {
            if bars {
                BarMark(x: .value("Day", Date()), y: .value("Value", 0))
                    .foregroundStyle(tint.opacity(0.001))
                    .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: 0...top)
        .chartXScale(domain: NativeScopePlotMath.paddedXDomain(start: Date(), end: Date().addingTimeInterval(86_400)))
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .trailing, values: ticks) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeTokens.separator)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text((bars && !isDuration) ? NativeCountFormat.compact(raw) : format(raw))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis(.hidden)
        .nativeClippedChartPlot()
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
    var clockHero: Bool = false
    var isDuration: Bool = false
    var highlightKey: String?
    var higherIsBetter: Bool?
    var latest: NativeDayPoint?
    var previewSelected: String? = nil
    var previewTime: Date? = nil
    var calendar: Calendar = .current
    var color: ((Double) -> Color)? = nil
    var scrolls: Bool = false
    var sourceCaption: String? = nil
    var scopes: [NativeMetricScope] = NativeMetricScope.pickerCases
    var showsNavigationTitle: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NativeChrome.screen {
            Picker("Range", selection: Binding(
                get: { scope },
                set: { new in NativeContinuity.animate(reduced: reduceMotion) { onScope(new) } }
            )) {
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
                clockHero: clockHero,
                isDuration: isDuration,
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
                NativeLatestCapsule(label: "Latest", value: "No reading yet")
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

/// One label per month on 6M / Y axes. A window that opens in the last days of a month puts that
/// month's first bucket one week before the next month's, so "May" and "Jun" printed on top of each
/// other. Labels closer than `minGap` buckets keep the one nearer the 1st of its month.
enum NativeScopeAxis {
    static func minGap(for scope: NativeMetricScope) -> Int {
        scope == .sixMonths ? 3 : 1
    }

    static func monthLabelDates(_ starts: [Date], scope: NativeMetricScope, calendar: Calendar) -> [Date] {
        monthLabelDates(starts, minGap: minGap(for: scope), calendar: calendar)
    }

    static func monthLabelDates(_ starts: [Date], minGap: Int, calendar: Calendar) -> [Date] {
        var seen = Set<Int>()
        var kept: [(index: Int, date: Date)] = []
        for (index, date) in starts.enumerated() {
            let month = calendar.component(.month, from: date) + calendar.component(.year, from: date) * 12
            guard seen.insert(month).inserted else { continue }
            if let last = kept.last, index - last.index < minGap {
                if calendar.component(.day, from: date) < calendar.component(.day, from: last.date) {
                    kept[kept.count - 1] = (index, date)
                }
                continue
            }
            kept.append((index, date))
        }
        return kept.map(\.date)
    }
}

/// Hero, hairline, and vertex chrome may only touch buckets inside the visible window.
enum NativeScopeVisible {
    static func selected(key: String?, in visible: [NativeScopeBucket]) -> NativeScopeBucket? {
        guard let key else { return nil }
        return visible.first { $0.key == key && $0.value != nil }
    }

    static func vertexSegments(
        _ segments: [NativeScopePlotMath.LinePoint],
        visibleKeys: Set<String>
    ) -> [NativeScopePlotMath.LinePoint] {
        segments.filter { visibleKeys.contains($0.key) }
    }

    static func isTrailing(_ point: NativeScopePlotMath.LinePoint, visible: [NativeScopeBucket]) -> Bool {
        point.key == visible.last?.key
    }
}

extension ChartContent {
    /// Value label above a bar / vertex. The plot is clipped, so a label on the tallest bar (or the
    /// scrubbed one) used to lose its top half, and edge labels lost their sides. On iOS the label
    /// is nudged back inside the plot instead. The last visible bucket uses a trailing anchor so
    /// multi-digit values like "49" stay fully inside the plot.
    func nativeValueLabel<Label: View>(
        trailing: Bool = false,
        @ViewBuilder _ label: @escaping () -> Label
    ) -> some ChartContent {
        #if os(iOS)
        annotation(
            position: .top,
            alignment: trailing ? .trailing : .center,
            spacing: 4,
            overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
        ) {
            label().offset(x: trailing ? -4 : 0)
        }
        #else
        annotation(position: .top, alignment: trailing ? .trailing : .center, spacing: 4) {
            label().offset(x: trailing ? -4 : 0)
        }
        #endif
    }
}

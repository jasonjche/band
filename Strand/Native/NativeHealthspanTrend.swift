import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

struct NativeHealthspanTrendCard: View {
    var points: [HealthspanEngine.TrendPoint]
    var kind: NativeHealthspanTrendKind
    @Environment(\.nativeStyle) private var style
    @Environment(\.nativeNavigationPath) private var navigationPath
    @Environment(\.nativeContinuityActiveID) private var continuityID

    var body: some View {
        NativeChrome.panel {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    continuityID.select(.healthspanTrend(kind))
                    navigationPath.wrappedValue.append(kind)
                } label: {
                    HStack {
                        Text(kind.title.uppercased())
                            .font(style == .whoop ? NativeTokens.whoopCaps(11) : .caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens \(kind.title)")
                if kind == .bandAge {
                    NativeHealthspanBandAgeLegend()
                }
                NativeHealthspanTrendPlot(points: points, kind: kind, scope: .sixMonths)
                    .equatable()
            }
        }
        .nativeZoomSource(.healthspanTrend(kind))
    }
}

struct NativeHealthspanTrendPage: View {
    var kind: NativeHealthspanTrendKind
    var points: [HealthspanEngine.TrendPoint]
    @State private var scope: NativeHealthspanTrendScope = .sixMonths
    @Environment(\.nativeStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NativeChrome.screen {
            Picker("Scope", selection: Binding(
                get: { scope },
                set: { new in NativeContinuity.animate(reduced: reduceMotion) { scope = new } }
            )) {
                ForEach(NativeHealthspanTrendScope.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            NativeChrome.panel {
                VStack(alignment: .leading, spacing: 12) {
                    if kind == .bandAge {
                        NativeHealthspanBandAgeLegend()
                    }
                    NativeHealthspanTrendPlot(points: points, kind: kind, scope: scope)
                        .equatable()
                }
            }
        }
        .navigationTitle(kind.title)
        .modifier(NativeInlineTitle())
    }
}

struct NativeHealthspanBandAgeLegend: View {
    @Environment(\.nativeStyle) private var style

    var body: some View {
        HStack(spacing: 12) {
            swatch(NativePaint.recovery(style), "Your Band Age")
            swatch(Color.primary.opacity(0.7), "Chronological age")
            Spacer(minLength: 0)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your Band Age and chronological age")
    }

    private func swatch(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(title)
        }
    }
}

struct NativeHealthspanTrendPlot: View, Equatable {
    var points: [HealthspanEngine.TrendPoint]
    var kind: NativeHealthspanTrendKind
    var scope: NativeHealthspanTrendScope

    static func == (lhs: NativeHealthspanTrendPlot, rhs: NativeHealthspanTrendPlot) -> Bool {
        lhs.points == rhs.points && lhs.kind == rhs.kind && lhs.scope == rhs.scope
    }

    var body: some View {
        NativeHealthspanTrendChart(
            model: NativeHealthspanTrendModel.make(points: points, kind: kind, scope: scope)
        )
    }
}

/// Immutable chart payload. Built once per (points, kind, scope), never inside a scroll-driven body.
struct NativeHealthspanTrendModel: Equatable {
    struct PlotPoint: Identifiable, Equatable {
        var id: String
        var day: Date
        var bandAge: Double
        var chronoAge: Double
        var pace: Double?
    }

    struct Tick: Equatable {
        var value: Double
        var label: String
    }

    struct DateTick: Equatable {
        var date: Date
        var label: String
    }

    var kind: NativeHealthspanTrendKind
    var inWindow: [PlotPoint]
    var steppedBandAge: [PlotPoint]
    var xDomain: ClosedRange<Date>
    var ageDomain: ClosedRange<Double>
    var paceDomain: ClosedRange<Double>
    var ageYTicks: [Tick]
    var paceYTicks: [Tick]
    var monthTicks: [DateTick]
    var lastChronoLabel: String?
    var lastBandAgeLabel: String?
    var lastPaceLabel: String?
    var lastChrono: PlotPoint?
    var lastBand: PlotPoint?
    var lastPace: PlotPoint?
    var showPaceRule: Bool

    static func make(
        points: [HealthspanEngine.TrendPoint],
        kind: NativeHealthspanTrendKind,
        scope: NativeHealthspanTrendScope,
        calendar: Calendar = .current
    ) -> NativeHealthspanTrendModel {
        let plot: [PlotPoint] = NativeHealthspanTrendScope.windowed(points, scope: scope)
            .enumerated()
            .compactMap { index, point in
                guard let day = NativeDayLogic.startOfLocalDay(point.day) else { return nil }
                return PlotPoint(
                    id: "\(point.day)-\(index)",
                    day: day,
                    bandAge: point.bandAge,
                    chronoAge: point.chronoAge,
                    pace: point.pace
                )
            }
        let stepped = steppedBandAge(plot)
        let xDomain: ClosedRange<Date> = {
            guard let first = plot.first, let last = plot.last, last.day >= first.day else {
                let now = Date()
                return now...now.addingTimeInterval(86_400)
            }
            return first.day...last.day
        }()
        let ageDomain = NativePlotAxis.yDomain(
            plot.flatMap { [$0.bandAge, $0.chronoAge] },
            fallback: 20...40
        )
        let paceDomain = NativePlotAxis.yDomain(
            plot.compactMap(\.pace) + [1],
            fallback: 0...2
        )
        let inWindow = plot.filter { NativePlotAxis.inTimeDomain($0.day, xDomain) }
        let last = inWindow.last
        let lastChrono = last.flatMap { NativePlotAxis.inValueDomain($0.chronoAge, ageDomain) ? $0 : nil }
        let lastBand = last.flatMap { NativePlotAxis.inValueDomain($0.bandAge, ageDomain) ? $0 : nil }
        let lastPace = last.flatMap { point -> PlotPoint? in
            guard let pace = point.pace, NativePlotAxis.inValueDomain(pace, paceDomain) else { return nil }
            return point
        }
        return NativeHealthspanTrendModel(
            kind: kind,
            inWindow: inWindow,
            steppedBandAge: stepped,
            xDomain: xDomain,
            ageDomain: ageDomain,
            paceDomain: paceDomain,
            ageYTicks: NativePlotAxis.yTicks(in: ageDomain).map {
                Tick(value: $0, label: NativeHealthspanFormat.ageText($0))
            },
            paceYTicks: NativePlotAxis.yTicks(in: paceDomain).map {
                Tick(value: $0, label: NativeHealthspanFormat.paceText($0))
            },
            monthTicks: NativePlotAxis.monthTicks(start: xDomain.lowerBound, end: xDomain.upperBound, calendar: calendar).map {
                DateTick(date: $0, label: NativeScopeFormat.month($0, calendar: calendar))
            },
            lastChronoLabel: lastChrono.map { NativeHealthspanFormat.ageText($0.chronoAge) },
            lastBandAgeLabel: lastBand.map { NativeHealthspanFormat.ageText($0.bandAge) },
            lastPaceLabel: lastPace.flatMap(\.pace).map(NativeHealthspanFormat.paceText),
            lastChrono: lastChrono,
            lastBand: lastBand,
            lastPace: lastPace,
            showPaceRule: NativePlotAxis.inValueDomain(1, paceDomain)
        )
    }

    /// Hold-then-jump Band Age, matching WHOOP's weekly steps.
    static func steppedBandAge(_ plot: [PlotPoint]) -> [PlotPoint] {
        guard plot.count >= 2 else { return plot }
        var out: [PlotPoint] = []
        out.reserveCapacity(plot.count * 2)
        for index in 0..<(plot.count - 1) {
            let current = plot[index]
            let next = plot[index + 1]
            out.append(current)
            out.append(PlotPoint(
                id: "\(current.id)-hold",
                day: next.day,
                bandAge: current.bandAge,
                chronoAge: current.chronoAge,
                pace: current.pace
            ))
        }
        if let last = plot.last { out.append(last) }
        return out
    }
}

enum NativeHealthspanTrendMath {
    static func nearest(
        to date: Date?,
        in points: [NativeHealthspanTrendModel.PlotPoint]
    ) -> NativeHealthspanTrendModel.PlotPoint? {
        guard let date, let snapped = NativeChartScrubMath.snapDate(date, in: points.map(\.day)) else {
            return nil
        }
        return points.first { $0.day == snapped }
    }
}

private struct NativeHealthspanTrendChart: View {
    var model: NativeHealthspanTrendModel
    @Environment(\.nativeStyle) private var style
    @State private var selected: Date?

    private var selectedPoint: NativeHealthspanTrendModel.PlotPoint? {
        NativeHealthspanTrendMath.nearest(to: selected, in: model.inWindow)
    }

    private var timeBinding: Binding<Date?> {
        Binding(
            get: { selected },
            set: { selected = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            readout
            if model.kind == .bandAge {
                ageChart.modifier(scrubChrome(height: 180))
            } else {
                paceChart.modifier(scrubChrome(height: 160))
            }
        }
        .modifier(NativeSelectionFeedback(trigger: selectedPoint?.id ?? ""))
        .onChangeCompat(of: model.xDomain.lowerBound) { _ in selected = nil }
        .onChangeCompat(of: model.kind) { _ in selected = nil }
    }

    private func scrubChrome(height: CGFloat) -> NativeHealthspanScrubChrome {
        NativeHealthspanScrubChrome(
            model: model,
            selected: timeBinding,
            point: selectedPoint,
            style: style,
            height: height
        )
    }

    @ViewBuilder private var readout: some View {
        if let point = selectedPoint {
            Text(readoutText(point))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .frame(height: 18, alignment: .leading)
        } else {
            Color.clear.frame(height: 18)
        }
    }

    private func readoutText(_ point: NativeHealthspanTrendModel.PlotPoint) -> String {
        let date = NativeScopeFormat.weekdayDate(point.day, calendar: .current)
        if model.kind == .bandAge {
            return "\(date)  \(NativeHealthspanFormat.ageText(point.bandAge))"
        }
        if let pace = point.pace {
            return "\(date)  \(NativeHealthspanFormat.paceText(pace))"
        }
        return date
    }

    private var ageChart: some View {
        Chart {
            ForEach(model.inWindow) { point in
                if NativePlotAxis.inValueDomain(point.chronoAge, model.ageDomain) {
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Age", point.chronoAge),
                        series: .value("Kind", "Chronological")
                    )
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            ForEach(model.steppedBandAge) { point in
                if NativePlotAxis.inValueDomain(point.bandAge, model.ageDomain) {
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Age", point.bandAge),
                        series: .value("Kind", "Band Age")
                    )
                    .foregroundStyle(NativePaint.recovery(style))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            if selectedPoint == nil, let last = model.lastChrono, let label = model.lastChronoLabel {
                PointMark(
                    x: .value("Day", last.day),
                    y: .value("Age", last.chronoAge)
                )
                .foregroundStyle(Color.primary)
                .symbolSize(36)
                .annotation(position: .trailing, spacing: 4) {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary)
                }
            }
            if selectedPoint == nil, let last = model.lastBand, let label = model.lastBandAgeLabel {
                PointMark(
                    x: .value("Day", last.day),
                    y: .value("Age", last.bandAge)
                )
                .foregroundStyle(NativePaint.recovery(style))
                .symbolSize(36)
                .annotation(position: .trailing, spacing: 4) {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(NativePaint.recovery(style))
                }
            }
        }
        .chartXScale(domain: model.xDomain)
        .chartYScale(domain: model.ageDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: model.ageYTicks.map(\.value)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let age = value.as(Double.self),
                       let tick = model.ageYTicks.first(where: { $0.value == age }) {
                        Text(tick.label)
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: model.monthTicks.map(\.date)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let date = value.as(Date.self),
                       let tick = model.monthTicks.first(where: { $0.date == date }) {
                        Text(tick.label)
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }

    private var paceChart: some View {
        Chart {
            ForEach(model.inWindow) { point in
                if let pace = point.pace, NativePlotAxis.inValueDomain(pace, model.paceDomain) {
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Pace", pace)
                    )
                    .foregroundStyle(NativePaint.strain(style))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            if model.showPaceRule {
                RuleMark(y: .value("1x", 1.0))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if selectedPoint == nil, let last = model.lastPace, let pace = last.pace, let label = model.lastPaceLabel {
                PointMark(
                    x: .value("Day", last.day),
                    y: .value("Pace", pace)
                )
                .foregroundStyle(NativePaint.strain(style))
                .symbolSize(36)
                .annotation(position: .trailing, spacing: 4) {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(NativePaint.strain(style))
                }
            }
        }
        .chartXScale(domain: model.xDomain)
        .chartYScale(domain: model.paceDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: model.paceYTicks.map(\.value)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let pace = value.as(Double.self),
                       let tick = model.paceYTicks.first(where: { $0.value == pace }) {
                        Text(tick.label)
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: model.monthTicks.map(\.date)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let date = value.as(Date.self),
                       let tick = model.monthTicks.first(where: { $0.date == date }) {
                        Text(tick.label)
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }
}

private struct NativeHealthspanScrubChrome: ViewModifier {
    var model: NativeHealthspanTrendModel
    var selected: Binding<Date?>
    var point: NativeHealthspanTrendModel.PlotPoint?
    var style: NativeStyle
    var height: CGFloat

    func body(content: Content) -> some View {
        content
            .nativeClippedChartPlot()
            .frame(height: height)
            .chartOverlay { proxy in
                NativeHealthspanScrubGuide(
                    proxy: proxy,
                    model: model,
                    point: point,
                    style: style
                )
            }
            .modifier(NativeTimeSelect(
                selected: selected,
                snap: { NativeChartScrubMath.snapDate($0, in: model.inWindow.map(\.day)) },
                onChange: { _ in }
            ))
    }
}

private struct NativeHealthspanScrubGuide: View {
    var proxy: ChartProxy
    var model: NativeHealthspanTrendModel
    var point: NativeHealthspanTrendModel.PlotPoint?
    var style: NativeStyle

    var body: some View {
        if let point {
            if model.kind == .bandAge {
                NativeChartTimeScrubGuide(
                    proxy: proxy,
                    time: point.day,
                    y: NativePlotAxis.inValueDomain(point.bandAge, model.ageDomain) ? point.bandAge : nil,
                    tint: NativePaint.recovery(style),
                    extra: NativePlotAxis.inValueDomain(point.chronoAge, model.ageDomain)
                        ? [(y: point.chronoAge, tint: Color.primary)]
                        : []
                )
            } else if let pace = point.pace, NativePlotAxis.inValueDomain(pace, model.paceDomain) {
                NativeChartTimeScrubGuide(
                    proxy: proxy,
                    time: point.day,
                    y: pace,
                    tint: NativePaint.strain(style)
                )
            }
        }
    }
}

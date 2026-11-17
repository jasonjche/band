import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

struct NativeHealthspanTrendCard: View {
    var points: [HealthspanEngine.TrendPoint]
    var kind: NativeHealthspanTrendKind
    @Environment(\.nativeStyle) private var style
    @Environment(\.nativeNavigationPath) private var navigationPath

    var body: some View {
        Button {
            navigationPath.wrappedValue.append(kind)
        } label: {
            NativeChrome.panel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(kind.title.uppercased())
                            .font(style == .whoop ? NativeTokens.whoopCaps(11) : .caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    if kind == .bandAge {
                        NativeHealthspanBandAgeLegend()
                    }
                    NativeHealthspanTrendPlot(points: points, kind: kind, scope: .sixMonths)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(kind.title)")
    }
}

struct NativeHealthspanTrendPage: View {
    var kind: NativeHealthspanTrendKind
    var points: [HealthspanEngine.TrendPoint]
    @State private var scope: NativeHealthspanTrendScope = .sixMonths
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.screen {
            Picker("Scope", selection: $scope) {
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

struct NativeHealthspanTrendPlot: View {
    var points: [HealthspanEngine.TrendPoint]
    var kind: NativeHealthspanTrendKind
    var scope: NativeHealthspanTrendScope
    @Environment(\.nativeStyle) private var style

    private struct PlotPoint: Identifiable {
        var id: String
        var day: Date
        var bandAge: Double
        var chronoAge: Double
        var pace: Double?
    }

    private var plot: [PlotPoint] {
        NativeHealthspanTrendScope.windowed(points, scope: scope).enumerated().compactMap { index, point in
            guard let day = NativeDayLogic.startOfLocalDay(point.day) else { return nil }
            return PlotPoint(
                id: "\(point.day)-\(index)",
                day: day,
                bandAge: point.bandAge,
                chronoAge: point.chronoAge,
                pace: point.pace
            )
        }
    }

    /// Hold-then-jump Band Age, matching WHOOP's weekly steps.
    private var steppedBandAge: [PlotPoint] {
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

    private var xDomain: ClosedRange<Date> {
        guard let first = plot.first, let last = plot.last, last.day >= first.day else {
            let now = Date()
            return now...now.addingTimeInterval(86_400)
        }
        return first.day...last.day
    }

    private var ageDomain: ClosedRange<Double> {
        let values = plot.flatMap { [$0.bandAge, $0.chronoAge] }
        return NativePlotAxis.yDomain(values, fallback: 20...40)
    }

    private var paceDomain: ClosedRange<Double> {
        let values = plot.compactMap(\.pace) + [1]
        return NativePlotAxis.yDomain(values, fallback: 0...2)
    }

    private var inWindow: [PlotPoint] {
        plot.filter { NativePlotAxis.inTimeDomain($0.day, xDomain) }
    }

    var body: some View {
        Group {
            if kind == .bandAge {
                ageChart
            } else {
                paceChart
            }
        }
        .nativeClippedChartPlot()
        .frame(height: kind == .bandAge ? 180 : 160)
    }

    private var ageChart: some View {
        Chart {
            ForEach(inWindow) { point in
                if NativePlotAxis.inValueDomain(point.chronoAge, ageDomain) {
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
            ForEach(steppedBandAge) { point in
                if NativePlotAxis.inValueDomain(point.bandAge, ageDomain) {
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
            if let last = inWindow.last, NativePlotAxis.inValueDomain(last.chronoAge, ageDomain) {
                PointMark(
                    x: .value("Day", last.day),
                    y: .value("Age", last.chronoAge)
                )
                .foregroundStyle(Color.primary)
                .symbolSize(36)
                .annotation(position: .trailing, spacing: 4) {
                    Text(NativeHealthspanFormat.ageText(last.chronoAge))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary)
                }
            }
            if let last = inWindow.last, NativePlotAxis.inValueDomain(last.bandAge, ageDomain) {
                PointMark(
                    x: .value("Day", last.day),
                    y: .value("Age", last.bandAge)
                )
                .foregroundStyle(NativePaint.recovery(style))
                .symbolSize(36)
                .annotation(position: .trailing, spacing: 4) {
                    Text(NativeHealthspanFormat.ageText(last.bandAge))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(NativePaint.recovery(style))
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: ageDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: NativePlotAxis.yTicks(in: ageDomain)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let age = value.as(Double.self) {
                        Text(NativeHealthspanFormat.ageText(age))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: NativePlotAxis.monthTicks(start: xDomain.lowerBound, end: xDomain.upperBound)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(NativeScopeFormat.month(date, calendar: .current))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }

    private var paceChart: some View {
        Chart {
            ForEach(inWindow) { point in
                if let pace = point.pace, NativePlotAxis.inValueDomain(pace, paceDomain) {
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Pace", pace)
                    )
                    .foregroundStyle(NativePaint.strain(style))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            if NativePlotAxis.inValueDomain(1, paceDomain) {
                RuleMark(y: .value("1x", 1.0))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let last = inWindow.last, let pace = last.pace, NativePlotAxis.inValueDomain(pace, paceDomain) {
                PointMark(
                    x: .value("Day", last.day),
                    y: .value("Pace", pace)
                )
                .foregroundStyle(NativePaint.strain(style))
                .symbolSize(36)
                .annotation(position: .trailing, spacing: 4) {
                    Text(NativeHealthspanFormat.paceText(pace))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(NativePaint.strain(style))
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: paceDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: NativePlotAxis.yTicks(in: paceDomain)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let pace = value.as(Double.self) {
                        Text(NativeHealthspanFormat.paceText(pace))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: NativePlotAxis.monthTicks(start: xDomain.lowerBound, end: xDomain.upperBound)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(NativeScopeFormat.month(date, calendar: .current))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }
}

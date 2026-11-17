import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// Sleep-page cards. Apple Health chrome, WHOOP order and functions.

struct NativeSleepHoursVsNeededCard: View {
    var model: NativeSleepNeed.Resolved
    var onOpen: (() -> Void)? = nil
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            let header = NativeCardHeader(
                title: "Hours vs. Needed",
                symbol: "clock.fill",
                tint: NativePaint.sleep(style),
                chevron: onOpen != nil
            )
            if let onOpen {
                Button(action: onOpen) { header }
                    .buttonStyle(.plain)
            } else {
                header
            }
            if let percent = model.percent {
                NativeHeroValue(
                    caption: "Last night",
                    value: "\(Int(percent.rounded()))",
                    unit: "%"
                )
            }
            if let slept = model.hoursSleptMin, model.needMin > 0 {
                NativeSleepNeedBars(slept: slept, needed: model.needMin, tint: NativePaint.sleep(style))
            }
            if model.hasBreakdown {
                VStack(spacing: 0) {
                    NativeContributorRow(
                        symbol: "circle.fill",
                        title: "Baseline",
                        value: NativeScoreMath.duration(model.baselineMin ?? 0),
                        tint: NativePaint.sleep(style)
                    )
                    Divider().padding(.leading, 34)
                    NativeContributorRow(
                        symbol: "bolt.fill",
                        title: "Recent Strain",
                        value: NativeSleepNeed.signedDuration(model.strainMin ?? 0),
                        tint: NativePaint.sleep(style)
                    )
                    Divider().padding(.leading, 34)
                    NativeContributorRow(
                        symbol: "moon.fill",
                        title: "Sleep Debt",
                        value: NativeSleepNeed.signedDuration(model.debtMin ?? 0),
                        tint: NativePaint.sleep(style)
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hours vs. Needed")
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
    }
}

struct NativeSleepNeedBars: View {
    var slept: Double
    var needed: Double
    var tint: Color

    var body: some View {
        let scale = max(slept, needed, 1)
        VStack(alignment: .leading, spacing: 10) {
            bar(title: "Hours of Sleep", minutes: slept, scale: scale, fill: tint)
            bar(title: "Sleep Needed", minutes: needed, scale: scale, fill: tint.opacity(NativeTokens.trackOpacity))
        }
    }

    private func bar(title: String, minutes: Double, scale: Double, fill: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 8)
                Text(NativeScoreMath.duration(minutes))
                    .font(StrandFont.rounded(15, weight: .semibold))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(NativeTokens.separator.opacity(0.35))
                    Capsule()
                        .fill(fill)
                        .frame(width: max(6, geo.size.width * CGFloat(minutes / scale)))
                }
            }
            .frame(height: 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(NativeScoreMath.duration(minutes))")
    }
}

struct NativeSleepConsistencyCard: View {
    var nights: [NativeSleepNight]
    var percent: Double?
    var onOpen: (() -> Void)? = nil
    @Environment(\.nativeStyle) private var style
    @State private var selectedKey: String?

    private var selected: NativeSleepNight? {
        guard let selectedKey else { return nil }
        return nights.first { $0.key == selectedKey }
    }

    var body: some View {
        NativeChrome.panel {
            header
            hero
                .frame(height: 76, alignment: .topLeading)
            NativeSleepConsistencyChart(
                nights: nights,
                tint: NativePaint.sleep(style),
                selectedKey: $selectedKey,
                onOpen: onOpen
            )
            .frame(height: 220)
        }
    }

    @ViewBuilder private var header: some View {
        let title = NativeCardHeader(
            title: "Sleep Consistency",
            symbol: "calendar",
            tint: NativePaint.sleep(style),
            chevron: onOpen != nil
        )
        if let onOpen {
            Button(action: onOpen) { title }
                .buttonStyle(.plain)
        } else {
            title
        }
    }

    @ViewBuilder private var hero: some View {
        if let selected {
            NativeHeroValue(
                caption: NativeChartDay.longLabel(selected.key),
                value: NativeSleepClock.clock(selected.bedtime),
                date: NativeSleepClock.clock(selected.wake)
            )
        } else if let percent {
            NativeHeroValue(
                caption: "Last night",
                value: "\(Int(percent.rounded()))",
                unit: "%"
            )
        } else if let last = nights.last {
            NativeHeroValue(
                caption: NativeChartDay.longLabel(last.key),
                value: NativeSleepClock.clock(last.bedtime),
                date: NativeSleepClock.clock(last.wake)
            )
        }
    }
}

struct NativeSleepConsistencyChart: View {
    var nights: [NativeSleepNight]
    var tint: Color
    var selectedKey: Binding<String?>? = nil
    var onOpen: (() -> Void)? = nil
    @Environment(\.nativeStyle) private var style

    private var avgBed: Double? { NativeSleepConsistency.averageBed(nights) }
    private var avgWake: Double? { NativeSleepConsistency.averageWake(nights) }
    private var selected: String? { selectedKey?.wrappedValue }

    var body: some View {
        let chart = Chart {
            ForEach(nights) { night in
                BarMark(
                    x: .value("Day", night.key),
                    yStart: .value("Wake", NativeSleepClock.plotY(night.wakeFromEvening)),
                    yEnd: .value("Bed", NativeSleepClock.plotY(night.bedFromEvening)),
                    width: 14
                )
                .foregroundStyle(night.key == selected || (selected == nil && night.isToday) ? tint : Color.secondary.opacity(0.45))
                .clipShape(Capsule())
                .accessibilityLabel(NativeChartDay.longLabel(night.key))
                .accessibilityValue("\(NativeSleepClock.clock(night.bedtime)) to \(NativeSleepClock.clock(night.wake))")
            }
            if let avgBed {
                RuleMark(y: .value("Avg bed", NativeSleepClock.plotY(avgBed)))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .accessibilityLabel("Average bedtime")
            }
            if let avgWake {
                RuleMark(y: .value("Avg wake", NativeSleepClock.plotY(avgWake)))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .accessibilityLabel("Average wake")
            }
        }
        .chartYScale(domain: NativeSleepClock.plotY(1140)...NativeSleepClock.plotY(180))
        .chartYAxis {
            AxisMarks(position: .trailing, values: NativeSleepClock.axisMarks.map(NativeSleepClock.plotY)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let y = value.as(Double.self) {
                        Text(NativeSleepClock.label(-y))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: nights.map(\.key)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let key = value.as(String.self) {
                        Text(NativeChartDay.weekday(key))
                            .font(.caption2.weight(key == nights.first(where: \.isToday)?.key ? .semibold : .regular))
                            .foregroundStyle(key == nights.first(where: \.isToday)?.key ? Color.primary : Color.secondary)
                    }
                }
            }
        }
        .accessibilityLabel("Sleep consistency, last \(nights.count) nights")

        if #available(iOS 17.0, macOS 14.0, *), let selectedKey {
            chart.chartXSelection(value: selectedKey)
                .onTapGesture { onOpen?() }
        } else {
            chart.onTapGesture { onOpen?() }
        }
    }
}

struct NativeSleepEfficiencyCard: View {
    var model: NativeSleepEfficiency.Model
    var onOpen: (() -> Void)? = nil
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            let header = NativeCardHeader(
                title: "Sleep Efficiency",
                symbol: "bed.double.fill",
                tint: NativePaint.sleep(style),
                chevron: onOpen != nil
            )
            if let onOpen {
                Button(action: onOpen) { header }
                    .buttonStyle(.plain)
            } else {
                header
            }
            NativeHeroValue(
                caption: "Last night",
                value: "\(Int(model.percent.rounded()))",
                unit: "%",
                date: model.prior.map { "\(Int($0.rounded()))% last 30 days" }
            )
            if !model.spans.isEmpty {
                NativeSleepStageStrip(spans: model.spans)
                    .frame(height: 28)
                    .clipShape(Capsule())
            }
            if let events = model.wakeEvents {
                NativeContributorRow(
                    symbol: "moon.zzz.fill",
                    title: "Wake Events",
                    value: "\(events)",
                    tint: NativePaint.sleep(style)
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
    }
}

struct NativeSleepStageStrip: View {
    var spans: [NativeSleepStageSpan]
    @Environment(\.nativeStyle) private var style

    private var total: Double {
        max(spans.map(\.minutes).reduce(0, +), 1)
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(spans) { span in
                    NativePaint.sleepStage(named: span.name, style: style)
                        .frame(width: max(1, geo.size.width * CGFloat(span.minutes / total)))
                }
            }
        }
        .accessibilityLabel("Sleep stages across the night")
    }
}

struct NativeSleepStressCard: View {
    var model: NativeSleepStress.Model
    var onOpen: (() -> Void)? = nil
    @Environment(\.nativeStyle) private var style
    @State private var scrub = NativeScopeScrub()

    private var average: Double {
        NativeScoreMath.mean(model.points.map(\.value)) ?? 0
    }

    var body: some View {
        NativeChrome.panel {
            let header = NativeCardHeader(
                title: "Sleep Stress",
                symbol: "waveform.path",
                tint: NativePaint.sleep(style),
                chevron: onOpen != nil
            )
            if let onOpen {
                Button(action: onOpen) { header }
                    .buttonStyle(.plain)
            } else {
                header
            }
            NativeSleepStressHero(scrub: scrub, points: model.points, average: average)
                .frame(height: 76, alignment: .topLeading)
            NativeSleepStressPlot(
                points: model.points,
                tint: NativePaint.sleep(style),
                scrub: scrub,
                onOpen: onOpen
            )
            .frame(height: 160)
            VStack(spacing: 0) {
                bandRow(model.high, symbol: "arrow.up.circle.fill")
                Divider().padding(.leading, 34)
                bandRow(model.medium, symbol: "equal.circle.fill")
                Divider().padding(.leading, 34)
                bandRow(model.low, symbol: "arrow.down.circle.fill")
            }
        }
    }

    private func bandRow(_ band: NativeSleepStress.Band, symbol: String) -> some View {
        NativeContributorRow(
            symbol: symbol,
            title: band.title,
            value: "\(NativeScoreMath.duration(band.minutes))  \(Int(band.percent.rounded()))%",
            tint: NativePaint.stressBand(band.title == "High" ? 2.5 : band.title == "Medium" ? 1.5 : 0.5, style: style)
        )
    }
}

private struct NativeSleepStressHero: View {
    @ObservedObject var scrub: NativeScopeScrub
    var points: [NativeHourPoint]
    var average: Double

    var body: some View {
        if let time = scrub.time,
           let point = NativeChartScrubMath.nearestHour(
            to: time,
            in: points,
            maxGap: NativeChartScrubMath.inferredMaxGap(in: points)
           ) {
            NativeHeroValue(
                caption: "Stress",
                value: String(format: "%.1f", point.value),
                date: NativeScopeFormat.time(point.time)
            )
        } else {
            NativeHeroValue(
                caption: "Average",
                value: String(format: "%.1f", average)
            )
        }
    }
}

struct NativeSleepStressPlot: View {
    var points: [NativeHourPoint]
    var tint: Color
    var scrub: NativeScopeScrub? = nil
    var onOpen: (() -> Void)? = nil
    @State private var localScrub = NativeScopeScrub()

    private var box: NativeScopeScrub { scrub ?? localScrub }

    private var timeBinding: Binding<Date?> {
        Binding(
            get: { box.time },
            set: { box.time = $0 }
        )
    }

    var body: some View {
        let marks = Chart {
            ForEach(points) { point in
                LineMark(x: .value("Time", point.time), y: .value("Stress", point.value))
                    .foregroundStyle(tint)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .accessibilityLabel(NativeScopeFormat.time(point.time))
                    .accessibilityValue(String(format: "%.1f", point.value))
            }
        }
        .chartYScale(domain: 0...3)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 1, 2, 3]) { _ in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(NativeScopeFormat.time(date))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .accessibilityLabel("Overnight sleep stress")

        Group {
            if #available(iOS 17.0, macOS 14.0, *) {
                marks
                    .chartXSelection(value: timeBinding)
                    .chartOverlay { proxy in
                        NativeSleepStressMarker(proxy: proxy, points: points, tint: tint, scrub: box)
                    }
            } else {
                marks
            }
        }
        .onTapGesture { onOpen?() }
    }
}

private struct NativeSleepStressMarker: View {
    var proxy: ChartProxy
    var points: [NativeHourPoint]
    var tint: Color
    @ObservedObject var scrub: NativeScopeScrub

    var body: some View {
        GeometryReader { _ in
            if let time = scrub.time,
               let point = NativeChartScrubMath.nearestHour(
                to: time,
                in: points,
                maxGap: NativeChartScrubMath.inferredMaxGap(in: points)
               ),
               let x = proxy.position(forX: point.time),
               let y = proxy.position(forY: point.value) {
                NativeSelectedVertex(tint: tint)
                    .position(x: x, y: y)
            }
        }
        .allowsHitTesting(false)
    }
}

struct NativeSleepDualLineCard: View {
    var title: String
    var slept: [NativeDayPoint]
    var needed: [NativeDayPoint]
    var highlightKey: String?
    var typical: ClosedRange<Double>? = nil
    var onOpen: (() -> Void)? = nil
    @Environment(\.nativeStyle) private var style
    @State private var selectedKey: String?

    private var knownSlept: [NativeDayPoint] { slept.filter { $0.value.isFinite } }
    private var knownNeeded: [NativeDayPoint] { needed.filter { $0.value.isFinite } }
    private var yDomain: ClosedRange<Double> {
        NativeChartDay.fittedDomain(
            (knownSlept + knownNeeded).map(\.value) + typicalBounds,
            fallback: 0...480
        )
    }

    private var typicalBounds: [Double] {
        guard let typical else { return [] }
        return [typical.lowerBound, typical.upperBound]
    }

    var body: some View {
        NativeChrome.panel {
            header
            hero
                .frame(height: 76, alignment: .topLeading)
            plot.frame(height: 200)
        }
        .modifier(NativeSelectionFeedback(trigger: selectedKey ?? ""))
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.fill")
                .foregroundStyle(NativePaint.sleep(style))
            Text(title)
                .foregroundStyle(NativePaint.sleep(style))
            Spacer(minLength: 8)
            NativeSleepSeriesKey(color: NativeTokens.sleep, name: "Hours of Sleep")
            NativeSleepSeriesKey(color: Color.secondary, name: "Sleep Needed")
            if onOpen != nil {
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote.weight(.semibold))
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
    }

    @ViewBuilder private var hero: some View {
        if let selectedKey, let sleptPoint = NativeChartScrubMath.finitePoint(key: selectedKey, in: slept) {
            NativeClockHero(caption: NativeChartDay.longLabel(selectedKey), minutes: sleptPoint.value)
            if let neededPoint = NativeChartScrubMath.finitePoint(key: selectedKey, in: needed) {
                Text("Needed \(NativeScoreMath.duration(neededPoint.value))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else if let average = NativeScoreMath.mean(knownSlept.map(\.value)) {
            NativeClockHero(caption: "Average", minutes: average)
            if let first = slept.first?.key, let last = slept.last?.key {
                Text(NativeChartDay.rangeLabel(from: first, to: last))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var plot: some View {
        Chart {
            ForEach(slept) { point in
                BarMark(x: .value("Day", point.key), y: .value("Slot", 0))
                    .foregroundStyle(Color.clear)
                    .accessibilityHidden(true)
                if let typical {
                    BarMark(
                        x: .value("Day", point.key),
                        yStart: .value("Typical lo", typical.lowerBound),
                        yEnd: .value("Typical hi", typical.upperBound)
                    )
                    .foregroundStyle(NativeTokens.sleep.opacity(0.14))
                    .accessibilityHidden(true)
                }
            }
            ForEach(NativeChartDay.linePoints(slept)) { point in
                LineMark(
                    x: .value("Day", point.key),
                    y: .value("Hours", point.value),
                    series: .value("Series", "Slept-\(point.segment)")
                )
                .foregroundStyle(NativeTokens.sleep)
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                PointMark(x: .value("Day", point.key), y: .value("Hours", point.value))
                    .foregroundStyle(NativeTokens.sleep)
                    .symbol {
                        if point.key == selectedKey {
                            NativeSelectedVertex(tint: NativeTokens.sleep)
                        } else {
                            NativeSleepVertex(tint: NativeTokens.sleep)
                        }
                    }
            }
            ForEach(NativeChartDay.linePoints(needed)) { point in
                LineMark(
                    x: .value("Day", point.key),
                    y: .value("Hours", point.value),
                    series: .value("Series", "Needed-\(point.segment)")
                )
                .foregroundStyle(Color.secondary)
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(NativeScoreMath.duration(v))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: slept.map(\.key)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let key = value.as(String.self) {
                        Text(NativeChartDay.weekday(key))
                            .font(.caption2.weight(key == highlightKey ? .semibold : .regular))
                            .foregroundStyle(key == highlightKey ? Color.primary : Color.secondary)
                    }
                }
            }
        }
        .accessibilityLabel("Hours slept and hours needed")
        .modifier(NativeSleepDaySelect(selected: $selectedKey))
        .onTapGesture { onOpen?() }
    }
}

private struct NativeSleepDaySelect: ViewModifier {
    @Binding var selected: String?
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.chartXSelection(value: $selected)
        } else {
            content
        }
    }
}

private struct NativeSleepSeriesKey: View {
    var color: Color
    var name: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityLabel(name)
    }
}

private struct NativeSleepVertex: View {
    var tint: Color
    var size: CGFloat = 8
    @Environment(\.nativeStyle) private var style

    var body: some View {
        ZStack {
            Circle().fill(NativePaint.card(style))
            Circle().strokeBorder(tint, lineWidth: 2)
        }
        .frame(width: size, height: size)
    }
}

struct NativeSleepTimeInBedWeekCard: View {
    var points: [NativeDayPoint]
    var highlightKey: String?
    var onOpen: (() -> Void)? = nil
    @Environment(\.nativeStyle) private var style
    @State private var selectedKey: String?

    private var known: [NativeDayPoint] {
        points.filter { $0.value.isFinite || ($0.low != nil && $0.high != nil) }
    }

    var body: some View {
        NativeChrome.panel {
            let header = NativeCardHeader(
                title: "Time in Bed",
                symbol: "bed.double.fill",
                tint: NativePaint.sleep(style),
                chevron: onOpen != nil
            )
            if let onOpen {
                Button(action: onOpen) { header }
                    .buttonStyle(.plain)
            } else {
                header
            }
            hero
                .frame(height: 76, alignment: .topLeading)
            plot.frame(height: 200)
        }
        .modifier(NativeSelectionFeedback(trigger: selectedKey ?? ""))
    }

    @ViewBuilder private var hero: some View {
        if let selectedKey, let point = NativeChartScrubMath.finitePoint(key: selectedKey, in: points) {
            NativeClockHero(caption: NativeChartDay.longLabel(selectedKey), minutes: point.value)
        } else if let average = NativeScoreMath.mean(known.compactMap { $0.value.isFinite ? $0.value : nil }) {
            NativeClockHero(caption: "Average", minutes: average)
            if let first = points.first?.key, let last = points.last?.key {
                Text(NativeChartDay.rangeLabel(from: first, to: last))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var plot: some View {
        Chart {
            ForEach(points) { point in
                BarMark(x: .value("Day", point.key), y: .value("Slot", 0))
                    .foregroundStyle(Color.clear)
                    .accessibilityHidden(true)
                if let low = point.low, let high = point.high, high >= low {
                    BarMark(
                        x: .value("Day", point.key),
                        yStart: .value("Wake", NativeSleepClock.plotY(high)),
                        yEnd: .value("Bed", NativeSleepClock.plotY(low)),
                        width: 14
                    )
                    .foregroundStyle(
                        point.key == selectedKey || (selectedKey == nil && point.key == highlightKey)
                            ? NativePaint.sleep(style)
                            : Color.secondary.opacity(0.45)
                    )
                    .opacity(NativeChartScrubMath.barOpacity(
                        isSelected: point.key == selectedKey,
                        hasSelection: selectedKey != nil && known.contains(where: { $0.key == selectedKey })
                    ))
                    .clipShape(Capsule())
                    .accessibilityLabel(NativeChartDay.longLabel(point.key))
                    .accessibilityValue(NativeScoreMath.duration(point.value))
                }
            }
        }
        .chartYScale(domain: NativeSleepClock.plotY(1140)...NativeSleepClock.plotY(180))
        .chartYAxis {
            AxisMarks(position: .trailing, values: NativeSleepClock.axisMarks.map(NativeSleepClock.plotY)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let y = value.as(Double.self) {
                        Text(NativeSleepClock.label(-y))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: points.map(\.key)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let key = value.as(String.self) {
                        Text(NativeChartDay.weekday(key))
                            .font(.caption2.weight(key == highlightKey ? .semibold : .regular))
                            .foregroundStyle(key == highlightKey ? Color.primary : Color.secondary)
                    }
                }
            }
        }
        .accessibilityLabel("Time in bed, last 7 days")
        .modifier(NativeSleepDaySelect(selected: $selectedKey))
        .onTapGesture { onOpen?() }
    }
}

enum NativeSleepGallery {
    struct Section: Identifiable {
        var id: String { name }
        var name: String
        var padded: Bool
        var view: AnyView
    }

    static var sections: [Section] {
        [
            Section(name: "sleep-hours-needed", padded: true, view: AnyView(hoursNeeded)),
            Section(name: "sleep-hours-needed-imported", padded: true, view: AnyView(hoursNeededImported)),
            Section(name: "sleep-consistency-card", padded: true, view: AnyView(consistency)),
            Section(name: "sleep-efficiency-card", padded: true, view: AnyView(efficiency)),
            Section(name: "sleep-stress-card", padded: true, view: AnyView(stress)),
            Section(name: "sleep-week-hours-needed", padded: true, view: AnyView(weekHours)),
            Section(name: "sleep-week-time-in-bed", padded: true, view: AnyView(weekInBed)),
            Section(name: "sleep-last-night", padded: true, view: AnyView(lastNight)),
            Section(name: "sleep-stage-detail", padded: true, view: AnyView(stageDetail)),
            Section(name: "sleep-hypnogram-page", padded: true, view: AnyView(hypnogramPage)),
        ]
    }

    private static var hoursNeeded: some View {
        NativeSleepHoursVsNeededCard(model: NativeSleepSnapshot.bandNeed)
    }

    private static var hoursNeededImported: some View {
        NativeSleepHoursVsNeededCard(model: NativeSleepSnapshot.importedNeed)
    }

    private static var consistency: some View {
        NativeSleepConsistencyCard(
            nights: NativeSleepSnapshot.consistencyNights,
            percent: 79
        )
    }

    private static var efficiency: some View {
        NativeSleepEfficiencyCard(model: NativeSleepSnapshot.efficiency)
    }

    private static var stress: some View {
        NativeSleepStressCard(model: NativeSleepSnapshot.stress)
    }

    private static var weekHours: some View {
        NativeSleepDualLineCard(
            title: "Hours vs. Needed",
            slept: NativeWeek.series(NativeSleepSnapshot.snapshotDays, todayKey: NativeSleepSnapshot.highlightKey) {
                NativeDayLogic.asleepMinutes(light: $0.lightMin, deep: $0.deepMin, rem: $0.remMin,
                                             totalSleepMin: $0.totalSleepMin)
            },
            needed: NativeSleepSnapshot.pageDetail.hoursNeededWeek,
            highlightKey: NativeSleepSnapshot.highlightKey,
            typical: NativeSleepSnapshot.pageDetail.hoursTypical
        )
    }

    private static var weekInBed: some View {
        NativeSleepTimeInBedWeekCard(
            points: NativeSleepSnapshot.pageDetail.timeInBedWeek,
            highlightKey: NativeSleepSnapshot.highlightKey
        )
    }

    private static var lastNight: some View {
        NativeLastNightCard(
            asleepMinutes: 410,
            stages: NativeSleepSnapshot.stages,
            sleepStart: NativeSleepSnapshot.sleepStart,
            sleepEnd: NativeSleepSnapshot.sleepEnd,
            awakeTypical: 45,
            needMinutes: 465,
            debtMinutes: 36,
            spans: NativeSleepSnapshot.hypnogram
        )
    }

    private static var stageDetail: some View {
        let detail = NativeSleepSnapshot.stageDetails.first { $0.kind == .deep }
            ?? NativeSleepSnapshot.stageDetails[0]
        return NativeSleepStageDetailView(
            detail: detail,
            spans: NativeSleepSnapshot.hypnogram,
            nightStart: NativeSleepSnapshot.sleepStart,
            nightEnd: NativeSleepSnapshot.sleepEnd,
            dayKey: NativeSleepSnapshot.highlightKey,
            scrolls: false
        )
    }

    private static var hypnogramPage: some View {
        NativeSleepHypnogramPage(
            spans: NativeSleepSnapshot.hypnogram,
            nightStart: NativeSleepSnapshot.sleepStart,
            nightEnd: NativeSleepSnapshot.sleepEnd,
            stages: NativeSleepSnapshot.stages,
            asleepMinutes: 410,
            awakeTypical: 45,
            scrolls: false
        )
    }
}

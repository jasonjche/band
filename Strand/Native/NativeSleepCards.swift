import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// Sleep-page cards. Apple Health chrome, WHOOP order and functions.

struct NativeSleepHoursVsNeededCard: View {
    var model: NativeSleepNeed.Resolved
    var onOpen: (() -> Void)? = nil

    var body: some View {
        NativeSleepHoursVsNeededHost(model: model, onOpen: onOpen)
            .equatable()
    }
}

private struct NativeSleepHoursVsNeededHost: View, Equatable {
    var model: NativeSleepNeed.Resolved
    var onOpen: (() -> Void)?
    @Environment(\.nativeStyle) private var style

    static func == (lhs: NativeSleepHoursVsNeededHost, rhs: NativeSleepHoursVsNeededHost) -> Bool {
        lhs.model == rhs.model
    }

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
            NativeHeroValue(
                caption: "Last night",
                value: model.percent.map { "\(Int($0.rounded()))" } ?? "—",
                unit: "%"
            )
            if let slept = model.hoursSleptMin, model.needMin > 0 {
                NativeSleepNeedBars(slept: slept, needed: model.needMin, tint: NativePaint.sleep(style))
            } else {
                Color.clear.frame(height: 56)
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
        .accessibilityAction { onOpen?() }
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

    var body: some View {
        NativeSleepConsistencyHost(nights: nights, percent: percent, onOpen: onOpen)
            .equatable()
    }
}

private struct NativeSleepConsistencyHost: View, Equatable {
    var nights: [NativeSleepNight]
    var percent: Double?
    var onOpen: (() -> Void)?
    @Environment(\.nativeStyle) private var style
    @State private var selectedKey: String?

    static func == (lhs: NativeSleepConsistencyHost, rhs: NativeSleepConsistencyHost) -> Bool {
        lhs.nights == rhs.nights && lhs.percent == rhs.percent
    }

    private var selected: NativeSleepNight? {
        guard let selectedKey else { return nil }
        return nights.first { $0.key == selectedKey }
    }

    var body: some View {
        NativeChrome.panel {
            header
            hero
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
        let night = selected ?? nights.last
        if let percent {
            NativeHeroValue(
                caption: selected.map { NativeChartDay.longLabel($0.key) } ?? "Sleep Consistency",
                value: "\(Int(percent.rounded()))",
                unit: "%"
            )
        }
        if let night {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bedtime")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(NativeSleepClock.clock(night.bedtime))
                        .font(StrandFont.rounded(17, weight: .semibold))
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wake")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(NativeSleepClock.clock(night.wake))
                        .font(StrandFont.rounded(17, weight: .semibold))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct NativeSleepConsistencyPage: View {
    var nights: [NativeSleepNight]
    var percent: Double?

    var body: some View {
        NativeChrome.screen {
            NativeSleepConsistencyCard(nights: nights, percent: percent)
        }
        .navigationTitle("Sleep Consistency")
        .modifier(NativeInlineTitle())
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

    private var keys: [String] {
        let end = nights.first(where: \.isToday)?.key ?? nights.last?.key
        guard let end else { return nights.map(\.key) }
        return NativeSleepConsistency.chartKeys(dayKey: end)
    }

    private var plotWindow: NativeSleepClock.PlotWindow {
        NativeSleepClock.fittedPlot(beds: nights.map(\.bedFromEvening), wakes: nights.map(\.wakeFromEvening))
    }

    var body: some View {
        let yDomain = plotWindow.domain
        let chart = Chart {
            ForEach(keys, id: \.self) { key in
                BarMark(
                    x: .value("Day", key),
                    yStart: .value("Slot", yDomain.lowerBound),
                    yEnd: .value("Slot top", yDomain.lowerBound)
                )
                .foregroundStyle(Color.clear)
                .accessibilityHidden(true)
            }
            ForEach(nights) { night in
                let bedY = NativeSleepClock.plotY(night.bedFromEvening)
                let wakeY = NativeSleepClock.plotY(night.wakeFromEvening)
                if max(bedY, wakeY) >= yDomain.lowerBound, min(bedY, wakeY) <= yDomain.upperBound {
                    BarMark(
                        x: .value("Day", night.key),
                        yStart: .value("Wake", wakeY),
                        yEnd: .value("Bed", bedY),
                        width: 14
                    )
                    .foregroundStyle(night.key == selected || (selected == nil && night.isToday) ? tint : Color.secondary.opacity(0.45))
                    .clipShape(Capsule())
                    .accessibilityLabel(NativeChartDay.longLabel(night.key))
                    .accessibilityValue("\(NativeSleepClock.clock(night.bedtime)) to \(NativeSleepClock.clock(night.wake))")
                }
            }
            if let avgBed {
                let y = NativeSleepClock.plotY(avgBed)
                if y >= yDomain.lowerBound, y <= yDomain.upperBound {
                    RuleMark(y: .value("Avg bed", y))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .accessibilityLabel("Average bedtime")
                }
            }
            if let avgWake {
                let y = NativeSleepClock.plotY(avgWake)
                if y >= yDomain.lowerBound, y <= yDomain.upperBound {
                    RuleMark(y: .value("Avg wake", y))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .accessibilityLabel("Average wake")
                }
            }
        }
        .chartXScale(domain: keys)
        .chartYScale(domain: yDomain)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(position: .trailing, values: plotWindow.marks.map(NativeSleepClock.plotY)) { value in
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
            AxisMarks(values: keys) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let key = value.as(String.self) {
                        NativeChartAxisLabel(key: key, highlighted: key == nights.first(where: \.isToday)?.key)
                            .equatable()
                    }
                }
            }
        }
        .accessibilityLabel("Sleep consistency, last \(keys.count) nights")

        if #available(iOS 17.0, macOS 14.0, *), let selectedKey {
            chart.chartXSelection(value: selectedKey)
                .nativeChartButton(action: onOpen)
                .onTapGesture { onOpen?() }
        } else {
            chart
                .nativeChartButton(action: onOpen)
                .onTapGesture { onOpen?() }
        }
    }
}

struct NativeSleepEfficiencyCard: View {
    var model: NativeSleepEfficiency.Model
    var onOpen: (() -> Void)? = nil

    var body: some View {
        NativeSleepEfficiencyHost(model: model, onOpen: onOpen)
            .equatable()
    }
}

private struct NativeSleepEfficiencyHost: View, Equatable {
    var model: NativeSleepEfficiency.Model
    var onOpen: (() -> Void)?
    @Environment(\.nativeStyle) private var style

    static func == (lhs: NativeSleepEfficiencyHost, rhs: NativeSleepEfficiencyHost) -> Bool {
        lhs.model == rhs.model
    }

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
        .accessibilityAction { onOpen?() }
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
    var plot: NativeSleepStressPlotModel? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        NativeSleepStressHost(
            model: model,
            plot: plot ?? NativeSleepStressPlotModel.make(points: model.points),
            onOpen: onOpen
        )
        .equatable()
    }
}

private struct NativeSleepStressHost: View, Equatable {
    var model: NativeSleepStress.Model
    var plot: NativeSleepStressPlotModel
    var onOpen: (() -> Void)?
    @Environment(\.nativeStyle) private var style
    @State private var scrub = NativeScopeScrub()

    static func == (lhs: NativeSleepStressHost, rhs: NativeSleepStressHost) -> Bool {
        lhs.model == rhs.model && lhs.plot == rhs.plot
    }

    private var average: Double { plot.average }

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
                onOpen: onOpen,
                plot: plot
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
    var plot: NativeSleepStressPlotModel? = nil
    @State private var localScrub = NativeScopeScrub()

    private var box: NativeScopeScrub { scrub ?? localScrub }

    private var timeBinding: Binding<Date?> {
        Binding(
            get: { box.time },
            set: { box.time = $0 }
        )
    }

    private var resolved: NativeSleepStressPlotModel {
        plot ?? NativeSleepStressPlotModel.make(points: points)
    }

    var body: some View {
        let model = resolved
        let marks = Chart {
            ForEach(model.domainPoints) { point in
                LineMark(x: .value("Time", point.time), y: .value("Stress", point.value))
                    .foregroundStyle(tint)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .accessibilityLabel(model.pointTimeText[point.time.timeIntervalSince1970] ?? NativeScopeFormat.time(point.time))
                    .accessibilityValue(String(format: "%.1f", point.value))
            }
        }
        .chartYScale(domain: 0...3)
        .chartXScale(domain: model.xDomain ?? Date()...Date())
        .chartPlotStyle { $0.clipped() }
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
            AxisMarks(values: model.hourLabels) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(model.hourLabelText[date.timeIntervalSince1970] ?? NativeScopeFormat.hourClock(date, calendar: .current))
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
                        NativeSleepStressMarker(proxy: proxy, points: model.domainPoints, tint: tint, scrub: box)
                            .clipped()
                    }
            } else {
                marks
            }
        }
        .nativeChartButton(action: onOpen)
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
    var plot: NativeSleepDualLineModel? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        NativeSleepDualLineHost(
            title: title,
            model: plot ?? NativeSleepDualLineModel.make(slept: slept, needed: needed, typical: typical),
            highlightKey: highlightKey,
            onOpen: onOpen
        )
        .equatable()
    }
}

private struct NativeSleepDualLineHost: View, Equatable {
    var title: String
    var model: NativeSleepDualLineModel
    var highlightKey: String?
    var onOpen: (() -> Void)?
    @Environment(\.nativeStyle) private var style
    @State private var selectedKey: String?

    static func == (lhs: NativeSleepDualLineHost, rhs: NativeSleepDualLineHost) -> Bool {
        lhs.title == rhs.title
            && lhs.model == rhs.model
            && lhs.highlightKey == rhs.highlightKey
    }

    private var slept: [NativeDayPoint] { model.slept }
    private var needed: [NativeDayPoint] { model.needed }
    private var axisTicks: [Double] { model.axisTicks }
    private var yDomain: ClosedRange<Double> { model.yDomain }
    private var typicalClipped: ClosedRange<Double>? { model.typicalClipped }

    var body: some View {
        NativeChrome.panel {
            header
            hero
            plot.frame(height: 200)
        }
        .modifier(NativeSelectionFeedback(trigger: selectedKey ?? ""))
    }

    @ViewBuilder private var header: some View {
        let titleRow = NativeCardHeader(
            title: title,
            symbol: "clock.fill",
            tint: NativePaint.sleep(style),
            chevron: onOpen != nil
        )
        VStack(alignment: .leading, spacing: 8) {
            if let onOpen {
                Button(action: onOpen) { titleRow }
                    .buttonStyle(.plain)
            } else {
                titleRow
            }
            HStack(spacing: 10) {
                NativeSleepSeriesKey(color: NativeTokens.sleep, name: "Hours of Sleep")
                NativeSleepSeriesKey(color: Color.secondary, name: "Sleep Needed")
            }
        }
        .contentShape(Rectangle())
        .nativeOpenButton(action: onOpen)
    }

    @ViewBuilder private var hero: some View {
        if let selectedKey, let sleptPoint = NativeChartScrubMath.finitePoint(key: selectedKey, in: slept) {
            let neededLine = NativeChartScrubMath.finitePoint(key: selectedKey, in: needed)
                .map { "Needed \(NativeScoreMath.duration($0.value))" }
            NativeClockHero(
                caption: NativeChartDay.longLabel(selectedKey),
                minutes: sleptPoint.value,
                date: neededLine
            )
        } else if let average = model.averageSlept {
            NativeClockHero(caption: "Average", minutes: average, date: model.rangeLabel)
        }
    }

    private var plot: some View {
        Chart {
            ForEach(slept) { point in
                BarMark(
                    x: .value("Day", point.key),
                    yStart: .value("Slot", yDomain.lowerBound),
                    yEnd: .value("Slot top", yDomain.lowerBound)
                )
                .foregroundStyle(Color.clear)
                .accessibilityHidden(true)
                if let typicalClipped {
                    BarMark(
                        x: .value("Day", point.key),
                        yStart: .value("Typical lo", typicalClipped.lowerBound),
                        yEnd: .value("Typical hi", typicalClipped.upperBound)
                    )
                    .foregroundStyle(NativeTokens.sleep.opacity(0.14))
                    .accessibilityHidden(true)
                }
            }
            ForEach(model.sleptLine) { point in
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
            ForEach(model.neededLine) { point in
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
        .chartXScale(domain: slept.map(\.key))
        .chartYScale(domain: yDomain)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(position: .trailing, values: axisTicks) { value in
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
                        NativeChartAxisLabel(key: key, highlighted: key == highlightKey)
                            .equatable()
                    }
                }
            }
        }
        .accessibilityLabel("Hours slept and hours needed")
        .modifier(NativeSleepDaySelect(selected: $selectedKey))
        .nativeChartButton(action: onOpen)
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
    var plot: NativeSleepTimeInBedPlotModel? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        NativeSleepTimeInBedWeekHost(
            model: plot ?? NativeSleepTimeInBedPlotModel.make(points: points),
            highlightKey: highlightKey,
            onOpen: onOpen
        )
        .equatable()
    }
}

private struct NativeSleepTimeInBedWeekHost: View, Equatable {
    var model: NativeSleepTimeInBedPlotModel
    var highlightKey: String?
    var onOpen: (() -> Void)?
    @Environment(\.nativeStyle) private var style
    @State private var selectedKey: String?

    static func == (lhs: NativeSleepTimeInBedWeekHost, rhs: NativeSleepTimeInBedWeekHost) -> Bool {
        lhs.model == rhs.model && lhs.highlightKey == rhs.highlightKey
    }

    private var points: [NativeDayPoint] { model.points }
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
            plot.frame(height: 200)
        }
        .modifier(NativeSelectionFeedback(trigger: selectedKey ?? ""))
    }

    @ViewBuilder private var hero: some View {
        if let selectedKey, let point = NativeChartScrubMath.finitePoint(key: selectedKey, in: points) {
            NativeClockHero(caption: NativeChartDay.longLabel(selectedKey), minutes: point.value)
        } else if let average = model.average {
            NativeClockHero(caption: "Average", minutes: average, date: model.rangeLabel)
        }
    }

    private var plotWindow: NativeSleepClock.PlotWindow { model.window }

    private var plot: some View {
        let yDomain = plotWindow.domain
        return Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Day", point.key),
                    yStart: .value("Slot", yDomain.lowerBound),
                    yEnd: .value("Slot top", yDomain.lowerBound)
                )
                .foregroundStyle(Color.clear)
                .accessibilityHidden(true)
                if let low = point.low, let high = point.high, high >= low {
                    let bedY = NativeSleepClock.plotY(low)
                    let wakeY = NativeSleepClock.plotY(high)
                    if max(bedY, wakeY) >= yDomain.lowerBound, min(bedY, wakeY) <= yDomain.upperBound {
                        BarMark(
                            x: .value("Day", point.key),
                            yStart: .value("Wake", wakeY),
                            yEnd: .value("Bed", bedY),
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
        }
        .chartXScale(domain: points.map(\.key))
        .chartYScale(domain: yDomain)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(position: .trailing, values: plotWindow.marks.map(NativeSleepClock.plotY)) { value in
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
                        NativeChartAxisLabel(key: key, highlighted: key == highlightKey)
                            .equatable()
                    }
                }
            }
        }
        .accessibilityLabel("Time in bed, last 7 days")
        .modifier(NativeSleepDaySelect(selected: $selectedKey))
        .nativeChartButton(action: onOpen)
        .onTapGesture { onOpen?() }
    }
}

/// Restorative Sleep week: stacked REM (bottom) + Deep (top) in WHOOP stage colours.
struct NativeSleepRestorativeWeekCard: View {
    var deep: [NativeDayPoint]
    var rem: [NativeDayPoint]
    var highlightKey: String?
    var plot: NativeSleepRestorativePlotModel? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        NativeSleepRestorativeWeekHost(
            deep: deep,
            rem: rem,
            highlightKey: highlightKey,
            plot: plot ?? NativeSleepRestorativePlotModel.make(deep: deep, rem: rem),
            onOpen: onOpen
        )
        .equatable()
    }
}

private struct NativeSleepRestorativeWeekHost: View, Equatable {
    var deep: [NativeDayPoint]
    var rem: [NativeDayPoint]
    var highlightKey: String?
    var plot: NativeSleepRestorativePlotModel
    var onOpen: (() -> Void)?
    @Environment(\.nativeStyle) private var style

    static func == (lhs: NativeSleepRestorativeWeekHost, rhs: NativeSleepRestorativeWeekHost) -> Bool {
        lhs.plot == rhs.plot && lhs.highlightKey == rhs.highlightKey
    }

    var body: some View {
        NativeChrome.panel {
            let header = NativeCardHeader(
                title: "Restorative Sleep",
                symbol: "sparkles",
                tint: NativePaint.sleep(style),
                chevron: onOpen != nil
            )
            if let onOpen {
                Button(action: onOpen) { header }
                    .buttonStyle(.plain)
            } else {
                header
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                NativeSleepSeriesKey(
                    color: NativePaint.sleepStage(named: "Deep", style: style),
                    name: "Deep Sleep"
                )
                NativeSleepSeriesKey(
                    color: NativePaint.sleepStage(named: "REM", style: style),
                    name: "REM Sleep"
                )
            }
            NativeSleepRestorativeChart(
                deep: deep,
                rem: rem,
                highlightKey: highlightKey,
                plotHeight: 200,
                plot: plot
            )
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityLabel("Restorative Sleep")
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
        .accessibilityAction { onOpen?() }
    }
}

struct NativeSleepRestorativeChart: View {
    var deep: [NativeDayPoint]
    var rem: [NativeDayPoint]
    var highlightKey: String?
    var plotHeight: CGFloat = 200
    var previewSelected: String? = nil
    var plot: NativeSleepRestorativePlotModel? = nil
    @Environment(\.nativeStyle) private var style
    @State private var selectedKey: String?

    /// REM first (bottom of the stack), Deep second (top). WHOOP IMG_9434.
    static func stackOrder() -> [String] { NativeSleepRestorativePlotModel.stackOrder() }

    private var resolved: NativeSleepRestorativePlotModel {
        plot ?? NativeSleepRestorativePlotModel.make(deep: deep, rem: rem)
    }

    private var totals: [NativeDayPoint] { resolved.totals }

    private var slices: [NativeSleepRestorativePlotModel.Slice] { resolved.slices }

    private var keys: [String] { resolved.keys }

    private var axisTicks: [Double] { resolved.axisTicks }

    private var ceiling: Double { resolved.ceiling }

    private var selectedPoint: NativeDayPoint? {
        guard let selectedKey else { return nil }
        return NativeChartScrubMath.finitePoint(key: selectedKey, in: totals)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            hero
            chart.frame(height: plotHeight)
        }
        .onAppear {
            if selectedKey == nil { selectedKey = previewSelected }
        }
        .modifier(NativeSelectionFeedback(trigger: selectedKey ?? ""))
    }

    @ViewBuilder private var hero: some View {
        if let selectedPoint {
            NativeClockHero(minutes: selectedPoint.value, date: NativeChartDay.longLabel(selectedPoint.key))
        } else if let average = resolved.average {
            NativeClockHero(
                caption: "Average",
                minutes: average,
                date: resolved.rangeLabel
            )
        } else {
            NativeHeroValue(caption: "Average", value: "No data")
        }
    }

    private var chart: some View {
        let deepTint = NativePaint.sleepStage(named: "Deep", style: style)
        let remTint = NativePaint.sleepStage(named: "REM", style: style)
        let whoop = style == .whoop
        return Chart {
            ForEach(keys, id: \.self) { key in
                BarMark(
                    x: .value("Day", key),
                    yStart: .value("Slot", 0),
                    yEnd: .value("Slot top", 0),
                    width: .ratio(whoop ? 0.42 : 0.5)
                )
                .foregroundStyle(Color.clear)
                .accessibilityHidden(true)
                if key == highlightKey {
                    RectangleMark(
                        x: .value("Day", key),
                        yStart: .value("Low", 0),
                        yEnd: .value("High", ceiling)
                    )
                    .foregroundStyle(whoop ? NativeTokens.whoopHighlight : NativeTokens.highlight)
                    .cornerRadius(8)
                    .accessibilityHidden(true)
                }
            }
            ForEach(slices) { slice in
                BarMark(
                    x: .value("Day", slice.key),
                    y: .value("Minutes", slice.value),
                    width: .ratio(whoop ? 0.42 : 0.5)
                )
                .foregroundStyle(by: .value("Stage", slice.series))
                .cornerRadius(whoop ? 3 : 4)
                .opacity(NativeChartScrubMath.barOpacity(
                    isSelected: slice.key == selectedKey,
                    hasSelection: selectedKey != nil
                ))
                .annotation(position: .top, spacing: 4) {
                    if slice.series == "Deep",
                       let total = NativeChartScrubMath.finitePoint(key: slice.key, in: totals) {
                        Text(NativeScoreMath.duration(total.value))
                            .font(whoop ? NativeTokens.whoopNumber(11, weight: .semibold) : .caption2.weight(.semibold))
                            .foregroundStyle(whoop ? NativeTokens.whoopLabel : Color.secondary)
                    }
                }
            }
        }
        .chartForegroundStyleScale([
            "Deep": deepTint,
            "REM": remTint,
        ])
        .chartLegend(.hidden)
        .chartXScale(domain: keys)
        .chartYScale(domain: 0...max(ceiling, 1))
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(position: .trailing, values: axisTicks) { value in
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
            AxisMarks(values: keys) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let key = value.as(String.self) {
                        NativeChartAxisLabel(key: key, highlighted: key == highlightKey)
                            .equatable()
                    }
                }
            }
        }
        .accessibilityLabel("Restorative sleep, deep and REM")
        .modifier(NativeSleepDaySelect(selected: $selectedKey))
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
            Section(name: "sleep-week-restorative", padded: true, view: AnyView(weekRestorative)),
            Section(name: "sleep-last-night", padded: true, view: AnyView(lastNight)),
            Section(name: "sleep-estimated-hypnogram", padded: true, view: AnyView(estimatedLastNight)),
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

    private static var weekRestorative: some View {
        let card = NativeSleepSnapshot.extraWeekCards.first { $0.title == "Restorative Sleep" }
        return NativeSleepRestorativeWeekCard(
            deep: card?.stacks.first { $0.title == "Deep" }?.points ?? [],
            rem: card?.stacks.first { $0.title == "REM" }?.points ?? [],
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

    private static var estimatedLastNight: some View {
        let json = NativeSleepEstimatedHypnogram.sampleTotalsJSON
        let start = NativeSleepSnapshot.sleepStart
        let end = start.addingTimeInterval(442 * 60)
        let spans = NativeSleepEstimatedHypnogram.spans(
            startTs: Int(start.timeIntervalSince1970),
            endTs: Int(end.timeIntervalSince1970),
            totals: SleepStageTotals.minutes(fromStagesJSON: json)!
        )
        return NativeLastNightCard(
            asleepMinutes: 395,
            stages: [
                NativeStage(name: "Awake", minutes: 47, typical: 45, tint: NativeChrome.sleepAwake),
                NativeStage(name: "Light", minutes: 157, typical: 240, tint: NativeChrome.sleepLight),
                NativeStage(name: "Deep", minutes: 125, typical: 80, tint: NativeChrome.sleepDeep),
                NativeStage(name: "REM", minutes: 113, typical: 95, tint: NativeChrome.sleepREM),
            ],
            sleepStart: start,
            sleepEnd: end,
            spans: spans,
            hypnogramEstimated: true
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

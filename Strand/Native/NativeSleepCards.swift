import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// Sleep-page cards. Apple Health chrome, WHOOP order and functions.

struct NativeSleepHoursVsNeededCard: View {
    var model: NativeSleepNeed.Resolved
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: "Hours vs. Needed",
                symbol: "clock.fill",
                tint: NativePaint.sleep(style)
            )
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hours vs. Needed")
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
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: "Sleep Consistency",
                symbol: "calendar",
                tint: NativePaint.sleep(style)
            )
            if let percent {
                NativeHeroValue(
                    caption: "Last night",
                    value: "\(Int(percent.rounded()))",
                    unit: "%"
                )
            }
            NativeSleepConsistencyChart(nights: nights, tint: NativePaint.sleep(style))
                .frame(height: 220)
        }
    }
}

struct NativeSleepConsistencyChart: View {
    var nights: [NativeSleepNight]
    var tint: Color
    @Environment(\.nativeStyle) private var style

    private var avgBed: Double? { NativeSleepConsistency.averageBed(nights) }
    private var avgWake: Double? { NativeSleepConsistency.averageWake(nights) }

    var body: some View {
        Chart {
            ForEach(nights) { night in
                BarMark(
                    x: .value("Day", night.key),
                    yStart: .value("Wake", NativeSleepClock.plotY(night.wakeFromEvening)),
                    yEnd: .value("Bed", NativeSleepClock.plotY(night.bedFromEvening)),
                    width: 14
                )
                .foregroundStyle(night.isToday ? tint : Color.secondary.opacity(0.45))
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
    }
}

struct NativeSleepEfficiencyCard: View {
    var model: NativeSleepEfficiency.Model
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: "Sleep Efficiency",
                symbol: "bed.double.fill",
                tint: NativePaint.sleep(style)
            )
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
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: "Sleep Stress",
                symbol: "waveform.path",
                tint: NativePaint.sleep(style)
            )
            NativeHeroValue(
                caption: "Average",
                value: String(format: "%.1f", model.points.map(\.value).reduce(0, +) / Double(max(model.points.count, 1))),
                unit: nil
            )
            NativeSleepStressPlot(points: model.points, tint: NativePaint.sleep(style))
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

struct NativeSleepStressPlot: View {
    var points: [NativeHourPoint]
    var tint: Color

    var body: some View {
        Chart {
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
    }
}

struct NativeSleepDualLineCard: View {
    var title: String
    var slept: [NativeDayPoint]
    var needed: [NativeDayPoint]
    var highlightKey: String?
    @Environment(\.nativeStyle) private var style

    private var knownSlept: [NativeDayPoint] { slept.filter { $0.value.isFinite } }
    private var knownNeeded: [NativeDayPoint] { needed.filter { $0.value.isFinite } }
    private var yDomain: ClosedRange<Double> {
        NativeChartDay.fittedDomain(
            (knownSlept + knownNeeded).map(\.value),
            fallback: 0...480
        )
    }

    var body: some View {
        NativeChrome.panel {
            HStack(spacing: 6) {
                Image(systemName: "clock.fill")
                    .foregroundStyle(NativePaint.sleep(style))
                Text(title)
                    .foregroundStyle(NativePaint.sleep(style))
                Spacer(minLength: 8)
                NativeSleepSeriesKey(color: NativeTokens.sleep, name: "Hours of Sleep")
                NativeSleepSeriesKey(color: Color.secondary, name: "Sleep Needed")
            }
            .font(.footnote.weight(.semibold))
            hero
            plot.frame(height: 200)
        }
    }

    @ViewBuilder private var hero: some View {
        if let average = NativeScoreMath.mean(knownSlept.map(\.value)) {
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
                    .symbol { NativeSleepVertex(tint: NativeTokens.sleep) }
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
    @Environment(\.nativeStyle) private var style

    private var known: [NativeDayPoint] {
        points.filter { $0.value.isFinite || ($0.low != nil && $0.high != nil) }
    }

    var body: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: "Time in Bed",
                symbol: "bed.double.fill",
                tint: NativePaint.sleep(style)
            )
            hero
            plot.frame(height: 200)
        }
    }

    @ViewBuilder private var hero: some View {
        if let average = NativeScoreMath.mean(known.compactMap { $0.value.isFinite ? $0.value : nil }) {
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
                    .foregroundStyle(point.key == highlightKey ? NativePaint.sleep(style) : Color.secondary.opacity(0.45))
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
            highlightKey: NativeSleepSnapshot.highlightKey
        )
    }

    private static var weekInBed: some View {
        NativeSleepTimeInBedWeekCard(
            points: NativeSleepSnapshot.pageDetail.timeInBedWeek,
            highlightKey: NativeSleepSnapshot.highlightKey
        )
    }
}

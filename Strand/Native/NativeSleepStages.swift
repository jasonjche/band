import SwiftUI
import StrandDesign

// Last Night hypnogram, shared-scale stage bars, and the per-stage detail page.

struct NativeScoreMetricRoute: Hashable {
    var key: String
}

struct NativeScoreTrendRoute: Hashable {
    var title: String
}

struct NativeSleepStageRoute: Hashable {
    var kind: NativeSleepStageKind
}

struct NativeSleepHypnogramRoute: Hashable {}

struct NativeSleepConsistencyRoute: Hashable {}

struct NativeSleepLightHaptic<Value: Equatable>: ViewModifier {
    var trigger: Value
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.sensoryFeedback(.impact(weight: .light), trigger: trigger)
        } else {
            content
        }
    }
}

struct NativeSleepHypnogram: View {
    var spans: [NativeSleepStageSpan]
    var nightStart: Date
    var nightEnd: Date
    var highlight: NativeSleepStageKind? = nil
    var plotHeight: CGFloat = 132
    var estimated: Bool = false
    var onOpen: (() -> Void)? = nil
    @Environment(\.nativeStyle) private var style
    @State private var scrub = NativeScopeScrub()

    private var startTs: Int { Int(nightStart.timeIntervalSince1970) }
    private var endTs: Int { Int(nightEnd.timeIntervalSince1970) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeSleepHypnogramReadout(scrub: scrub, spans: spans, style: style)
                .frame(height: 36, alignment: .topLeading)
            NativeSleepHypnogramPlot(
                spans: spans,
                startTs: startTs,
                endTs: endTs,
                highlight: highlight,
                scrub: scrub,
                onOpen: onOpen
            )
            .frame(height: plotHeight)
            axis
            if estimated {
                Text(NativeSleepEstimatedHypnogram.caption)
                    .font(style == .whoop ? NativeTokens.whoopCaps(10) : .caption2)
                    .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                    .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(estimated
            ? "\(NativeSleepEstimatedHypnogram.caption). Sleep stages from \(NativeSleepClock.clock(nightStart)) to \(NativeSleepClock.clock(nightEnd))"
            : "Sleep stages from \(NativeSleepClock.clock(nightStart)) to \(NativeSleepClock.clock(nightEnd))")
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
    }

    private var axis: some View {
        HStack {
            Spacer().frame(width: 48)
            ForEach(Array(NativeSleepHypnogramMath.axisTimes(start: nightStart, end: nightEnd).enumerated()), id: \.offset) { index, time in
                if index > 0 { Spacer(minLength: 0) }
                Text(NativeSleepClock.clock(time))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

private struct NativeSleepHypnogramReadout: View {
    @ObservedObject var scrub: NativeScopeScrub
    var spans: [NativeSleepStageSpan]
    var style: NativeStyle

    var body: some View {
        Group {
            if let time = scrub.time,
               let span = NativeSleepHypnogramMath.span(at: Int(time.timeIntervalSince1970), spans: spans) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(span.kind.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NativePaint.sleepStage(named: span.kind.title, style: style))
                    Text(NativeSleepClock.clock(time))
                        .font(StrandFont.rounded(15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeSleepHypnogramPlot: View {
    var spans: [NativeSleepStageSpan]
    var startTs: Int
    var endTs: Int
    var highlight: NativeSleepStageKind?
    @ObservedObject var scrub: NativeScopeScrub
    var onOpen: (() -> Void)?
    @Environment(\.nativeStyle) private var style

    var body: some View {
        GeometryReader { geo in
            let plotWidth = max(geo.size.width - 48, 1)
            let laneH = geo.size.height / 4
            let selected = scrub.time.flatMap {
                NativeSleepHypnogramMath.span(at: Int($0.timeIntervalSince1970), spans: spans)
            }
            ZStack(alignment: .topLeading) {
                ForEach(Array(NativeSleepStageKind.hypnogramLanes.enumerated()), id: \.element) { index, lane in
                    Text(lane.title)
                        .font(.caption2)
                        .foregroundStyle(highlight == lane ? Color.primary : Color.secondary)
                        .frame(width: 44, height: laneH, alignment: .leading)
                        .offset(y: CGFloat(index) * laneH)
                }
                ForEach(spans) { span in
                    if let range = NativeSleepHypnogramMath.xRange(
                        start: span.startTs, end: span.endTs,
                        nightStart: startTs, nightEnd: endTs,
                        width: plotWidth
                    ) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(NativePaint.sleepStage(named: span.kind.title, style: style)
                                .opacity(NativeSleepHypnogramMath.spanOpacity(
                                    span: span, selected: selected, highlight: highlight
                                )))
                            .frame(width: max(range.width, 1), height: max(laneH * 0.55, 6))
                            .offset(
                                x: 48 + range.x,
                                y: CGFloat(laneIndex(span.kind)) * laneH + laneH * 0.22
                            )
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard NativeChartScrubMath.isHorizontalScrub(translation: value.translation) else { return }
                        let x = Double(min(max(value.location.x - 48, 0), plotWidth))
                        let ts = NativeSleepHypnogramMath.timestamp(
                            x: x, width: plotWidth, nightStart: startTs, nightEnd: endTs
                        )
                        scrub.time = Date(timeIntervalSince1970: TimeInterval(ts))
                    }
                    .onEnded { _ in scrub.time = nil }
            )
            .onTapGesture { onOpen?() }
        }
    }

    private func laneIndex(_ kind: NativeSleepStageKind) -> Int {
        NativeSleepStageKind.hypnogramLanes.firstIndex(of: kind) ?? 2
    }
}

struct NativeSleepHypnogramPage: View {
    var spans: [NativeSleepStageSpan]
    var nightStart: Date?
    var nightEnd: Date?
    var stages: [NativeStage]
    var asleepMinutes: Double?
    var awakeTypical: Double?
    var estimated: Bool = false
    var scrolls: Bool = true
    @Environment(\.nativeStyle) private var style

    var body: some View {
        Group {
            if scrolls {
                NativeChrome.screen { detailBody }
            } else {
                NativeChrome.stack { detailBody }
            }
        }
        .navigationTitle("Sleep Stages")
        .modifier(NativeInlineTitle())
    }

    @ViewBuilder private var detailBody: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: "Last night",
                symbol: "bed.double.fill",
                tint: NativePaint.sleep(style)
            )
            if let nightStart, let nightEnd, nightEnd > nightStart, !spans.isEmpty {
                NativeSleepHypnogram(
                    spans: spans,
                    nightStart: nightStart,
                    nightEnd: nightEnd,
                    plotHeight: 220,
                    estimated: estimated
                )
            }
        }
        if !nightRows.isEmpty {
            NativeChrome.panel {
                let scale = max(
                    NativeDayLogic.inBedMinutes(start: nightStart, end: nightEnd)
                        ?? nightRows.compactMap(\.minutes).reduce(0, +),
                    1
                )
                ForEach(nightRows) { stage in
                    NativeSleepStageRow(
                        kind: NativeSleepStageKind.parse(stage.name),
                        minutes: stage.minutes ?? 0,
                        percent: NativeSleepHypnogramMath.share(minutes: stage.minutes ?? 0, inBed: scale) * 100,
                        typical: stage.typical,
                        scale: scale
                    )
                }
            }
        }
    }

    private var nightRows: [NativeStage] {
        NativeSleepNightRows.make(
            stages: stages,
            inBedMinutes: NativeDayLogic.inBedMinutes(start: nightStart, end: nightEnd),
            asleepMinutes: asleepMinutes,
            awakeTypical: awakeTypical
        )
    }
}

struct NativeSleepStageShareBar: View {
    var minutes: Double
    var typical: Double?
    var scale: Double
    var tint: Color
    @Environment(\.nativeStyle) private var style

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                NativeWhoopHatch(color: style == .whoop ? NativeTokens.whoopHatch : NativeTokens.separator)
                    .frame(width: width, height: 10)
                Capsule()
                    .fill(tint)
                    .frame(
                        width: max(minutes > 0 ? 4 : 0, NativeSleepHypnogramMath.barWidth(
                            minutes: minutes, inBed: scale, width: width
                        )),
                        height: 10
                    )
                if let typical, typical > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 2, height: 16)
                        .offset(x: max(0, NativeSleepHypnogramMath.barWidth(
                            minutes: typical, inBed: scale, width: width
                        ) - 1))
                }
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

struct NativeSleepStageRow: View {
    var kind: NativeSleepStageKind
    var minutes: Double
    var percent: Double
    var typical: Double?
    var scale: Double
    var chevron: Bool = false
    var selected: Bool = false
    var dimmed: Bool = false
    var tappable: Bool = false
    @Environment(\.nativeStyle) private var style

    var body: some View {
        let tint = NativePaint.sleepStage(named: kind.title, style: style)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(tint, lineWidth: 2)
                    .background(Circle().fill(selected ? tint : Color.clear))
                    .frame(width: 14, height: 14)
                Text(label)
                    .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline.weight(.semibold))
                    .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                    .foregroundStyle(Color.primary)
                Text("\(Int(percent.rounded()))%")
                    .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline)
                    .foregroundStyle(tint)
                Spacer(minLength: 8)
                Text(NativeScoreMath.duration(minutes))
                    .font(style == .whoop ? NativeTokens.whoopNumber(17, weight: .semibold) : StrandFont.rounded(17, weight: .semibold))
                    .monospacedDigit()
                if chevron {
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            NativeSleepStageShareBar(minutes: minutes, typical: typical, scale: scale, tint: tint)
        }
        .padding(.vertical, 6)
        .opacity(dimmed ? 0.35 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(NativeScoreMath.duration(minutes)), \(Int(percent.rounded())) percent")
        .accessibilityAddTraits(tappable || chevron ? .isButton : [])
        .accessibilityHint(tappable ? (selected ? "Clears the stage highlight" : "Highlights this stage on the graph") : "")
    }

    private var label: String {
        if style == .whoop {
            if kind == .light { return "LIGHT" }
            if kind == .deep { return "SWS (DEEP)" }
            return kind.title.uppercased()
        }
        return kind.title
    }
}

struct NativeSleepStageDetailView: View {
    var detail: NativeSleepStageDetail
    var spans: [NativeSleepStageSpan]
    var nightStart: Date?
    var nightEnd: Date?
    var dayKey: String?
    var estimated: Bool = false
    var scrolls: Bool = true
    @Environment(\.nativeStyle) private var style

    private var tint: Color { NativePaint.sleepStage(named: detail.kind.title, style: style) }
    private var highlighted: [NativeSleepStageSpan] {
        spans.filter { $0.kind == detail.kind }
    }

    var body: some View {
        Group {
            if scrolls {
                NativeChrome.screen { detailBody }
            } else {
                NativeChrome.stack { detailBody }
            }
        }
        .navigationTitle(detail.kind.title)
        .modifier(NativeInlineTitle())
    }

    @ViewBuilder private var detailBody: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: detail.kind.title,
                symbol: "moon.zzz.fill",
                tint: tint
            )
            if let minutes = detail.minutes {
                NativeClockHero(caption: "Last night", minutes: minutes)
            }
            if let percent = detail.percent {
                Text("\(Int(percent.rounded()))% of time in bed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let typical = detail.typical {
                NativeContributorRow(
                    symbol: "calendar",
                    title: "Typical",
                    value: NativeScoreMath.duration(typical),
                    tint: tint
                )
            }
        }
        if detail.trend.contains(where: { $0.value.isFinite }) {
            NativeChrome.panel {
                NativeCardHeader(
                    title: detail.kind.title,
                    symbol: "chart.bar.fill",
                    tint: tint
                )
                NativeChartBlock(
                    points: detail.trend,
                    bars: true,
                    tint: tint,
                    format: { NativeScoreMath.duration($0) },
                    axisFormat: { NativeScoreMath.duration($0) },
                    maxY: max(detail.trend.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 60),
                    highlightKey: dayKey,
                    plotHeight: 160,
                    accessibilityName: detail.kind.title,
                    clockHero: true
                )
            }
        }
        if !highlighted.isEmpty, let nightStart, let nightEnd, nightEnd > nightStart {
            NativeChrome.panel {
                NativeCardHeader(
                    title: "Last night",
                    symbol: "bed.double.fill",
                    tint: tint
                )
                NativeSleepHypnogram(
                    spans: spans,
                    nightStart: nightStart,
                    nightEnd: nightEnd,
                    highlight: detail.kind,
                    estimated: estimated
                )
            }
        }
        NativeChrome.footnote(detail.kind.about)
    }
}

struct NativeScoreTrendPage: View {
    var card: NativeWeek.Card
    var dayKey: String?
    var format: (Double) -> String
    var axisFormat: (Double) -> String
    var unit: String?
    var symbol: String
    var tint: Color
    var color: ((Double) -> Color)? = nil

    var body: some View {
        NativeChrome.screen {
            NativeChrome.panel {
                NativeCardHeader(
                    title: card.title,
                    symbol: symbol,
                    tint: tint
                )
                if card.title == "Restorative Sleep", !card.stacks.isEmpty {
                    NativeSleepRestorativeChart(
                        deep: card.stacks.first { $0.title == "Deep" }?.points ?? [],
                        rem: card.stacks.first { $0.title == "REM" }?.points ?? [],
                        highlightKey: dayKey,
                        plotHeight: 200
                    )
                } else {
                    NativeChartBlock(
                        points: card.points,
                        bars: card.bars,
                        tint: tint,
                        format: format,
                        axisFormat: axisFormat,
                        unit: unit,
                        maxY: card.maxY,
                        color: color,
                        highlightKey: dayKey,
                        plotHeight: 200,
                        accessibilityName: card.title,
                        clockHero: card.format == .duration,
                        yTicks: card.format == .strain ? NativeDayLogic.strainYTicks(maxY: card.maxY) : nil,
                        stacks: card.stacks
                    )
                }
            }
        }
        .navigationTitle(card.title)
        .modifier(NativeInlineTitle())
    }
}

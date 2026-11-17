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

struct NativeSleepHypnogram: View {
    var spans: [NativeSleepStageSpan]
    var nightStart: Date
    var nightEnd: Date
    var highlight: NativeSleepStageKind? = nil
    var plotHeight: CGFloat = 132
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
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep stages from \(NativeSleepClock.clock(nightStart)) to \(NativeSleepClock.clock(nightEnd))")
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
                    plotHeight: 220
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
        var rows = stages
        let inBed = NativeDayLogic.inBedMinutes(start: nightStart, end: nightEnd)
        if !rows.contains(where: { $0.name == "Awake" }),
           let inBed, let asleepMinutes, inBed > asleepMinutes {
            rows.insert(
                NativeStage(name: "Awake", minutes: inBed - asleepMinutes, typical: awakeTypical, tint: NativeTokens.sleepAwake),
                at: 0
            )
        } else if let idx = rows.firstIndex(where: { $0.name == "Awake" }),
                  rows[idx].typical == nil, let awakeTypical {
            rows[idx].typical = awakeTypical
        }
        let order = ["Awake", "Light", "Deep", "REM"]
        return rows.sorted { (order.firstIndex(of: $0.name) ?? 99) < (order.firstIndex(of: $1.name) ?? 99) }
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
    @Environment(\.nativeStyle) private var style

    var body: some View {
        let tint = NativePaint.sleepStage(named: kind.title, style: style)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(tint, lineWidth: 2)
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
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(NativeScoreMath.duration(minutes)), \(Int(percent.rounded())) percent")
        .accessibilityAddTraits(chevron ? .isButton : [])
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
                    highlight: detail.kind
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
        .navigationTitle(card.title)
        .modifier(NativeInlineTitle())
    }
}

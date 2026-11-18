import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Pure helpers for the sleep / activity `[start, end]` scrubber: context range,
/// 1-minute snap, handle hit-testing, independent-edge clamp, and in-window HR.
enum NativeTimeWindowEditorLogic {
    static let bucketSeconds = 60
    static let chartHeight: CGFloat = 200
    static let handleHit: CGFloat = 44
    static let minDuration: TimeInterval = 60
    static let hapticStep: TimeInterval = 5 * 60
    static let activityPad: TimeInterval = 2 * 3600
    static let sleepPad: TimeInterval = 90 * 60
    static let sleepMaxSpan: TimeInterval = 14 * 3600
    static let nudgeMinutes = [-15, -5, 5, 15]
    static let emptyWindowMessage = "No heart rate for this time"
    static let emptyChartMessage = "No heart rate stored for this time"
    static let displaySmoothWindow: TimeInterval = 180

    enum Kind: Equatable {
        case sleep
        case activity
    }

    enum Edge: Equatable {
        case start
        case end
        case window
    }

    struct Sample: Equatable {
        var ts: Int
        var bpm: Double
        var minBpm: Double
        var maxBpm: Double

        init(ts: Int, bpm: Double, minBpm: Double? = nil, maxBpm: Double? = nil) {
            self.ts = ts
            self.bpm = bpm
            self.minBpm = minBpm ?? bpm
            self.maxBpm = maxBpm ?? bpm
        }

        init(_ bucket: HRBucket) {
            self.ts = bucket.ts
            self.bpm = bucket.bpm
            self.minBpm = bucket.minBpm
            self.maxBpm = bucket.maxBpm
        }
    }

    struct WindowStats: Equatable {
        var average: Int
        var min: Int
        var max: Int
    }

    struct SegmentPoint: Equatable, Identifiable {
        var time: Date
        var value: Double
        var segment: Int
        var id: String { "\(segment)-\(time.timeIntervalSince1970)" }
    }

    static func title(for kind: Kind) -> LocalizedStringKey {
        switch kind {
        case .sleep: return "Edit sleep times"
        case .activity: return "Edit activity times"
        }
    }

    static func blurb(for kind: Kind) -> LocalizedStringKey {
        switch kind {
        case .sleep:
            return "Correct when you went to bed and woke. Stages are re-derived from your data; the edit is kept through the next strap sync."
        case .activity:
            return "Drag the Start and End handles, or nudge by a few minutes. Heart rate in the window updates as you drag."
        }
    }

    static func startLabel(for kind: Kind) -> LocalizedStringKey {
        switch kind {
        case .sleep: return "Bedtime"
        case .activity: return "Start"
        }
    }

    static func endLabel(for kind: Kind) -> LocalizedStringKey {
        switch kind {
        case .sleep: return "Wake"
        case .activity: return "End"
        }
    }

    static func handleStartTitle(for kind: Kind) -> String {
        switch kind {
        case .sleep: return "Bedtime"
        case .activity: return "Start"
        }
    }

    static func handleEndTitle(for kind: Kind) -> String {
        switch kind {
        case .sleep: return "Wake"
        case .activity: return "End"
        }
    }

    static func deleteLabel(for kind: Kind) -> LocalizedStringKey {
        switch kind {
        case .sleep: return "Delete this sleep"
        case .activity: return "Delete this activity"
        }
    }

    static func deleteConfirmTitle(for kind: Kind) -> LocalizedStringKey {
        switch kind {
        case .sleep: return "Delete this sleep session?"
        case .activity: return "Delete this activity?"
        }
    }

    /// Padded chart domain around the seed window. Sleep pads ±90 m (capped near 14 h)
    /// so onset and wake sit inside a readable overnight HR drop / rise. Activity
    /// pads ±2 h and never past `now`.
    static func contextRange(
        kind: Kind,
        seedStart: Date,
        seedEnd: Date,
        now: Date
    ) -> (start: Date, end: Date) {
        let pad = kind == .sleep ? sleepPad : activityPad
        var start = seedStart.addingTimeInterval(-pad)
        var end = min(now, seedEnd.addingTimeInterval(pad))
        if end <= start {
            end = min(now, start.addingTimeInterval(minDuration))
        }
        if kind == .sleep {
            let span = end.timeIntervalSince(start)
            if span > sleepMaxSpan {
                let needed = max(minDuration, seedEnd.timeIntervalSince(seedStart))
                let remaining = max(0, sleepMaxSpan - needed)
                start = seedStart.addingTimeInterval(-remaining / 2)
                end = min(now, seedEnd.addingTimeInterval(remaining / 2))
                if end.timeIntervalSince(start) > sleepMaxSpan {
                    start = end.addingTimeInterval(-sleepMaxSpan)
                }
            }
        }
        if end <= start {
            end = min(now, start.addingTimeInterval(minDuration))
        }
        return (start, end)
    }

    static func snapToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.toNearestOrAwayFromZero) * 60)
    }

    static func hapticBucket(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / hapticStep).rounded(.towardZero))
    }

    /// Near the left handle → start; near the right → end; inside the band → slide.
    /// Outside the band, the closer handle wins.
    static func hitEdge(
        x: CGFloat,
        startX: CGFloat,
        endX: CGFloat,
        hit: CGFloat = handleHit
    ) -> Edge {
        let distStart = abs(x - startX)
        let distEnd = abs(x - endX)
        if distStart <= hit && distStart <= distEnd { return .start }
        if distEnd <= hit { return .end }
        let lo = min(startX, endX)
        let hi = max(startX, endX)
        if x > lo && x < hi { return .window }
        return distStart <= distEnd ? .start : .end
    }

    static func clampStart(
        _ start: Date,
        keepingEnd end: Date,
        now: Date,
        bounds: ClosedRange<Date>,
        minDuration: TimeInterval = minDuration
    ) -> (start: Date, end: Date) {
        let cap = min(bounds.upperBound, now)
        let earliest = bounds.lowerBound
        var s = snapToMinute(start)
        var e = snapToMinute(end)
        if e > cap { e = cap }
        let latest = e.addingTimeInterval(-minDuration)
        if s > latest { s = latest }
        if s < earliest {
            s = earliest
            if e.timeIntervalSince(s) < minDuration {
                e = min(s.addingTimeInterval(minDuration), cap)
            }
        }
        if e.timeIntervalSince(s) < minDuration {
            s = e.addingTimeInterval(-minDuration)
            if s < earliest {
                s = earliest
                e = min(s.addingTimeInterval(minDuration), cap)
            }
        }
        return (s, e)
    }

    static func clampEnd(
        _ end: Date,
        keepingStart start: Date,
        now: Date,
        bounds: ClosedRange<Date>,
        minDuration: TimeInterval = minDuration
    ) -> (start: Date, end: Date) {
        let cap = min(bounds.upperBound, now)
        let earliest = bounds.lowerBound
        var s = snapToMinute(start)
        var e = snapToMinute(end)
        if s < earliest { s = earliest }
        let earliestEnd = s.addingTimeInterval(minDuration)
        if e < earliestEnd { e = earliestEnd }
        if e > cap {
            e = cap
            if e.timeIntervalSince(s) < minDuration {
                s = e.addingTimeInterval(-minDuration)
                if s < earliest {
                    s = earliest
                    e = min(s.addingTimeInterval(minDuration), cap)
                }
            }
        }
        return (s, e)
    }

    static func slideWindow(
        start: Date,
        end: Date,
        delta: TimeInterval,
        now: Date,
        bounds: ClosedRange<Date>,
        minDuration: TimeInterval = minDuration
    ) -> (start: Date, end: Date) {
        let cap = min(bounds.upperBound, now)
        let earliest = bounds.lowerBound
        let held = max(minDuration, end.timeIntervalSince(start))
        var s = snapToMinute(start.addingTimeInterval(delta))
        var e = s.addingTimeInterval(held)
        if s < earliest {
            s = earliest
            e = s.addingTimeInterval(held)
        }
        if e > cap {
            e = cap
            s = e.addingTimeInterval(-held)
        }
        if s < earliest {
            s = earliest
            e = min(s.addingTimeInterval(held), cap)
        }
        return (s, e)
    }

    static func applyDrag(
        edge: Edge,
        finger: Date,
        origin: Date,
        anchorStart: Date,
        anchorEnd: Date,
        now: Date,
        bounds: ClosedRange<Date>,
        minDuration: TimeInterval = minDuration
    ) -> (start: Date, end: Date) {
        switch edge {
        case .start:
            return clampStart(finger, keepingEnd: anchorEnd, now: now, bounds: bounds, minDuration: minDuration)
        case .end:
            return clampEnd(finger, keepingStart: anchorStart, now: now, bounds: bounds, minDuration: minDuration)
        case .window:
            return slideWindow(
                start: anchorStart,
                end: anchorEnd,
                delta: finger.timeIntervalSince(origin),
                now: now,
                bounds: bounds,
                minDuration: minDuration
            )
        }
    }

    static func nudgeStart(
        start: Date,
        end: Date,
        minutes: Int,
        now: Date,
        bounds: ClosedRange<Date>
    ) -> (start: Date, end: Date) {
        clampStart(
            start.addingTimeInterval(TimeInterval(minutes * 60)),
            keepingEnd: end,
            now: now,
            bounds: bounds
        )
    }

    static func nudgeEnd(
        start: Date,
        end: Date,
        minutes: Int,
        now: Date,
        bounds: ClosedRange<Date>
    ) -> (start: Date, end: Date) {
        clampEnd(
            end.addingTimeInterval(TimeInterval(minutes * 60)),
            keepingStart: start,
            now: now,
            bounds: bounds
        )
    }

    static func nudgeLabel(_ minutes: Int) -> String {
        minutes > 0 ? "+\(minutes)m" : "\(minutes)m"
    }

    static func nudgeAccessibility(_ minutes: Int) -> String {
        let amount = abs(minutes)
        let unit = amount == 1 ? "minute" : "minutes"
        return minutes < 0 ? "Minus \(amount) \(unit)" : "Plus \(amount) \(unit)"
    }

    static func durationLabel(from start: Date, to end: Date) -> String {
        let total = max(0, Int(end.timeIntervalSince(start).rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }

    static func rangeLabel(start: Date, end: Date, calendar: Calendar = .current) -> String {
        "\(NativeScopeFormat.time(start, calendar: calendar)) – \(NativeScopeFormat.time(end, calendar: calendar))"
    }

    static func windowStats(
        samples: [Sample],
        start: Date,
        end: Date
    ) -> WindowStats? {
        let lo = Int(start.timeIntervalSince1970)
        let hi = Int(end.timeIntervalSince1970)
        let inside = samples.filter { $0.ts >= lo && $0.ts < hi }
        guard !inside.isEmpty else { return nil }
        let average = inside.map(\.bpm).reduce(0, +) / Double(inside.count)
        let low = inside.map(\.minBpm).min() ?? inside.map(\.bpm).min()!
        let high = inside.map(\.maxBpm).max() ?? inside.map(\.bpm).max()!
        return WindowStats(
            average: Int(average.rounded()),
            min: Int(low.rounded()),
            max: Int(high.rounded())
        )
    }

    static func windowReadout(_ stats: WindowStats?) -> String {
        guard let stats else { return emptyWindowMessage }
        return "Avg \(stats.average) BPM · \(stats.min)–\(stats.max) BPM"
    }

    static func segments(
        samples: [Sample],
        bucketSeconds: Int = bucketSeconds
    ) -> [SegmentPoint] {
        let ordered = samples.sorted { $0.ts < $1.ts }
        var segment = 0
        var lastTs: Int?
        var result: [SegmentPoint] = []
        for sample in ordered {
            if let lastTs, sample.ts - lastTs > bucketSeconds {
                segment += 1
            }
            result.append(SegmentPoint(
                time: Date(timeIntervalSince1970: TimeInterval(sample.ts)),
                value: sample.bpm,
                segment: segment
            ))
            lastTs = sample.ts
        }
        return result
    }

    static func smoothed(_ samples: [Sample], window: TimeInterval = displaySmoothWindow) -> [Sample] {
        let points = samples.map {
            NativeHourPoint(time: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm)
        }
        let smoothed = NativeHRSmoothing.smooth(points, window: window)
        guard !smoothed.isEmpty else { return samples }
        var byTs: [Int: Double] = [:]
        for point in smoothed {
            byTs[Int(point.time.timeIntervalSince1970)] = point.value
        }
        return samples.map { sample in
            var copy = sample
            if let value = byTs[sample.ts] { copy.bpm = value }
            return copy
        }
    }

    static func validatedSleepWindow(start: Date, end: Date, now: Date) -> (start: Int, end: Int)? {
        SleepEditGuard.clampedEditWindow(
            start: Int(start.timeIntervalSince1970),
            end: Int(end.timeIntervalSince1970),
            now: Int(now.timeIntervalSince1970)
        )
    }
}

struct NativeTimeWindowNudgeRow: View {
    var onNudge: (Int) -> Void
    @Environment(\.nativeStyle) private var style

    var body: some View {
        HStack(spacing: 8) {
            ForEach(NativeTimeWindowEditorLogic.nudgeMinutes, id: \.self) { minutes in
                Button {
                    onNudge(minutes)
                } label: {
                    Text(NativeTimeWindowEditorLogic.nudgeLabel(minutes))
                        .font(style == .whoop ? NativeTokens.whoopCaps(12) : .caption.weight(.semibold))
                        .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(NativePaint.separator(style).opacity(0.22))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NativeTimeWindowEditorLogic.nudgeAccessibility(minutes))
            }
            Spacer(minLength: 0)
        }
    }
}

/// Vertical pill handles at the window edges. 44 pt hit targets live on the drag overlay.
struct NativeTimeWindowHandlePills: View {
    var startX: CGFloat
    var endX: CGFloat
    var plot: CGRect
    var startTitle: String
    var endTitle: String
    var tint: Color
    @Environment(\.nativeStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            handle(x: startX, title: startTitle)
            handle(x: endX, title: endTitle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func handle(x: CGFloat, title: String) -> some View {
        let barWidth: CGFloat = 3
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(tint)
                .frame(width: barWidth, height: max(plot.height, 1))
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(NativePaint.card(style))
                        .shadow(
                            color: NativePaint.separator(style).opacity(reduceMotion ? 0 : 0.35),
                            radius: reduceMotion ? 0 : 2,
                            y: reduceMotion ? 0 : 1
                        )
                )
                .overlay(
                    Capsule().stroke(tint, lineWidth: 1.5)
                )
                .offset(y: -10)
        }
        .frame(width: NativeTimeWindowEditorLogic.handleHit, height: plot.height)
        .position(x: x, y: plot.midY)
    }
}

/// Context HR chart with a tinted `[start, end]` band and two drag handles.
struct NativeTimeWindowRangeChart: View {
    var samples: [NativeTimeWindowEditorLogic.Sample]
    var windowStart: Date
    var windowEnd: Date
    var rangeStart: Date
    var rangeEnd: Date
    var tint: Color
    var startTitle: String
    var endTitle: String
    var now: Date
    var onMove: (Date, Date) -> Void

    @Environment(\.nativeStyle) private var style
    @State private var dragEdge: NativeTimeWindowEditorLogic.Edge?
    @State private var dragOrigin: Date?
    @State private var dragAnchorStart: Date?
    @State private var dragAnchorEnd: Date?
    @State private var hapticBucket: Int?

    private var xDomain: ClosedRange<Date> { rangeStart...rangeEnd }

    private var points: [NativeTimeWindowEditorLogic.SegmentPoint] {
        NativeTimeWindowEditorLogic.segments(samples: NativeTimeWindowEditorLogic.smoothed(samples))
            .filter { NativePlotAxis.inTimeDomain($0.time, xDomain) }
    }

    private var yDomain: ClosedRange<Double> {
        NativePlotAxis.yDomain(points.map(\.value), fallback: 40...100)
    }

    private var bandStart: Date { max(windowStart, rangeStart) }
    private var bandEnd: Date { min(windowEnd, rangeEnd) }

    private var readout: String {
        NativeTimeWindowEditorLogic.windowReadout(
            NativeTimeWindowEditorLogic.windowStats(samples: samples, start: windowStart, end: windowEnd)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .whoop ? 12 : 10) {
            plot.frame(height: NativeTimeWindowEditorLogic.chartHeight)
            Text(readout)
                .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline)
                .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Heart rate")
        .accessibilityValue(readout)
        .accessibilityHint("Drag the \(startTitle) or \(endTitle) handle to set the window")
        .modifier(NativeSelectionFeedback(trigger: hapticBucket ?? 0))
    }

    private var plot: some View {
        Chart {
            if bandEnd > bandStart {
                RectangleMark(
                    xStart: .value("Window start", bandStart),
                    xEnd: .value("Window end", bandEnd),
                    yStart: .value("Low", yDomain.lowerBound),
                    yEnd: .value("High", yDomain.upperBound)
                )
                .foregroundStyle(tint.opacity(0.22))
                .accessibilityHidden(true)
            }
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value("HR", point.value),
                    series: .value("Series", "HR-\(point.segment)")
                )
                .foregroundStyle(lineTint)
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .trailing, values: NativePlotAxis.yTicks(in: yDomain)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let bpm = value.as(Double.self) {
                        Text("\(Int(bpm.rounded()))")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: NativePlotAxis.timeTicks(start: rangeStart, end: rangeEnd)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(NativePlotAxis.clockLabel(date))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { $0.clipped() }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ZStack {
                    if plot.width > 1,
                       let startPos = proxy.position(forX: bandStart),
                       let endPos = proxy.position(forX: bandEnd) {
                        NativeTimeWindowHandlePills(
                            startX: plot.origin.x + startPos,
                            endX: plot.origin.x + endPos,
                            plot: plot,
                            startTitle: startTitle,
                            endTitle: endTitle,
                            tint: tint
                        )
                    }
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    applyDrag(value.location, proxy: proxy, geo: geo)
                                }
                                .onEnded { _ in
                                    dragEdge = nil
                                    dragOrigin = nil
                                    dragAnchorStart = nil
                                    dragAnchorEnd = nil
                                    hapticBucket = nil
                                }
                        )
                }
            }
        }
    }

    private var lineTint: Color {
        style == .whoop ? NativeTokens.whoopLabel : Color.primary
    }

    private func applyDrag(_ location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let date = dateAt(location, proxy: proxy, geo: geo) else { return }
        let plot = proxy.plotRectCompat(in: geo)
        if dragEdge == nil {
            guard let startPos = proxy.position(forX: windowStart),
                  let endPos = proxy.position(forX: windowEnd) else { return }
            dragEdge = NativeTimeWindowEditorLogic.hitEdge(
                x: location.x,
                startX: plot.origin.x + startPos,
                endX: plot.origin.x + endPos
            )
            dragOrigin = date
            dragAnchorStart = windowStart
            dragAnchorEnd = windowEnd
        }
        guard let edge = dragEdge,
              let origin = dragOrigin,
              let anchorStart = dragAnchorStart,
              let anchorEnd = dragAnchorEnd else { return }
        let next = NativeTimeWindowEditorLogic.applyDrag(
            edge: edge,
            finger: date,
            origin: origin,
            anchorStart: anchorStart,
            anchorEnd: anchorEnd,
            now: now,
            bounds: rangeStart...min(rangeEnd, now)
        )
        onMove(next.start, next.end)
        let moving = edge == .end ? next.end : next.start
        let bucket = NativeTimeWindowEditorLogic.hapticBucket(moving)
        if hapticBucket == nil {
            hapticBucket = bucket
        } else if hapticBucket != bucket {
            hapticBucket = bucket
        }
    }

    private func dateAt(_ location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Date? {
        if #available(iOS 17.0, macOS 14.0, *), let plotFrame = proxy.plotFrame {
            let origin = geo[plotFrame].origin
            return proxy.value(atX: location.x - origin.x)
        }
        return proxy.value(atX: location.x)
    }
}

struct NativeTimeWindowSummary: View {
    var kind: NativeTimeWindowEditorLogic.Kind
    var start: Date
    var end: Date
    var stats: NativeTimeWindowEditorLogic.WindowStats?
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                column(
                    NativeTimeWindowEditorLogic.handleStartTitle(for: kind),
                    NativeScopeFormat.time(start)
                )
                column(
                    NativeTimeWindowEditorLogic.handleEndTitle(for: kind),
                    NativeScopeFormat.time(end)
                )
                column(
                    "Duration",
                    NativeTimeWindowEditorLogic.durationLabel(from: start, to: end)
                )
            }
            Text(NativeTimeWindowEditorLogic.windowReadout(stats))
                .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline)
                .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    private func column(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(style == .whoop ? title.uppercased() : title)
                .font(style == .whoop ? NativeTokens.whoopCaps(11) : .caption.weight(.semibold))
                .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
            Text(value)
                .font(style == .whoop
                      ? NativeTokens.whoopNumber(22, weight: .semibold)
                      : StrandFont.rounded(22, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibility: String {
        let startTitle = NativeTimeWindowEditorLogic.handleStartTitle(for: kind)
        let endTitle = NativeTimeWindowEditorLogic.handleEndTitle(for: kind)
        return "\(startTitle) \(NativeScopeFormat.time(start)), \(endTitle) \(NativeScopeFormat.time(end)), duration \(NativeTimeWindowEditorLogic.durationLabel(from: start, to: end)), \(NativeTimeWindowEditorLogic.windowReadout(stats))"
    }
}

/// Sheet that edits a sleep or activity `[start, end]` window with the HR scrubber.
struct NativeTimeWindowEditorSheet: View {
    var kind: NativeTimeWindowEditorLogic.Kind
    var seedStart: Date
    var seedEnd: Date
    var coverage: ClosedRange<Int>? = nil
    var suppressesReDetection: Bool = true
    var title: LocalizedStringKey? = nil
    var blurb: LocalizedStringKey? = nil
    var startLabel: LocalizedStringKey? = nil
    var endLabel: LocalizedStringKey? = nil
    var deleteLabel: LocalizedStringKey? = nil
    var repo: Repository? = nil
    var onSave: (Int, Int) async -> Void
    var onDelete: (() async -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.nativeStyle) private var style
    @State private var start: Date
    @State private var end: Date
    @State private var previousStart: Date
    @State private var samples: [NativeTimeWindowEditorLogic.Sample] = []
    @State private var loadedFrom: Int = 0
    @State private var loadedTo: Int = 0
    @State private var loading = true
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var confirmingDisjoint = false

    init(
        kind: NativeTimeWindowEditorLogic.Kind,
        seedStart: Date,
        seedEnd: Date,
        coverage: ClosedRange<Int>? = nil,
        suppressesReDetection: Bool = true,
        title: LocalizedStringKey? = nil,
        blurb: LocalizedStringKey? = nil,
        startLabel: LocalizedStringKey? = nil,
        endLabel: LocalizedStringKey? = nil,
        deleteLabel: LocalizedStringKey? = nil,
        repo: Repository? = nil,
        onSave: @escaping (Int, Int) async -> Void,
        onDelete: (() async -> Void)? = nil
    ) {
        self.kind = kind
        self.seedStart = seedStart
        self.seedEnd = seedEnd
        self.coverage = coverage
        self.suppressesReDetection = suppressesReDetection
        self.title = title
        self.blurb = blurb
        self.startLabel = startLabel
        self.endLabel = endLabel
        self.deleteLabel = deleteLabel
        self.repo = repo
        self.onSave = onSave
        self.onDelete = onDelete
        let now = Date()
        let seededStart = min(seedStart, now)
        _start = State(initialValue: seededStart)
        _previousStart = State(initialValue: seededStart)
        _end = State(initialValue: seedEnd)
    }

    private var shownTitle: LocalizedStringKey { title ?? NativeTimeWindowEditorLogic.title(for: kind) }
    private var shownBlurb: LocalizedStringKey { blurb ?? NativeTimeWindowEditorLogic.blurb(for: kind) }
    private var shownStartLabel: LocalizedStringKey { startLabel ?? NativeTimeWindowEditorLogic.startLabel(for: kind) }
    private var shownEndLabel: LocalizedStringKey { endLabel ?? NativeTimeWindowEditorLogic.endLabel(for: kind) }
    private var shownDeleteLabel: LocalizedStringKey { deleteLabel ?? NativeTimeWindowEditorLogic.deleteLabel(for: kind) }

    private var now: Date { Date() }

    private var context: (start: Date, end: Date) {
        NativeTimeWindowEditorLogic.contextRange(kind: kind, seedStart: seedStart, seedEnd: seedEnd, now: now)
    }

    private var chartRange: (start: Date, end: Date) {
        let ctx = context
        return (min(ctx.start, start), max(ctx.end, min(end, now)))
    }

    private var dragBounds: ClosedRange<Date> {
        let range = chartRange
        return range.start...min(range.end, now)
    }

    private var tint: Color {
        kind == .sleep ? NativePaint.sleep(style) : NativePaint.heart(style)
    }

    private var stats: NativeTimeWindowEditorLogic.WindowStats? {
        NativeTimeWindowEditorLogic.windowStats(samples: samples, start: start, end: end)
    }

    private var validatedWindow: (start: Int, end: Int)? {
        switch kind {
        case .sleep:
            return NativeTimeWindowEditorLogic.validatedSleepWindow(start: start, end: end, now: now)
        case .activity:
            let s = Int(start.timeIntervalSince1970)
            let e = Int(min(end, now).timeIntervalSince1970)
            guard e - s >= Int(NativeTimeWindowEditorLogic.minDuration) else { return nil }
            return (s, e)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NativeTimeWindowSummary(kind: kind, start: start, end: end, stats: stats)
                    chartBlock
                }
                Section {
                    DatePicker(shownStartLabel, selection: $start, in: ...now, displayedComponents: [.date, .hourAndMinute])
                    NativeTimeWindowNudgeRow { minutes in
                        let next = NativeTimeWindowEditorLogic.nudgeStart(
                            start: start, end: end, minutes: minutes, now: now, bounds: dragBounds
                        )
                        applyWindow(next.start, next.end)
                    }
                    DatePicker(shownEndLabel, selection: $end, in: ...now, displayedComponents: [.date, .hourAndMinute])
                    NativeTimeWindowNudgeRow { minutes in
                        let next = NativeTimeWindowEditorLogic.nudgeEnd(
                            start: start, end: end, minutes: minutes, now: now, bounds: dragBounds
                        )
                        applyWindow(next.start, next.end)
                    }
                } footer: {
                    Text(shownBlurb)
                }
                if onDelete != nil {
                    Section {
                        Button(shownDeleteLabel, role: .destructive) { confirmingDelete = true }
                            .disabled(saving)
                    }
                }
            }
            .navigationTitle(shownTitle)
            .modifier(NativeInlineTitle())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { attemptSave() }
                        .disabled(saving || validatedWindow == nil)
                }
            }
            #if os(iOS)
            .scrollContentBackground(.hidden)
            .background(NativePageFill())
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 640)
        #endif
        .task {
            await loadSamples(aroundStart: start, end: end)
        }
        .onChangeCompat(of: start) { newStart in
            var corrected = newStart
            if kind == .sleep {
                corrected = SleepEditGuard.autoCorrectedBed(
                    previousBed: previousStart,
                    candidateBed: newStart,
                    originalWake: coverage.map { Date(timeIntervalSince1970: TimeInterval($0.upperBound)) },
                    now: now
                )
                if corrected != newStart { start = corrected }
            }
            previousStart = corrected
            Task { await loadSamplesIfNeeded(start: corrected, end: end) }
        }
        .onChangeCompat(of: end) { newEnd in
            Task { await loadSamplesIfNeeded(start: start, end: newEnd) }
        }
        .alert("Move this sleep?", isPresented: $confirmingDisjoint) {
            Button("Cancel", role: .cancel) { }
            Button("Move anyway") {
                guard let window = validatedWindow else { return }
                commit(start: window.start, end: window.end)
            }
        } message: {
            Text("This moves the night to a time with no recorded data. Stages can't be derived there, so it may show as empty until data covers it.")
        }
        .alert(NativeTimeWindowEditorLogic.deleteConfirmTitle(for: kind), isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                saving = true
                Task {
                    await onDelete?()
                    dismiss()
                }
            }
        } message: {
            Text(deleteMessage)
        }
    }

    @ViewBuilder private var chartBlock: some View {
        if loading && samples.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: NativeTimeWindowEditorLogic.chartHeight)
        } else if samples.isEmpty {
            Text(NativeTimeWindowEditorLogic.emptyChartMessage)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        } else {
            NativeTimeWindowRangeChart(
                samples: samples,
                windowStart: start,
                windowEnd: end,
                rangeStart: chartRange.start,
                rangeEnd: chartRange.end,
                tint: tint,
                startTitle: NativeTimeWindowEditorLogic.handleStartTitle(for: kind),
                endTitle: NativeTimeWindowEditorLogic.handleEndTitle(for: kind),
                now: now,
                onMove: applyWindow
            )
        }
    }

    private var deleteMessage: LocalizedStringKey {
        switch kind {
        case .sleep:
            return suppressesReDetection
                ? "Removes this recorded sleep and recomputes the day without it. NOOP won't re-detect sleep in this window. You can undo for a few seconds after."
                : "Removes this sleep and recomputes the day without it. You can undo for a few seconds after."
        case .activity:
            return "Removes this workout from your history."
        }
    }

    private func applyWindow(_ newStart: Date, _ newEnd: Date) {
        start = newStart
        end = newEnd
        previousStart = newStart
    }

    private func attemptSave() {
        guard let window = validatedWindow else { return }
        if kind == .sleep, let coverage, SleepEditGuard.isDisjoint(
            newStart: window.start, newEnd: window.end,
            coverageStart: coverage.lowerBound, coverageEnd: coverage.upperBound
        ) {
            confirmingDisjoint = true
        } else {
            commit(start: window.start, end: window.end)
        }
    }

    private func commit(start: Int, end: Int) {
        saving = true
        Task {
            await onSave(start, end)
            dismiss()
        }
    }

    @MainActor
    private func loadSamplesIfNeeded(start: Date, end: Date) async {
        let range = NativeTimeWindowEditorLogic.contextRange(kind: kind, seedStart: start, seedEnd: end, now: now)
        let from = Int(range.start.timeIntervalSince1970)
        let to = Int(range.end.timeIntervalSince1970)
        if loadedTo > loadedFrom, from >= loadedFrom, to <= loadedTo { return }
        await loadSamples(aroundStart: start, end: end)
    }

    @MainActor
    private func loadSamples(aroundStart seedStart: Date, end seedEnd: Date) async {
        guard let repo else {
            loading = false
            return
        }
        loading = samples.isEmpty
        let range = NativeTimeWindowEditorLogic.contextRange(
            kind: kind, seedStart: seedStart, seedEnd: seedEnd, now: now
        )
        let from = Int(range.start.timeIntervalSince1970)
        let to = Int(range.end.timeIntervalSince1970)
        let buckets = await repo.hrSamples(
            from: from, to: to,
            bucketSeconds: NativeTimeWindowEditorLogic.bucketSeconds
        )
        guard !Task.isCancelled else { return }
        samples = buckets.map(NativeTimeWindowEditorLogic.Sample.init)
        loadedFrom = from
        loadedTo = to
        loading = false
    }
}

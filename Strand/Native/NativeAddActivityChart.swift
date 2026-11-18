import SwiftUI
import Charts
import StrandDesign
import WhoopStore

/// Pure helpers for the past-activity heart-rate chart: window clamp/snap, in-window
/// avg/max, and gap splitting. The view lives below; load HR in the form's `.task(id:)`.
enum NativeAddActivityChartLogic {
    static let bucketSeconds = 60
    static let chartHeight: CGFloat = 200
    static let emptyDayMessage = "No heart rate stored for this day"
    static let emptyWindowMessage = "No heart rate for this time"

    struct Sample: Equatable {
        var ts: Int
        var bpm: Double
        var maxBpm: Double

        init(ts: Int, bpm: Double, maxBpm: Double? = nil) {
            self.ts = ts
            self.bpm = bpm
            self.maxBpm = maxBpm ?? bpm
        }

        init(_ bucket: HRBucket) {
            self.ts = bucket.ts
            self.bpm = bucket.bpm
            self.maxBpm = bucket.maxBpm
        }
    }

    struct SegmentPoint: Equatable, Identifiable {
        var time: Date
        var value: Double
        var segment: Int
        var id: String { "\(segment)-\(time.timeIntervalSince1970)" }
    }

    struct WorkoutBand: Equatable, Identifiable {
        var start: Date
        var end: Date
        var id: String { "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }
    }

    struct WindowHeartRate: Equatable {
        var average: Int
        var max: Int
    }

    static func dayBounds(for date: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    static func snapToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.toNearestOrAwayFromZero) * 60)
    }

    /// Snap `start` to the nearest minute, keep `duration`, and clamp so the window
    /// stays on the calendar day and does not end after `now`. Duration shrinks only
    /// when it cannot fit between `dayStart` and `min(dayEnd, now)`.
    static func clampedWindow(
        start: Date,
        duration: TimeInterval,
        dayStart: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let bounds = dayBounds(for: dayStart, calendar: calendar)
        let cap = min(bounds.end, now)
        let held = max(0, duration)
        let earliest = bounds.start
        var latest = snapToMinute(cap.addingTimeInterval(-held))
        if latest.addingTimeInterval(held) > cap {
            latest = Date(timeIntervalSince1970: ((cap.addingTimeInterval(-held).timeIntervalSince1970) / 60).rounded(.down) * 60)
        }
        if latest < earliest {
            return (earliest, cap)
        }
        var snapped = snapToMinute(start)
        if snapped < earliest { snapped = earliest }
        if snapped > latest { snapped = latest }
        if snapped < earliest { snapped = earliest }
        var end = snapped.addingTimeInterval(held)
        if end > cap {
            snapped = latest
            end = min(snapped.addingTimeInterval(held), cap)
        }
        return (snapped, end)
    }

    /// Snap both edges independently, keep them on the calendar day, end at or
    /// before `now`, and at least 60 s apart. Duration is not preserved.
    static func clampedIndependent(
        start: Date,
        end: Date,
        dayStart: Date,
        now: Date,
        calendar: Calendar = .current,
        minDuration: TimeInterval = NativeTimeWindowEditorLogic.minDuration
    ) -> (start: Date, end: Date) {
        let bounds = dayBounds(for: dayStart, calendar: calendar)
        let cap = min(bounds.end, now)
        let range = bounds.start...cap
        let startFirst = NativeTimeWindowEditorLogic.clampStart(
            start, keepingEnd: end, now: now, bounds: range, minDuration: minDuration
        )
        return NativeTimeWindowEditorLogic.clampEnd(
            end, keepingStart: startFirst.start, now: now, bounds: range, minDuration: minDuration
        )
    }

    static func clampedStart(
        _ start: Date,
        keepingEnd end: Date,
        dayStart: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let bounds = dayBounds(for: dayStart, calendar: calendar)
        return NativeTimeWindowEditorLogic.clampStart(
            start, keepingEnd: end, now: now, bounds: bounds.start...min(bounds.end, now)
        )
    }

    static func clampedEnd(
        _ end: Date,
        keepingStart start: Date,
        dayStart: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let bounds = dayBounds(for: dayStart, calendar: calendar)
        return NativeTimeWindowEditorLogic.clampEnd(
            end, keepingStart: start, now: now, bounds: bounds.start...min(bounds.end, now)
        )
    }

    static func applyDrag(
        edge: NativeTimeWindowEditorLogic.Edge,
        finger: Date,
        origin: Date,
        anchorStart: Date,
        anchorEnd: Date,
        dayStart: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        switch edge {
        case .window:
            let duration = max(anchorEnd.timeIntervalSince(anchorStart), NativeTimeWindowEditorLogic.minDuration)
            let proposedStart = anchorStart.addingTimeInterval(finger.timeIntervalSince(origin))
            return clampedWindow(
                start: proposedStart, duration: duration, dayStart: dayStart, now: now, calendar: calendar
            )
        case .start:
            return clampedStart(finger, keepingEnd: anchorEnd, dayStart: dayStart, now: now, calendar: calendar)
        case .end:
            return clampedEnd(finger, keepingStart: anchorStart, dayStart: dayStart, now: now, calendar: calendar)
        }
    }

    /// Average of bucket means and max of per-bucket peaks in `[windowStart, windowEnd)`.
    static func windowHeartRate(
        samples: [Sample],
        windowStart: Int,
        windowEnd: Int
    ) -> WindowHeartRate? {
        let inside = samples.filter { $0.ts >= windowStart && $0.ts < windowEnd }
        guard !inside.isEmpty else { return nil }
        let average = inside.map(\.bpm).reduce(0, +) / Double(inside.count)
        let peak = inside.map(\.maxBpm).max() ?? inside.map(\.bpm).max()!
        return WindowHeartRate(average: Int(average.rounded()), max: Int(peak.rounded()))
    }

    static func windowReadout(_ stats: WindowHeartRate?) -> String {
        guard let stats else { return emptyWindowMessage }
        return "Avg \(stats.average) BPM · Max \(stats.max) BPM"
    }

    /// Display-only smoothing. Avg/max readout still uses the raw `samples`.
    static let displaySmoothWindow: TimeInterval = 180

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

    /// Consecutive 60 s buckets stay in one series; a hole larger than `bucketSeconds`
    /// starts a new segment so LineMark does not interpolate across it.
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

    static func overlappingWorkouts(
        workouts: [WorkoutRow],
        dayStart: Int,
        dayEnd: Int,
        excludingStartTs: Int? = nil
    ) -> [WorkoutBand] {
        workouts.compactMap { row in
            if let excludingStartTs, row.startTs == excludingStartTs { return nil }
            let lo = max(row.startTs, dayStart)
            let hi = min(row.endTs, dayEnd)
            guard hi > lo else { return nil }
            return WorkoutBand(
                start: Date(timeIntervalSince1970: TimeInterval(lo)),
                end: Date(timeIntervalSince1970: TimeInterval(hi))
            )
        }
    }
}

/// Day heart-rate plot for the past-activity form. The selected window is a tinted
/// band with Start / End handles. Dragging a handle moves that edge; dragging the
/// middle of the band keeps duration.
struct NativeAddActivityDayChart: View {
    var samples: [NativeAddActivityChartLogic.Sample]
    var windowStart: Date
    var windowEnd: Date
    var dayStart: Date
    var dayEnd: Date
    var otherWorkouts: [NativeAddActivityChartLogic.WorkoutBand]
    var onMoveWindow: (Date, Date) -> Void

    @Environment(\.nativeStyle) private var style
    @State private var dragEdge: NativeTimeWindowEditorLogic.Edge?
    @State private var dragOrigin: Date?
    @State private var dragAnchorStart: Date?
    @State private var dragAnchorEnd: Date?
    @State private var hapticBucket: Int?

    private var xDomain: ClosedRange<Date> { dayStart...dayEnd }

    private var points: [NativeAddActivityChartLogic.SegmentPoint] {
        NativeAddActivityChartLogic.segments(samples: NativeAddActivityChartLogic.smoothed(samples))
            .filter { NativePlotAxis.inTimeDomain($0.time, xDomain) }
    }

    private var yDomain: ClosedRange<Double> {
        NativePlotAxis.yDomain(points.map(\.value), fallback: 80...180)
    }

    private var bandStart: Date { max(windowStart, dayStart) }
    private var bandEnd: Date { min(windowEnd, dayEnd) }

    private var readout: String {
        NativeAddActivityChartLogic.windowReadout(
            NativeAddActivityChartLogic.windowHeartRate(
                samples: samples,
                windowStart: Int(windowStart.timeIntervalSince1970),
                windowEnd: Int(windowEnd.timeIntervalSince1970)
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .whoop ? 12 : 10) {
            plot.frame(height: NativeAddActivityChartLogic.chartHeight)
            Text(readout)
                .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline)
                .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Heart rate")
        .accessibilityValue(readout)
        .accessibilityHint("Drag the Start or End handle to set the activity window")
        .modifier(NativeSelectionFeedback(trigger: hapticBucket ?? 0))
    }

    private var plot: some View {
        Chart {
            ForEach(otherWorkouts) { band in
                RectangleMark(
                    xStart: .value("Other start", max(band.start, dayStart)),
                    xEnd: .value("Other end", min(band.end, dayEnd)),
                    yStart: .value("Low", yDomain.lowerBound),
                    yEnd: .value("High", yDomain.upperBound)
                )
                .foregroundStyle(Color.secondary.opacity(0.14))
                .accessibilityHidden(true)
            }
            if bandEnd > bandStart {
                RectangleMark(
                    xStart: .value("Window start", bandStart),
                    xEnd: .value("Window end", bandEnd),
                    yStart: .value("Low", yDomain.lowerBound),
                    yEnd: .value("High", yDomain.upperBound)
                )
                .foregroundStyle(NativePaint.heart(style).opacity(0.22))
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
            AxisMarks(values: NativePlotAxis.timeTicks(start: dayStart, end: dayEnd)) { value in
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
                            startTitle: NativeTimeWindowEditorLogic.handleStartTitle(for: .activity),
                            endTitle: NativeTimeWindowEditorLogic.handleEndTitle(for: .activity),
                            tint: NativePaint.heart(style)
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
        let next = NativeAddActivityChartLogic.applyDrag(
            edge: edge,
            finger: date,
            origin: origin,
            anchorStart: anchorStart,
            anchorEnd: anchorEnd,
            dayStart: dayStart,
            now: Date()
        )
        onMoveWindow(next.start, next.end)
        let moving = edge == .end ? next.end : next.start
        let bucket = NativeTimeWindowEditorLogic.hapticBucket(moving)
        if hapticBucket == nil {
            hapticBucket = bucket
        } else if hapticBucket != bucket {
            hapticBucket = bucket
        }
    }

    private var lineTint: Color {
        style == .whoop ? NativeTokens.whoopLabel : Color.primary
    }

    private func dateAt(_ location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Date? {
        if #available(iOS 17.0, macOS 14.0, *), let plotFrame = proxy.plotFrame {
            let origin = geo[plotFrame].origin
            return proxy.value(atX: location.x - origin.x)
        }
        return proxy.value(atX: location.x)
    }
}

/// Round axis ticks and plot domains for Native Charts. Copied small from
/// `NativeScopeYTicks` / `chartTimeTicks` so those files stay untouched.
enum NativePlotAxis {
    /// 1 / 2 / 2.5 / 5 × 10^n, next step up so a domain does not sprout extra ticks.
    static func niceStep(_ raw: Double) -> Double {
        let v = max(abs(raw), 1e-9)
        let exp = floor(log10(v))
        let mag = pow(10, exp)
        let n = v / mag
        let nice: Double
        if n <= 1 { nice = 1 }
        else if n <= 2 { nice = 2 }
        else if n <= 2.5 { nice = 2.5 }
        else if n <= 5 { nice = 5 }
        else { nice = 10 }
        return nice * mag
    }

    static func yTicks(in domain: ClosedRange<Double>, maxCount: Int = 3) -> [Double] {
        let lo = domain.lowerBound
        let hi = domain.upperBound
        let span = hi - lo
        guard span > 0, maxCount >= 2 else { return [lo] }
        let step = niceStep(span / Double(max(maxCount, 2)))
        guard step > 0 else { return [lo, hi] }
        let start = ceil(lo / step - 1e-9) * step
        var ticks: [Double] = []
        var cursor = start
        while cursor <= hi + step * 0.01 {
            ticks.append((cursor * 1e9).rounded() / 1e9)
            cursor += step
            if ticks.count > 8 { break }
        }
        if ticks.count < 2 { return [lo, hi] }
        return ticks
    }

    /// Fitted data domain expanded to cover the outer nice ticks.
    static func yDomain(_ values: [Double], fallback: ClosedRange<Double>, maxCount: Int = 3) -> ClosedRange<Double> {
        let fitted = NativeChartDay.fittedDomain(values, fallback: fallback)
        let ticks = yTicks(in: fitted, maxCount: maxCount)
        guard let first = ticks.first, let last = ticks.last, last > first else { return fitted }
        return min(fitted.lowerBound, first)...max(fitted.upperBound, last)
    }

    /// Wall-clock ticks. A full day is 12 AM / 6 AM / 12 PM / 6 PM (end exclusive).
    static func timeTicks(start: Date, end: Date, calendar: Calendar = .current) -> [Date] {
        let ticks = chartTimeTicks(start: start, end: end, calendar: calendar)
        let span = end.timeIntervalSince(start)
        if span >= 20 * 3600 {
            return ticks.filter { $0 >= start && $0 < end }
        }
        return ticks.filter { $0 >= start && $0 <= end }
    }

    /// Compact "6 AM"; sub-hour ticks keep minutes ("6:15 AM").
    static func clockLabel(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.component(.minute, from: date) == 0 {
            return NativeScopeFormat.hourClock(date, calendar: calendar)
        }
        return NativeScopeFormat.time(date, calendar: calendar)
    }

    /// Workout elapsed ticks: 15 min under an hour, 1 h for short windows, 3 h after that.
    static func elapsedTicks(start: Date, end: Date) -> [Date] {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return [] }
        let step: TimeInterval
        if span < 3600 { step = 15 * 60 }
        else if span < 6 * 3600 { step = 3600 }
        else { step = 3 * 3600 }
        var ticks: [Date] = []
        var cursor = start.addingTimeInterval(step)
        var steps = 0
        while cursor <= end + 0.5, steps < 64 {
            ticks.append(cursor)
            cursor = cursor.addingTimeInterval(step)
            steps += 1
        }
        return ticks
    }

    static func elapsedLabel(_ date: Date, start: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(start).rounded()))
        let minutes = total / 60
        if minutes >= 60 {
            return String(format: "%d:%02d", minutes / 60, minutes % 60)
        }
        return String(format: "0:%02d", minutes)
    }

    /// First-of-month ticks inside the domain. The range start/end are omitted so a
    /// mid-month window (May 16…Jun 1) cannot print overlapping "May" + "Jun" labels.
    static func monthTicks(start: Date, end: Date, calendar: Calendar = .current) -> [Date] {
        guard end > start else { return [start] }
        var components = calendar.dateComponents([.year, .month], from: start)
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        var tick = calendar.date(from: components) ?? start
        if tick < start {
            tick = calendar.date(byAdding: .month, value: 1, to: tick) ?? end
        }
        var candidates: [Date] = []
        var steps = 0
        while tick <= end, steps < 36 {
            candidates.append(tick)
            tick = calendar.date(byAdding: .month, value: 1, to: tick) ?? end
            steps += 1
        }
        if candidates.isEmpty { return [start] }
        let minGap = max(end.timeIntervalSince(start) * 0.12, 1)
        var out: [Date] = []
        for date in candidates {
            if let prev = out.last, date.timeIntervalSince(prev) < minGap { continue }
            out.append(date)
        }
        return out
    }

    static func inTimeDomain(_ date: Date, _ domain: ClosedRange<Date>) -> Bool {
        date >= domain.lowerBound && date <= domain.upperBound
    }

    static func inValueDomain(_ value: Double, _ domain: ClosedRange<Double>) -> Bool {
        value.isFinite && value >= domain.lowerBound && value <= domain.upperBound
    }
}

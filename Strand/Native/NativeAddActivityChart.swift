import SwiftUI
import Charts
import StrandDesign
import WhoopStore

/// Pure helpers for the past-activity heart-rate chart: window clamp/snap, in-window
/// avg/max, and gap splitting. The view lives below; load HR in the form's `.task(id:)`.
enum NativeAddActivityChartLogic {
    static let bucketSeconds = 60
    static let chartHeight: CGFloat = 180
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
/// band (no vertical rule). Dragging moves the window's start and keeps duration.
struct NativeAddActivityDayChart: View {
    var samples: [NativeAddActivityChartLogic.Sample]
    var windowStart: Date
    var windowEnd: Date
    var dayStart: Date
    var dayEnd: Date
    var otherWorkouts: [NativeAddActivityChartLogic.WorkoutBand]
    var onMoveStart: (Date) -> Void

    @Environment(\.nativeStyle) private var style

    private var points: [NativeAddActivityChartLogic.SegmentPoint] {
        NativeAddActivityChartLogic.segments(samples: NativeAddActivityChartLogic.smoothed(samples))
    }

    private var yDomain: ClosedRange<Double> {
        NativeChartDay.fittedDomain(points.map(\.value), fallback: 80...180)
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
        .accessibilityHint("Drag to set the activity start time")
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
        .chartXScale(domain: dayStart...dayEnd)
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .trailing, values: NativeChartTicks.values(in: yDomain, maxCount: 3)) { _ in
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
                        Text(AppClock.hourMinute(date))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let date = dateAt(value.location, proxy: proxy, geo: geo) else { return }
                                onMoveStart(date)
                            }
                    )
            }
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

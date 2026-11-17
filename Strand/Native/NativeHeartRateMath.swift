import Foundation

/// Display-only heart-rate series: spark window, draw budget, y-domain, live append.
/// Stats (min / avg / max) stay on the raw buckets; Charts never see more than `drawBudget` points.
enum NativeHeartRateMath {
    /// Health Monitor spark: last few hours of today's trace.
    static let sparkSpan: TimeInterval = 4 * 3600
    /// Full-day Charts budget. 24h at 5-minute means is 288 points.
    static let drawBudget = 300
    /// Replace the last vertex when a live sample lands inside this gap.
    static let liveReplaceGap: TimeInterval = 90

    struct Stats: Equatable {
        var minBpm: Double?
        var avgBpm: Double?
        var maxBpm: Double?
        var restingBpm: Int?
    }

    struct Model: Equatable {
        var plot: [NativeHourPoint]
        var yDomain: ClosedRange<Double>
        var stats: Stats
        var sleepStart: Date?
        var sleepEnd: Date?
        var dayStart: Date
        var plotEnd: Date
        var showsNow: Bool

        static let empty = Model(
            plot: [],
            yDomain: 40...180,
            stats: Stats(),
            sleepStart: nil,
            sleepEnd: nil,
            dayStart: Date(timeIntervalSince1970: 0),
            plotEnd: Date(timeIntervalSince1970: 86_400),
            showsNow: false
        )
    }

    /// Last `span` of `points`, smoothed, then capped at `drawBudget`.
    static func spark(
        from points: [NativeHourPoint],
        now: Date,
        span: TimeInterval = sparkSpan,
        maxPoints: Int = drawBudget
    ) -> [NativeHourPoint] {
        let cutoff = now.addingTimeInterval(-span)
        let window = points.filter { $0.time >= cutoff }
        return downsample(NativeHRSmoothing.smoothDay(window), maxPoints: maxPoints)
    }

    /// Live BPM rides the end of an already-smoothed spark. Does not resmooth.
    static func appendLive(
        _ points: [NativeHourPoint],
        bpm: Int?,
        at time: Date,
        replaceGap: TimeInterval = liveReplaceGap
    ) -> [NativeHourPoint] {
        guard let bpm else { return points }
        let point = NativeHourPoint(time: time, value: Double(bpm))
        guard let last = points.last else { return [point] }
        if abs(time.timeIntervalSince(last.time)) <= replaceGap {
            var copy = points
            copy[copy.count - 1] = point
            return copy
        }
        return points + [point]
    }

    /// Mean-per-bucket downsample so a 1 Hz / 1-minute day stays at `maxPoints`.
    static func downsample(
        _ points: [NativeHourPoint],
        maxPoints: Int = drawBudget
    ) -> [NativeHourPoint] {
        guard maxPoints >= 2, points.count > maxPoints else { return points }
        let ordered = points.sorted { $0.time < $1.time }
        guard let first = ordered.first, let last = ordered.last else { return [] }
        let span = last.time.timeIntervalSince(first.time)
        guard span > 0 else { return Array(ordered.prefix(maxPoints)) }
        let width = span / Double(maxPoints)
        var totals = [Double](repeating: 0, count: maxPoints)
        var counts = [Int](repeating: 0, count: maxPoints)
        for point in ordered {
            let key = min(maxPoints - 1, Int(point.time.timeIntervalSince(first.time) / width))
            totals[key] += point.value
            counts[key] += 1
        }
        var out: [NativeHourPoint] = []
        out.reserveCapacity(maxPoints)
        for key in 0..<maxPoints where counts[key] > 0 {
            let time = first.time.addingTimeInterval(TimeInterval(key) * width + width / 2)
            out.append(NativeHourPoint(time: time, value: totals[key] / Double(counts[key])))
        }
        return out
    }

    /// Bucket width (seconds) that keeps a `span` under `maxPoints`. Floor 60 s.
    static func bucketSeconds(span: TimeInterval, maxPoints: Int = drawBudget) -> Int {
        guard span > 0, maxPoints > 0 else { return 60 }
        return max(60, Int((span / Double(maxPoints)).rounded(.up)))
    }

    /// Fitted y-domain with padding so a 60–80 bpm trace is not flattened against 0…max.
    static func fittedDomain(
        _ values: [Double],
        fallback: ClosedRange<Double> = 40...180
    ) -> ClosedRange<Double> {
        NativeChartDay.fittedDomain(values, fallback: fallback)
    }

    static func stats(
        values: [Double],
        extrema: [(min: Double, max: Double)] = [],
        restingBpm: Int? = nil
    ) -> Stats {
        let finite = values.filter(\.isFinite)
        let mins = extrema.map(\.min).filter(\.isFinite)
        let maxs = extrema.map(\.max).filter(\.isFinite)
        return Stats(
            minBpm: (mins + finite).min(),
            avgBpm: NativeScoreMath.mean(finite),
            maxBpm: (maxs + finite).max(),
            restingBpm: restingBpm
        )
    }

    static func plotEnd(dayStart: Date, now: Date) -> Date {
        NativeStressMonitorMath.plotEnd(dayStart: dayStart, now: now)
    }

    static func showsNow(dayStart: Date, now: Date) -> Bool {
        NativeStressMonitorMath.showsNow(dayStart: dayStart, now: now)
    }

    /// Hero subline: "Latest" at rest, the scrubbed clock while dragging.
    static let latestLabel = "Latest"

    static func heroDate(isScrubbing: Bool, time: Date, calendar: Calendar = .current) -> String {
        isScrubbing ? NativeScopeFormat.time(time, calendar: calendar) : latestLabel
    }

    /// Round-hour ticks. 12 AM / 6 AM / 12 PM / 6 PM on a ≥12 h window; every 3 h when shorter.
    static func xAxisDates(dayStart: Date, plotEnd: Date, calendar: Calendar = .current) -> [Date] {
        let span = plotEnd.timeIntervalSince(dayStart)
        guard span > 0 else { return [dayStart] }
        let stepHours = span >= 12 * 3600 ? 6 : 3
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dayStart)) ?? plotEnd
        var dates: [Date] = []
        var date = calendar.startOfDay(for: dayStart)
        while date <= plotEnd {
            if date >= dayEnd { break }
            if date >= dayStart { dates.append(date) }
            guard let next = calendar.date(byAdding: .hour, value: stepHours, to: date) else { break }
            date = next
        }
        return dates.isEmpty ? [dayStart] : dates
    }

    static func clippedPlot(
        _ points: [NativeHourPoint],
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>? = nil
    ) -> [NativeHourPoint] {
        points.filter { point in
            guard point.time >= xDomain.lowerBound && point.time <= xDomain.upperBound else { return false }
            guard let yDomain else { return true }
            return point.value >= yDomain.lowerBound && point.value <= yDomain.upperBound
        }
    }

    static func clippedSleep(
        start: Date?,
        end: Date?,
        xDomain: ClosedRange<Date>
    ) -> (Date, Date)? {
        guard let start, let end else { return nil }
        let lo = max(start, xDomain.lowerBound)
        let hi = min(end, xDomain.upperBound)
        guard hi > lo else { return nil }
        return (lo, hi)
    }

    static func sparkXDomain(points: [NativeHourPoint], now: Date = Date()) -> ClosedRange<Date> {
        if let first = points.first?.time, let last = points.last?.time, last > first {
            return first...last
        }
        let end = points.last?.time ?? now
        return end.addingTimeInterval(-sparkSpan)...end
    }

    static func make(
        points: [NativeHourPoint],
        minBpm: Double?,
        maxBpm: Double?,
        avgBpm: Double?,
        restingBpm: Int?,
        sleepStart: Date?,
        sleepEnd: Date?,
        dayStart: Date,
        now: Date,
        viewingToday: Bool,
        maxPoints: Int = drawBudget
    ) -> Model {
        let smoothed = NativeHRSmoothing.smoothDay(points)
        let plot = downsample(smoothed, maxPoints: maxPoints)
        let values = points.map(\.value)
        let domainValues = plot.map(\.value)
        return Model(
            plot: plot,
            yDomain: fittedDomain(domainValues.isEmpty ? values : domainValues),
            stats: Stats(
                minBpm: minBpm ?? values.filter(\.isFinite).min(),
                avgBpm: avgBpm ?? NativeScoreMath.mean(values.filter(\.isFinite)),
                maxBpm: maxBpm ?? values.filter(\.isFinite).max(),
                restingBpm: restingBpm
            ),
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            dayStart: dayStart,
            plotEnd: plotEnd(dayStart: dayStart, now: now),
            showsNow: viewingToday && showsNow(dayStart: dayStart, now: now)
        )
    }

    static func appendLive(to model: Model, bpm: Int?, at time: Date) -> Model {
        let plot = appendLive(model.plot, bpm: bpm, at: time)
        guard plot != model.plot else { return model }
        var next = model
        next.plot = plot
        if let last = plot.last,
           last.value < model.yDomain.lowerBound || last.value > model.yDomain.upperBound {
            next.yDomain = fittedDomain(plot.map(\.value), fallback: model.yDomain)
        }
        if NativeStressMonitorMath.showsNow(dayStart: model.dayStart, now: time) {
            next.plotEnd = max(model.plotEnd, time)
            next.showsNow = true
        }
        return next
    }
}

import Foundation

/// Display-only heart-rate smoother. Raw samples stay for maxima, zones, and stats.
///
/// Callers pass already-bucketed chart points. Other charts should use the same helper:
/// `NativeHRSmoothing.smooth(points)` or `NativeHRSmoothing.smooth(points, window: 45)`.
enum NativeHRSmoothing {
    /// Default centred window, in seconds. WHOOP-like 30–60 s smoothing.
    static let defaultWindow: TimeInterval = 45
    /// Runs longer than this are reduced to bucket means before the rolling filters.
    static let longSpan: TimeInterval = 3 * 3600
    /// Bucket width used on long runs, in seconds.
    static let longBucket: TimeInterval = 20

    /// Smooth `points` for charting.
    ///
    /// Consecutive points farther apart than `gapLimit` stay in separate runs so a
    /// hole is not interpolated. Each run gets a centred rolling median, then a
    /// centred rolling mean, both over `window`. A run longer than `longSpan` is
    /// first reduced to `longBucket` means.
    static func smooth(_ points: [NativeHourPoint],
                       window: TimeInterval = defaultWindow) -> [NativeHourPoint] {
        guard points.count >= 3, window > 0 else { return points }
        let ordered = points.sorted { $0.time < $1.time }
        let gap = gapLimit(in: ordered, window: window)
        var out: [NativeHourPoint] = []
        out.reserveCapacity(ordered.count)
        for run in runs(ordered, maxGap: gap) {
            let prepared = runSpan(run) > longSpan ? bucketMeans(run, seconds: longBucket) : run
            out.append(contentsOf: smoothRun(prepared, window: window))
        }
        return out
    }

    /// A hole larger than the smoothing window, or 2× the median spacing, is a gap.
    static func gapLimit(in points: [NativeHourPoint], window: TimeInterval) -> TimeInterval {
        let spacings = zip(points, points.dropFirst()).map {
            $1.time.timeIntervalSince($0.time)
        }.filter { $0 > 0 }.sorted()
        let median = spacings.isEmpty ? window : spacings[spacings.count / 2]
        return max(window, median * 2)
    }

    // MARK: - Internals

    private static func runs(_ points: [NativeHourPoint], maxGap: TimeInterval) -> [[NativeHourPoint]] {
        var segments: [[NativeHourPoint]] = []
        var current: [NativeHourPoint] = []
        var last: Date?
        for point in points {
            if let last, point.time.timeIntervalSince(last) > maxGap {
                if !current.isEmpty { segments.append(current) }
                current = []
            }
            current.append(point)
            last = point.time
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private static func runSpan(_ points: [NativeHourPoint]) -> TimeInterval {
        guard let first = points.first, let last = points.last else { return 0 }
        return last.time.timeIntervalSince(first.time)
    }

    private static func bucketMeans(_ points: [NativeHourPoint], seconds: TimeInterval) -> [NativeHourPoint] {
        guard seconds > 0 else { return points }
        var sums: [Int: (total: Double, n: Int)] = [:]
        for point in points {
            let key = Int(point.time.timeIntervalSince1970 / seconds)
            let cur = sums[key] ?? (0, 0)
            sums[key] = (cur.total + point.value, cur.n + 1)
        }
        return sums.keys.sorted().map { key in
            let b = sums[key]!
            return NativeHourPoint(
                time: Date(timeIntervalSince1970: TimeInterval(key) * seconds),
                value: b.total / Double(b.n)
            )
        }
    }

    private static func smoothRun(_ points: [NativeHourPoint], window: TimeInterval) -> [NativeHourPoint] {
        guard points.count >= 3 else { return points }
        let medians = rolling(points, window: window, reduce: median)
        return rolling(medians, window: window, reduce: mean)
    }

    private static func rolling(
        _ points: [NativeHourPoint],
        window: TimeInterval,
        reduce: ([Double]) -> Double
    ) -> [NativeHourPoint] {
        let half = window / 2
        var lo = 0
        var hi = 0
        return points.enumerated().map { i, point in
            let start = point.time.addingTimeInterval(-half)
            let end = point.time.addingTimeInterval(half)
            while lo < points.count, points[lo].time < start { lo += 1 }
            if hi < lo { hi = lo }
            while hi < points.count, points[hi].time <= end { hi += 1 }
            let slice = points[lo..<hi]
            let values = slice.map(\.value)
            return NativeHourPoint(time: point.time, value: values.isEmpty ? point.value : reduce(values))
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }
}

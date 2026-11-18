import Foundation
import StrandAnalytics

/// Display-only heart-rate smoother. Raw samples stay for maxima, zones, and stats.
///
/// Callers pass already-bucketed chart points. Day traces use `smoothDay`
/// (per-minute means, then a centred ~15-minute two-pass mean). Short traces keep
/// `smooth(points)` or `smooth(points, window:)`. Two passes of `DisplaySeries.smooth`
/// make a triangular/Gaussian-like kernel with no phase lag.
enum NativeHRSmoothing {
    /// Default centred window, in seconds. Short traces (workout, overnight, live).
    static let defaultWindow: TimeInterval = 180
    /// Centred window for a WHOOP-like day HR line, in seconds.
    static let dayWindow: TimeInterval = 900
    /// Health Monitor 4-hour spark window, in seconds.
    static let sparkWindow: TimeInterval = 360
    /// Per-minute bucket used by `smoothDay` and long runs.
    static let minuteBucket: TimeInterval = 60
    /// Runs longer than this are reduced to bucket means before the rolling filters.
    static let longSpan: TimeInterval = 3 * 3600
    /// Bucket width used on long runs, in seconds.
    static let longBucket: TimeInterval = minuteBucket

    /// Per-minute means, then a centred ~15-minute two-pass mean. Full-day HR.
    static func smoothDay(_ points: [NativeHourPoint]) -> [NativeHourPoint] {
        guard points.count >= 3 else { return points }
        let ordered = points.sorted { $0.time < $1.time }
        return smooth(bucketMeans(ordered, seconds: minuteBucket), window: dayWindow)
    }

    /// Two-pass centred smooth over `sparkWindow`. Health Monitor 4-hour spark.
    static func smoothSpark(_ points: [NativeHourPoint]) -> [NativeHourPoint] {
        smooth(points, window: sparkWindow)
    }

    /// Smooth `points` for charting.
    ///
    /// Consecutive points farther apart than `gapLimit` stay in separate runs so a
    /// hole is not interpolated. Each run gets two passes of a centred rolling
    /// median then mean, both over `window`. A run longer than `longSpan` is
    /// first reduced to `longBucket` means.
    static func smooth(_ points: [NativeHourPoint],
                       window: TimeInterval = defaultWindow) -> [NativeHourPoint] {
        guard points.count >= 3, window > 0 else { return points }
        let ordered = points.sorted { $0.time < $1.time }
        let series = ordered.map { (ts: Int($0.time.timeIntervalSince1970), value: $0.value) }
        let width = max(1, Int(window.rounded()))
        let once = DisplaySeries.smooth(series, window: width)
        let smoothed = DisplaySeries.smooth(once, window: width)
        if smoothed.count == ordered.count {
            return zip(ordered, smoothed).map { NativeHourPoint(time: $0.0.time, value: $0.1.value) }
        }
        return smoothed.map {
            NativeHourPoint(time: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.value)
        }
    }

    /// A hole larger than the smoothing window, or 2× the median spacing, is a gap.
    static func gapLimit(in points: [NativeHourPoint], window: TimeInterval) -> TimeInterval {
        let series = points.map { (ts: Int($0.time.timeIntervalSince1970), value: $0.value) }
        return TimeInterval(DisplaySeries.gapLimit(in: series, window: max(1, Int(window.rounded()))))
    }

    /// Per-`seconds` bucket means, oldest first. Used by `smoothDay`.
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
}

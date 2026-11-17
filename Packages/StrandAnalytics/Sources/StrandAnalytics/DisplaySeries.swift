import Foundation

/// Display-only chart series: centred rolling median+mean, then a draw-budget downsample.
/// Unix-seconds form of the Native heart-rate smoother / Health Monitor spark.
public enum DisplaySeries {

    public static let defaultWindow: Int = 45
    public static let longSpan: Int = 3 * 3600
    public static let longBucket: Int = 20

    /// Consecutive points farther apart than `gapLimit` stay in separate runs so a
    /// hole is not interpolated. Each run gets a centred rolling median, then a
    /// centred rolling mean, both over `window` seconds. A run longer than `longSpan`
    /// is first reduced to `longBucket` means.
    public static func smooth(
        _ points: [(ts: Int, value: Double)],
        window: Int = defaultWindow
    ) -> [(ts: Int, value: Double)] {
        guard points.count >= 3, window > 0 else { return points }
        let ordered = points.sorted { $0.ts < $1.ts }
        let gap = gapLimit(in: ordered, window: window)
        var out: [(ts: Int, value: Double)] = []
        out.reserveCapacity(ordered.count)
        for run in runs(ordered, maxGap: gap) {
            let prepared = runSpan(run) > longSpan ? bucketMeans(run, seconds: longBucket) : run
            out.append(contentsOf: smoothRun(prepared, window: window))
        }
        return out
    }

    /// A hole larger than the smoothing window, or 2× the median spacing, is a gap.
    public static func gapLimit(in points: [(ts: Int, value: Double)], window: Int) -> Int {
        var n = 0
        var first = 0
        var allSame = true
        var i = 1
        while i < points.count {
            let d = points[i].ts - points[i - 1].ts
            if d > 0 {
                if n == 0 { first = d }
                else if d != first { allSame = false }
                n += 1
            }
            i += 1
        }
        if n == 0 { return window }
        if allSame { return max(window, first * 2) }
        var spacings = [Int]()
        spacings.reserveCapacity(n)
        i = 1
        while i < points.count {
            let d = points[i].ts - points[i - 1].ts
            if d > 0 { spacings.append(d) }
            i += 1
        }
        spacings.sort()
        return max(window, spacings[spacings.count / 2] * 2)
    }

    /// Mean-per-bucket downsample so a 1 Hz / 1-minute day stays at `maxPoints`.
    public static func downsample(
        _ points: [(ts: Int, value: Double)],
        maxPoints: Int
    ) -> [(ts: Int, value: Double)] {
        guard maxPoints >= 2, points.count > maxPoints else { return points }
        let ordered = points.sorted { $0.ts < $1.ts }
        guard let first = ordered.first, let last = ordered.last else { return [] }
        let span = Double(last.ts - first.ts)
        guard span > 0 else { return Array(ordered.prefix(maxPoints)) }
        let width = span / Double(maxPoints)
        var totals = [Double](repeating: 0, count: maxPoints)
        var counts = [Int](repeating: 0, count: maxPoints)
        for point in ordered {
            let key = min(maxPoints - 1, Int(Double(point.ts - first.ts) / width))
            totals[key] += point.value
            counts[key] += 1
        }
        var out: [(ts: Int, value: Double)] = []
        out.reserveCapacity(maxPoints)
        for key in 0..<maxPoints where counts[key] > 0 {
            let ts = first.ts + Int((Double(key) * width + width / 2).rounded())
            out.append((ts, totals[key] / Double(counts[key])))
        }
        return out
    }

    // MARK: - Internals

    private static func runs(
        _ points: [(ts: Int, value: Double)], maxGap: Int
    ) -> [[(ts: Int, value: Double)]] {
        var segments: [[(ts: Int, value: Double)]] = []
        var current: [(ts: Int, value: Double)] = []
        var last: Int?
        for point in points {
            if let last, point.ts - last > maxGap {
                if !current.isEmpty { segments.append(current) }
                current = []
            }
            current.append(point)
            last = point.ts
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private static func runSpan(_ points: [(ts: Int, value: Double)]) -> Int {
        guard let first = points.first, let last = points.last else { return 0 }
        return last.ts - first.ts
    }

    private static func bucketMeans(
        _ points: [(ts: Int, value: Double)], seconds: Int
    ) -> [(ts: Int, value: Double)] {
        guard seconds > 0, !points.isEmpty else { return points }
        var out: [(ts: Int, value: Double)] = []
        out.reserveCapacity(points.count)
        var key = points[0].ts / seconds
        var total = 0.0
        var n = 0
        for point in points {
            let k = point.ts / seconds
            if k != key {
                out.append((key * seconds, total / Double(n)))
                key = k
                total = 0
                n = 0
            }
            total += point.value
            n += 1
        }
        if n > 0 { out.append((key * seconds, total / Double(n))) }
        return out
    }

    private static func smoothRun(
        _ points: [(ts: Int, value: Double)], window: Int
    ) -> [(ts: Int, value: Double)] {
        guard points.count >= 3 else { return points }
        let medians = rollingMedian(points, window: window)
        return rollingMean(medians, window: window)
    }

    private static func rollingMedian(
        _ points: [(ts: Int, value: Double)], window: Int
    ) -> [(ts: Int, value: Double)] {
        let half = window / 2
        var lo = 0
        var hi = 0
        var sorted: [Double] = []
        sorted.reserveCapacity(64)
        var out: [(ts: Int, value: Double)] = []
        out.reserveCapacity(points.count)
        for point in points {
            let start = point.ts - half
            let end = point.ts + half
            while lo < points.count, points[lo].ts < start {
                removeSorted(&sorted, points[lo].value)
                lo += 1
            }
            if hi < lo {
                sorted.removeAll(keepingCapacity: true)
                hi = lo
            }
            while hi < points.count, points[hi].ts <= end {
                insertSorted(&sorted, points[hi].value)
                hi += 1
            }
            if sorted.count != hi - lo {
                sorted.removeAll(keepingCapacity: true)
                var m = lo
                while m < hi {
                    insertSorted(&sorted, points[m].value)
                    m += 1
                }
            }
            if lo >= hi {
                out.append(point)
                continue
            }
            let mid = sorted.count / 2
            let value: Double
            if sorted.count.isMultiple(of: 2) {
                value = (sorted[mid - 1] + sorted[mid]) / 2
            } else {
                value = sorted[mid]
            }
            out.append((point.ts, value))
        }
        return out
    }

    private static func insertSorted(_ a: inout [Double], _ x: Double) {
        var lo = 0, hi = a.count
        while lo < hi {
            let m = (lo + hi) / 2
            if a[m] < x { lo = m + 1 } else { hi = m }
        }
        a.insert(x, at: lo)
    }

    private static func removeSorted(_ a: inout [Double], _ x: Double) {
        var lo = 0, hi = a.count
        while lo < hi {
            let m = (lo + hi) / 2
            if a[m] < x { lo = m + 1 } else { hi = m }
        }
        if lo < a.count, a[lo] == x {
            a.remove(at: lo)
        }
    }

    private static func rollingMean(
        _ points: [(ts: Int, value: Double)], window: Int
    ) -> [(ts: Int, value: Double)] {
        let half = window / 2
        var lo = 0
        var hi = 0
        var out: [(ts: Int, value: Double)] = []
        out.reserveCapacity(points.count)
        for point in points {
            let start = point.ts - half
            let end = point.ts + half
            while lo < points.count, points[lo].ts < start { lo += 1 }
            if hi < lo { hi = lo }
            while hi < points.count, points[hi].ts <= end { hi += 1 }
            if lo >= hi {
                out.append(point)
                continue
            }
            var sum = 0.0
            var m = lo
            while m < hi {
                sum += points[m].value
                m += 1
            }
            out.append((point.ts, sum / Double(hi - lo)))
        }
        return out
    }
}

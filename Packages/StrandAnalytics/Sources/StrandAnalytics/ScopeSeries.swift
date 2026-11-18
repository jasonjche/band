import Foundation

/// Calendar-free daily / weekly aggregation used by Native metric scopes.
/// Days are Howard-Hinnant civil epoch days (same as `HealthspanEngine.isoEpochDay`).
public enum ScopeSeries {

    public struct Point: Equatable, Sendable {
        public var epochDay: Int
        public var value: Double
        public var low: Double?
        public var high: Double?
        public init(epochDay: Int, value: Double, low: Double? = nil, high: Double? = nil) {
            self.epochDay = epochDay
            self.value = value
            self.low = low
            self.high = high
        }
    }

    public struct Bucket: Equatable, Sendable {
        public var startEpoch: Int
        public var endEpoch: Int
        public var value: Double?
        public var low: Double?
        public var high: Double?
        public var sampleCount: Int
        public init(startEpoch: Int, endEpoch: Int, value: Double?, low: Double?,
                    high: Double?, sampleCount: Int) {
            self.startEpoch = startEpoch
            self.endEpoch = endEpoch
            self.value = value
            self.low = low
            self.high = high
            self.sampleCount = sampleCount
        }
    }

    /// One slot per civil day in `[fromEpoch, toEpoch]`. Missing days stay nil.
    public static func daily(points: [Point], fromEpoch: Int, toEpoch: Int) -> [Bucket] {
        guard toEpoch >= fromEpoch else { return [] }
        var byDay: [Int: Point] = [:]
        byDay.reserveCapacity(points.count)
        for point in points { byDay[point.epochDay] = point }
        var buckets: [Bucket] = []
        buckets.reserveCapacity(toEpoch - fromEpoch + 1)
        var cursor = fromEpoch
        while cursor <= toEpoch {
            let row = byDay[cursor]
            let value = row.flatMap { $0.value.isFinite ? $0.value : nil }
            buckets.append(Bucket(
                startEpoch: cursor, endEpoch: cursor + 1,
                value: value, low: row?.low, high: row?.high,
                sampleCount: value == nil ? 0 : 1
            ))
            cursor += 1
        }
        return buckets
    }

    /// Fold days into fixed-width groups (`unitDays` = 7 for weeks).
    public static func grouped(
        points: [Point], fromEpoch: Int, toEpoch: Int, unitDays: Int
    ) -> [Bucket] {
        guard unitDays > 0, toEpoch >= fromEpoch else { return [] }
        let ordered = points.filter { $0.value.isFinite && $0.epochDay >= fromEpoch && $0.epochDay <= toEpoch }
            .sorted { $0.epochDay < $1.epochDay }
        var buckets: [Bucket] = []
        var cursor = fromEpoch
        var i = 0
        while cursor <= toEpoch {
            let end = cursor + unitDays
            var sum = 0.0
            var n = 0
            var lo: Double?
            var hi: Double?
            while i < ordered.count, ordered[i].epochDay < end {
                if ordered[i].epochDay >= cursor {
                    sum += ordered[i].value
                    n += 1
                    if let v = ordered[i].low { lo = lo.map { min($0, v) } ?? v }
                    if let v = ordered[i].high { hi = hi.map { max($0, v) } ?? v }
                }
                i += 1
            }
            buckets.append(Bucket(
                startEpoch: cursor, endEpoch: end,
                value: n > 0 ? sum / Double(n) : nil,
                low: lo, high: hi, sampleCount: n
            ))
            cursor = end
        }
        return buckets
    }
}

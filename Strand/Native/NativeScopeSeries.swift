import Foundation
import SwiftUI
import StrandDesign

/// D / W / M / 6M on Native metric pages. `Y` exists only for cheap monthly rollups.
enum NativeMetricScope: String, CaseIterable, Identifiable, Hashable {
    case day
    case week
    case month
    case sixMonths
    case year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "D"
        case .week: return "W"
        case .month: return "M"
        case .sixMonths: return "6M"
        case .year: return "Y"
        }
    }

    /// Slots in the visible window (days for D/W/M, weeks for 6M, months for Y).
    var visibleCount: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        case .sixMonths: return 26
        case .year: return 12
        }
    }

    var visibleSeconds: TimeInterval {
        switch self {
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .sixMonths: return 26 * 7 * 86_400
        case .year: return 365 * 86_400
        }
    }

    static let pickerCases: [NativeMetricScope] = [.day, .week, .month, .sixMonths]
}

enum NativeScopeKind: String, Equatable {
    /// HRV, RHR, RR, recovery — weekly/monthly buckets take the mean of daily values.
    case rate
    /// Steps, calories, sleep hours, strain — 6M caption is "Daily Average".
    case total
}

/// One aggregated slot. `value` is nil when the period has no samples (never zero-filled).
struct NativeScopeBucket: Identifiable, Equatable {
    var start: Date
    var end: Date
    var value: Double?
    var low: Double?
    var high: Double?
    var isPartial: Bool
    var sampleCount: Int
    var key: String
    var id: String { key }

    var point: NativeDayPoint {
        NativeDayPoint(
            key: key,
            value: value ?? .nan,
            low: low,
            high: high,
            isPartial: isPartial
        )
    }
}

struct NativeScopeTrend: Equatable {
    var currentMean: Double
    var previousMean: Double
    var delta: NativeScore.Delta
    var minValue: Double
    var minDate: Date
    var maxValue: Double
    var maxDate: Date
}

/// Apple Health-style scope aggregation. One pure entry point; views never fold series in `body`.
struct NativeScopeSeries: Equatable {
    var scope: NativeMetricScope
    var kind: NativeScopeKind
    var buckets: [NativeScopeBucket]
    var caption: String

    static let empty = NativeScopeSeries(scope: .week, kind: .rate, buckets: [], caption: "Average")

    var points: [NativeDayPoint] { buckets.map(\.point) }

    var known: [NativeScopeBucket] { buckets.filter { $0.value != nil } }

    /// Mean of finite values. Missing days are skipped, never treated as zero.
    var aggregate: Double? {
        Self.mean(buckets.compactMap(\.value))
    }

    static func make(
        points: [NativeDayPoint],
        scope: NativeMetricScope,
        kind: NativeScopeKind,
        calendar: Calendar = .current,
        now: Date = Date(),
        ending: Date? = nil
    ) -> NativeScopeSeries {
        let parsed: [(date: Date, value: Double, low: Double?, high: Double?)] = points.compactMap { point in
            guard let date = date(from: point.key, calendar: calendar) else { return nil }
            let finite = point.value.isFinite ? point.value : nil
            return (date, finite ?? .nan, point.low, point.high)
        }.sorted { $0.date < $1.date }

        let finite = parsed.filter { $0.value.isFinite }
        guard let first = finite.first?.date else {
            return NativeScopeSeries(scope: scope, kind: kind, buckets: [], caption: caption(scope: scope, kind: kind))
        }
        let today = calendar.startOfDay(for: now)
        let last = calendar.startOfDay(for: ending ?? finite.last?.date ?? today)
        let endDay = min(last, today)

        let buckets: [NativeScopeBucket]
        switch scope {
        case .day, .week, .month:
            buckets = dailyBuckets(parsed: parsed, from: first, to: endDay, calendar: calendar)
        case .sixMonths:
            buckets = groupedBuckets(
                parsed: parsed, from: first, to: endDay, calendar: calendar, now: today, unit: .weekOfYear
            )
        case .year:
            buckets = groupedBuckets(
                parsed: parsed, from: first, to: endDay, calendar: calendar, now: today, unit: .month
            )
        }
        return NativeScopeSeries(
            scope: scope,
            kind: kind,
            buckets: buckets,
            caption: caption(scope: scope, kind: kind)
        )
    }

    static func caption(scope: NativeMetricScope, kind: NativeScopeKind) -> String {
        if kind == .total && (scope == .sixMonths || scope == .year) {
            return "Daily Average"
        }
        return "Average"
    }

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Visible window starting at `leading`, `scope.visibleCount` slots long.
    func window(leading: Date, calendar: Calendar) -> [NativeScopeBucket] {
        guard !buckets.isEmpty else { return [] }
        let count = scope.visibleCount
        let start = calendar.startOfDay(for: leading)
        guard let index = buckets.firstIndex(where: { $0.start >= start }) ?? buckets.indices.last else {
            return Array(buckets.suffix(count))
        }
        let end = min(index + count, buckets.count)
        let begin = min(index, max(0, end - count))
        return Array(buckets[begin..<end])
    }

    /// Last `visibleCount` slots — the default landing window.
    func latestWindow() -> [NativeScopeBucket] {
        Array(buckets.suffix(scope.visibleCount))
    }

    func aggregate(of window: [NativeScopeBucket]) -> Double? {
        Self.mean(window.compactMap(\.value))
    }

    /// Previous equal-length period vs `window`. Nil unless both sides have ≥ 3 finite values.
    func trend(visible window: [NativeScopeBucket], higherIsBetter: Bool?) -> NativeScopeTrend? {
        guard window.count >= 3, let last = window.last, let first = window.first else { return nil }
        let known = window.compactMap(\.value)
        guard known.count >= 3, let current = Self.mean(known) else { return nil }

        let span = last.end.timeIntervalSince(first.start)
        let prevEnd = first.start
        let prevStart = prevEnd.addingTimeInterval(-span)
        let previous = buckets.filter { $0.start >= prevStart && $0.start < prevEnd }
        let prevKnown = previous.compactMap(\.value)
        guard prevKnown.count >= 3, let previousMean = Self.mean(prevKnown) else { return nil }

        let withValues = window.compactMap { bucket -> (Double, Date)? in
            guard let value = bucket.value else { return nil }
            return (value, bucket.start)
        }
        guard let minPair = withValues.min(by: { $0.0 < $1.0 }),
              let maxPair = withValues.max(by: { $0.0 < $1.0 }) else { return nil }

        return NativeScopeTrend(
            currentMean: current,
            previousMean: previousMean,
            delta: NativeMetricDirection.delta(
                current: current, previous: previousMean, higherIsBetter: higherIsBetter
            ),
            minValue: minPair.0,
            minDate: minPair.1,
            maxValue: maxPair.0,
            maxDate: maxPair.1
        )
    }

    func heroDateText(of window: [NativeScopeBucket], calendar: Calendar) -> String? {
        guard let first = window.first, let last = window.last else { return nil }
        let lastDay = calendar.date(byAdding: .day, value: -1, to: last.end) ?? last.start
        return NativeScopeFormat.heroRange(
            from: first.start, to: lastDay, scope: scope, calendar: calendar
        )
    }

    func selectionDateText(for bucket: NativeScopeBucket, calendar: Calendar) -> String {
        switch scope {
        case .sixMonths, .year:
            let lastDay = calendar.date(byAdding: .day, value: -1, to: bucket.end) ?? bucket.start
            return NativeScopeFormat.weekRange(from: bucket.start, to: lastDay, calendar: calendar)
        case .day, .week, .month:
            return NativeScopeFormat.weekdayDate(bucket.start, calendar: calendar)
        }
    }

    // MARK: - Building

    private static func dailyBuckets(
        parsed: [(date: Date, value: Double, low: Double?, high: Double?)],
        from: Date,
        to: Date,
        calendar: Calendar
    ) -> [NativeScopeBucket] {
        let byDay = Dictionary(uniqueKeysWithValues: parsed.map { ($0.date, $0) })
        var buckets: [NativeScopeBucket] = []
        var cursor = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        while cursor <= end {
            let next = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86_400)
            let row = byDay[cursor]
            let value = row.flatMap { $0.value.isFinite ? $0.value : nil }
            buckets.append(
                NativeScopeBucket(
                    start: cursor,
                    end: next,
                    value: value,
                    low: row?.low,
                    high: row?.high,
                    isPartial: false,
                    sampleCount: value == nil ? 0 : 1,
                    key: key(from: cursor, calendar: calendar)
                )
            )
            cursor = next
        }
        return buckets
    }

    private static func groupedBuckets(
        parsed: [(date: Date, value: Double, low: Double?, high: Double?)],
        from: Date,
        to: Date,
        calendar: Calendar,
        now: Date,
        unit: Calendar.Component
    ) -> [NativeScopeBucket] {
        guard let firstInterval = calendar.dateInterval(of: unit, for: from) else { return [] }
        var buckets: [NativeScopeBucket] = []
        var cursor = firstInterval.start
        let end = calendar.startOfDay(for: to)
        while cursor <= end {
            guard let interval = calendar.dateInterval(of: unit, for: cursor) else { break }
            let values = parsed.filter { $0.date >= interval.start && $0.date < interval.end && $0.value.isFinite }
            let lows = values.compactMap(\.low)
            let highs = values.compactMap(\.high)
            let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
            let isPartial = lastDay > now
            buckets.append(
                NativeScopeBucket(
                    start: interval.start,
                    end: interval.end,
                    value: mean(values.map(\.value)),
                    low: lows.isEmpty ? nil : lows.min(),
                    high: highs.isEmpty ? nil : highs.max(),
                    isPartial: isPartial,
                    sampleCount: values.count,
                    key: key(from: interval.start, calendar: calendar)
                )
            )
            guard let next = calendar.date(byAdding: unit, value: 1, to: interval.start), next > cursor else { break }
            cursor = next
        }
        return buckets
    }

    static func date(from key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func key(from date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Higher-is-better table for Native trend arrows. Independent of MetricCatalog.
enum NativeMetricDirection {
    static func higherIsBetter(_ key: String) -> Bool? {
        switch key {
        case "hrv", "recovery", "sleep_performance", "hours_vs_needed_pct",
             "sleep_efficiency", "sleep_total_min", "asleep_min", "steps", "steps_est",
             "spo2", "vo2max", "vo2max_est", "restorative_pct", "restorative_min",
             "sleep_deep_min", "sleep_rem_min", "lean_mass", "mood":
            return true
        case "rhr", "resting_hr", "sleep_debt_min", "stress", "fitness_age", "body_age", "body_fat":
            return false
        default:
            return nil
        }
    }

    static func delta(current: Double, previous: Double, higherIsBetter: Bool?) -> NativeScore.Delta {
        let denom = max(abs(previous), 1e-9)
        let change = (current - previous) / denom
        if abs(change) <= 0.03 {
            return .flat
        }
        let wentUp = current > previous
        let good: Bool
        if let higherIsBetter {
            good = wentUp == higherIsBetter
        } else {
            good = wentUp
        }
        let tint = good ? NativeTokens.positiveDelta : NativeTokens.negativeDelta
        if wentUp {
            return NativeScore.Delta(
                symbol: "arrow.up",
                tint: tint,
                name: "higher than the previous period"
            )
        }
        return NativeScore.Delta(
            symbol: "arrow.down",
            tint: tint,
            name: "lower than the previous period"
        )
    }
}

enum NativeScopeKindMap {
    static func kind(for key: String) -> NativeScopeKind {
        switch key {
        case "steps", "steps_est", "energy_kcal", "active_kcal", "strain",
             "sleep_total_min", "asleep_min", "in_bed_min", "sleep_deep_min",
             "sleep_rem_min", "sleep_light_min", "restorative_min":
            return .total
        default:
            return .rate
        }
    }
}

/// Shared formatters. Never construct `DateFormatter()` in a view body.
enum NativeScopeFormat {
    private static let posix = Locale(identifier: "en_US_POSIX")

    private static let weekdayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.dateFormat = "MMM"
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    private static let dayOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.dateFormat = "d"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static func aligned(_ formatter: DateFormatter, calendar: Calendar) {
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
    }

    static func weekdayDate(_ date: Date, calendar: Calendar) -> String {
        aligned(weekdayDateFormatter, calendar: calendar)
        return weekdayDateFormatter.string(from: date)
    }

    static func monthDay(_ date: Date, calendar: Calendar) -> String {
        aligned(monthDayFormatter, calendar: calendar)
        return monthDayFormatter.string(from: date)
    }

    static func month(_ date: Date, calendar: Calendar) -> String {
        aligned(monthFormatter, calendar: calendar)
        return monthFormatter.string(from: date)
    }

    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        aligned(timeFormatter, calendar: calendar)
        return timeFormatter.string(from: date)
    }

    static func weekRange(from start: Date, to end: Date, calendar: Calendar) -> String {
        aligned(monthDayFormatter, calendar: calendar)
        let startMonth = calendar.component(.month, from: start)
        let endMonth = calendar.component(.month, from: end)
        if startMonth == endMonth {
            aligned(dayOnlyFormatter, calendar: calendar)
            return "\(monthDayFormatter.string(from: start)) – \(dayOnlyFormatter.string(from: end))"
        }
        return "\(monthDayFormatter.string(from: start)) – \(monthDayFormatter.string(from: end))"
    }

    static func heroRange(from start: Date, to end: Date, scope: NativeMetricScope, calendar: Calendar) -> String {
        aligned(monthFormatter, calendar: calendar)
        aligned(yearFormatter, calendar: calendar)
        aligned(monthDayFormatter, calendar: calendar)
        aligned(dayOnlyFormatter, calendar: calendar)
        if scope == .sixMonths || scope == .year {
            let startName = monthFormatter.string(from: start)
            let endName = monthFormatter.string(from: end)
            let startYear = calendar.component(.year, from: start)
            let endYear = calendar.component(.year, from: end)
            if startYear == endYear {
                if startName == endName {
                    return "\(startName) \(yearFormatter.string(from: end))"
                }
                return "\(startName) – \(endName) \(yearFormatter.string(from: end))"
            }
            return "\(startName) \(startYear) – \(endName) \(endYear)"
        }
        let startYear = calendar.component(.year, from: start)
        let endYear = calendar.component(.year, from: end)
        let startMonth = calendar.component(.month, from: start)
        let endMonth = calendar.component(.month, from: end)
        if startYear == endYear {
            if startMonth == endMonth {
                return "\(monthDayFormatter.string(from: start))–\(dayOnlyFormatter.string(from: end)), \(yearFormatter.string(from: end))"
            }
            return "\(monthDayFormatter.string(from: start)) – \(monthDayFormatter.string(from: end)), \(yearFormatter.string(from: end))"
        }
        return "\(monthDayFormatter.string(from: start)), \(startYear) – \(monthDayFormatter.string(from: end)), \(endYear)"
    }
}

enum NativeCountFormat {
    private static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .halfUp
        return formatter
    }()

    static func integer(_ value: Double) -> String {
        grouped.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }
}

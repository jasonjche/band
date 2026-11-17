import Foundation
import SwiftUI
import StrandAnalytics
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
    var percentChange: Double
    var delta: NativeScore.Delta
    var minValue: Double
    var minDate: Date
    var maxValue: Double
    var maxDate: Date
}

/// Trailing personal typical band: `TypicalVitalRange` (median ± 2.5 MAD-sigma, 30 days, 14 nights).
/// Same function Health Monitor uses, so the overlay and the flags cannot disagree.
enum NativeTypicalRange {
    static let minDays = TypicalVitalRange.minNights
    static let window = TypicalVitalRange.windowDays

    static func cfg(for key: String) -> MetricCfg? {
        switch key {
        case "hrv": return Baselines.hrvCfg
        case "rhr", "resting_hr": return Baselines.restingHRCfg
        case "resp_rate": return Baselines.respCfg
        case "skin_temp": return Baselines.metricCfg["skin_temp"]
        default: return nil
        }
    }

    /// Previous `window` calendar days excluding `ending`. Nils are missing nights.
    static func windowValues(
        dates: [(date: Date, value: Double?)],
        ending: Date,
        calendar: Calendar
    ) -> [Double?] {
        let end = calendar.startOfDay(for: ending)
        var byDay: [Date: Double] = [:]
        for point in dates {
            let day = calendar.startOfDay(for: point.date)
            guard day < end, let value = point.value, value.isFinite else { continue }
            byDay[day] = value
        }
        var out: [Double?] = []
        for offset in (1...window).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: end) else { continue }
            out.append(byDay[day])
        }
        return out
    }

    static func band(values: [Double?], cfg: MetricCfg? = nil) -> ClosedRange<Double>? {
        TypicalVitalRange.range(history: values, sigmaFloor: TypicalVitalRange.sigmaFloor(matching: cfg))
    }

    /// Count metrics never get the MAD vital band (it goes negative on steps).
    /// Vitals keep the shared band; a negative lower bound is clamped at 0.
    static func display(_ range: ClosedRange<Double>?, kind: NativeScopeKind) -> ClosedRange<Double>? {
        guard let range, range.upperBound.isFinite else { return nil }
        if kind == .total { return nil }
        let lo = max(0, range.lowerBound)
        let hi = range.upperBound
        guard hi > lo, lo.isFinite, hi.isFinite else { return nil }
        return lo...hi
    }

    static func caption(range: ClosedRange<Double>, format: (Double) -> String, unit: String?) -> String {
        let low = format(max(0, range.lowerBound))
        let high = format(max(0, range.upperBound))
        if let unit, !unit.isEmpty {
            return "Typical range \(low)–\(high) \(unit)"
        }
        return "Typical range \(low)–\(high)"
    }
}

/// Apple Health-style scope aggregation. One pure entry point; views never fold series in `body`.
struct NativeScopeSeries: Equatable {
    var scope: NativeMetricScope
    var kind: NativeScopeKind
    var buckets: [NativeScopeBucket]
    var caption: String
    var typical: ClosedRange<Double>? = nil

    static let empty = NativeScopeSeries(scope: .week, kind: .rate, buckets: [], caption: "Average")

    /// Horizontal average / trend line on W / M / 6M / Y. Day is a single slot.
    var showsTrendLine: Bool {
        switch scope {
        case .week, .month, .sixMonths, .year: return true
        case .day: return false
        }
    }

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
        ending: Date? = nil,
        cfg: MetricCfg? = nil
    ) -> NativeScopeSeries {
        let parsed: [(date: Date, value: Double, low: Double?, high: Double?)] = points.compactMap { point in
            guard let date = date(from: point.key, calendar: calendar) else { return nil }
            let finite = point.value.isFinite ? point.value : nil
            return (date, finite ?? .nan, point.low, point.high)
        }.sorted { $0.date < $1.date }

        let finite = parsed.filter { $0.value.isFinite }
        let today = calendar.startOfDay(for: now)
        let last = calendar.startOfDay(for: ending ?? finite.last?.date ?? today)
        let endDay = min(last, today)
        let typical = NativeTypicalRange.display(
            cfg == nil ? nil : NativeTypicalRange.band(
                values: NativeTypicalRange.windowValues(
                    dates: parsed.map { ($0.date, $0.value.isFinite ? $0.value : nil) },
                    ending: endDay,
                    calendar: calendar
                ),
                cfg: cfg
            ),
            kind: kind
        )
        guard let first = finite.first?.date else {
            return NativeScopeSeries(
                scope: scope, kind: kind, buckets: [],
                caption: caption(scope: scope, kind: kind), typical: typical
            )
        }

        let buckets: [NativeScopeBucket]
        switch scope {
        case .day, .week, .month:
            buckets = dailyBuckets(
                parsed: parsed,
                from: dailyStart(first: first, endDay: endDay, scope: scope, calendar: calendar),
                to: endDay,
                calendar: calendar
            )
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
            caption: caption(scope: scope, kind: kind),
            typical: typical
        )
    }

    static func caption(scope: NativeMetricScope, kind: NativeScopeKind) -> String {
        if kind == .total {
            switch scope {
            case .day: return "Total"
            case .sixMonths, .year: return "Daily Average"
            case .week, .month: return "Average"
            }
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

        let denom = max(abs(previousMean), 1e-9)
        return NativeScopeTrend(
            currentMean: current,
            previousMean: previousMean,
            percentChange: (current - previousMean) / denom,
            delta: NativeMetricDirection.delta(
                current: current, previous: previousMean, higherIsBetter: higherIsBetter
            ),
            minValue: minPair.0,
            minDate: minPair.1,
            maxValue: maxPair.0,
            maxDate: maxPair.1
        )
    }

    func priorPeriodName() -> String {
        switch scope {
        case .day: return "vs. prior day"
        case .week: return "vs. prior week"
        case .month: return "vs. prior month"
        case .sixMonths: return "vs. prior 6 months"
        case .year: return "vs. prior year"
        }
    }

    func periodDeltaCaption(of window: [NativeScopeBucket], higherIsBetter: Bool?) -> String? {
        guard showsTrendLine, let trend = trend(visible: window, higherIsBetter: higherIsBetter) else {
            return nil
        }
        let percent = Int((abs(trend.percentChange) * 100).rounded())
        return "\(percent)% \(priorPeriodName())"
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

    /// Trailing visible window, plus any earlier samples so the chart can still scroll.
    static func dailyStart(
        first: Date,
        endDay: Date,
        scope: NativeMetricScope,
        calendar: Calendar
    ) -> Date {
        let pad = max(scope.visibleCount - 1, 0)
        let visibleStart = calendar.date(byAdding: .day, value: -pad, to: endDay) ?? first
        let a = calendar.startOfDay(for: first)
        let b = calendar.startOfDay(for: visibleStart)
        return min(a, b)
    }

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

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.dateFormat = "h a"
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

    static func hourClock(_ date: Date, calendar: Calendar) -> String {
        aligned(hourFormatter, calendar: calendar)
        return hourFormatter.string(from: date)
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
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return formatter
    }()

    static func integer(_ value: Double) -> String {
        grouped.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }

    /// Axis labels: 0, 5k, 10k. Hero values keep `integer`.
    static func compact(_ value: Double) -> String {
        let rounded = value.rounded()
        let magnitude = abs(rounded)
        if magnitude >= 1000 {
            let k = rounded / 1000
            if abs(k - k.rounded()) < 0.05 {
                return "\(Int(k.rounded()))k"
            }
            return String(format: "%.1fk", k)
        }
        return integer(rounded)
    }
}

/// 0-based nice ticks for step/calorie bars (0 / 5k / 10k).
enum NativeCountTicks {
    static func niceCeiling(_ value: Double) -> Double {
        let v = max(value, 1)
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

    static func values(ceiling: Double) -> [Double] {
        let top = niceCeiling(ceiling)
        if top <= 1 { return [0, top] }
        return [0, top / 2, top]
    }

    static func hourLabelDates(dayStart: Date, calendar: Calendar) -> [Date] {
        [0, 6, 12, 18].compactMap { calendar.date(byAdding: .hour, value: $0, to: calendar.startOfDay(for: dayStart)) }
    }
}

/// Plot geometry that views must not recompute in `body`.
enum NativeScopePlotMath {
    /// Join consecutive readings closer than this; a 14-day hole stays a hole.
    static let maxConnectGap: TimeInterval = 14 * 24 * 60 * 60

    struct LinePoint: Identifiable, Equatable {
        var date: Date
        var value: Double
        var segment: Int
        var key: String
        var id: String { "\(segment)-\(key)" }
    }

    static func barUnit(scope: NativeMetricScope) -> Calendar.Component {
        switch scope {
        case .day: return .hour
        case .week, .month: return .day
        case .sixMonths: return .weekOfYear
        case .year: return .month
        }
    }

    static func showsVertices(scope: NativeMetricScope, knownCount: Int) -> Bool {
        switch scope {
        case .day, .week: return true
        case .month: return knownCount <= 16
        case .sixMonths, .year: return knownCount <= 12
        }
    }

    /// Consecutive known points share a segment until the calendar gap exceeds `maxConnectGap`.
    static func lineSegments(_ buckets: [NativeScopeBucket]) -> [LinePoint] {
        var segment = 0
        var lastDate: Date?
        var result: [LinePoint] = []
        for bucket in buckets {
            guard let value = bucket.value, value.isFinite else { continue }
            if let lastDate, bucket.start.timeIntervalSince(lastDate) > maxConnectGap {
                segment += 1
            }
            result.append(LinePoint(date: bucket.start, value: value, segment: segment, key: bucket.key))
            lastDate = bucket.start
        }
        return result
    }

    /// Typical band clipped to the y domain so it cannot flood the plot.
    static func clippedTypical(
        _ typical: ClosedRange<Double>?,
        yDomain: ClosedRange<Double>
    ) -> ClosedRange<Double>? {
        guard let typical else { return nil }
        let lo = max(typical.lowerBound, yDomain.lowerBound)
        let hi = min(typical.upperBound, yDomain.upperBound)
        guard hi > lo else { return nil }
        return lo...hi
    }
}

/// Round y-axis ticks for line charts (bars use `NativeCountTicks`).
enum NativeScopeYTicks {
    static func values(in domain: ClosedRange<Double>, maxCount: Int = 3) -> [Double] {
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

    static func niceDomain(_ values: [Double], fallback: ClosedRange<Double>) -> ClosedRange<Double> {
        let fitted = NativeChartDay.fittedDomain(values, fallback: fallback)
        let ticks = Self.values(in: fitted)
        guard let first = ticks.first, let last = ticks.last, last > first else { return fitted }
        let lo = min(fitted.lowerBound, first)
        let hi = max(fitted.upperBound, last)
        return lo...hi
    }

    private static func niceStep(_ raw: Double) -> Double {
        let v = max(abs(raw), 1e-9)
        let exp = floor(log10(v))
        let mag = pow(10, exp)
        let n = v / mag
        let nice: Double
        // Nearest nice step (not the next one up), so a 64-wide domain gets 20s, not one 50.
        if n < 1.5 { nice = 1 }
        else if n < 3.5 { nice = 2 }
        else if n < 7.5 { nice = 5 }
        else { nice = 10 }
        return nice * mag
    }
}

/// One-sentence Trend View copy under the hero.
enum NativeScopeSummary {
    static func sentence(
        title: String,
        scope: NativeMetricScope,
        kind: NativeScopeKind,
        current: Double?,
        previous: Double?,
        format: (Double) -> String,
        higherIsBetter: Bool?
    ) -> String? {
        guard let current, current.isFinite else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let caption = kind == .total && scope == .day ? "total" : "average"
        let period = periodPhrase(scope)
        let formatted = format(current)
        guard let previous, previous.isFinite else {
            return "Your \(caption) \(name) \(period) was \(formatted)."
        }
        let denom = max(abs(previous), 1e-9)
        let relation: String
        if abs(current - previous) / denom <= 0.03 {
            relation = "was about the same as"
        } else if current < previous {
            relation = "was below"
        } else {
            relation = "was above"
        }
        return "Your \(caption) \(name) \(period) (\(formatted)) \(relation) your previous \(priorPhrase(scope)) average of \(format(previous))."
    }

    static func periodPhrase(_ scope: NativeMetricScope) -> String {
        switch scope {
        case .day: return "today"
        case .week: return "this week"
        case .month: return "this month"
        case .sixMonths: return "over 6 months"
        case .year: return "this year"
        }
    }

    static func priorPhrase(_ scope: NativeMetricScope) -> String {
        switch scope {
        case .day: return "day"
        case .week: return "week"
        case .month: return "30-day"
        case .sixMonths: return "6-month"
        case .year: return "year"
        }
    }
}

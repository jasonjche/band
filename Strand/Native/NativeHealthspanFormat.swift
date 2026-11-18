import Foundation
import StrandAnalytics

/// Copy, scale labels, marker math, and orb hue mapping for Healthspan.
enum NativeHealthspanFormat {
    static func chronoAge(dob: Date, asOf: Date) -> Double {
        max(0, asOf.timeIntervalSince(dob) / (365.25 * 86_400))
    }

    static func ageText(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func paceText(_ value: Double) -> String {
        // Round first so -0.04 reads "0.0x", never "-0.0x".
        let rounded = (value * 10).rounded() / 10
        return String(format: "%.1fx", rounded == 0 ? 0 : rounded)
    }

    static func yearsImpact(_ years: Double?, available: Bool) -> String {
        guard available, let years else { return "—" }
        if abs(years) < 0.05 { return "0.0 years" }
        return String(format: "%+.1f years", years)
    }

    static func youngerText(_ delta: Double) -> String {
        if abs(delta) < 0.05 { return "Same as your age" }
        if delta > 0 { return String(format: "%.1f years younger", delta) }
        return String(format: "%.1f years older", -delta)
    }

    static func compactDeltaValue(_ delta: Double) -> String {
        String(format: "%.1f", abs(delta))
    }

    static func compactDeltaCaption(_ delta: Double) -> String {
        if abs(delta) < 0.05 { return "YEARS" }
        return delta > 0 ? "YEARS YOUNGER" : "YEARS OLDER"
    }

    static func valueText(_ value: Double, unit: String, key: String) -> String {
        switch key {
        case "sleep": return NativeScoreMath.duration(value * 60) + " h"
        case "zone13", "zone45", "strength": return NativeScoreMath.duration(value) + " h"
        case "steps": return NativeScoreMath.count(value)
        case "consistency", "lean": return String(format: "%.0f%%", value)
        case "rhr": return String(format: "%.0f bpm", value)
        case "vo2max": return String(format: "%.0f ml/kg/min", value)
        default:
            if unit.isEmpty { return String(format: "%.0f", value) }
            return String(format: "%.0f %@", value, unit)
        }
    }

    /// Compact end-cap for a contributor bar (WHOOP's 40% / 5h / 0K / 40bpm).
    static func scaleLabel(_ value: Double, key: String) -> String {
        switch key {
        case "sleep":
            return "\(Int(value.rounded()))h"
        case "zone13", "zone45", "strength":
            let hours = value / 60
            if abs(hours) < 0.05 { return "0h" }
            if abs(hours - hours.rounded()) < 0.05 { return "\(Int(hours.rounded()))h" }
            return String(format: "%.1fh", hours)
        case "steps":
            return "\(Int((value / 1_000).rounded()))K"
        case "consistency", "lean":
            return "\(Int(value.rounded()))%"
        case "rhr":
            return "\(Int(value.rounded()))bpm"
        default:
            return "\(Int(value.rounded()))"
        }
    }

    static func calibrationTitle(_ readiness: HealthspanEngine.Readiness, days: Int) -> String {
        switch readiness {
        case .notReady: return "Not enough data yet"
        case .calibrating: return "Calibrating Band Age"
        case .ready: return "Calibrated"
        }
    }

    static func calibrationBody(days: Int) -> String {
        let remain = max(0, HealthspanEngine.minDaysForAge - days)
        return "Band Age uses a 6-month average. \(days) days on record. Pace of Aging uses 30 days.\(remain > 0 ? " About \(remain) more days until Band Age is calibrated." : "")"
    }

    static func accessibility(_ row: HealthspanEngine.Contributor) -> String {
        let value = row.value.map { valueText($0, unit: row.unit, key: row.key) } ?? "not available"
        let years = yearsImpact(row.years, available: row.available)
        return "\(row.label), \(value), target \(row.targetLabel), \(years)"
    }

    static func contributorNote(_ row: HealthspanEngine.Contributor) -> String {
        guard row.available, let years = row.years else {
            return "Not enough \(row.label.lowercased()) data yet to estimate an age impact."
        }
        if abs(years) < 0.05 {
            return "Your \(row.label.lowercased()) is in range and is not changing Band Age."
        }
        if years > 0 {
            return "Your \(row.label.lowercased()) is increasing Band Age by \(yearsImpact(years, available: true)). The 30-day average shows whether this is holding."
        }
        return "Your \(row.label.lowercased()) is reducing Band Age by \(String(format: "%.1f years", abs(years)))."
    }

    /// 0 at `scaleMin`, 1 at `scaleMax`, clamped.
    static func markerProgress(value: Double, scaleMin: Double, scaleMax: Double) -> Double {
        let span = scaleMax - scaleMin
        guard span > 0 else { return 0.5 }
        return HealthspanEngine.clamp((value - scaleMin) / span, 0, 1)
    }

    /// Pace of Aging rail: −1.0x at 0, 1.0x at 0.5, 3.0x at 1.
    static func paceProgress(_ pace: Double) -> Double {
        HealthspanEngine.clamp((pace + 1) / 4, 0, 1)
    }
}

/// Orb palette from Band Age delta. Younger → mint/teal/blue; older → amber/orange.
enum NativeHealthspanOrbHue: Equatable {
    case younger
    case mixed
    case older
    case forming

    /// ±5 years saturates the ends. Nil delta (no score yet) sits in the middle.
    static func progress(deltaYears: Double?) -> Double {
        guard let delta = deltaYears else { return 0.5 }
        return HealthspanEngine.clamp(delta / 10 + 0.5, 0, 1)
    }

    static func resolve(deltaYears: Double?, forming: Bool) -> NativeHealthspanOrbHue {
        if forming { return .forming }
        let p = progress(deltaYears: deltaYears)
        if p >= 0.58 { return .younger }
        if p <= 0.42 { return .older }
        return .mixed
    }
}

enum NativeHealthspanPaceChip: Equatable {
    case faster
    case slower

    var label: String {
        switch self {
        case .faster: return "faster vs last week"
        case .slower: return "slower vs last week"
        }
    }

    /// Positive week delta means Pace of Aging sped up (worse).
    static func from(weekDelta: Double?) -> NativeHealthspanPaceChip? {
        guard let delta = weekDelta else { return nil }
        if delta > 0.05 { return .faster }
        if delta < -0.05 { return .slower }
        return nil
    }

    static func weekDelta(points: [HealthspanEngine.TrendPoint]) -> Double? {
        let paces = points.compactMap(\.pace)
        guard paces.count >= 2 else { return nil }
        return paces[paces.count - 1] - paces[paces.count - 2]
    }
}

enum NativeHealthspanTrendScope: String, CaseIterable, Identifiable {
    case month
    case sixMonths

    var id: String { rawValue }

    var label: String {
        switch self {
        case .month: return "M"
        case .sixMonths: return "6M"
        }
    }

    var days: Int {
        switch self {
        case .month: return 30
        case .sixMonths: return 180
        }
    }

    static func windowed(
        _ points: [HealthspanEngine.TrendPoint],
        scope: NativeHealthspanTrendScope
    ) -> [HealthspanEngine.TrendPoint] {
        guard let last = points.last, let endDay = NativeDayLogic.epochDay(last.day) else { return points }
        let startDay = endDay - scope.days
        return points.filter { point in
            guard let day = NativeDayLogic.epochDay(point.day) else { return false }
            return day >= startDay
        }
    }
}

enum NativeHealthspanTrendKind: String, Hashable {
    case bandAge
    case pace

    var title: String {
        switch self {
        case .bandAge: return "Band Age trend"
        case .pace: return "Pace of Aging trend"
        }
    }
}

import Foundation
import StrandAnalytics

/// Canonical metric number / unit / duration-axis formatting for Native metric pages.
///
/// Stored values stay SI (minutes, kg, °C, 0–100 strain). This layer converts for display
/// so `NativeMetricPage`, `NativeScopeChart`, and Trends never disagree.
enum NativeMetricFormat {

    private static let durationMinuteKeys: Set<String> = [
        "sleep_total_min", "asleep_min", "in_bed_min",
        "sleep_deep_min", "deep_min",
        "sleep_rem_min", "rem_min",
        "sleep_light_min", "core_min",
        "sleep_awake_min", "awake_min",
        "sleep_need_min", "sleep_debt_min", "restorative_min",
        "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min",
        "strength_min", "intensity_min",
    ]

    private static let percentKeys: Set<String> = [
        "recovery", "sleep_performance", "sleep_consistency", "sleep_efficiency",
        "hours_vs_needed_pct", "restorative_pct", "spo2", "sleep_score", "body_fat",
    ]

    private static let heartRateKeys: Set<String> = [
        "rhr", "resting_hr", "avg_hr", "max_hr",
    ]

    private static let countKeys: Set<String> = [
        "steps", "steps_est",
    ]

    private static let calorieKeys: Set<String> = [
        "energy_kcal", "active_kcal", "calories_in",
    ]

    private static let gramKeys: Set<String> = [
        "protein_g", "carbs_g", "fat_g",
    ]

    private static let vo2Keys: Set<String> = [
        "vo2max", "vo2max_est",
    ]

    private static let massKeys: Set<String> = [
        "weight", "lean_mass",
    ]

    private static let durationSteps: [Double] = [15, 30, 60, 120, 180, 240]

    static func isDurationMinutes(key: String) -> Bool {
        key.hasSuffix("_min") || durationMinuteKeys.contains(key)
    }

    static func usesClockHero(key: String) -> Bool {
        isDurationMinutes(key: key)
    }

    /// Convert a stored value onto the display axis (minutes stay minutes; mass/temp/strain convert).
    static func displayValue(
        raw: Double?,
        key: String,
        scale: EffortScale,
        unitSystem: UnitSystem,
        temperatureUnit: TemperatureUnit
    ) -> Double? {
        guard let raw, raw.isFinite else { return nil }
        if key == "strain" {
            return NativeDayLogic.strainDisplayValue(raw, scale: scale)
        }
        if percentKeys.contains(key), abs(raw) <= 1 {
            return raw * 100
        }
        if massKeys.contains(key), unitSystem == .imperial {
            return UnitFormatter.kgToPounds(raw)
        }
        if key == "skin_temp", temperatureUnit == .fahrenheit {
            return SkinTempDisplay.kind(of: raw) == .absolute
                ? UnitFormatter.celsiusToFahrenheit(raw)
                : UnitFormatter.celsiusDeltaToFahrenheit(raw)
        }
        return raw
    }

    /// Format a display-scaled value (already converted by `displayValue`).
    static func format(value: Double, key: String, scale: EffortScale) -> String {
        guard value.isFinite else { return "—" }
        if isDurationMinutes(key: key) {
            return NativeScoreMath.duration(value)
        }
        if key == "hours_vs_needed_hours" {
            return NativeSleepNeed.signedDuration(value * 60)
        }
        if key == "strain" {
            return scale == .whoop
                ? String(format: "%.1f", value)
                : String(Int(value.rounded()))
        }
        if key == "pace_of_aging" {
            return String(format: "%.2fx", value)
        }
        if key == "band_age" {
            return String(format: "%.1f", value)
        }
        if key == "mood" {
            if abs(value - value.rounded()) < 0.05 {
                return "\(Int(value.rounded()))"
            }
            return String(format: "%.1f", value)
        }
        if key == "stress"
            || key == "bmi"
            || key == "resp_rate"
            || vo2Keys.contains(key)
            || massKeys.contains(key)
            || key == "skin_temp"
            || key == "body_fat"
        {
            return String(format: "%.1f", value)
        }
        if countKeys.contains(key) || calorieKeys.contains(key) {
            return NativeCountFormat.integer(value)
        }
        return "\(Int(value.rounded()))"
    }

    static func unit(
        for key: String,
        scale: EffortScale,
        unitSystem: UnitSystem,
        temperatureUnit: TemperatureUnit,
        metricUnit: String?,
        source: String? = nil
    ) -> String? {
        _ = scale
        if isDurationMinutes(key: key) || key == "hours_vs_needed_hours" {
            return nil
        }
        if key == "strain" || key == "bmi" || key == "pace_of_aging" {
            return nil
        }
        if key == "stress" {
            if source == "xiaomi-band" { return "/100" }
            return nil
        }
        if massKeys.contains(key) {
            return UnitFormatter.massUnit(unitSystem)
        }
        if key == "skin_temp" {
            return UnitFormatter.temperatureUnit(temperatureUnit)
        }
        if percentKeys.contains(key) {
            return "%"
        }
        if key == "hrv" { return "ms" }
        if heartRateKeys.contains(key) { return "BPM" }
        if key == "resp_rate" { return "breaths/min" }
        if vo2Keys.contains(key) { return "ml/kg·min" }
        if countKeys.contains(key) { return "steps" }
        if calorieKeys.contains(key) { return "cal" }
        if gramKeys.contains(key) { return "g" }
        if key == "band_age" || key == "fitness_age" || key == "body_age" { return "yrs" }
        if key == "mood" { return "/5" }
        let unit = metricUnit ?? ""
        return unit.isEmpty ? nil : unit
    }

    /// Nice duration step: 15m / 30m / 1h / 2h / 3h / 4h, aiming for about three intervals.
    static func durationStep(maxMinutes: Double) -> Double {
        let max = Swift.max(maxMinutes, 1)
        let raw = max / 3
        if let step = durationSteps.first(where: { $0 >= raw }) {
            return step
        }
        return (raw / 240).rounded(.up) * 240
    }

    static func durationCeiling(maxMinutes: Double) -> Double {
        let step = durationStep(maxMinutes: maxMinutes)
        let max = Swift.max(maxMinutes, 0)
        if max <= 0 { return step }
        return (max / step - 1e-9).rounded(.up) * step
    }

    static func durationAxisTicks(maxMinutes: Double) -> [Double] {
        let top = durationCeiling(maxMinutes: maxMinutes)
        let step = durationStep(maxMinutes: maxMinutes)
        guard step > 0 else { return [0, top] }
        return Array(stride(from: 0, through: top + step * 0.01, by: step))
            .map { ($0 * 1e9).rounded() / 1e9 }
    }
}

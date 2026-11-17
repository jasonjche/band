import Foundation
import StrandAnalytics
import WhoopStore

/// One funnel for today's strain-coach range. Home ring and Strain page both call this
/// so the arc and the caption cannot disagree. Past days are always nil.
enum NativeStrainTarget {

    enum Position: String {
        case below = "Below"
        case inRange = "In range"
        case above = "Above"
    }

    static func resolve(
        viewingKey: String,
        todayKey: String,
        days: [DailyMetric],
        sleeps: [CachedSleepSession] = [],
        workouts: [WorkoutRow] = [],
        importedSleep: [String: ImportedSleepFigures] = [:]
    ) -> BandStrainTarget.Result? {
        guard viewingKey == todayKey else { return nil }
        let scores = NativeBandScores.resolve(
            days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        return BandStrainTarget.recommend(
            recovery: scores.byDay[viewingKey]?.recovery,
            recentStrain21: history21(
                days: days, excluding: viewingKey, workouts: workouts, importedSleep: importedSleep
            )
        )
    }

    /// Day strain on the 0–21 axis, chronological, excluding `excluding` (today).
    static func history21(
        days: [DailyMetric],
        excluding: String,
        workouts: [WorkoutRow] = [],
        importedSleep: [String: ImportedSleepFigures] = [:]
    ) -> [Double] {
        let workoutMax = NativeStrain.workoutMaxByDay(workouts)
        return days
            .filter { $0.day < excluding }
            .sorted { $0.day < $1.day }
            .compactMap { day in
                NativeStrain.day(
                    stored: day.strain,
                    live: nil,
                    imported: NativeStrain.isImportedDay(importedSleep[day.day]),
                    workoutMax: workoutMax[day.day]
                ).map { NativeDayLogic.strainDisplayValue($0, scale: .whoop) }
            }
    }

    static func position(strain21: Double, range: ClosedRange<Double>) -> Position {
        if strain21 < range.lowerBound { return .below }
        if strain21 > range.upperBound { return .above }
        return .inRange
    }

    /// "Target 10.2-13.8 · Maintain · In range"
    static func caption(result: BandStrainTarget.Result, strain21: Double?) -> String {
        let lo = String(format: "%.1f", result.range.lowerBound)
        let hi = String(format: "%.1f", result.range.upperBound)
        var line = "Target \(lo)-\(hi) · \(result.label.rawValue)"
        if let strain21, strain21.isFinite {
            line += " · \(position(strain21: strain21, range: result.range).rawValue)"
        }
        return line
    }

    /// Ring trim fractions on the 0–1 track (strain 0–21).
    static func ringFraction(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        let lo = min(max(range.lowerBound / 21, 0), 1)
        let hi = min(max(range.upperBound / 21, 0), 1)
        return min(lo, hi)...max(lo, hi)
    }

    /// Midpoint of the target range on the 0–1 ring. WHOOP draws one tick here.
    static func ringTickFraction(_ range: ClosedRange<Double>) -> Double {
        let frac = ringFraction(range)
        return (frac.lowerBound + frac.upperBound) / 2
    }
}

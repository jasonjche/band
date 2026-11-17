import Foundation
import StrandAnalytics
import WhoopStore
import WhoopProtocol

/// One funnel for every Native-shell strain number (Home ring, live, score page, week,
/// Strain & Recovery, activity pills, activity page).
///
/// Imported WHOOP days/workouts keep the export's stored strain. Strap days and workouts
/// use `BandStrain` on stored HR, written 0–100 (`BandStrain` 0–21 × 100/21) so
/// `NativeDayLogic.strainText` / `UnitFormatter.effortValue` stay unchanged.
enum NativeStrain {

    /// Day strain on the stored 0–100 axis. Imported days ignore a live recompute.
    static func day(stored: Double?, live: Double?, imported: Bool) -> Double? {
        if imported { return stored }
        return NativeDayLogic.effectiveStrain(live: live, stored: stored)
    }

    static func isImportedDay(_ figures: ImportedSleepFigures?) -> Bool {
        NativeBandScores.isImported(figures)
    }

    /// WHOOP / Apple / file imports keep their stored strain. Strap-native rows use the stored
    /// value too, which the personal analysis pass writes from BandStrain.
    static func isImportedWorkout(_ source: String) -> Bool {
        switch WorkoutSource.classify(source) {
        case .whoop, .apple, .lifting, .activityFile: return true
        case .manual, .detected: return false
        }
    }

    static func workout(_ row: WorkoutRow) -> Double? {
        row.strain
    }

    /// BandStrain on samples, stored 0–100. Empty → nil.
    static func score(_ samples: [HRSample], maxHR: Double?, restingHR: Double) -> Double? {
        score(times: samples.map { Double($0.ts) },
              hr: samples.map { Double($0.bpm) },
              maxHR: maxHR, restingHR: restingHR)
    }

    static func score(times: [Double], hr: [Double], maxHR: Double?, restingHR: Double) -> Double? {
        guard let params = BandStrain.bundledParams() else { return nil }
        let hrmax = maxHR ?? Double(StrainScorer.defaultMaxHR())
        return BandStrain.effort100(
            BandStrain.strain(times: times, hr: hr, maxHR: hrmax, restingHR: restingHR, params: params)
        )
    }

    /// Day's overnight RHR, else the most recent prior day's RHR, else the model's default (60).
    static func restingHR(day: DailyMetric?, days: [DailyMetric] = [], dayKey: String? = nil) -> Double {
        if let r = day?.restingHr { return Double(r) }
        if let key = dayKey,
           let prior = days.last(where: { $0.day < key && $0.restingHr != nil })?.restingHr {
            return Double(prior)
        }
        return BandStrain.defaultRestingHR
    }
}

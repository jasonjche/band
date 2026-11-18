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
    ///
    /// `workoutMax` is the highest workout strain logged that day. A day can never read lower
    /// than one of its own workouts: when it would, the strap HR for that workout is missing
    /// (another app took it off the strap), so the workout's load is added to the day's.
    static func day(stored: Double?, live: Double?, imported: Bool, workoutMax: Double? = nil) -> Double? {
        if imported { return stored }
        return withWorkout(day: NativeDayLogic.effectiveStrain(live: live, stored: stored),
                           workoutMax: workoutMax)
    }

    static func withWorkout(day: Double?, workoutMax: Double?) -> Double? {
        guard let w = workoutMax, w > 0 else { return day }
        guard let d = day, d > 0 else { return w }
        if d >= w { return d }
        guard let params = BandStrain.bundledParams(),
              let ld = load(effort100: d, params: params),
              let lw = load(effort100: w, params: params) else { return w }
        return BandStrain.effort100(BandStrain.strain(load: ld + lw, params: params)) ?? w
    }

    /// Inverse of `BandStrain.strain(load:)` from the stored 0–100 axis.
    static func load(effort100: Double, params: BandStrain.Params) -> Double? {
        let s = effort100 / 100 * params.maxStrain
        guard s > 0, s < params.maxStrain, params.k > 0, params.p > 0 else { return nil }
        return pow(-log(1 - s / params.maxStrain) / params.k, 1 / params.p)
    }

    /// Highest workout strain per local day key.
    /// Home `rebuildModel` calls this from `NativeDay.make` and twice from `NativeWeek.points`.
    /// Cache the last input so those three walks share one pass. Full array equality, so numbers match.
    static func workoutMaxByDay(_ workouts: [WorkoutRow]) -> [String: Double] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if cachedWorkouts == workouts { return cachedMaxByDay }
        var out: [String: Double] = [:]
        for w in workouts {
            guard let s = w.strain, s > 0 else { continue }
            let key = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(w.startTs)))
            out[key] = max(out[key] ?? 0, s)
        }
        cachedWorkouts = workouts
        cachedMaxByDay = out
        return out
    }

    private static let cacheLock = NSLock()
    private static var cachedWorkouts: [WorkoutRow] = []
    private static var cachedMaxByDay: [String: Double] = [:]

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

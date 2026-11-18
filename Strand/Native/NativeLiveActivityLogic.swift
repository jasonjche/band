import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Pure live-activity maths. The live ring, the saved row, and the activity page
/// all read strain from `NativeStrain.score` on the same HR window.
enum NativeLiveActivityLogic {
    static let strainRefreshSeconds: TimeInterval = 3

    static func showsStrain(_ sport: String) -> Bool {
        !WorkoutCatalog.isRecovery(sport) && LiveActivityScoring.showsActivityStrain(sport)
    }

    static func showsTrackRoute(_ sport: String) -> Bool {
        WorkoutCatalog.sport(named: sport)?.isDistanceSport ?? false
    }

    static func showsDistancePace(_ sport: String) -> Bool {
        LiveActivityScoring.showsDistancePace(sport)
    }

    static func defaultTrackRoute(_ sport: String) -> Bool {
        showsTrackRoute(sport)
    }

    /// One sample per unix second, matching `AppModel.ActiveWorkout.recordSample`.
    @discardableResult
    static func recordSample(into samples: inout [HRSample], bpm: Int, at date: Date) -> Bool {
        let ts = Int(date.timeIntervalSince1970)
        if let last = samples.last, last.ts == ts { return false }
        samples.append(HRSample(ts: ts, bpm: bpm))
        return true
    }

    static func shouldRefreshMetrics(lastTs: Int, now: Date, force: Bool) -> Bool {
        if force { return true }
        return Int(now.timeIntervalSince1970) - lastTs >= Int(strainRefreshSeconds)
    }

    /// Stored 0–100 strain, same function the activity page reads off the saved row.
    static func strain(samples: [HRSample], maxHR: Double?, restingHR: Double) -> Double? {
        guard samples.count >= 2 else { return nil }
        return NativeStrain.score(samples, maxHR: maxHR, restingHR: restingHR)
    }

    static func strain21(_ effort100: Double?) -> Double {
        NativeDayLogic.strainDisplayValue(effort100 ?? 0, scale: .whoop)
    }

    static func strainText(_ effort100: Double?) -> String {
        NativeDayLogic.strainText(effort100 ?? 0, scale: .whoop)
    }

    static func strainBand(_ effort100: Double?) -> BandStrainBand {
        BandStrainBand.band(strain21: strain21(effort100))
    }

    static func strainFraction(_ effort100: Double?) -> Double {
        min(max(strain21(effort100) / 21, 0), 1)
    }

    static func calories(
        samples: [HRSample],
        profile: UserProfile,
        maxHR: Double?,
        restingHR: Double
    ) -> Double? {
        LiveActivityScoring.calories(
            samples: samples,
            profile: profile,
            maxHR: maxHR ?? Double(StrainScorer.defaultMaxHR()),
            restingHR: restingHR
        )
    }

    static func averageHr(_ samples: [HRSample]) -> Int? {
        LiveActivityScoring.averageHr(samples)
    }

    static func peakHr(_ samples: [HRSample]) -> Int? {
        LiveActivityScoring.peakHr(samples)
    }

    static func shouldFireTarget(
        enabled: Bool,
        alreadyFired: Bool,
        strain21: Double,
        range: ClosedRange<Double>?
    ) -> Bool {
        guard enabled, !alreadyFired, let range else { return false }
        return strain21 >= range.lowerBound
    }

    static func zoneBarLabel(_ zone: HRZone) -> String {
        let lo = Int((zone.lowerPct * 100).rounded())
        let hi = Int((zone.upperPct * 100).rounded())
        if zone.number == 5 { return "\(lo)–100%" }
        return "\(lo)–\(max(lo, hi - 1))%"
    }

    static func hrPoints(_ samples: [HRSample]) -> [NativeHourPoint] {
        NativeActivityPageLogic.bucketed(
            samples.map { (ts: $0.ts, bpm: Double($0.bpm)) },
            seconds: NativeActivityPageLogic.hrBucketSeconds
        )
    }

    /// Pause-aware elapsed, same arithmetic as `ActiveWorkoutClock`.
    static func elapsed(
        start: Date,
        now: Date,
        pausedAt: Date?,
        pausedDuration: TimeInterval
    ) -> TimeInterval {
        ActiveWorkoutClock.activeElapsed(
            start: start, pausedAt: pausedAt, pausedDuration: pausedDuration, now: now
        )
    }

    static func makeRow(
        sport: String,
        startTs: Int,
        end: Date,
        elapsed: TimeInterval,
        samples: [HRSample],
        maxHR: Double?,
        restingHR: Double,
        profile: UserProfile,
        route: WorkoutRoute?
    ) -> WorkoutRow? {
        guard !NativeActiveWorkoutState.shouldDiscard(elapsed: elapsed) else { return nil }
        let endTs = Int(end.timeIntervalSince1970)
        guard endTs > startTs else { return nil }
        let recovery = !showsStrain(sport)
        let scored = samples.count >= 2
            ? NativeStrain.score(samples, maxHR: maxHR, restingHR: restingHR)
            : nil
        let kcal = calories(samples: samples, profile: profile, maxHR: maxHR, restingHR: restingHR)
        return WorkoutRow(
            startTs: startTs,
            endTs: endTs,
            sport: sport,
            source: "manual",
            durationS: elapsed,
            energyKcal: kcal,
            avgHr: averageHr(samples),
            maxHr: peakHr(samples),
            strain: recovery ? nil : scored,
            distanceM: route?.distanceM,
            zonesJSON: nil,
            notes: nil,
            steps: nil
        )
    }
}

struct NativeLiveWorkoutResult {
    var elapsed: TimeInterval
    var samples: [HRSample]
    var avgHr: Int?
    var maxHr: Int?
    var strain: Double?
    var energyKcal: Double?
    var route: WorkoutRoute?
    var discarded: Bool
}

struct NativeActiveWorkoutSnapshot: Equatable {
    var sport: String
    var elapsed: String
    var strainText: String
    var strainBand: String
    var strainFraction: Double
    var bpm: Int?
    var zone: Int
    var zoneSet: HRZoneSet?
    var avgHr: Int?
    var maxHr: Int?
    var caloriesText: String
    var caloriesHint: String?
    var distanceText: String?
    var paceText: String?
    var isRecovery: Bool
    var isPaused: Bool
    var targetFraction: ClosedRange<Double>?
    var hrPoints: [NativeHourPoint]
    var route: [RouteMath.LatLng]
    var showsMap: Bool
    var showsDistancePace: Bool
}

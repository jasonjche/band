import Foundation
import WhoopStore

/// How Band scores an activity, against what WHOOP publishes for each kind.
///
/// WHOOP's public lists (support.whoop.com “List of WHOOP Activities”, locker
/// “How WHOOP Measures Muscular Load”):
///
///  * **Strain / cardio** — running, walking, cycling, swimming, … Activity
///    strain is heart-rate load. Walking is cardio-only (no muscular *).
///  * **Strain / strength** — weightlifting, powerlifting, bodybuilding,
///    strength, calisthenics, CrossFit. Activity strain = cardio + muscular.
///  * **Strain / mixed** — HIIT, yoga, pilates, climbing, rucking, boxing,
///    barre. WHOOP auto-estimates muscular load from type + duration; Band
///    only adds muscular load when the user logged sets × reps × weight.
///  * **Recovery** — sauna, ice bath, meditation, stretching, breathwork,
///    massage, restorative yoga, … WHOOP records HR but these do **not**
///    add Activity Strain. Day Strain can still move if HR is elevated,
///    because WHOOP scores the whole day from HR. Regular yoga / pilates
///    stay strain activities; **restorative** yoga is recovery.
///
/// Band's muscular figure is relative volume from logged working sets
/// (`Σ weight × reps / body weight`), mapped onto 0–21 with a documented
/// exponential. It does **not** write `workout.strain` or daily Effort.
/// 1 Hz gravity cannot count reps (Nyquist 0.5 Hz). High-rate IMU is not
/// used here; any accelerometer estimate stays off.
public enum ActivityScoring {

    public enum Kind: Equatable, Sendable {
        /// Heart-rate strain only (run, walk, cycle, swim, …).
        case cardio
        /// Cardio + muscular when sets are logged (lift, powerlifting, …).
        case strength
        /// WHOOP auto-muscular; Band muscular only from logged sets.
        case mixed
        /// No activity strain. HR is still shown.
        case recovery
    }

    public static func kind(_ sport: String) -> Kind {
        let s = sport.lowercased()
        if isRecovery(s) { return .recovery }
        if isStrength(s) { return .strength }
        if isMixed(s) { return .mixed }
        return .cardio
    }

    public static func contributesActivityStrain(_ sport: String) -> Bool {
        kind(sport) != .recovery
    }

    /// 1 Hz gravity / dynAccel cannot resolve reps. Need > 3 Hz to clear Nyquist
    /// for a 1.5 Hz (90 / min) press. WHOOP 5 raw IMU is 100 Hz when captured;
    /// the stored gravity table is 1 Hz.
    public static let gravitySampleRateHz = 1.0
    public static let minRepSampleRateHz = 3.0

    public static func canCountReps(sampleRateHz: Double) -> Bool {
        sampleRateHz >= minRepSampleRateHz
    }

    public static var canCountRepsFromStoredGravity: Bool {
        canCountReps(sampleRateHz: gravitySampleRateHz)
    }

    // MARK: - Muscular load from logged sets

    /// `21 × (1 − exp(−relativeVolume × intensity / tau))`. Tau is chosen so a
    /// moderate session (relative volume ~80 at intensity 0.7) lands near 4.
    public static let volumeTau = 280.0
    /// Used when no working set was rated.
    public static let defaultIntensity = 0.7

    public struct Muscular: Equatable, Sendable {
        public var kind: Kind
        public var relativeVolume: Double
        public var intensity: Double
        public var cardioStrain21: Double
        public var muscularStrain21: Double
        public var combinedStrain21: Double
        public var cardioPercent: Int
        public var muscularPercent: Int

        public init(kind: Kind, relativeVolume: Double, intensity: Double,
                    cardioStrain21: Double, muscularStrain21: Double,
                    combinedStrain21: Double, cardioPercent: Int, muscularPercent: Int) {
            self.kind = kind
            self.relativeVolume = relativeVolume
            self.intensity = intensity
            self.cardioStrain21 = cardioStrain21
            self.muscularStrain21 = muscularStrain21
            self.combinedStrain21 = combinedStrain21
            self.cardioPercent = cardioPercent
            self.muscularPercent = muscularPercent
        }
    }

    /// Muscular split when this sport takes muscular load and working sets have
    /// countable volume. Nil for cardio, recovery, or sessions with no log.
    public static func muscularLoad(
        sport: String,
        sets: [LiftSetRow],
        bodyWeightKg: Double?,
        cardioStrain21: Double?
    ) -> Muscular? {
        let kind = kind(sport)
        guard kind == .strength || kind == .mixed else { return nil }
        guard let body = bodyWeightKg, body > 0,
              let volume = LiftMetrics.volumeLoadKg(sets), volume > 0 else { return nil }
        let relative = volume / body
        let intensity = workingIntensity(sets)
        let muscular21 = strain21(relativeVolume: relative, intensity: intensity)
        guard muscular21 > 0 else { return nil }
        let cardio = max(0, cardioStrain21 ?? 0)
        let parts = combine(cardio21: cardio, muscular21: muscular21)
        let percents = percentPair(cardioShare: parts.cardioShare, muscularShare: parts.muscularShare)
        return Muscular(
            kind: kind,
            relativeVolume: relative,
            intensity: intensity,
            cardioStrain21: cardio,
            muscularStrain21: muscular21,
            combinedStrain21: parts.combined,
            cardioPercent: percents.cardio,
            muscularPercent: percents.muscular
        )
    }

    /// Mean working-set RPE / 10, else `defaultIntensity`.
    public static func workingIntensity(_ sets: [LiftSetRow]) -> Double {
        let rated = sets.filter { !$0.isWarmup && LiftMetrics.isPerformed(reps: $0.reps) }
            .compactMap(\.rpe)
            .filter { $0 > 0 }
        guard !rated.isEmpty else { return defaultIntensity }
        return min(1, max(0, rated.reduce(0, +) / Double(rated.count) / 10))
    }

    public static func strain21(relativeVolume: Double, intensity: Double) -> Double {
        let load = max(0, relativeVolume) * min(max(intensity, 0), 1)
        if load <= 0 { return 0 }
        return 21 * (1 - exp(-load / volumeTau))
    }

    /// Saturating combination so two loads share the 0–21 ceiling.
    public static func combine(cardio21: Double, muscular21: Double)
        -> (combined: Double, cardioShare: Double, muscularShare: Double) {
        let cardio = max(0, cardio21)
        let muscular = max(0, muscular21)
        let cf = min(cardio / 21, 1)
        let mf = min(muscular / 21, 1)
        let combined = 21 * (1 - (1 - cf) * (1 - mf))
        let sum = cardio + muscular
        if sum <= 0 { return (0, 1, 0) }
        return (combined, cardio / sum, muscular / sum)
    }

    public static func percentPair(cardioShare: Double, muscularShare: Double) -> (cardio: Int, muscular: Int) {
        let cardio = min(max(Int((cardioShare * 100).rounded()), 0), 100)
        return (cardio, 100 - cardio)
    }

    // MARK: - Sport lists (WHOOP public catalogue)

    private static func isRecovery(_ s: String) -> Bool {
        if s.contains("restorative") { return true }
        if s.contains("meditation") || s.contains("breathwork") || s.contains("breath work") { return true }
        if s.contains("stretch") { return true }
        if s.contains("massage") { return true }
        if s.contains("sauna") { return true }
        if s.contains("ice bath") || s.contains("cold plunge") || s.contains("cold shower") { return true }
        if s.contains("foam roll") { return true }
        if s.contains("hot tub") || s.contains("warm bath") || s.contains("steam") { return true }
        if s.contains("contrast therap") { return true }
        if s.contains("tai chi") || s.contains("taichi") || s.contains("qigong") { return true }
        if s.contains("acupuncture") || s.contains("chiropractic") { return true }
        if s.contains("red light") || s.contains("non-sleep") || s.contains("nsdr") { return true }
        return false
    }

    private static func isStrength(_ s: String) -> Bool {
        if s.contains("powerlift") || s.contains("bodybuild") { return true }
        if s.contains("weightlift") || s.contains("olympic") { return true }
        if s.contains("calisthen") { return true }
        if s.contains("crossfit") || s.contains("cross fit") { return true }
        if s.contains("strength") || s.contains("weight") || s.contains("lift") { return true }
        return false
    }

    private static func isMixed(_ s: String) -> Bool {
        if s.contains("hiit") || s.contains("interval") || s.contains("boot camp") { return true }
        if s.contains("yoga") || s.contains("pilates") || s.contains("barre") { return true }
        if s.contains("climb") || s.contains("ruck") { return true }
        if s.contains("box") || s.contains("kickbox") { return true }
        if s.contains("functional") { return true }
        return false
    }
}

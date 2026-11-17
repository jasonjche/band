import Foundation

/// Overnight load signal: personal-baseline z of RHR, HRV, respiratory rate,
/// and skin temperature, raised only when two or more signals move together
/// on two consecutive nights.
///
/// Why this replaces `IllnessSignalEngine` for Band
/// -----------------------------------------------
/// `IllnessSignalEngine` is sound in spirit — personal z-scores, a ≥2
/// corroboration gate, confounder tags — but it scores a *single* recent
/// window (AppModel averages ~2 days then requires the latest night to
/// clear z ≥ 2). On this wearer's history that single-night rule fires about
/// 3.5 episodes per 60 days, well above the ~1-per-2-months budget. It also
/// posts notifications, which Band does not.
///
/// Band keeps the four-signal personal-baseline pattern documented in the
/// wearable early-warning literature, then adds a consecutive-night gate
/// and a z threshold calibrated on this wearer's own nights:
///
///   Mishra T et al. Pre-symptomatic detection of COVID-19 from smartwatch
///   data. Nat Biomed Eng. 2020;4:1208–1220. Resting HR rose above the
///   personal baseline, often for more than one day, before symptoms.
///
///   Related multi-vital signatures (RHR ↑, HRV ↓, respiratory rate ↑,
///   skin temperature ↑) appear in Alavi et al. 2022 (TemPredict) and
///   Quer et al. 2021. Band re-derives the *pattern* against the wearer's
///   own 28-day baseline; it never uses a population cutoff and never
///   names a condition.
///
/// Rules
/// -----
///   • Each night is z-scored against the prior 28 calendar days (missing
///     nights skipped, never zero-filled). Minimum 14 valid nights per
///     signal, matching `Baselines.minNightsTrust` / `TypicalVitalRange`.
///   • A signal “fires” when its illness-ward z reaches `zThreshold` (1.5).
///     Illness-ward: RHR ↑, HRV ↓, respiratory rate ↑, skin temperature ↑.
///   • A night corroborates when ≥2 signals fire.
///   • The surface raises only when *this* night and the *previous calendar
///     night* both corroborate. A gap resets the count.
///   • z = 1.5 plus the consecutive-night gate was the combination that
///     stayed at about one episode per 60 days on this wearer's history
///     (see the implementation report). `IllnessSignalEngine`'s z = 2.0
///     without a consecutive gate over-fired; z = 2.0 *with* the gate was
///     nearly silent.
///   • Alcohol / journal tags are recorded for sanity-check counts. They
///     do not suppress the level and they never send a notification.
///
/// Wellness copy only. Approximate. Not a diagnosis. No notifications.
public enum BandIllnessSignal {

    public static let baselineWindowDays = 28
    public static let minBaselineNights = 14
    /// Calibrated on this wearer's history with the consecutive-night gate
    /// so the episode rate stays around one per 60 days.
    public static let zThreshold = 1.5
    public static let minCorroboratingSignals = 2
    public static let consecutiveNights = 2

    /// Physiological floors so a flat history cannot produce a zero-width
    /// z (same magnitudes as `TypicalVitalRange.Metric.sigmaFloor`).
    public static let rhrSigmaFloor = 1.0
    public static let hrvSigmaFloor = 3.0
    public static let respSigmaFloor = 0.2
    public static let skinSigmaFloor = 0.1

    public enum Level: String, Equatable, Sendable {
        /// Not enough personal history to judge tonight.
        case building
        /// Judged; tonight is not the second corroborated night.
        case quiet
        /// Two consecutive nights, each with ≥2 illness-ward signals.
        case watch
    }

    public enum SignalKey: String, Equatable, Sendable, Hashable, CaseIterable {
        case rhr, hrv, resp, skin
    }

    public struct Night: Equatable, Sendable {
        public var day: String
        public var rhr: Double?
        public var hrvMs: Double?
        public var respRpm: Double?
        public var skinTemp: Double?
        /// Journal “alcoholic drinks” (or equivalent) on this wake day.
        /// Counted for sanity-check overlap; does not change `level`.
        public var alcohol: Bool

        public init(day: String, rhr: Double? = nil, hrvMs: Double? = nil,
                    respRpm: Double? = nil, skinTemp: Double? = nil,
                    alcohol: Bool = false) {
            self.day = day
            self.rhr = rhr
            self.hrvMs = hrvMs
            self.respRpm = respRpm
            self.skinTemp = skinTemp
            self.alcohol = alcohol
        }
    }

    public struct DayResult: Equatable, Sendable {
        public var day: String
        public var level: Level
        public var signalCount: Int
        public var consecutive: Bool
        public var fired: [SignalKey]
        public var zRhr: Double?
        public var zHrv: Double?
        public var zResp: Double?
        public var zSkin: Double?
        public var alcoholTagged: Bool
        /// True when this night or the previous calendar night logged drinks.
        public var alcoholOnEpisode: Bool
        public var copy: String

        public init(day: String, level: Level, signalCount: Int, consecutive: Bool,
                    fired: [SignalKey], zRhr: Double?, zHrv: Double?, zResp: Double?,
                    zSkin: Double?, alcoholTagged: Bool, alcoholOnEpisode: Bool,
                    copy: String) {
            self.day = day
            self.level = level
            self.signalCount = signalCount
            self.consecutive = consecutive
            self.fired = fired
            self.zRhr = zRhr
            self.zHrv = zHrv
            self.zResp = zResp
            self.zSkin = zSkin
            self.alcoholTagged = alcoholTagged
            self.alcoholOnEpisode = alcoholOnEpisode
            self.copy = copy
        }
    }

    public static let disclaimerTail = "On-device estimate - not a diagnosis."

    public static func evaluate(nights: [Night]) -> [DayResult] {
        let ordered = uniqueSorted(nights)
        guard !ordered.isEmpty else { return [] }
        var byDay: [String: Night] = [:]
        for n in ordered { byDay[n.day] = n }

        var corroborated: [String: Bool] = [:]
        var results: [DayResult] = []
        results.reserveCapacity(ordered.count)

        for night in ordered {
            let z = zs(for: night, byDay: byDay)
            var fired: [SignalKey] = []
            if let v = z.rhr, v >= zThreshold { fired.append(.rhr) }
            if let v = z.hrv, v >= zThreshold { fired.append(.hrv) }
            if let v = z.resp, v >= zThreshold { fired.append(.resp) }
            if let v = z.skin, v >= zThreshold { fired.append(.skin) }

            let judged = z.rhr != nil || z.hrv != nil || z.resp != nil || z.skin != nil
            let tonightOK = judged && fired.count >= minCorroboratingSignals
            corroborated[night.day] = tonightOK

            let prevDay = BandDayKey.addDays(night.day, -1)
            let prevOK = prevDay.flatMap { corroborated[$0] } ?? false
            let consecutive = tonightOK && prevOK

            let level: Level
            if !judged {
                level = .building
            } else if consecutive {
                level = .watch
            } else {
                level = .quiet
            }

            let prevAlcohol = prevDay.flatMap { byDay[$0]?.alcohol } ?? false
            let alcoholOnEpisode = consecutive && (night.alcohol || prevAlcohol)
            results.append(DayResult(
                day: night.day,
                level: level,
                signalCount: fired.count,
                consecutive: consecutive,
                fired: fired,
                zRhr: z.rhr,
                zHrv: z.hrv,
                zResp: z.resp,
                zSkin: z.skin,
                alcoholTagged: night.alcohol,
                alcoholOnEpisode: alcoholOnEpisode,
                copy: copy(level: level, fired: fired)
            ))
        }
        return results
    }

    public static func result(on day: String, nights: [Night]) -> DayResult? {
        evaluate(nights: nights).last { $0.day == day }
    }

    /// Count contiguous `.watch` runs in already-evaluated days. One run is
    /// one episode for the false-alarm rate (not each night of a streak).
    public static func episodeCount(_ results: [DayResult]) -> Int {
        var n = 0
        var inside = false
        for r in results {
            if r.level == .watch {
                if !inside { n += 1; inside = true }
            } else {
                inside = false
            }
        }
        return n
    }

    // MARK: - Internals

    private struct Zs {
        var rhr: Double?
        var hrv: Double?
        var resp: Double?
        var skin: Double?
    }

    private static func zs(for night: Night, byDay: [String: Night]) -> Zs {
        var rhrHist: [Double] = []
        var hrvHist: [Double] = []
        var respHist: [Double] = []
        var skinHist: [Double] = []
        for offset in 1...baselineWindowDays {
            guard let key = BandDayKey.addDays(night.day, -offset), let prev = byDay[key] else { continue }
            if let v = finitePositive(prev.rhr) { rhrHist.append(v) }
            if let v = finitePositive(prev.hrvMs) { hrvHist.append(v) }
            if let v = finitePositive(prev.respRpm) { respHist.append(v) }
            if let v = finite(prev.skinTemp) { skinHist.append(v) }
        }
        // HRV is illness-ward when it DROPS, so the z is negated.
        return Zs(
            rhr: illnessZ(night.rhr.flatMap(finitePositive), history: rhrHist, floor: rhrSigmaFloor, invert: false),
            hrv: illnessZ(night.hrvMs.flatMap(finitePositive), history: hrvHist, floor: hrvSigmaFloor, invert: true),
            resp: illnessZ(night.respRpm.flatMap(finitePositive), history: respHist, floor: respSigmaFloor, invert: false),
            skin: illnessZ(night.skinTemp.flatMap(finite), history: skinHist, floor: skinSigmaFloor, invert: false)
        )
    }

    static func illnessZ(_ value: Double?, history: [Double], floor: Double, invert: Bool) -> Double? {
        guard let value, history.count >= minBaselineNights else { return nil }
        guard let mu = mean(history), let sd = sampleSD(history) else { return nil }
        let scale = max(sd, floor)
        guard scale > 0 else { return nil }
        let z = (value - mu) / scale
        return invert ? -z : z
    }

    private static func copy(level: Level, fired: [SignalKey]) -> String {
        switch level {
        case .building:
            return "Still learning your usual range."
        case .quiet:
            return "Overnight signals look like your usual range."
        case .watch:
            let phrase = fired.isEmpty ? "more than one signal" : fired.map(label).joined(separator: ", ")
            return "Overnight load is up (\(phrase)). An easier day matches the data. \(disclaimerTail)"
        }
    }

    private static func label(_ key: SignalKey) -> String {
        switch key {
        case .rhr: return "resting HR"
        case .hrv: return "HRV"
        case .resp: return "respiratory rate"
        case .skin: return "skin temperature"
        }
    }

    private static func uniqueSorted(_ nights: [Night]) -> [Night] {
        var seen: [String: Night] = [:]
        for n in nights { seen[n.day] = n }
        return seen.values.sorted { $0.day < $1.day }
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func sampleSD(_ values: [Double]) -> Double? {
        let n = values.count
        guard n >= 2, let mu = mean(values) else { return nil }
        var ss = 0.0
        for v in values { let d = v - mu; ss += d * d }
        return sqrt(ss / Double(n - 1))
    }
}

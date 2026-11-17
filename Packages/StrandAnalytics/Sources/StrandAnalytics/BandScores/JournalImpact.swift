import Foundation

/// Yes/no journal impact on next-morning recovery, using Band's stored day keys.
///
/// Band (and the WHOOP import) attach a journal answer to the cycle **wake** day — the same
/// key as the recovery shown that morning. Pair answer day D with recovery day D (`alignmentLagDays = 0`).
/// Shifting to D+1 inverts known directions (alcohol comes out positive).
///
/// Effect is mean(outcome | yes) − mean(outcome | no) in outcome points. Unlogged days are
/// dropped, not treated as no. A behaviour is shown only with ≥ `minGroup` yes and no days
/// that also have an outcome. Uncertainty is a Welch 90% interval. Helps / Hurts only when
/// that interval excludes zero.
///
/// Associations in the user's own days. Not a cause.
public enum JournalImpact {

    /// Answer day D is paired with the outcome stored on D.
    public static let alignmentLagDays = 0
    /// Minimum yes and no days (each) before an effect is computed.
    public static let minGroup = 5
    /// Preferred lookback; thinner behaviours fall back to all history through `asOfDay`.
    public static let defaultWindowDays = 90

    public enum Verdict: String, Equatable, Sendable {
        case helps
        case hurts
        case unclear

        public var isClear: Bool {
            self == .helps || self == .hurts
        }
    }

    public struct Answer: Equatable, Sendable {
        public let day: String
        public let behaviorId: String
        public let yes: Bool

        public init(day: String, behaviorId: String, yes: Bool) {
            self.day = day
            self.behaviorId = behaviorId
            self.yes = yes
        }
    }

    public struct OutcomeEffect: Equatable, Sendable {
        public let nYes: Int
        public let nNo: Int
        public let meanYes: Double
        public let meanNo: Double
        /// meanYes − meanNo (signed outcome points).
        public let effect: Double
        public let intervalLow: Double
        public let intervalHigh: Double
        public let verdict: Verdict
        /// True when the 90-day window was too thin and all history was used instead.
        public let usedFullHistory: Bool

        public init(nYes: Int, nNo: Int, meanYes: Double, meanNo: Double,
                    effect: Double, intervalLow: Double, intervalHigh: Double,
                    verdict: Verdict, usedFullHistory: Bool) {
            self.nYes = nYes
            self.nNo = nNo
            self.meanYes = meanYes
            self.meanNo = meanNo
            self.effect = effect
            self.intervalLow = intervalLow
            self.intervalHigh = intervalHigh
            self.verdict = verdict
            self.usedFullHistory = usedFullHistory
        }
    }

    public struct Insight: Equatable, Sendable {
        public let behaviorId: String
        public let recovery: OutcomeEffect?
        public let sleep: OutcomeEffect?
        /// Yes days paired with recovery across all history through `asOfDay` (for "N more" copy).
        public let nYesAll: Int
        public let nNoAll: Int

        public init(behaviorId: String, recovery: OutcomeEffect?, sleep: OutcomeEffect?,
                    nYesAll: Int, nNoAll: Int) {
            self.behaviorId = behaviorId
            self.recovery = recovery
            self.sleep = sleep
            self.nYesAll = nYesAll
            self.nNoAll = nNoAll
        }

        public var neededYes: Int { max(0, JournalImpact.minGroup - nYesAll) }
        public var neededNo: Int { max(0, JournalImpact.minGroup - nNoAll) }
    }

    /// Rank every behaviour that appears in `answers`. Clear recovery effects first
    /// (by |effect| desc), then unclear, then under-gate, each group stable by id.
    public static func rank(answers: [Answer],
                            recoveryByDay: [String: Double],
                            sleepByDay: [String: Double] = [:],
                            asOfDay: String,
                            windowDays: Int = defaultWindowDays) -> [Insight] {
        let byBehavior = groupedAnswers(answers)
        var rows: [Insight] = []
        for id in byBehavior.keys.sorted() {
            let yesNo = byBehavior[id]!
            let allRec = split(yesNo: yesNo, outcome: recoveryByDay, asOfDay: asOfDay, startDay: nil)
            let recovery = effect(yesNo: yesNo, outcome: recoveryByDay,
                                  asOfDay: asOfDay, windowDays: windowDays)
            let sleep = effect(yesNo: yesNo, outcome: sleepByDay,
                               asOfDay: asOfDay, windowDays: windowDays)
            rows.append(Insight(behaviorId: id, recovery: recovery, sleep: sleep,
                                nYesAll: allRec.yes.count, nNoAll: allRec.no.count))
        }
        return sorted(rows)
    }

    // MARK: - One outcome

    static func effect(yesNo: [String: Bool],
                       outcome: [String: Double],
                       asOfDay: String,
                       windowDays: Int) -> OutcomeEffect? {
        let windowStart = shiftDay(asOfDay, by: -windowDays)
        let windowed = split(yesNo: yesNo, outcome: outcome, asOfDay: asOfDay, startDay: windowStart)
        if let e = measure(windowed.yes, windowed.no, usedFullHistory: false) {
            return e
        }
        let all = split(yesNo: yesNo, outcome: outcome, asOfDay: asOfDay, startDay: nil)
        return measure(all.yes, all.no, usedFullHistory: true)
    }

    static func measure(_ yes: [Double], _ no: [Double], usedFullHistory: Bool) -> OutcomeEffect? {
        guard yes.count >= minGroup, no.count >= minGroup else { return nil }
        let m1 = mean(yes)
        let m2 = mean(no)
        let delta = m1 - m2
        let ci = welch90(yes, no, meanYes: m1, meanNo: m2)
        let verdict: Verdict
        if ci.high < 0 {
            verdict = .hurts
        } else if ci.low > 0 {
            verdict = .helps
        } else {
            verdict = .unclear
        }
        return OutcomeEffect(nYes: yes.count, nNo: no.count, meanYes: m1, meanNo: m2,
                             effect: delta, intervalLow: ci.low, intervalHigh: ci.high,
                             verdict: verdict, usedFullHistory: usedFullHistory)
    }

    // MARK: - Split

    static func groupedAnswers(_ answers: [Answer]) -> [String: [String: Bool]] {
        let ordered = answers.sorted { a, b in
            if a.day != b.day { return a.day < b.day }
            if a.behaviorId != b.behaviorId { return a.behaviorId < b.behaviorId }
            return false
        }
        var out: [String: [String: Bool]] = [:]
        for a in ordered {
            out[a.behaviorId, default: [:]][a.day] = a.yes
        }
        return out
    }

    static func split(yesNo: [String: Bool],
                      outcome: [String: Double],
                      asOfDay: String,
                      startDay: String?) -> (yes: [Double], no: [Double]) {
        var yes: [Double] = []
        var no: [Double] = []
        for day in yesNo.keys.sorted() {
            if day > asOfDay { continue }
            if let startDay, day <= startDay { continue }
            guard let value = outcome[day], value.isFinite else { continue }
            if yesNo[day] == true {
                yes.append(value)
            } else {
                no.append(value)
            }
        }
        return (yes, no)
    }

    // MARK: - Welch 90% interval

    /// Welch mean difference with Satterthwaite df and a two-sided 90% t interval.
    static func welch90(_ yes: [Double], _ no: [Double],
                        meanYes: Double, meanNo: Double) -> (low: Double, high: Double) {
        let n1 = Double(yes.count)
        let n2 = Double(no.count)
        let v1 = sampleVariance(yes, mean: meanYes)
        let v2 = sampleVariance(no, mean: meanNo)
        let delta = meanYes - meanNo
        let se2 = v1 / n1 + v2 / n2
        if se2 <= 0 {
            return (delta, delta)
        }
        let se = se2.squareRoot()
        let u1 = v1 / n1
        let u2 = v2 / n2
        let denom = (n1 > 1 ? u1 * u1 / (n1 - 1) : 0) + (n2 > 1 ? u2 * u2 / (n2 - 1) : 0)
        let df = denom > 0 ? (u1 + u2) * (u1 + u2) / denom : max(n1 + n2 - 2, 1)
        let t = tCrit90(df: max(df, 1))
        let h = t * se
        return (delta - h, delta + h)
    }

    /// t_{0.95, df} via Cornish–Fisher / Hill inverse-t (two-sided 90%).
    static func tCrit90(df: Double) -> Double {
        let z = 1.6448536269514722
        if df > 1e8 { return z }
        let z2 = z * z
        let z3 = z2 * z
        let z5 = z3 * z2
        let z7 = z5 * z2
        let g1 = (z3 + z) / 4
        let g2 = (5 * z5 + 16 * z3 + 3 * z) / 96
        let g3 = (3 * z7 + 19 * z5 + 17 * z3 - 15 * z) / 384
        return z + g1 / df + g2 / (df * df) + g3 / (df * df * df)
    }

    static func sampleVariance(_ values: [Double], mean: Double) -> Double {
        let n = values.count
        guard n >= 2 else { return 0 }
        var ss = 0.0
        for v in values { let d = v - mean; ss += d * d }
        return ss / Double(n - 1)
    }

    static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    static func sorted(_ rows: [Insight]) -> [Insight] {
        rows.sorted { a, b in
            let ac = a.recovery?.verdict.isClear == true
            let bc = b.recovery?.verdict.isClear == true
            if ac != bc { return ac }
            if ac, let ea = a.recovery, let eb = b.recovery {
                let aa = abs(ea.effect), bb = abs(eb.effect)
                if aa != bb { return aa > bb }
            }
            let aHas = a.recovery != nil
            let bHas = b.recovery != nil
            if aHas != bHas { return aHas }
            if aHas, let ea = a.recovery, let eb = b.recovery {
                let aa = abs(ea.effect), bb = abs(eb.effect)
                if aa != bb { return aa > bb }
            }
            return a.behaviorId < b.behaviorId
        }
    }

    /// UTC calendar day arithmetic, same contract as `CorrelationEngine.shiftDay`.
    static func shiftDay(_ day: String, by delta: Int) -> String? {
        if delta == 0 { return day }
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1 else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let base = cal.date(from: comps),
              let shifted = cal.date(byAdding: .day, value: delta, to: base) else { return nil }
        let out = cal.dateComponents([.year, .month, .day], from: shifted)
        guard let oy = out.year, let om = out.month, let od = out.day else { return nil }
        return String(format: "%04d-%02d-%02d", oy, om, od)
    }
}

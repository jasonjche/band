import Foundation

/// WHOOP-style sleep planner maths.
///
/// Tonight's need is one extra `BandSleepLedger` step — the same formula Hours vs. Needed
/// already uses — not a second sleep-need model. Bedtime is wake − (need × goal / efficiency)
/// − typical latency.
public enum SleepPlanner {

    public enum Goal: String, Sendable, CaseIterable {
        case peak
        case perform
        case getBy

        /// Peak 100%, Perform 85%, Get By 70% of tonight's need.
        public var fraction: Double {
            switch self {
            case .peak: return 1.00
            case .perform: return 0.85
            case .getBy: return 0.70
            }
        }
    }

    /// One night's contribution to typical efficiency / latency.
    public struct NightSample: Equatable, Sendable {
        public var efficiency: Double?
        public var latencyMin: Double?

        public init(efficiency: Double? = nil, latencyMin: Double? = nil) {
            self.efficiency = efficiency
            self.latencyMin = latencyMin
        }
    }

    public struct TypicalSleep: Equatable, Sendable {
        public var efficiency: Double
        public var latencyMin: Double
        public var efficiencyNights: Int
        public var latencyNights: Int
        public var usingDefaultEfficiency: Bool
        public var usingDefaultLatency: Bool
    }

    /// Tonight's need, split the way `BandSleepLedger` builds it:
    /// `clip(base + a·load + b·debt − knap·nap)`.
    public struct Need: Equatable, Sendable {
        public var baselineMin: Double
        public var strainMin: Double
        public var debtMin: Double
        public var napCreditMin: Double
        public var totalMin: Double
        public var load: Double
        public var clipped: Bool
    }

    public static let defaultEfficiency = 0.90
    public static let defaultLatencyMin = 15.0
    public static let typicalWindowMin = 14
    public static let typicalWindowMax = 30
    public static let minTypicalNights = 7
    public static let efficiencyFloor = 0.50
    public static let efficiencyCeil = 0.99

    /// One more ledger step after the last scored wake-day.
    ///
    /// `asleep` / `loadForNeed` / `napForNeed` are the `BandScores.evaluate` arrays (today last).
    /// Tonight's sleep ends tomorrow, so its load is *today's* `strainHat` and its naps are
    /// today's naps — the same lag `BandSleepLedger` already documents.
    public static func projectTonight(
        asleep: [Double],
        loadForNeed: [Double],
        napForNeed: [Double],
        todayStrainHat: Double,
        todayNapMin: Double,
        params: BandSleepLedger.Params
    ) -> Need {
        let load = todayStrainHat.isFinite ? todayStrainHat : 0
        let nap = todayNapMin.isFinite && todayNapMin > 0 ? todayNapMin : 0
        let asleepExt = asleep + [.nan]
        let loadExt = loadForNeed + [load]
        let napExt = napForNeed + [nap]
        let series = BandSleepLedger.run(
            asleep: asleepExt, loadForNeed: loadExt, napForNeed: napExt, params: params
        )
        let idx = series.need.count - 1
        let total = series.need[idx]
        let debt = series.debt[idx]
        let strainMin = params.a * load
        let debtMin = params.b * (debt.isFinite ? debt : 0)
        let napCreditMin = params.knap * nap
        let raw = params.base + strainMin + debtMin - napCreditMin
        let clippedTotal = total.isFinite ? total : BandScores.clip(raw, params.needLo, params.needHi)
        return Need(
            baselineMin: params.base,
            strainMin: strainMin,
            debtMin: debtMin,
            napCreditMin: napCreditMin,
            totalMin: clippedTotal,
            load: load,
            clipped: abs(clippedTotal - raw) > 1e-6
        )
    }

    /// Median efficiency and onset latency over the trailing 14–30 nights.
    public static func typicalSleep(_ nights: [NightSample], window: Int = typicalWindowMax) -> TypicalSleep {
        let cap = min(max(window, typicalWindowMin), typicalWindowMax)
        let slice = Array(nights.suffix(cap))
        let effs = slice.compactMap(\.efficiency).map(normalizedEfficiency).filter { $0 > 0 }
        let lats = slice.compactMap(\.latencyMin).filter { $0.isFinite && $0 >= 0 }
        let usingDefaultEfficiency = effs.count < minTypicalNights
        let usingDefaultLatency = lats.isEmpty
        let efficiency = usingDefaultEfficiency
            ? defaultEfficiency
            : min(max(BandScores.median(effs), efficiencyFloor), efficiencyCeil)
        let latencyMin = usingDefaultLatency ? defaultLatencyMin : BandScores.median(lats)
        return TypicalSleep(
            efficiency: efficiency,
            latencyMin: latencyMin,
            efficiencyNights: effs.count,
            latencyNights: lats.count,
            usingDefaultEfficiency: usingDefaultEfficiency,
            usingDefaultLatency: usingDefaultLatency
        )
    }

    /// Minute-of-day to be in bed. `wakeMinutes` is [0, 1440).
    public static func inBedMinutes(
        wakeMinutes: Int,
        needMin: Double,
        goal: Goal,
        typical: TypicalSleep
    ) -> Int {
        let wake = ((wakeMinutes % (24 * 60)) + 24 * 60) % (24 * 60)
        let asleep = max(needMin, 0) * goal.fraction
        let eff = min(max(typical.efficiency, efficiencyFloor), efficiencyCeil)
        let inBed = asleep / eff
        let total = inBed + max(typical.latencyMin, 0)
        var minute = wake - Int(total.rounded())
        let day = 24 * 60
        minute %= day
        if minute < 0 { minute += day }
        return minute
    }

    /// Stored efficiency is either a fraction or a percent. Returns 0…1.
    public static func normalizedEfficiency(_ raw: Double) -> Double {
        guard raw.isFinite, raw > 0 else { return 0 }
        let fraction = raw > 1 ? raw / 100 : raw
        return min(max(fraction, 0), 1)
    }

    /// Initial wake run at the start of a computed `[{start,end,stage}]` hypnogram, in minutes.
    /// Imported `{light,deep,…}` dicts have no order, so they return nil.
    public static func onsetLatencyMinutes(stagesJSON: String?) -> Double? {
        guard let stagesJSON, let data = stagesJSON.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        let segs = arr.compactMap { seg -> (start: Int, end: Int, stage: String)? in
            guard let s = (seg["start"] as? NSNumber)?.intValue,
                  let e = (seg["end"] as? NSNumber)?.intValue, e > s,
                  let name = seg["stage"] as? String else { return nil }
            return (s, e, name)
        }.sorted { $0.start < $1.start }
        guard let first = segs.first else { return nil }
        switch first.stage {
        case "wake", "awake":
            return Double(first.end - first.start) / 60.0
        default:
            return 0
        }
    }
}

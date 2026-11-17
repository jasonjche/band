import Foundation

/// 7-day ln(RMSSD) trend versus a 60-day personal baseline (Plews / Buchheit).
///
/// Method
/// ------
/// Nightly HRV is treated as RMSSD (ms). Each valid night is transformed to
/// `ln(RMSSD)` because ln rMSSD is approximately normal and is the quantity the
/// monitoring literature actually tracks:
///
///   Plews DJ, Laursen PB, Kilding AE, Buchheit M. Heart rate variability in
///   elite triathletes, is variation in variability the key to effective
///   training? A case comparison. Eur J Appl Physiol. 2012;112:3729–3741.
///
///   Plews DJ, Laursen PB, Stanley J, Kilding AE, Buchheit M. Training
///   adaptation and heart rate variability in elite endurance athletes:
///   opening the door to effective monitoring. Sports Med. 2013;43:773–781.
///
///   Buchheit M. Monitoring training status with HR measures: do all roads
///   lead to Rome? Front Physiol. 2014;5:73.
///
/// For day `t` (calendar, `yyyy-MM-dd`):
///   • trend  = mean of valid ln(RMSSD) in the 7 days ending at `t`
///   • baseline = mean of valid ln(RMSSD) in the 60 days ending at `t`
///     (the 7-day window is nested; this is the usual rolling-average plot)
///   • missing nights are skipped, never zero-filled
///
/// Smallest worthwhile change
/// --------------------------
/// Plews et al. 2013, Sports Med 43:773–781: “The smallest worthwhile change
/// (SWC) can be calculated as 0.5 times the coefficient of variation (CV) of
/// the measure.” Buchheit 2014 repeats SWC = 0.5 × CV. Applied in ln(RMSSD)
/// units, CV = SD / mean of the 60-day baseline, so
///
///     SWC = 0.5 × CV × baseline_mean = 0.5 × SD_baseline
///
/// The band is `baseline ± SWC`. 0.5 × within-athlete SD is the practical
/// “moderate” individual change on Hopkins’ modified Cohen scale (Hopkins WG.
/// How to interpret changes in an athletic performance test. Sportscience.
/// 2004;8:1–7); Plews/Buchheit pin the constant at 0.5 rather than 0.2/0.6.
///
/// 60 days is the long end of the 30–60 day / 4–8 week baselines those papers
/// use. The longer window keeps the SWC band from chasing last week’s drift.
/// A 7-day window needs at least 3 valid nights (Plews: ≥3 recordings/week);
/// a 60-day baseline needs at least 30.
///
/// Output is a wellness trend, not a diagnosis. Pure Double arithmetic.
public enum HRVTrend {

    public static let trendWindowDays = 7
    public static let baselineWindowDays = 60
    /// Plews: at least three recordings in the week before a 7-day mean is used.
    public static let minTrendNights = 3
    /// Half the 60-day window; enough nights for a stable CV.
    public static let minBaselineNights = 30
    /// Plews 2013 / Buchheit 2014: SWC = 0.5 × CV of the measure.
    public static let swcK = 0.5

    public enum State: String, Equatable, Sendable {
        case building
        case withinNormal
        case trendingBelow
        case trendingAbove
    }

    public struct Night: Equatable, Sendable {
        public var day: String
        public var rmssdMs: Double?

        public init(day: String, rmssdMs: Double?) {
            self.day = day
            self.rmssdMs = rmssdMs
        }
    }

    public struct DayResult: Equatable, Sendable {
        public var day: String
        /// 7-day mean of ln(RMSSD).
        public var trendLn: Double?
        /// 60-day mean of ln(RMSSD).
        public var baselineLn: Double?
        /// 0.5 × CV × baseline = 0.5 × SD of the baseline ln(RMSSD) values.
        public var swc: Double?
        public var bandLow: Double?
        public var bandHigh: Double?
        public var state: State
        /// 7-day CV of ln(RMSSD); day-to-day stability inside the trend window.
        public var trendCV: Double?
        public var trendNights: Int
        public var baselineNights: Int
        public var rmssdMs: Double?

        public init(day: String, trendLn: Double?, baselineLn: Double?, swc: Double?,
                    bandLow: Double?, bandHigh: Double?, state: State, trendCV: Double?,
                    trendNights: Int, baselineNights: Int, rmssdMs: Double?) {
            self.day = day
            self.trendLn = trendLn
            self.baselineLn = baselineLn
            self.swc = swc
            self.bandLow = bandLow
            self.bandHigh = bandHigh
            self.state = state
            self.trendCV = trendCV
            self.trendNights = trendNights
            self.baselineNights = baselineNights
            self.rmssdMs = rmssdMs
        }

        /// Geometric-mean RMSSD (ms) implied by the 7-day ln mean.
        public var trendMs: Double? { trendLn.map { exp($0) } }
        /// Geometric-mean RMSSD (ms) implied by the 60-day ln mean.
        public var baselineMs: Double? { baselineLn.map { exp($0) } }
    }

    /// ln(RMSSD) for a finite, positive millisecond value. Nights at or below
    /// 1 ms are treated as missing rather than log-clamped, so they cannot
    /// pull the mean toward 0.
    public static func lnRmssd(_ rmssdMs: Double?) -> Double? {
        guard let ms = rmssdMs, ms.isFinite, ms > 1 else { return nil }
        return log(ms)
    }

    /// Sample CV = SD / mean. Nil when there are fewer than 2 values or the
    /// mean is not positive.
    public static func coefficientOfVariation(_ values: [Double]) -> Double? {
        guard let sd = sampleSD(values), let mu = mean(values), mu > 0 else { return nil }
        return sd / mu
    }

    public static func evaluate(nights: [Night]) -> [DayResult] {
        let ordered = uniqueSorted(nights)
        guard !ordered.isEmpty else { return [] }
        var rows: [(day: String, epoch: Int, rmssdMs: Double?, ln: Double?)] = []
        rows.reserveCapacity(ordered.count)
        for n in ordered {
            guard let epoch = HealthspanEngine.isoEpochDay(n.day) else { continue }
            rows.append((n.day, epoch, n.rmssdMs, lnRmssd(n.rmssdMs)))
        }
        guard !rows.isEmpty else { return [] }
        var out: [DayResult] = []
        out.reserveCapacity(rows.count)
        var tLo = 0
        var bLo = 0
        var trendBuf: [Double] = []
        var baseBuf: [Double] = []
        trendBuf.reserveCapacity(trendWindowDays)
        baseBuf.reserveCapacity(baselineWindowDays)
        for i in 0..<rows.count {
            let e = rows[i].epoch
            let tMin = e - (trendWindowDays - 1)
            let bMin = e - (baselineWindowDays - 1)
            while tLo < i, rows[tLo].epoch < tMin { tLo += 1 }
            while bLo < i, rows[bLo].epoch < bMin { bLo += 1 }
            trendBuf.removeAll(keepingCapacity: true)
            var j = tLo
            while j <= i {
                if let ln = rows[j].ln { trendBuf.append(ln) }
                j += 1
            }
            baseBuf.removeAll(keepingCapacity: true)
            j = bLo
            while j <= i {
                if let ln = rows[j].ln { baseBuf.append(ln) }
                j += 1
            }
            out.append(result(day: rows[i].day, rmssdMs: rows[i].rmssdMs,
                              trendVals: trendBuf, baseVals: baseBuf))
        }
        return out
    }

    public static func result(on day: String, nights: [Night]) -> DayResult? {
        evaluate(nights: nights).last { $0.day == day }
    }

    // MARK: - Internals

    private static func result(day: String, rmssdMs: Double?,
                               trendVals: [Double], baseVals: [Double]) -> DayResult {
        let trendN = trendVals.count
        let baseN = baseVals.count
        let trendLn = mean(trendVals)
        let baselineLn = mean(baseVals)
        let trendCV = coefficientOfVariation(trendVals)

        guard trendN >= minTrendNights, baseN >= minBaselineNights,
              let trendLn, let baselineLn, let sd = sampleSD(baseVals) else {
            return DayResult(
                day: day, trendLn: trendLn, baselineLn: baselineLn, swc: nil,
                bandLow: nil, bandHigh: nil, state: .building, trendCV: trendCV,
                trendNights: trendN, baselineNights: baseN, rmssdMs: rmssdMs
            )
        }

        // Plews 2013: SWC = 0.5 × CV; in ln units that is 0.5 × SD.
        // Summing 60 copies of the same ln(RMSSD) leaves a residual SD on
        // the order of 1e-16, which is not physiological variation. Below
        // this floor there is no worthwhile-change scale.
        let swc = swcK * sd
        let low = baselineLn - swc
        let high = baselineLn + swc
        let state: State
        if !sd.isFinite || sd < 1e-12 {
            state = .withinNormal
        } else if trendLn < low {
            state = .trendingBelow
        } else if trendLn > high {
            state = .trendingAbove
        } else {
            state = .withinNormal
        }
        return DayResult(
            day: day, trendLn: trendLn, baselineLn: baselineLn, swc: swc,
            bandLow: low, bandHigh: high, state: state, trendCV: trendCV,
            trendNights: trendN, baselineNights: baseN, rmssdMs: rmssdMs
        )
    }

    private static func uniqueSorted(_ nights: [Night]) -> [Night] {
        var seen: [String: Night] = [:]
        for n in nights { seen[n.day] = n }
        return seen.values.sorted { $0.day < $1.day }
    }

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func sampleSD(_ values: [Double]) -> Double? {
        let n = values.count
        guard n >= 2, let mu = mean(values) else { return nil }
        var ss = 0.0
        for v in values { let d = v - mu; ss += d * d }
        return sqrt(ss / Double(n - 1))
    }
}

/// Gregorian UTC day-key arithmetic so calendar windows do not follow the
/// host time zone. Keys are `yyyy-MM-dd`.
enum BandDayKey {
    static func addDays(_ ymd: String, _ delta: Int) -> String? {
        CivilDay.addDays(ymd, delta)
    }
}

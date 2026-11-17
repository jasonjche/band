import Foundation

/// Personal typical range for one nightly vital (Health Monitor + metric-page band).
///
/// Previous 30 calendar days, excluding today. Median ± k × MAD-sigma, at least 14
/// valid nights. One sick night does not widen the band. Missing nights are skipped,
/// never zero-filled. Population ranges are not used.
///
/// Wellness indicator only — approximate, not a diagnosis.
public enum TypicalVitalRange {

    public static let windowDays = 30
    public static let minNights = 14
    /// ~99th percentile of a Gaussian one-sided tail once converted through 1.4826 × MAD.
    public static let sigmaK = 3.0
    public static let madToSigma = 1.4826
    /// Physiological SpO2 rail. Personal history still sets the typical band; this only flags low.
    public static let spo2AbsoluteFloor = 90.0

    public enum Concern: String, Equatable, Sendable {
        case high
        case low
        case both
    }

    public enum Status: String, Equatable, Sendable {
        case building
        case inRange
        case above
        case below
    }

    public enum Metric: String, Equatable, Sendable {
        case hrv
        case rhr
        case resp
        case skin
        case spo2

        public var concern: Concern {
            switch self {
            case .rhr, .resp: return .high
            case .hrv, .spo2: return .low
            case .skin: return .both
            }
        }

        /// Measurement-precision floor so a perfectly flat history is not a zero-width band.
        public var sigmaFloor: Double {
            switch self {
            case .rhr: return 1.0
            case .hrv: return 3.0
            case .resp: return 0.2
            case .skin: return 0.1
            case .spo2: return 0.3
            }
        }

        public var absoluteFloor: Double? {
            self == .spo2 ? spo2AbsoluteFloor : nil
        }
    }

    public struct Result: Equatable, Sendable {
        public var status: Status
        public var range: ClosedRange<Double>?
        public var nights: Int
        public var flagged: Bool

        public init(status: Status, range: ClosedRange<Double>?, nights: Int, flagged: Bool) {
            self.status = status
            self.range = range
            self.nights = nights
            self.flagged = flagged
        }

        public var building: Bool { status == .building && !flagged }
    }

    /// Typical band from prior nights only (the metric-page overlay).
    public static func range(history: [Double?], sigmaFloor: Double = 0) -> ClosedRange<Double>? {
        evaluate(history: history, today: nil, concern: .both, sigmaFloor: sigmaFloor).range
    }

    public static func evaluate(
        history: [Double?],
        today: Double?,
        metric: Metric
    ) -> Result {
        evaluate(
            history: history,
            today: today,
            concern: metric.concern,
            sigmaFloor: metric.sigmaFloor,
            absoluteFloor: metric.absoluteFloor
        )
    }

    public static func evaluate(
        history: [Double?],
        today: Double?,
        concern: Concern,
        sigmaFloor: Double = 0,
        absoluteFloor: Double? = nil,
        absoluteCeiling: Double? = nil
    ) -> Result {
        let valid = history.compactMap { value -> Double? in
            guard let value, value.isFinite else { return nil }
            return value
        }
        let nights = valid.count
        let range = nights >= minNights ? band(valid: valid, sigmaFloor: sigmaFloor) : nil

        guard let today, today.isFinite else {
            return Result(
                status: range == nil ? .building : .inRange,
                range: range,
                nights: nights,
                flagged: false
            )
        }

        var status: Status
        if let range {
            if today > range.upperBound { status = .above }
            else if today < range.lowerBound { status = .below }
            else { status = .inRange }
        } else {
            status = .building
        }

        if let absoluteFloor, today < absoluteFloor { status = .below }
        if let absoluteCeiling, today > absoluteCeiling { status = .above }

        let flagged: Bool
        switch status {
        case .building, .inRange:
            flagged = false
        case .above:
            flagged = concern == .high || concern == .both
        case .below:
            flagged = concern == .low || concern == .both
        }
        return Result(status: status, range: range, nights: nights, flagged: flagged)
    }

    /// Map a `MetricCfg` onto the matching sigma floor so Health Monitor and the metric page agree.
    public static func sigmaFloor(matching cfg: MetricCfg?) -> Double {
        guard let cfg else { return 0 }
        if cfg == Baselines.hrvCfg { return Metric.hrv.sigmaFloor }
        if cfg == Baselines.restingHRCfg { return Metric.rhr.sigmaFloor }
        if cfg == Baselines.respCfg { return Metric.resp.sigmaFloor }
        if cfg == Baselines.metricCfg["skin_temp"] { return Metric.skin.sigmaFloor }
        return 0
    }

    private static func band(valid: [Double], sigmaFloor: Double) -> ClosedRange<Double>? {
        let center = BandScores.median(valid)
        guard center.isFinite else { return nil }
        let mad = BandScores.median(valid.map { abs($0 - center) })
        var sigma = madToSigma * mad
        if !sigma.isFinite || sigma < sigmaFloor { sigma = sigmaFloor }
        if sigma < 1e-9 { sigma = 1e-9 }
        let lo = center - sigmaK * sigma
        let hi = center + sigmaK * sigma
        guard lo.isFinite, hi.isFinite else { return nil }
        return min(lo, hi)...max(lo, hi)
    }
}

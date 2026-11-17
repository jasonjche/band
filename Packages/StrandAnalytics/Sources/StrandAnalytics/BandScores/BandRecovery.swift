import Foundation

/// Logistic recovery over baseline z-scores and our sleep performance.
public enum BandRecovery {

    public struct Params: Sendable {
        public var b0: Double
        public var wHrv: Double
        public var wRhr: Double
        public var wRr: Double
        public var wTemp: Double
        public var wSpo2: Double
        public var wSleep: Double
        public var tempDeadzone: Double
        public var spo2Deadzone: Double
    }

    /// Colour bands: green ≥ 67, yellow 34–66, red ≤ 33.
    public static func band(_ value: Double) -> String {
        if value >= 67 { return "green" }
        if value <= 33 { return "red" }
        return "yellow"
    }

    public static func run(zHrv: [Double], zRhr: [Double], zRr: [Double],
                           zTemp: [Double], zSpo2: [Double], perf: [Double],
                           params: Params) -> [Double] {
        let n = zHrv.count
        var out = [Double](repeating: .nan, count: n)
        for t in 0..<n {
            var zh = zHrv[t], zr = zRhr[t], zrr = zRr[t], zt = zTemp[t], zs = zSpo2[t]
            let pf = perf[t]
            guard zh.isFinite, zr.isFinite, zrr.isFinite, zt.isFinite, zs.isFinite, pf.isFinite else { continue }
            zh = BandScores.clip(zh, -6, 6)
            zr = BandScores.clip(zr, -6, 6)
            zrr = BandScores.clip(zrr, -6, 6)
            zt = BandScores.clip(zt, -6, 6)
            zs = BandScores.clip(zs, -6, 6)
            let sleepTerm = (pf - 75.0) / 15.0
            let flagTemp = max(0.0, abs(zt) - params.tempDeadzone)
            let flagSpo2 = max(0.0, -zs - params.spo2Deadzone)
            var eta = params.b0
                + params.wHrv * zh
                + params.wRhr * zr
                + params.wRr * zrr
                + params.wTemp * flagTemp
                + params.wSpo2 * flagSpo2
                + params.wSleep * sleepTerm
            eta = BandScores.clip(eta, -20, 20)
            out[t] = BandScores.clip(100.0 / (1.0 + exp(-eta)), 1.0, 99.0)
        }
        return out
    }
}

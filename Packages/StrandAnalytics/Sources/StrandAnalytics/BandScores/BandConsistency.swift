import Foundation

/// SRI-style 1440-minute overlap, last-vs-each window, affine-mapped to 0…100.
public enum BandConsistency {

    public struct Params: Sendable {
        public var nNights: Int
        public var mode: String
        public var recency: Double
        public var intercept: Double
        public var slope: Double
        public var clipLo: Double
        public var clipHi: Double
    }

    public struct Series: Sendable {
        public var sri: [Double]
        public var mapped: [Double]
    }

    public static func clockMin(hour: Int, minute: Int) -> Int {
        hour * 60 + minute
    }

    public static func mask(onsetMin: Int?, wakeMin: Int?, naps: [(Int, Int)]) -> [Int8] {
        var m = [Int8](repeating: 0, count: 1440)
        fill(&m, onsetMin, wakeMin)
        for nap in naps { fill(&m, nap.0, nap.1) }
        return m
    }

    private static func fill(_ m: inout [Int8], _ sIn: Int?, _ eIn: Int?) {
        guard let sIn, let eIn else { return }
        let s = ((sIn % 1440) + 1440) % 1440
        let e = ((eIn % 1440) + 1440) % 1440
        if e == s { return }
        if e > s {
            for i in s..<e { m[i] = 1 }
        } else {
            for i in s..<1440 { m[i] = 1 }
            for i in 0..<e { m[i] = 1 }
        }
    }

    public static func sriPair(_ m1: [Int8], _ m2: [Int8]) -> Double {
        var same = 0
        for i in 0..<1440 where m1[i] == m2[i] { same += 1 }
        return 200.0 * (Double(same) / 1440.0 - 0.5)
    }

    public static func run(masks: [[Int8]], params: Params) -> Series {
        let n = masks.count
        var sri = [Double](repeating: .nan, count: n)
        var mapped = [Double](repeating: .nan, count: n)
        let k = params.nNights
        guard k >= 2 else { return Series(sri: sri, mapped: mapped) }
        for i in 0..<n {
            if i + 1 < k { continue }
            let ms = Array(masks[(i - k + 1)...i])
            if ms.contains(where: { $0.reduce(0) { $0 + Int($1) } < 60 }) { continue }
            var vals: [Double] = []
            var wts: [Double] = []
            switch params.mode {
            case "consecutive":
                for j in 0..<(k - 1) {
                    let age = (k - 2) - j
                    vals.append(sriPair(ms[j], ms[j + 1]))
                    wts.append(pow(params.recency, Double(age)))
                }
            case "all_pairs":
                for a in 0..<k {
                    for b in (a + 1)..<k {
                        let age = (k - 1) - b
                        vals.append(sriPair(ms[a], ms[b]))
                        wts.append(pow(params.recency, Double(age)))
                    }
                }
            default: // last_vs_each
                for j in 0..<(k - 1) {
                    let age = (k - 2) - j
                    vals.append(sriPair(ms[k - 1], ms[j]))
                    wts.append(pow(params.recency, Double(age)))
                }
            }
            let wsum = wts.reduce(0, +)
            guard wsum > 0 else { continue }
            var acc = 0.0
            for idx in vals.indices { acc += vals[idx] * wts[idx] }
            sri[i] = acc / wsum
            mapped[i] = BandScores.clip(params.intercept + params.slope * sri[i], params.clipLo, params.clipHi)
        }
        return Series(sri: sri, mapped: mapped)
    }
}

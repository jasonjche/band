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
        sriPair(pack(m1), pack(m2))
    }

    public static func run(masks: [[Int8]], params: Params) -> Series {
        let n = masks.count
        var sri = [Double](repeating: .nan, count: n)
        var mapped = [Double](repeating: .nan, count: n)
        let k = params.nNights
        guard k >= 2 else { return Series(sri: sri, mapped: mapped) }
        var packed = [PackedMask]()
        packed.reserveCapacity(n)
        for mask in masks { packed.append(pack(mask)) }
        for i in 0..<n {
            if i + 1 < k { continue }
            let base = i - k + 1
            var thin = false
            for j in 0..<k where packed[base + j].occupied < 60 { thin = true; break }
            if thin { continue }
            var acc = 0.0
            var wsum = 0.0
            switch params.mode {
            case "consecutive":
                for j in 0..<(k - 1) {
                    let age = (k - 2) - j
                    let w = pow(params.recency, Double(age))
                    acc += sriPair(packed[base + j], packed[base + j + 1]) * w
                    wsum += w
                }
            case "all_pairs":
                for a in 0..<k {
                    for b in (a + 1)..<k {
                        let age = (k - 1) - b
                        let w = pow(params.recency, Double(age))
                        acc += sriPair(packed[base + a], packed[base + b]) * w
                        wsum += w
                    }
                }
            default: // last_vs_each
                let last = packed[i]
                for j in 0..<(k - 1) {
                    let age = (k - 2) - j
                    let w = pow(params.recency, Double(age))
                    acc += sriPair(last, packed[base + j]) * w
                    wsum += w
                }
            }
            guard wsum > 0 else { continue }
            sri[i] = acc / wsum
            mapped[i] = BandScores.clip(params.intercept + params.slope * sri[i], params.clipLo, params.clipHi)
        }
        return Series(sri: sri, mapped: mapped)
    }

    /// 1440 sleep/wake minutes packed into 23 × UInt64. Hamming distance of the XOR
    /// is 1440 − same, so SRI is bit-identical to comparing Int8 slots.
    struct PackedMask {
        static let words = (1440 + 63) / 64
        var bits: [UInt64]
        var occupied: Int
    }

    static func pack(_ m: [Int8]) -> PackedMask {
        var bits = [UInt64](repeating: 0, count: PackedMask.words)
        var occupied = 0
        let n = min(m.count, 1440)
        var i = 0
        while i < n {
            if m[i] != 0 {
                bits[i >> 6] |= 1 << (i & 63)
                occupied += 1
            }
            i += 1
        }
        return PackedMask(bits: bits, occupied: occupied)
    }

    static func sriPair(_ a: PackedMask, _ b: PackedMask) -> Double {
        var diff = 0
        var i = 0
        while i < PackedMask.words {
            diff += (a.bits[i] ^ b.bits[i]).nonzeroBitCount
            i += 1
        }
        return 200.0 * (Double(1440 - diff) / 1440.0 - 0.5)
    }
}

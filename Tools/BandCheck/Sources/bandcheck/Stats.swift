import Foundation

struct Pair {
    var day: String
    var band: Double
    var whoop: Double
    var err: Double { band - whoop }
    var absErr: Double { abs(err) }
}

struct SeriesAgreement: Equatable {
    var name: String
    var n: Int
    var mae: Double
    var bias: Double
    var withinTol: Double
    var tolerance: Double
    var worstDay: String?
    var worstAbsErr: Double?

    var isEmpty: Bool { n == 0 }
}

func agree(_ name: String, _ pairs: [Pair], tolerance: Double) -> SeriesAgreement {
    let n = pairs.count
    guard n > 0 else {
        return SeriesAgreement(name: name, n: 0, mae: .nan, bias: .nan,
                               withinTol: .nan, tolerance: tolerance,
                               worstDay: nil, worstAbsErr: nil)
    }
    let mae = pairs.map(\.absErr).reduce(0, +) / Double(n)
    let bias = pairs.map(\.err).reduce(0, +) / Double(n)
    let within = Double(pairs.filter { $0.absErr <= tolerance }.count) / Double(n)
    let worst = pairs.max(by: { $0.absErr < $1.absErr })
    return SeriesAgreement(
        name: name, n: n, mae: mae, bias: bias, withinTol: within, tolerance: tolerance,
        worstDay: worst?.day, worstAbsErr: worst?.absErr)
}

func mean(_ v: [Double]) -> Double {
    v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count)
}

func fmt(_ v: Double, _ w: Int = 7, _ p: Int = 2) -> String {
    v.isNaN ? String(repeating: " ", count: max(0, w - 3)) + "n/a"
        : String(format: "%\(w).\(p)f", v)
}

func pct(_ v: Double) -> String {
    v.isNaN ? "  n/a" : String(format: "%5.1f%%", v * 100)
}

func strain21(fromStoredEffort100 value: Double?) -> Double? {
    guard let value else { return nil }
    return value * 21.0 / 100.0
}

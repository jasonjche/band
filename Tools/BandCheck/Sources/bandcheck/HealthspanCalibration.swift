import Foundation
import StrandAnalytics

/// WHOOP Healthspan labelled snapshots, kept OUTSIDE the repository (private).
/// Schema only — never print `value` / WHOOP years / ages from a snapshot.
///
///     {"snapshots":[{"chronologicalAge":30,"whoopAge":30,"sex":"male",
///       "contributors":{"sleepHours":{"value":7.5,"years":0.0,"scale":[5,8]}}}]}
struct HealthspanLabels: Equatable, Decodable {
    var snapshots: [Snapshot]

    struct Snapshot: Equatable, Decodable {
        var capturedOn: String?
        var chronologicalAge: Double
        var whoopAge: Double?
        var yearsYounger: Double?
        var paceOfAging: Double?
        var sex: String
        var contributors: [String: Metric]
    }

    struct Metric: Equatable, Decodable {
        var value: Double
        var thirtyDay: Double? = nil
        var years: Double
        var scale: [Double?]? = nil
    }

    static let engineKeys: [String: String] = [
        "sleepConsistencyPct": "consistency",
        "sleepHours": "sleep",
        "zone13WeeklyMin": "zone13",
        "zone45WeeklyMin": "zone45",
        "strengthWeeklyMin": "strength",
        "dailySteps": "steps",
        "vo2max": "vo2max",
        "restingHR": "rhr",
        "leanMassPct": "lean",
    ]

    static let contributorOrder = [
        "consistency", "sleep", "zone13", "zone45", "strength",
        "steps", "vo2max", "rhr", "lean",
    ]

    static func engineKey(_ raw: String) -> String { engineKeys[raw] ?? raw }

    static func load(path: String) throws -> HealthspanLabels {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return try JSONDecoder().decode(HealthspanLabels.self, from: Data(contentsOf: url))
    }
}

struct HealthspanCalibPoint: Equatable {
    var key: String
    var n: Int
    var mae: Double
    var bias: Double
    var maxAbs: Double
}

struct HealthspanCalibReport: Equatable {
    var snapshotCount: Int
    var contributors: [HealthspanCalibPoint]
    var yearsTotal: HealthspanCalibPoint
    var bandAge: HealthspanCalibPoint
}

func summarizeCalib(_ key: String, _ errs: [Double]) -> HealthspanCalibPoint {
    let n = errs.count
    guard n > 0 else {
        return HealthspanCalibPoint(key: key, n: 0, mae: .nan, bias: .nan, maxAbs: .nan)
    }
    let mae = errs.map(abs).reduce(0, +) / Double(n)
    let bias = errs.reduce(0, +) / Double(n)
    let maxAbs = errs.map(abs).max() ?? 0
    return HealthspanCalibPoint(key: key, n: n, mae: mae, bias: bias, maxAbs: maxAbs)
}

func window(from snap: HealthspanLabels.Snapshot) -> HealthspanEngine.Window {
    var byKey: [String: Double] = [:]
    for (raw, metric) in snap.contributors {
        byKey[HealthspanLabels.engineKey(raw)] = metric.value
    }
    return HealthspanEngine.Window(
        sleepHours: byKey["sleep"],
        sleepConsistency: byKey["consistency"],
        weeklyZone13Min: byKey["zone13"],
        weeklyZone45Min: byKey["zone45"],
        weeklyStrengthMin: byKey["strength"],
        dailySteps: byKey["steps"],
        restingHR: byKey["rhr"],
        vo2max: byKey["vo2max"],
        leanMassPct: byKey["lean"],
        daysWithData: 180)
}

func evaluateHealthspanCalibration(labels: HealthspanLabels) -> HealthspanCalibReport {
    var errs: [String: [Double]] = [:]
    var totalErrs: [Double] = []
    var ageErrs: [Double] = []
    for snap in labels.snapshots {
        let six = window(from: snap)
        let profile = HealthspanEngine.Profile(chronoAge: snap.chronologicalAge, sex: snap.sex)
        let result = HealthspanEngine.compute(
            profile: profile, sixMonth: six, thirtyDay: six, coverageDays: 180)
        var bandByKey: [String: Double] = [:]
        for c in result.contributors {
            if let y = c.years { bandByKey[c.key] = y }
        }
        var sumBand = 0.0
        var sumWhoop = 0.0
        var nPair = 0
        for (raw, metric) in snap.contributors {
            let key = HealthspanLabels.engineKey(raw)
            guard let bandY = bandByKey[key] else { continue }
            errs[key, default: []].append(bandY - metric.years)
            sumBand += bandY
            sumWhoop += metric.years
            nPair += 1
        }
        if nPair > 0 {
            totalErrs.append(sumBand - sumWhoop)
        }
        if let whoopAge = snap.whoopAge, let bandAge = result.bandAge {
            ageErrs.append(bandAge - whoopAge)
        }
    }
    let points = HealthspanLabels.contributorOrder.map { summarizeCalib($0, errs[$0] ?? []) }
    return HealthspanCalibReport(
        snapshotCount: labels.snapshots.count,
        contributors: points,
        yearsTotal: summarizeCalib("years_total", totalErrs),
        bandAge: summarizeCalib("band_age", ageErrs))
}

func evaluateHealthspanCalibration(path: String) throws -> HealthspanCalibReport {
    try evaluateHealthspanCalibration(labels: HealthspanLabels.load(path: path))
}

func gateHealthspanCalibration(_ report: HealthspanCalibReport,
                               cap: Thresholds.HealthspanCalibrationCap) -> [GateFail] {
    guard report.yearsTotal.n > 0, report.yearsTotal.maxAbs.isFinite else { return [] }
    if report.yearsTotal.maxAbs > cap.maxAbsTotalYears {
        return [GateFail(
            check: "healthspan_calibration",
            detail: String(format: "|total years|=%.3f > max_abs_total_years=%.3f",
                           report.yearsTotal.maxAbs, cap.maxAbsTotalYears))]
    }
    return []
}

func printHealthspanCalibration(_ report: HealthspanCalibReport) {
    print("""

F. HEALTHSPAN CALIBRATION  (HealthspanEngine vs labelled WHOOP years; errors only)
--------------------------------------------------------------------------------
contributor                    n      MAE     bias   |err|max
""")
    func row(_ p: HealthspanCalibPoint) {
        let name = p.key.padding(toLength: 30, withPad: " ", startingAt: 0)
        print("\(name) \(String(format: "%4d", p.n)) \(fmt(p.mae)) \(fmt(p.bias)) \(fmt(p.maxAbs))")
    }
    for p in report.contributors where p.n > 0 {
        row(p)
    }
    row(report.yearsTotal)
    if report.bandAge.n > 0 { row(report.bandAge) }
    print("  snapshots \(report.snapshotCount)  (aggregates only; labelled inputs are never printed)")
}

func healthspanCalibrationJSON(_ report: HealthspanCalibReport) -> [String: Any] {
    func point(_ p: HealthspanCalibPoint) -> [String: Any] {
        [
            "key": p.key, "n": p.n,
            "mae": p.mae.isFinite ? p.mae : NSNull(),
            "bias": p.bias.isFinite ? p.bias : NSNull(),
            "max_abs": p.maxAbs.isFinite ? p.maxAbs : NSNull(),
        ]
    }
    return [
        "snapshots": report.snapshotCount,
        "contributors": report.contributors.filter { $0.n > 0 }.map(point),
        "years_total": point(report.yearsTotal),
        "band_age": point(report.bandAge),
    ]
}

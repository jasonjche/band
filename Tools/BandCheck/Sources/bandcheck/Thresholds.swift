import Foundation

struct Thresholds: Equatable, Codable {
    var agreement: [String: AgreementCap]
    var detection: DetectionCap
    var invariants: InvariantCap
    var healthspanCalibration: HealthspanCalibrationCap

    enum CodingKeys: String, CodingKey {
        case agreement, detection, invariants
        case healthspanCalibration = "healthspan_calibration"
    }

    init(agreement: [String: AgreementCap], detection: DetectionCap, invariants: InvariantCap,
         healthspanCalibration: HealthspanCalibrationCap = .lenient) {
        self.agreement = agreement
        self.detection = detection
        self.invariants = invariants
        self.healthspanCalibration = healthspanCalibration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agreement = try c.decode([String: AgreementCap].self, forKey: .agreement)
        detection = try c.decode(DetectionCap.self, forKey: .detection)
        invariants = try c.decode(InvariantCap.self, forKey: .invariants)
        healthspanCalibration = try c.decodeIfPresent(
            HealthspanCalibrationCap.self, forKey: .healthspanCalibration) ?? .lenient
    }

    struct HealthspanCalibrationCap: Equatable, Codable {
        var maxAbsTotalYears: Double
        enum CodingKeys: String, CodingKey {
            case maxAbsTotalYears = "max_abs_total_years"
        }
        static let lenient = HealthspanCalibrationCap(maxAbsTotalYears: 0.5)
    }

    struct AgreementCap: Equatable, Codable {
        var maxMae: Double
        var maxAbsBias: Double
        var minWithinTol: Double
        var minN: Int
        enum CodingKeys: String, CodingKey {
            case maxMae = "max_mae"
            case maxAbsBias = "max_abs_bias"
            case minWithinTol = "min_within_tol"
            case minN = "min_n"
        }
    }

    struct DetectionCap: Equatable, Codable {
        var minPrecision: Double
        var minRecall: Double
        var minReference: Int
        enum CodingKeys: String, CodingKey {
            case minPrecision = "min_precision"
            case minRecall = "min_recall"
            case minReference = "min_reference"
        }
    }

    struct InvariantCap: Equatable, Codable {
        var maxStepsUndercountDays: Int
        var maxDuplicateDailyMetric: Int
        var maxAutoOverlap: Int
        var maxWorkoutsWithoutHR: Int
        var maxJournalDuplicateTitles: Int
        var maxMetricsWithoutSource: Int
        var maxUnresolvedStepsDays: Int
        var maxStressGateWorse: Int
        enum CodingKeys: String, CodingKey {
            case maxStepsUndercountDays = "max_steps_undercount_days"
            case maxDuplicateDailyMetric = "max_duplicate_daily_metric"
            case maxAutoOverlap = "max_auto_overlap"
            case maxWorkoutsWithoutHR = "max_workouts_without_hr"
            case maxJournalDuplicateTitles = "max_journal_duplicate_titles"
            case maxMetricsWithoutSource = "max_metrics_without_source"
            case maxUnresolvedStepsDays = "max_unresolved_steps_days"
            case maxStressGateWorse = "max_stress_gate_worse"
        }

        init(maxStepsUndercountDays: Int, maxDuplicateDailyMetric: Int, maxAutoOverlap: Int,
             maxWorkoutsWithoutHR: Int, maxJournalDuplicateTitles: Int, maxMetricsWithoutSource: Int,
             maxUnresolvedStepsDays: Int, maxStressGateWorse: Int = 0) {
            self.maxStepsUndercountDays = maxStepsUndercountDays
            self.maxDuplicateDailyMetric = maxDuplicateDailyMetric
            self.maxAutoOverlap = maxAutoOverlap
            self.maxWorkoutsWithoutHR = maxWorkoutsWithoutHR
            self.maxJournalDuplicateTitles = maxJournalDuplicateTitles
            self.maxMetricsWithoutSource = maxMetricsWithoutSource
            self.maxUnresolvedStepsDays = maxUnresolvedStepsDays
            self.maxStressGateWorse = maxStressGateWorse
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            maxStepsUndercountDays = try c.decode(Int.self, forKey: .maxStepsUndercountDays)
            maxDuplicateDailyMetric = try c.decode(Int.self, forKey: .maxDuplicateDailyMetric)
            maxAutoOverlap = try c.decode(Int.self, forKey: .maxAutoOverlap)
            maxWorkoutsWithoutHR = try c.decode(Int.self, forKey: .maxWorkoutsWithoutHR)
            maxJournalDuplicateTitles = try c.decode(Int.self, forKey: .maxJournalDuplicateTitles)
            maxMetricsWithoutSource = try c.decode(Int.self, forKey: .maxMetricsWithoutSource)
            maxUnresolvedStepsDays = try c.decode(Int.self, forKey: .maxUnresolvedStepsDays)
            maxStressGateWorse = try c.decodeIfPresent(Int.self, forKey: .maxStressGateWorse) ?? 0
        }
    }

    static let defaults = Thresholds(
        agreement: [:],
        detection: DetectionCap(minPrecision: 0, minRecall: 0, minReference: 0),
        invariants: InvariantCap(
            maxStepsUndercountDays: 0,
            maxDuplicateDailyMetric: 0,
            maxAutoOverlap: 0,
            maxWorkoutsWithoutHR: 0,
            maxJournalDuplicateTitles: 0,
            maxMetricsWithoutSource: 0,
            maxUnresolvedStepsDays: 0,
            maxStressGateWorse: 0)
    )

    static func load(path: String) throws -> Thresholds {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Thresholds.self, from: data)
    }
}

struct GateFail: Equatable {
    var check: String
    var detail: String
}

func evaluateGates(agreements: [SeriesAgreement],
                   detection: [String: MatchStats],
                   invariants: [InvariantResult],
                   thresholds: Thresholds) -> [GateFail] {
    var fails: [GateFail] = []
    for a in agreements {
        guard let cap = thresholds.agreement[a.name] else { continue }
        if a.n < cap.minN {
            fails.append(GateFail(check: a.name, detail: "n=\(a.n) < min_n=\(cap.minN)"))
            continue
        }
        if a.n == 0 { continue }
        if a.mae > cap.maxMae {
            fails.append(GateFail(check: a.name, detail: String(format: "mae=%.3f > max_mae=%.3f", a.mae, cap.maxMae)))
        }
        if abs(a.bias) > cap.maxAbsBias {
            fails.append(GateFail(check: a.name, detail: String(format: "|bias|=%.3f > max_abs_bias=%.3f", abs(a.bias), cap.maxAbsBias)))
        }
        if a.withinTol < cap.minWithinTol {
            fails.append(GateFail(check: a.name, detail: String(format: "within_tol=%.3f < min=%.3f", a.withinTol, cap.minWithinTol)))
        }
    }
    let det = thresholds.detection
    for (name, m) in detection.sorted(by: { $0.key < $1.key }) {
        if m.reference < det.minReference { continue }
        if !m.precision.isNaN, m.precision < det.minPrecision {
            fails.append(GateFail(check: "detect.\(name).precision",
                                  detail: String(format: "%.3f < min_precision=%.3f", m.precision, det.minPrecision)))
        }
        if !m.recall.isNaN, m.recall < det.minRecall {
            fails.append(GateFail(check: "detect.\(name).recall",
                                  detail: String(format: "%.3f < min_recall=%.3f", m.recall, det.minRecall)))
        }
    }
    let inv = thresholds.invariants
    func cap(_ r: InvariantResult, _ max: Int) {
        if r.failCount > max {
            fails.append(GateFail(check: r.name, detail: "fail_count=\(r.failCount) > max=\(max)"))
        }
    }
    for r in invariants {
        switch r.name {
        case "steps_undercount": cap(r, inv.maxStepsUndercountDays)
        case "duplicate_daily_metric": cap(r, inv.maxDuplicateDailyMetric)
        case "auto_workout_overlap": cap(r, inv.maxAutoOverlap)
        case "workouts_without_hr": cap(r, inv.maxWorkoutsWithoutHR)
        case "journal_duplicate_titles": cap(r, inv.maxJournalDuplicateTitles)
        case "metrics_without_source": cap(r, inv.maxMetricsWithoutSource)
        case "unresolved_steps": cap(r, inv.maxUnresolvedStepsDays)
        case "stress_activity_gate": cap(r, inv.maxStressGateWorse)
        default: break
        }
    }
    return fails
}

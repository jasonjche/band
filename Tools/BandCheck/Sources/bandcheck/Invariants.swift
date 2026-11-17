import Foundation
import StrandAnalytics

struct InvariantResult: Equatable {
    var name: String
    var pass: Bool
    var failCount: Int
    var checked: Int
    var note: String
}

struct StepsDay: Equatable {
    var day: String
    var strap: Double?
    var apple: Double?
    var resolved: Double?
}

func resolveStepsDays(strapByDay: [String: Int], appleByDay: [String: Int]) -> [StepsDay] {
    let days = Set(strapByDay.keys).union(appleByDay.keys).sorted()
    return days.map { day in
        var inputs: [FusionInput] = []
        if let s = strapByDay[day], s > 0 {
            inputs.append(FusionInput(source: .noopComputed, value: Double(s)))
        }
        if let a = appleByDay[day], a > 0 {
            inputs.append(FusionInput(source: .appleHealth, value: Double(a)))
        }
        let resolved = FusionResolver.resolve(metricKey: "steps", inputs: inputs)?.value
        return StepsDay(day: day, strap: strapByDay[day].map(Double.init),
                        apple: appleByDay[day].map(Double.init), resolved: resolved)
    }
}

func stepsUndercount(_ days: [StepsDay], fraction: Double = 0.10) -> [StepsDay] {
    days.filter { d in
        guard let strap = d.strap, let apple = d.apple, apple > 0 else { return false }
        return strap < fraction * apple
    }
}

func unresolvedSteps(_ days: [StepsDay]) -> [StepsDay] {
    days.filter { $0.resolved == nil && ($0.strap != nil || $0.apple != nil) }
}

func autoOverlaps(auto: [WorkoutDBRow], others: [WorkoutDBRow]) -> [(auto: WorkoutDBRow, other: WorkoutDBRow)] {
    var hits: [(WorkoutDBRow, WorkoutDBRow)] = []
    for a in auto {
        for o in others where spansOverlap(a.startTs, a.endTs, o.startTs, o.endTs) {
            hits.append((a, o))
        }
    }
    return hits
}

func journalDuplicateTitles(_ questions: [String]) -> [String: [String]] {
    var byKey: [String: Set<String>] = [:]
    for q in questions {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { continue }
        byKey[journalTitleKey(t), default: []].insert(t)
    }
    return byKey.filter { $0.value.count > 1 }.mapValues { $0.sorted() }
}

func vo2WithoutApple(series: [MetricPointRow], apple: [AppleDailyRow]) -> [String] {
    let appleDays = Set(apple.compactMap { row -> String? in
        guard let v = row.vo2max, v > 0 else { return nil }
        return row.day
    })
    var days: Set<String> = []
    for p in series where (p.key == "vo2max" || p.key == "vo2max_est") && p.value > 0 {
        if !appleDays.contains(p.day) { days.insert(p.day) }
    }
    return days.sorted()
}

import Foundation

struct TimeSpan {
    var start: Int
    var end: Int
    var day: String
    var durationSec: Int { max(0, end - start) }
}

struct MatchStats {
    var predicted: Int
    var reference: Int
    var truePositives: Int
    var precision: Double
    var recall: Double
    var falsePositives: [(start: Int, durationSec: Int)]

    var f1: Double {
        if precision.isNaN || recall.isNaN { return .nan }
        let s = precision + recall
        return s == 0 ? 0 : 2 * precision * recall / s
    }
}

/// A predicted span matches a reference span when they overlap by at least
/// `minOverlap` of the shorter duration (default 0.5). Greedy one-to-one.
func matchSpans(_ predicted: [TimeSpan], _ reference: [TimeSpan],
                minOverlap: Double = 0.5) -> MatchStats {
    var used = Set<Int>()
    var tp = 0
    var fps: [(Int, Int)] = []
    for p in predicted {
        var best: (idx: Int, frac: Double)?
        for (i, r) in reference.enumerated() where !used.contains(i) {
            let frac = overlapFraction(p, r)
            if frac >= minOverlap, frac > (best?.frac ?? -1) {
                best = (i, frac)
            }
        }
        if let best {
            used.insert(best.idx)
            tp += 1
        } else {
            fps.append((p.start, p.durationSec))
        }
    }
    let prec = predicted.isEmpty ? Double.nan : Double(tp) / Double(predicted.count)
    let rec = reference.isEmpty ? Double.nan : Double(tp) / Double(reference.count)
    return MatchStats(predicted: predicted.count, reference: reference.count,
                      truePositives: tp, precision: prec, recall: rec,
                      falsePositives: fps)
}

func overlapSeconds(_ a: TimeSpan, _ b: TimeSpan) -> Int {
    max(0, min(a.end, b.end) - max(a.start, b.start))
}

func overlapFraction(_ a: TimeSpan, _ b: TimeSpan) -> Double {
    let shorter = min(a.durationSec, b.durationSec)
    guard shorter > 0 else { return 0 }
    return Double(overlapSeconds(a, b)) / Double(shorter)
}

func spansOverlap(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Bool {
    aStart <= bEnd && bStart <= aEnd
}

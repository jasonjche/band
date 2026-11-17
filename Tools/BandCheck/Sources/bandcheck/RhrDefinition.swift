import Foundation
import StrandAnalytics
import WhoopProtocol

/// A/B of resting-HR definitions against the WHOOP export, replayed from 1 Hz HR in each
/// primary sleep session. Informational: not a threshold gate.
///
/// - `floor`: lowest gated 5-minute bin (`SleepStager.sessionRestingHR`, #2522).
/// - `mean_minus_2_2`: whole-session mean − 2.2 bpm (Iskrata/noop, citing PMC12367097).
///
/// Held-out days are the last 30% of overlapping wake days, chronological. This measures
/// agreement with the WHOOP export RHR column on nights that have both a WHOOP RHR and
/// enough sleep-window HR in the phone DB. It does not replay WHOOP's own estimator.
struct RhrDefinitionReport {
    var floorAll: SeriesAgreement
    var meanAll: SeriesAgreement
    var floorHoldout: SeriesAgreement
    var meanHoldout: SeriesAgreement
    var shipMeanMinus: Bool
}

func rhrDefinitionCheck(whoopDays: [WhoopDay], sleeps: [SleepRow],
                        hrByDay: [String: [HRSample]], cfg: CheckConfig) -> RhrDefinitionReport {
    let whoopRhr = whoopMap(whoopDays, \.rhr)
    var allHR: [HRSample] = []
    allHR.reserveCapacity(hrByDay.values.reduce(0) { $0 + $1.count })
    for samples in hrByDay.values { allHR.append(contentsOf: samples) }
    allHR.sort { $0.ts < $1.ts }

    var primaryByDay: [String: SleepRow] = [:]
    for s in sleeps where s.deviceId == cfg.computedDevice || s.deviceId == cfg.importedDevice {
        let day = DayKey.logical(s.endTs, calendar: cfg.calendar)
        if let cur = primaryByDay[day] {
            if s.durationS > cur.durationS { primaryByDay[day] = s }
        } else {
            primaryByDay[day] = s
        }
    }

    var floorPairs: [Pair] = []
    var meanPairs: [Pair] = []
    for day in Set(whoopRhr.keys).intersection(primaryByDay.keys).sorted() {
        guard let whoop = whoopRhr[day], let session = primaryByDay[day] else { continue }
        let hr = samplesInRange(allHR, start: session.startTs, end: session.endTs)
        guard !hr.isEmpty else { continue }
        if let floor = SleepStager.sessionRestingHR(start: session.startTs, end: session.endTs, hr: hr) {
            floorPairs.append(Pair(day: day, band: Double(floor), whoop: whoop))
        }
        let valid = hr.map { Double($0.bpm) }.filter { (30...220).contains($0) }
        if valid.count >= PrimarySessionRestingHR.defaultMinValidSamples {
            let mean = valid.reduce(0, +) / Double(valid.count)
            meanPairs.append(Pair(day: day, band: mean - 2.2, whoop: whoop))
        }
    }

    let floorHold = holdout(floorPairs)
    let meanHold = holdout(meanPairs)
    let floorAll = agree("replay.rhr_floor_5min", floorPairs, tolerance: 3)
    let meanAll = agree("replay.rhr_mean_minus_2_2", meanPairs, tolerance: 3)
    let floorH = agree("replay.rhr_floor_5min.holdout", floorHold, tolerance: 3)
    let meanH = agree("replay.rhr_mean_minus_2_2.holdout", meanHold, tolerance: 3)
    let ship = meanH.n >= 5 && meanH.mae.isFinite && floorH.mae.isFinite && meanH.mae < floorH.mae
    return RhrDefinitionReport(floorAll: floorAll, meanAll: meanAll,
                               floorHoldout: floorH, meanHoldout: meanH,
                               shipMeanMinus: ship)
}

func holdout(_ pairs: [Pair], fraction: Double = 0.30) -> [Pair] {
    guard pairs.count >= 4 else { return pairs }
    let sorted = pairs.sorted { $0.day < $1.day }
    let n = max(1, Int((Double(sorted.count) * fraction).rounded(.down)))
    return Array(sorted.suffix(n))
}

private func samplesInRange(_ sorted: [HRSample], start: Int, end: Int) -> [HRSample] {
    guard !sorted.isEmpty else { return [] }
    var lo = 0
    var hi = sorted.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if sorted[mid].ts < start { lo = mid + 1 } else { hi = mid }
    }
    var out: [HRSample] = []
    var i = lo
    while i < sorted.count, sorted[i].ts <= end {
        out.append(sorted[i])
        i += 1
    }
    return out
}

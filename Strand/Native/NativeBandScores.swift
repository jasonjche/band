import Foundation
import os
import StrandAnalytics
import WhoopStore

/// One funnel for Native recovery, sleep performance, need, debt, consistency, and hours-vs-needed.
/// Imported WHOOP figures win per day; every other day is the Band causal pipeline.
enum NativeBandScores {

    private static let log = Logger(subsystem: "band", category: "BandScores")
    private static var cachedParams: BandScores.Params?

    enum Source: Equatable {
        case imported
        case band
    }

    struct Day: Equatable {
        var recovery: Double?
        var sleepPerformance: Double?
        var sleepNeed: Double?
        var sleepDebt: Double?
        var sleepConsistency: Double?
        var hoursVsNeeded: Double?
        var source: Source
    }

    struct Snapshot: Equatable {
        var byDay: [String: Day]
        var ordered: [Day]
    }

    static func params() -> BandScores.Params? {
        if let cachedParams { return cachedParams }
        cachedParams = try? BandScores.Params.bundled()
        return cachedParams
    }

    /// A day is imported when the WHOOP export stored any sleep figure for it.
    static func isImported(_ figures: ImportedSleepFigures?) -> Bool {
        guard let figures else { return false }
        return figures.performancePct != nil
            || figures.consistencyPct != nil
            || figures.needMin != nil
            || figures.debtMin != nil
    }

    static func resolve(days: [DailyMetric], sleeps: [CachedSleepSession] = [],
                        workouts: [WorkoutRow] = [],
                        importedSleep: [String: ImportedSleepFigures] = [:]) -> Snapshot {
        let inputs = dayInputs(days: days, sleeps: sleeps, workouts: workouts)
        let band: [BandScores.DayOutput]
        if let params = params(), !inputs.isEmpty {
            band = BandScores.evaluate(days: inputs, params: params)
        } else {
            band = []
        }
        let bandByDay = Dictionary(uniqueKeysWithValues: band.map { ($0.day, $0) })
        var ordered: [Day] = []
        var byDay: [String: Day] = [:]
        for d in days {
            let imported = isImported(importedSleep[d.day])
            let fig = importedSleep[d.day]
            let b = bandByDay[d.day]
            let rec = recoveryAllowingMissing(b)
            let need = imported ? (fig?.needMin ?? b?.need) : b?.need
            let asleep = d.totalSleepMin
            let hours: Double?
            if let asleep, let need, need > 0, asleep > 0 {
                hours = asleep / need * 100
            } else {
                hours = nil
            }
            let day = Day(
                recovery: imported ? d.recovery : rec,
                sleepPerformance: imported ? (fig?.performancePct ?? b?.perf) : b?.perf,
                sleepNeed: need,
                sleepDebt: imported ? (fig?.debtMin ?? b?.debt) : b?.debt,
                sleepConsistency: imported ? (fig?.consistencyPct ?? b?.cons) : b?.cons,
                hoursVsNeeded: hours,
                source: imported ? .imported : .band
            )
            ordered.append(day)
            byDay[d.day] = day
        }
        return Snapshot(byDay: byDay, ordered: ordered)
    }

    static func day(_ key: String, in snapshot: Snapshot) -> Day? {
        snapshot.byDay[key]
    }

    /// Debug-only SWS HRV beside the incumbent nightly HRV. Never a Recovery input.
    static func logHrvSws(beats: [BandHrvSws.Beat], epochs: [BandHrvSws.Epoch],
                          sleepStart: Date, sleepEnd: Date, nightlyHrv: Double?) {
        let result = BandHrvSws.compute(
            beats: beats, epochs: epochs,
            sleepStartSec: sleepStart.timeIntervalSince1970,
            sleepEndSec: sleepEnd.timeIntervalSince1970
        )
        let sws = result.fallback ? result.fullSleepRmssd : result.allSwsRmssd
        log.debug("HRV SWS \(sws ?? -1, privacy: .public) ms (fallback=\(result.fallback, privacy: .public) windows=\(result.windowCount, privacy: .public)) vs nightly \(nightlyHrv ?? -1, privacy: .public) ms")
    }

    // MARK: - Inputs

    static func dayInputs(days: [DailyMetric], sleeps: [CachedSleepSession],
                          workouts: [WorkoutRow]) -> [BandScores.DayInput] {
        let sleepsByDay = Dictionary(grouping: sleeps) {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs)))
        }
        let workoutsByDay = Dictionary(grouping: workouts) {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs)))
        }
        return days.map { day in
            let blocks = (sleepsByDay[day.day] ?? []).sorted {
                ($0.endTs - $0.effectiveStartTs) > ($1.endTs - $1.effectiveStartTs)
            }
            let main = blocks.first
            let naps = Array(blocks.dropFirst())
            let napMin = naps.reduce(0.0) { acc, s in
                acc + Double(max(0, s.endTs - s.effectiveStartTs)) / 60.0
            }
            let wo = workoutsByDay[day.day] ?? []
            var edwards = 0.0
            var z45 = 0.0
            var kcalSum = 0.0
            var hasKcal = false
            for row in wo {
                let dur = (row.durationS ?? Double(max(0, row.endTs - row.startTs))) / 60.0
                if let p = WorkoutZones.percents(row.zonesJSON), dur > 0 {
                    let parts = BandLoadIndex.workout(
                        durationMin: dur, z1: p[0], z2: p[1], z3: p[2], z4: p[3], z5: p[4]
                    )
                    edwards += parts.edwards
                    z45 += parts.z45
                }
                if let k = row.energyKcal {
                    kcalSum += k
                    hasKcal = true
                }
            }
            let energy = day.activeKcalEst ?? (hasKcal ? kcalSum : nil)
            let asleep = day.totalSleepMin
            let inbed: Double?
            if let asleep, let raw = day.efficiency, raw > 0 {
                let eff = raw <= 1 ? raw : raw / 100
                inbed = eff > 0 ? asleep / eff : nil
            } else {
                inbed = nil
            }
            return BandScores.DayInput(
                day: day.day,
                energyKcal: energy,
                edwards: wo.isEmpty ? nil : edwards,
                z45Min: wo.isEmpty ? nil : z45,
                asleep: asleep,
                inbed: inbed,
                napMin: napMin,
                onsetMin: main.map { clockMin($0.effectiveStartTs) },
                wakeMin: main.map { clockMin($0.endTs) },
                naps: naps.map {
                    BandScores.NapSpan(onsetMin: clockMin($0.effectiveStartTs), wakeMin: clockMin($0.endTs))
                },
                hrvMs: day.avgHrv,
                rhr: day.restingHr.map(Double.init),
                resp: day.respRateBpm,
                temp: day.skinTempC,
                spo2: day.spo2Pct
            )
        }
    }

    private static func clockMin(_ ts: Int) -> Int {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Temp / SpO2 / RHR / RR are optional on-device; HRV and sleep performance are required.
    private static func recoveryAllowingMissing(_ b: BandScores.DayOutput?) -> Double? {
        guard let b else { return nil }
        if let r = b.recovery { return r }
        guard let zHrv = b.zHrv, let perf = b.perf, let params = params() else { return nil }
        let rec = BandRecovery.run(
            zHrv: [zHrv],
            zRhr: [b.zRhr ?? 0],
            zRr: [b.zRr ?? 0],
            zTemp: [b.zTemp ?? 0],
            zSpo2: [b.zSpo2 ?? 0],
            perf: [perf],
            params: params.recovery
        )
        return BandScores.finite(rec[0])
    }

    static func epochs(from stagesJSON: String?, sessionStart: Int) -> [BandHrvSws.Epoch] {
        guard let stagesJSON, let data = stagesJSON.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { seg in
            guard let s = (seg["start"] as? NSNumber)?.intValue,
                  let e = (seg["end"] as? NSNumber)?.intValue, e > s,
                  let name = seg["stage"] as? String else { return nil }
            return BandHrvSws.Epoch(
                startSec: Double(s), endSec: Double(e),
                isSws: name == "deep"
            )
        }
    }
}

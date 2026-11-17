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
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache.first(where: {
            $0.days == days && $0.sleeps == sleeps && $0.workouts == workouts
                && $0.importedSleep == importedSleep
        }) {
            return hit.snapshot
        }
        let snapshot = compute(days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep)
        cache.insert(CacheEntry(days: days, sleeps: sleeps, workouts: workouts,
                                importedSleep: importedSleep, snapshot: snapshot), at: 0)
        if cache.count > 4 { cache.removeLast() }
        return snapshot
    }

    private struct CacheEntry {
        var days: [DailyMetric]
        var sleeps: [CachedSleepSession]
        var workouts: [WorkoutRow]
        var importedSleep: [String: ImportedSleepFigures]
        var snapshot: Snapshot
    }

    /// Screens call `resolve` from view bodies, so the full-history pipeline runs once per data change.
    private static var cache: [CacheEntry] = []
    private static let cacheLock = NSLock()

    private static func compute(days: [DailyMetric], sleeps: [CachedSleepSession],
                                workouts: [WorkoutRow],
                                importedSleep: [String: ImportedSleepFigures]) -> Snapshot {
        let inputs = dayInputs(days: days, sleeps: sleeps, workouts: workouts,
                               importedSleep: importedSleep)
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
            let need = imported ? (fig?.needMin ?? b?.need) : b?.need
            let asleep = d.totalSleepMin
            let hours: Double?
            if let asleep, let need, need > 0, asleep > 0 {
                hours = asleep / need * 100
            } else {
                hours = nil
            }
            let day = Day(
                // WHOOP's figure on imported days. Strap days use the Band logistic once it has a
                // value (after warmup); NOOP's DailyMetric.recovery is the fallback while Band has none.
                // Missing-signal rule (port_spec.md §5 + BandRecovery): recovery is published only when
                // z_hrv, z_rhr, z_rr, z_temp, z_spo2, and sleep performance are all finite. A missing
                // z is left missing (IEEE NaN through the logistic); there is no zero-fill. Missing
                // energy on a cycle uses the train median of log_energy; missing Edwards / z45 fill 0.
                // A missing night decays sleep debt and does not append a shortfall.
                recovery: imported ? d.recovery : (strapRecovery(b) ?? d.recovery),
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
                          workouts: [WorkoutRow],
                          importedSleep: [String: ImportedSleepFigures] = [:]) -> [BandScores.DayInput] {
        let sleepsByDay = Dictionary(grouping: sleeps) {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs)))
        }
        let workoutsByDay = Dictionary(grouping: workouts) {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs)))
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
            for row in wo {
                let dur = (row.durationS ?? Double(max(0, row.endTs - row.startTs))) / 60.0
                if let p = WorkoutZones.percents(row.zonesJSON), dur > 0 {
                    let parts = BandLoadIndex.workout(
                        durationMin: dur, z1: p[0], z2: p[1], z3: p[2], z4: p[3], z5: p[4]
                    )
                    edwards += parts.edwards
                    z45 += parts.z45
                }
            }
            // Whole-day energy only. Workout calories are a different scale and skew sleep need.
            let energy = day.activeKcalEst
            // Zero or absent sleep is a night the strap was not worn, not a night of no sleep.
            // Counting it as a shortfall would inflate sleep debt and tonight's need.
            let asleep = day.totalSleepMin.flatMap { $0 > 0 ? $0 : nil }
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
                spo2: day.spo2Pct,
                source: isImported(importedSleep[day.day]) ? .imported : .strap
            )
        }
    }

    private static func clockMin(_ ts: Int) -> Int {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Band recovery for a strap day. HRV, resting HR, respiratory rate and sleep performance are
    /// required. Skin temperature and SpO2 only enter as out-of-range flags with a dead zone, and
    /// the strap does not report SpO2 by default, so a missing one counts as "no flag" (z = 0).
    private static func strapRecovery(_ b: BandScores.DayOutput?) -> Double? {
        guard let b else { return nil }
        if let r = b.recovery { return r }
        guard let zHrv = b.zHrv, let zRhr = b.zRhr, let zRr = b.zRr, let perf = b.perf,
              let params = params() else { return nil }
        let rec = BandRecovery.run(
            zHrv: [zHrv], zRhr: [zRhr], zRr: [zRr],
            zTemp: [b.zTemp ?? 0], zSpo2: [b.zSpo2 ?? 0],
            perf: [perf], params: params.recovery
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

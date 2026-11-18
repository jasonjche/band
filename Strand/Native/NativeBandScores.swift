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
        /// Hours vs. Needed breakdown (strap days only). Same `a * loadForNeed` / `b * debt`
        /// parts `NativeSleepNeed` used to re-evaluate BandScores for.
        var needBaselineMin: Double?
        var needStrainMin: Double?
        var needDebtMin: Double?
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
            $0.days.count == days.count
                && $0.sleeps.count == sleeps.count
                && $0.workouts.count == workouts.count
                && $0.importedSleep.count == importedSleep.count
                && $0.days == days && $0.sleeps == sleeps && $0.workouts == workouts
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
        // Evaluate full causal timeline so unworn days still carry tonight's sleepNeed/debt,
        // and evaluate worn-only nights as a fallback when a gap inside the 5-night window
        // blanks consistency and sleepPerformance.
        let scoredInputs = inputs.filter { ($0.asleep ?? 0) > 0 }
        let band: [BandScores.DayOutput]
        let wornBand: [BandScores.DayOutput]
        if let params = params(), !inputs.isEmpty {
            band = BandScores.evaluate(days: inputs, params: params)
            wornBand = scoredInputs.count == inputs.count || scoredInputs.isEmpty
                ? band
                : BandScores.evaluate(days: scoredInputs, params: params)
        } else {
            band = []
            wornBand = []
        }
        let bandByDay = Dictionary(uniqueKeysWithValues: band.map { ($0.day, $0) })
        let wornByDay = Dictionary(uniqueKeysWithValues: wornBand.map { ($0.day, $0) })
        let inputByDay = Dictionary(uniqueKeysWithValues: inputs.map { ($0.day, $0) })
        let daysByKey = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0) })
        var keys = days.map(\.day)
        for input in inputs where !keys.contains(input.day) {
            keys.append(input.day)
        }
        keys.sort()
        var ordered: [Day] = []
        var byDay: [String: Day] = [:]
        for key in keys {
            let d = daysByKey[key]
            let imported = isImported(importedSleep[key])
            let fig = importedSleep[key]
            let b = bandByDay[key]
            let wb = wornByDay[key]
            let need = imported ? (fig?.needMin ?? b?.need ?? wb?.need) : (b?.need ?? wb?.need)
            let asleep = inputByDay[key]?.asleep
                ?? (d?.totalSleepMin).flatMap { $0 > 0 ? $0 : nil }
            let hours: Double?
            if let asleep, let need, need > 0, asleep > 0 {
                hours = asleep / need * 100
            } else {
                hours = nil
            }
            var needBaseline: Double?
            var needStrain: Double?
            var needDebtPart: Double?
            if !imported, let b = b ?? wb, let params = params() {
                let strainPart = params.sleepLedger.a * (b.loadForNeed ?? 0)
                let debtPart = params.sleepLedger.b * (b.debt ?? 0)
                needStrain = strainPart
                needDebtPart = debtPart
                if let need {
                    needBaseline = need - strainPart - debtPart
                }
            }
            let cons = imported ? (fig?.consistencyPct ?? b?.cons ?? wb?.cons) : (b?.cons ?? wb?.cons)
            let perf: Double? = {
                if imported { return fig?.performancePct ?? b?.perf ?? wb?.perf }
                if let p = b?.perf { return p }
                if let params = params(),
                   let a = asleep, a > 0,
                   let nd = need, nd > 0,
                   let ib = inputByDay[key]?.inbed, ib > 0 {
                    let c = cons ?? 75.0
                    let out = BandSleepPerformance.run(
                        asleep: [a], need: [nd], cons: [c], inbed: [ib],
                        params: params.sleepPerformance
                    )
                    if let finite = BandScores.finite(out[0]) { return finite }
                }
                return wb?.perf
            }()
            let day = Day(
                // Imported days keep WHOOP's DailyMetric.recovery. Strap days prefer round-5
                // recoveryV3 once it has passed the current-source warm-up; else round-2
                // strapRecovery (tolerates missing temp/SpO2); else DailyMetric.recovery.
                recovery: imported
                    ? d?.recovery
                    : (b?.recoveryV3 ?? wb?.recoveryV3 ?? strapRecovery(b ?? wb, perfOverride: perf) ?? d?.recovery),
                sleepPerformance: perf,
                sleepNeed: need,
                sleepDebt: imported ? (fig?.debtMin ?? b?.debt ?? wb?.debt) : (b?.debt ?? wb?.debt),
                sleepConsistency: cons,
                hoursVsNeeded: hours,
                source: imported ? .imported : .band,
                needBaselineMin: needBaseline,
                needStrainMin: needStrain,
                needDebtMin: needDebtPart
            )
            ordered.append(day)
            byDay[key] = day
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

    /// Asleep / in-bed / stage minutes from a DailyMetric when it has them, else from the
    /// night's `CachedSleepSession` so a just-synced or user-edited night scores before
    /// `DailyMetric` finishes rescoring (or when that row is steps-only).
    struct NightSleep: Equatable {
        var asleep: Double? = nil
        var inbed: Double? = nil
        var light: Double? = nil
        var deep: Double? = nil
        var rem: Double? = nil
        var awake: Double? = nil
        var efficiency: Double? = nil
    }

    static func nightSleep(metric: DailyMetric?, session: CachedSleepSession?) -> NightSleep {
        let fromSession = session.map(sessionSleep) ?? NightSleep()
        let edited = session?.userEdited == true && fromSession.asleep != nil
        let metricAsleep = metric.flatMap {
            NativeDayLogic.asleepMinutes(
                light: $0.lightMin, deep: $0.deepMin, rem: $0.remMin, totalSleepMin: $0.totalSleepMin
            )
        }
        let asleep = edited ? fromSession.asleep : (metricAsleep ?? fromSession.asleep)
        let light = edited ? (fromSession.light ?? positive(metric?.lightMin)) : (positive(metric?.lightMin) ?? fromSession.light)
        let deep = edited ? (fromSession.deep ?? positive(metric?.deepMin)) : (positive(metric?.deepMin) ?? fromSession.deep)
        let rem = edited ? (fromSession.rem ?? positive(metric?.remMin)) : (positive(metric?.remMin) ?? fromSession.rem)
        let inbed = fromSession.inbed ?? inbedFromEfficiency(asleep: asleep, efficiency: metric?.efficiency)
        let awake: Double?
        if let inbed, let asleep, inbed > asleep {
            awake = inbed - asleep
        } else {
            awake = fromSession.awake
        }
        let efficiency = edited ? (fromSession.efficiency ?? metric?.efficiency) : (metric?.efficiency ?? fromSession.efficiency)
        return NightSleep(
            asleep: asleep, inbed: inbed, light: light, deep: deep, rem: rem,
            awake: awake, efficiency: efficiency
        )
    }

    static func sessionSleep(_ session: CachedSleepSession) -> NightSleep {
        let inbedClock: Double? = session.endTs > session.effectiveStartTs
            ? Double(session.endTs - session.effectiveStartTs) / 60.0 : nil
        if let minutes = SleepStageTotals.minutes(fromStagesJSON: session.stagesJSON), minutes.inBed > 0 {
            return NightSleep(
                asleep: minutes.asleep > 0 ? minutes.asleep : nil,
                inbed: minutes.inBed,
                light: minutes.light > 0 ? minutes.light : nil,
                deep: minutes.deep > 0 ? minutes.deep : nil,
                rem: minutes.rem > 0 ? minutes.rem : nil,
                awake: minutes.awake > 0 ? minutes.awake : nil,
                efficiency: minutes.inBed > 0 ? minutes.asleep / minutes.inBed : session.efficiency
            )
        }
        let efficiency = session.efficiency
        let asleep: Double?
        if let inbedClock, inbedClock > 0, let raw = efficiency, raw > 0 {
            let eff = raw <= 1 ? raw : raw / 100
            let value = inbedClock * eff
            asleep = value > 0 ? value : nil
        } else {
            asleep = inbedClock
        }
        return NightSleep(
            asleep: asleep, inbed: inbedClock, light: nil, deep: nil, rem: nil,
            awake: inbedFromAwake(inbed: inbedClock, asleep: asleep),
            efficiency: efficiency
        )
    }

    private static func inbedFromEfficiency(asleep: Double?, efficiency: Double?) -> Double? {
        guard let asleep, let raw = efficiency, asleep > 0, raw > 0 else { return nil }
        let eff = raw <= 1 ? raw : raw / 100
        guard eff > 0 else { return nil }
        return asleep / eff
    }

    private static func inbedFromAwake(inbed: Double?, asleep: Double?) -> Double? {
        guard let inbed, let asleep, inbed > asleep else { return nil }
        return inbed - asleep
    }

    private static func positive(_ value: Double?) -> Double? {
        value.flatMap { $0 > 0 ? $0 : nil }
    }

    static func dayInputs(days: [DailyMetric], sleeps: [CachedSleepSession],
                          workouts: [WorkoutRow],
                          importedSleep: [String: ImportedSleepFigures] = [:]) -> [BandScores.DayInput] {
        let sleepsByDay = Dictionary(grouping: sleeps) {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs)))
        }
        let workoutsByDay = Dictionary(grouping: workouts) {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs)))
        }
        let daysByKey = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0) })
        var keys = days.map(\.day)
        for key in sleepsByDay.keys where !keys.contains(key) {
            keys.append(key)
        }
        keys.sort()
        return keys.map { key in
            let day = daysByKey[key]
            let blocks = (sleepsByDay[key] ?? []).sorted {
                ($0.endTs - $0.effectiveStartTs) > ($1.endTs - $1.effectiveStartTs)
            }
            let main = blocks.first
            let naps = Array(blocks.dropFirst())
            let napMin = naps.reduce(0.0) { acc, s in
                acc + Double(max(0, s.endTs - s.effectiveStartTs)) / 60.0
            }
            let wo = workoutsByDay[key] ?? []
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
            let energy = day?.activeKcalEst
            let night = nightSleep(metric: day, session: main)
            // Zero or absent sleep is a night the strap was not worn, not a night of no sleep.
            // Counting it as a shortfall would inflate sleep debt and tonight's need.
            return BandScores.DayInput(
                day: key,
                energyKcal: energy,
                edwards: wo.isEmpty ? nil : edwards,
                z45Min: wo.isEmpty ? nil : z45,
                asleep: night.asleep,
                inbed: night.inbed,
                napMin: napMin,
                onsetMin: main.map { clockMin($0.effectiveStartTs) },
                wakeMin: main.map { clockMin($0.endTs) },
                naps: naps.map {
                    BandScores.NapSpan(onsetMin: clockMin($0.effectiveStartTs), wakeMin: clockMin($0.endTs))
                },
                hrvMs: day?.avgHrv ?? main?.avgHrv,
                rhr: (day?.restingHr ?? main?.restingHr).map(Double.init),
                resp: day?.respRateBpm,
                temp: day?.skinTempC,
                spo2: day?.spo2Pct,
                source: isImported(importedSleep[key]) ? .imported : .strap
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
    private static func strapRecovery(_ b: BandScores.DayOutput?, perfOverride: Double? = nil) -> Double? {
        guard let b else { return nil }
        if let r = b.recovery { return r }
        guard let zHrv = b.zHrv, let zRhr = b.zRhr, let zRr = b.zRr,
              let perf = b.perf ?? perfOverride,
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

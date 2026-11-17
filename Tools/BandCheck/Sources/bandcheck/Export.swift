import Foundation
import StrandAnalytics
import StrandImport

struct WhoopDay {
    var day: String
    var recovery: Double?
    var rhr: Double?
    var hrv: Double?
    var skinTempC: Double?
    var spo2: Double?
    var dayStrain: Double?
    var energyKcal: Double?
    var sleepPerformance: Double?
    var resp: Double?
    var asleepMin: Double?
    var inbedMin: Double?
    var lightMin: Double?
    var deepMin: Double?
    var remMin: Double?
    var awakeMin: Double?
    var sleepNeedMin: Double?
    var sleepDebtMin: Double?
    var sleepConsistency: Double?
    var sleepOnset: Date?
    var wakeOnset: Date?
    var tzOffsetMin: Int
}

struct WhoopWorkout {
    var start: Date
    var end: Date
    var startTs: Int
    var endTs: Int
    var day: String
    var strain: Double?
    var durationMin: Double
    var z1: Double
    var z2: Double
    var z3: Double
    var z4: Double
    var z5: Double
    var activity: String
}

struct WhoopSleep {
    var day: String
    var isNap: Bool
    var asleepMin: Double?
    var inbedMin: Double?
    var lightMin: Double?
    var deepMin: Double?
    var remMin: Double?
    var awakeMin: Double?
    var performance: Double?
    var onset: Date?
    var wake: Date?
}

func loadWhoopExport(path: String) throws -> (days: [WhoopDay], workouts: [WhoopWorkout], sleeps: [WhoopSleep], questions: [String]) {
    let result = try WhoopExportImporter().import(from: URL(fileURLWithPath: path))
    var days: [String: WhoopDay] = [:]
    for c in result.cycles {
        guard let key = WhoopDayKeying.wakeDayKey(wake: c.wakeOnset, end: c.cycleEnd,
                                                  start: c.cycleStart, tzOffsetMin: c.tzOffsetMin)
        else { continue }
        days[key] = WhoopDay(
            day: key,
            recovery: c.recoveryScore,
            rhr: c.restingHeartRate,
            hrv: c.hrvMs,
            skinTempC: c.skinTempCelsius,
            spo2: c.bloodOxygenPct,
            dayStrain: c.dayStrain,
            energyKcal: c.energyKcal,
            sleepPerformance: c.sleepPerformancePct,
            resp: c.respiratoryRate,
            asleepMin: c.asleepDurationMin,
            inbedMin: c.inBedDurationMin,
            lightMin: c.lightSleepDurationMin,
            deepMin: c.deepSleepDurationMin,
            remMin: c.remDurationMin,
            awakeMin: c.awakeDurationMin,
            sleepNeedMin: c.sleepNeedMin,
            sleepDebtMin: c.sleepDebtMin,
            sleepConsistency: c.sleepConsistencyPct,
            sleepOnset: c.sleepOnset,
            wakeOnset: c.wakeOnset,
            tzOffsetMin: c.tzOffsetMin)
    }
    var workouts: [WhoopWorkout] = []
    for w in result.workouts {
        guard let start = w.workoutStart, let end = w.workoutEnd, end > start else { continue }
        let key = WhoopDayKeying.wakeDayKey(wake: nil, end: nil, start: start,
                                            tzOffsetMin: w.tzOffsetMin)
            ?? DayKey.local(start, calendar: DayKey.calendar(tz: TimeZone(secondsFromGMT: w.tzOffsetMin * 60) ?? TimeZone(secondsFromGMT: 0)!))
        let dur = end.timeIntervalSince(start) / 60.0
        workouts.append(WhoopWorkout(
            start: start, end: end,
            startTs: Int(start.timeIntervalSince1970),
            endTs: Int(end.timeIntervalSince1970),
            day: key,
            strain: w.activityStrain,
            durationMin: dur,
            z1: w.hrZone1Pct ?? 0, z2: w.hrZone2Pct ?? 0, z3: w.hrZone3Pct ?? 0,
            z4: w.hrZone4Pct ?? 0, z5: w.hrZone5Pct ?? 0,
            activity: w.activityName ?? ""))
    }
    var sleeps: [WhoopSleep] = []
    for s in result.sleeps {
        let key = WhoopDayKeying.wakeDayKey(wake: s.wakeOnset, end: nil,
                                            start: s.sleepOnset ?? s.cycleStart,
                                            tzOffsetMin: s.tzOffsetMin)
        guard let key else { continue }
        sleeps.append(WhoopSleep(
            day: key, isNap: s.isNap,
            asleepMin: s.asleepDurationMin, inbedMin: s.inBedDurationMin,
            lightMin: s.lightSleepDurationMin, deepMin: s.deepSleepDurationMin,
            remMin: s.remDurationMin, awakeMin: s.awakeDurationMin,
            performance: s.sleepPerformancePct,
            onset: s.sleepOnset, wake: s.wakeOnset))
    }
    let questions = Array(Set(result.journal.compactMap(\.question)))
    return (days.values.sorted { $0.day < $1.day },
            workouts.sorted { $0.startTs < $1.startTs },
            sleeps, questions)
}

func bandDayInputs(from days: [WhoopDay], workouts: [WhoopWorkout], sleeps: [WhoopSleep]) -> [BandScores.DayInput] {
    let woByDay = Dictionary(grouping: workouts, by: \.day)
    let sleepByDay = Dictionary(grouping: sleeps, by: \.day)
    return days.map { d in
        let cal = DayKey.calendar(tz: TimeZone(secondsFromGMT: d.tzOffsetMin * 60) ?? TimeZone(secondsFromGMT: 0)!)
        let wo = woByDay[d.day] ?? []
        var edwards = 0.0
        var z45 = 0.0
        for w in wo {
            let parts = BandLoadIndex.workout(durationMin: w.durationMin,
                                              z1: w.z1, z2: w.z2, z3: w.z3, z4: w.z4, z5: w.z5)
            edwards += parts.edwards
            z45 += parts.z45
        }
        let blocks = (sleepByDay[d.day] ?? []).sorted {
            ($0.asleepMin ?? 0) > ($1.asleepMin ?? 0)
        }
        let main = blocks.first
        let naps = Array(blocks.dropFirst())
        let napMin = naps.reduce(0.0) { $0 + ($1.inbedMin ?? $1.asleepMin ?? 0) }
        return BandScores.DayInput(
            day: d.day,
            energyKcal: d.energyKcal,
            edwards: wo.isEmpty ? nil : edwards,
            z45Min: wo.isEmpty ? nil : z45,
            asleep: d.asleepMin.flatMap { $0 > 0 ? $0 : nil },
            inbed: d.inbedMin.flatMap { $0 > 0 ? $0 : nil },
            napMin: napMin,
            onsetMin: main?.onset.map { DayKey.clockMin($0, calendar: cal) },
            wakeMin: main?.wake.map { DayKey.clockMin($0, calendar: cal) },
            naps: naps.compactMap { n in
                guard let o = n.onset, let w = n.wake else { return nil }
                return BandScores.NapSpan(onsetMin: DayKey.clockMin(o, calendar: cal),
                                          wakeMin: DayKey.clockMin(w, calendar: cal))
            },
            hrvMs: d.hrv,
            rhr: d.rhr,
            resp: d.resp,
            temp: d.skinTempC,
            spo2: d.spo2,
            source: .imported)
    }
}

func zoneMinutes6(_ w: WhoopWorkout) -> [Double] {
    let dur = w.durationMin
    let z = [w.z1, w.z2, w.z3, w.z4, w.z5].map { $0 / 100.0 }
    let covered = z.reduce(0, +)
    let m0 = dur * max(0, 1 - covered)
    return [m0] + z.map { dur * $0 }
}

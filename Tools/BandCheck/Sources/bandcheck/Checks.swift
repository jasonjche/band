import Foundation
import StrandAnalytics
import WhoopProtocol

struct CheckConfig {
    var verbose: Bool
    var calendar: Calendar
    var streamDevice: String
    var importedDevice: String
    var computedDevice: String
    var hrMax: Double
    var strainParams: BandStrain.Params
    var scoreParams: BandScores.Params
    var profile: UserProfile
}

func pair(_ name: String, whoop: [String: Double], band: [String: Double],
          tolerance: Double) -> (SeriesAgreement, [Pair]) {
    var pairs: [Pair] = []
    for day in Set(whoop.keys).intersection(band.keys).sorted() {
        guard let w = whoop[day], let b = band[day], w.isFinite, b.isFinite else { continue }
        pairs.append(Pair(day: day, band: b, whoop: w))
    }
    return (agree(name, pairs, tolerance: tolerance), pairs)
}

func printPairs(_ pairs: [Pair], verbose: Bool) {
    guard verbose else { return }
    for p in pairs {
        print(String(format: "    %@  band=%g  whoop=%g  err=%+.3f", p.day, p.band, p.whoop, p.err))
    }
}

func byDay(_ rows: [DailyRow], device: String, _ pick: (DailyRow) -> Double?) -> [String: Double] {
    var out: [String: Double] = [:]
    for r in rows where r.deviceId == device {
        if let v = pick(r), v.isFinite { out[r.day] = v }
    }
    return out
}

func whoopMap(_ days: [WhoopDay], _ pick: (WhoopDay) -> Double?) -> [String: Double] {
    var out: [String: Double] = [:]
    for d in days {
        if let v = pick(d), v.isFinite { out[d.day] = v }
    }
    return out
}

func agreementChecks(whoopDays: [WhoopDay], whoopWorkouts: [WhoopWorkout],
                     whoopSleeps: [WhoopSleep], daily: [DailyRow], sleeps: [SleepRow],
                     workouts: [WorkoutDBRow], hrByDay: [String: [HRSample]],
                     energySeries: [MetricPointRow],
                     cfg: CheckConfig) -> ([SeriesAgreement], [Pair]) {
    var out: [SeriesAgreement] = []
    var verbosePairs: [Pair] = []

    func add(_ name: String, whoop: [String: Double], band: [String: Double], tol: Double) {
        let (a, pairs) = pair(name, whoop: whoop, band: band, tolerance: tol)
        out.append(a)
        if cfg.verbose { print("  \(name)"); printPairs(pairs, verbose: true) }
        verbosePairs.append(contentsOf: pairs)
    }

    let wStrain = whoopMap(whoopDays, \.dayStrain)
    let wRec = whoopMap(whoopDays, \.recovery)
    let wPerf = whoopMap(whoopDays, \.sleepPerformance)
    let wAsleep = whoopMap(whoopDays, \.asleepMin)
    let wInbed = whoopMap(whoopDays, \.inbedMin)
    let wLight = whoopMap(whoopDays, \.lightMin)
    let wDeep = whoopMap(whoopDays, \.deepMin)
    let wRem = whoopMap(whoopDays, \.remMin)
    let wAwake = whoopMap(whoopDays, \.awakeMin)
    let wRhr = whoopMap(whoopDays, \.rhr)
    let wHrv = whoopMap(whoopDays, \.hrv)
    let wResp = whoopMap(whoopDays, \.resp)

    // Stored imported (my-whoop) vs WHOOP — import fidelity.
    add("stored_imported.day_strain", whoop: wStrain,
        band: byDay(daily, device: cfg.importedDevice) { strain21(fromStoredEffort100: $0.strain) }, tol: 1.0)
    add("stored_imported.recovery", whoop: wRec,
        band: byDay(daily, device: cfg.importedDevice) { $0.recovery }, tol: 5)
    add("stored_imported.sleep_duration", whoop: wAsleep,
        band: byDay(daily, device: cfg.importedDevice) { $0.totalSleepMin }, tol: 20)
    add("stored_imported.rhr", whoop: wRhr,
        band: byDay(daily, device: cfg.importedDevice) { $0.restingHr }, tol: 2)
    add("stored_imported.hrv", whoop: wHrv,
        band: byDay(daily, device: cfg.importedDevice) { $0.avgHrv }, tol: 5)
    add("stored_imported.resp", whoop: wResp,
        band: byDay(daily, device: cfg.importedDevice) { $0.respRateBpm }, tol: 0.5)

    // Stored computed (Band's own days) vs WHOOP — the overlap the install cares about.
    add("stored_computed.day_strain", whoop: wStrain,
        band: byDay(daily, device: cfg.computedDevice) { strain21(fromStoredEffort100: $0.strain) }, tol: 1.5)
    add("stored_computed.recovery", whoop: wRec,
        band: byDay(daily, device: cfg.computedDevice) { $0.recovery }, tol: 8)
    add("stored_computed.sleep_duration", whoop: wAsleep,
        band: byDay(daily, device: cfg.computedDevice) { $0.totalSleepMin }, tol: 30)
    add("stored_computed.rhr", whoop: wRhr,
        band: byDay(daily, device: cfg.computedDevice) { $0.restingHr }, tol: 3)
    add("stored_computed.hrv", whoop: wHrv,
        band: byDay(daily, device: cfg.computedDevice) { $0.avgHrv }, tol: 8)
    add("stored_computed.resp", whoop: wResp,
        band: byDay(daily, device: cfg.computedDevice) { $0.respRateBpm }, tol: 1.0)

    // Replay BandScores over export-period inputs (NativeBandScores-equivalent package path).
    let inputs = bandDayInputs(from: whoopDays, workouts: whoopWorkouts, sleeps: whoopSleeps)
    let scored = BandScores.evaluate(days: inputs, params: cfg.scoreParams)
    var rec2: [String: Double] = [:], rec3: [String: Double] = [:], perf: [String: Double] = [:]
    for s in scored {
        if let v = s.recovery { rec2[s.day] = v }
        if let v = s.recoveryV3 { rec3[s.day] = v }
        if let v = s.perf { perf[s.day] = v }
    }
    add("replay.recovery", whoop: wRec, band: rec2, tol: 8)
    add("replay.recovery_v3", whoop: wRec, band: rec3, tol: 8)
    add("replay.sleep_performance", whoop: wPerf, band: perf, tol: 8)

    // Replay BandStrain over 1 Hz HR on days that exist in both the phone DB and the export.
    var hrStrain: [String: Double] = [:]
    let rhrByDay = whoopMap(whoopDays, \.rhr)
    let storedRhr = byDay(daily, device: cfg.computedDevice) { $0.restingHr }
        .merging(byDay(daily, device: cfg.importedDevice) { $0.restingHr }) { a, _ in a }
    for (day, samples) in hrByDay {
        let rhr = rhrByDay[day] ?? storedRhr[day] ?? BandStrain.defaultRestingHR
        if let s = BandStrain.strain(samples, maxHR: cfg.hrMax, restingHR: rhr, params: cfg.strainParams) {
            hrStrain[day] = s
        }
    }
    add("replay.day_strain_hr", whoop: wStrain, band: hrStrain, tol: 1.5)

    // Replay BandStrain from WHOOP zone minutes vs WHOOP activity strain.
    var zonePairs: [Pair] = []
    for (i, w) in whoopWorkouts.enumerated() {
        guard let whoopS = w.strain else { continue }
        let bandS = BandStrain.strain(zoneMinutes: zoneMinutes6(w), params: cfg.strainParams)
        zonePairs.append(Pair(day: w.day + "#\(i)", band: bandS, whoop: whoopS))
    }
    out.append(agree("replay.workout_strain_zones", zonePairs, tolerance: 1.5))
    if cfg.verbose { print("  replay.workout_strain_zones"); printPairs(zonePairs, verbose: true) }

    // Held-out A/B/C workout-strain curves (70/30 time split). Production stays on C.
    let held = StrainEval.heldOutAgreements(
        workouts: whoopWorkouts, rhrByDay: rhrByDayFromWhoop(whoopDays),
        hrMax: cfg.hrMax, strainParams: cfg.strainParams)
    out.append(contentsOf: held)
    if cfg.verbose {
        for a in held { print("  \(a.name) n=\(a.n) mae=\(a.mae) bias=\(a.bias)") }
    }

    // Stored workout strain (imported whoop rows) vs WHOOP activity strain, matched by time.
    let storedWO = workouts.filter { $0.source.lowercased().contains("whoop") && !$0.isDetected }
    var woPairs: [Pair] = []
    var used = Set<Int>()
    for w in whoopWorkouts {
        guard let whoopS = w.strain else { continue }
        let ref = TimeSpan(start: w.startTs, end: w.endTs, day: w.day)
        var best: (idx: Int, frac: Double)?
        for (i, s) in storedWO.enumerated() where !used.contains(i) {
            let frac = overlapFraction(ref, TimeSpan(start: s.startTs, end: s.endTs, day: w.day))
            if frac >= 0.5, frac > (best?.frac ?? -1) { best = (i, frac) }
        }
        if let best, let stored = storedWO[best.idx].strain, let s21 = strain21(fromStoredEffort100: stored) {
            used.insert(best.idx)
            woPairs.append(Pair(day: w.day, band: s21, whoop: whoopS))
        }
    }
    out.append(agree("stored.workout_strain", woPairs, tolerance: 1.0))
    if cfg.verbose { print("  stored.workout_strain"); printPairs(woPairs, verbose: true) }

    // Sleep stages: Band sleepSession vs WHOOP non-nap sleep, keyed by logical wake day.
    var bandSleep: [String: SleepStageTotals.Minutes] = [:]
    for s in sleeps where s.deviceId == cfg.importedDevice || s.deviceId == cfg.computedDevice {
        let day = DayKey.logical(s.endTs, calendar: cfg.calendar)
        guard let m = SleepStageTotals.minutes(fromStagesJSON: s.stagesJSON) else { continue }
        var cur = bandSleep[day] ?? SleepStageTotals.Minutes()
        cur.awake += m.awake; cur.light += m.light; cur.deep += m.deep; cur.rem += m.rem
        bandSleep[day] = cur
    }
    func stageMap(_ pick: (SleepStageTotals.Minutes) -> Double) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: bandSleep.map { ($0.key, pick($0.value)) })
    }
    add("stored.sleep_light", whoop: wLight, band: stageMap(\.light), tol: 30)
    add("stored.sleep_deep", whoop: wDeep, band: stageMap(\.deep), tol: 20)
    add("stored.sleep_rem", whoop: wRem, band: stageMap(\.rem), tol: 20)
    add("stored.sleep_awake", whoop: wAwake, band: stageMap(\.awake), tol: 20)
    add("stored.sleep_asleep_stages", whoop: wAsleep, band: stageMap(\.asleep), tol: 20)
    add("stored.sleep_inbed_stages", whoop: wInbed, band: stageMap(\.inBed), tol: 25)

    // Imported WHOOP energy_kcal series vs export Energy burned (cal).
    let wEnergy = whoopMap(whoopDays, \.energyKcal)
    var importedEnergy: [String: Double] = [:]
    for row in energySeries where row.deviceId == cfg.importedDevice && row.key == "energy_kcal" {
        importedEnergy[row.day] = row.value
    }
    add("stored_imported.energy", whoop: wEnergy, band: importedEnergy, tol: 1)

    // Export-only replay: Mifflin–St Jeor × cycle duration + Keytel extra on workouts.
    // Inputs are the CSV columns (duration, avg/max HR, RHR, workouts) — no 1 Hz HR.
    let woByDay = Dictionary(grouping: whoopWorkouts, by: \.day)
    var summaryEnergy: [String: Double] = [:]
    for d in whoopDays {
        let bouts = (woByDay[d.day] ?? []).compactMap { w -> Calories.SteadyBout? in
            guard let avg = w.avgHR, w.durationMin > 0 else { return nil }
            return Calories.SteadyBout(durationSec: w.durationMin * 60, avgHR: avg, maxHR: w.maxHR)
        }
        let est = Calories.estimateSummaryEnergy(
            elapsedSeconds: d.durationSec, profile: cfg.profile, hrmax: d.maxHR ?? cfg.hrMax,
            restingHR: d.rhr, workouts: bouts)
        summaryEnergy[d.day] = est.totalKcal
    }
    add("replay.day_calories", whoop: wEnergy, band: summaryEnergy, tol: 400)

    // 1 Hz HR replay on days the phone DB actually has samples.
    var hrEnergy: [String: Double] = [:]
    for (day, samples) in hrByDay {
        let rhr = rhrByDayFromWhoop(whoopDays)[day]
        hrEnergy[day] = Calories.estimateDayCalories(
            samples, profile: cfg.profile, hrmax: cfg.hrMax, restingHR: rhr, elapsedSeconds: 86_400)
    }
    add("replay.day_calories_hr", whoop: wEnergy, band: hrEnergy, tol: 400)

    var kcalPairs: [Pair] = []
    for (i, w) in whoopWorkouts.enumerated() {
        guard let whoopE = w.energyKcal, let avg = w.avgHR, w.durationMin > 0 else { continue }
        let bandE = Calories.estimateSteadyCalories(
            durationSec: w.durationMin * 60, avgHR: avg, profile: cfg.profile,
            hrmax: w.maxHR ?? cfg.hrMax, restingHR: rhrByDayFromWhoop(whoopDays)[w.day])
        kcalPairs.append(Pair(day: w.day + "#\(i)", band: bandE, whoop: whoopE))
    }
    out.append(agree("replay.workout_calories", kcalPairs, tolerance: 80))
    if cfg.verbose { print("  replay.workout_calories"); printPairs(kcalPairs, verbose: true) }

    return (out, verbosePairs)
}

func rhrByDayFromWhoop(_ days: [WhoopDay]) -> [String: Double] {
    whoopMap(days, \.rhr)
}

func detectionChecks(whoopWorkouts: [WhoopWorkout], dbWorkouts: [WorkoutDBRow],
                     hrByDay: [String: [HRSample]], gravByDay: [String: [GravitySample]],
                     rhrByDay: [String: Double], labels: WorkoutLabels = WorkoutLabels(),
                     cfg: CheckConfig) -> [String: MatchStats] {
    var predicted: [TimeSpan] = []
    for (day, hr) in hrByDay.sorted(by: { $0.key < $1.key }) {
        let rhr = rhrByDay[day].map { Int($0.rounded()) }
        let motion = AutoWorkoutDetector.motionPoints(gravByDay[day] ?? [])
        let hits = AutoWorkoutDetector.detect(
            hr: hr.map { (ts: $0.ts, bpm: $0.bpm) },
            restingBpm: rhr,
            motion: motion.isEmpty ? nil : motion,
            savedSpans: [],
            minimumSustainedMinutes: AutoWorkoutDetector.minSustainedMin)
        for h in hits {
            predicted.append(TimeSpan(start: h.startSec, end: h.endSec, day: day))
        }
    }
    let hrDays = Set(hrByDay.keys)
    let whoopRef = whoopWorkouts.filter { hrDays.contains($0.day) }.map {
        TimeSpan(start: $0.startTs, end: $0.endTs, day: $0.day)
    }
    // Reference = Apple Health workouts + manual rows the user entered. Auto-saved rows
    // (detector output stored as manual "Activity", or "-noop" sources) are predictions, not
    // truth, so they are excluded; user-confirmed labels add real spans and veto false ones.
    func day(_ ts: Int) -> String { DayKey.logical(ts, calendar: cfg.calendar) }
    var phoneRef = dbWorkouts.filter {
        ($0.isApple || ($0.isManual && $0.sport.lowercased() != "activity"))
            && !$0.isDetected && hrDays.contains(day($0.startTs))
    }.map { TimeSpan(start: $0.startTs, end: $0.endTs, day: day($0.startTs)) }
    for l in labels.workouts where l.real && hrDays.contains(day(l.startTs)) {
        let span = TimeSpan(start: l.startTs, end: l.endTs, day: day(l.startTs))
        if !phoneRef.contains(where: { spansOverlap($0.start, $0.end, span.start, span.end) }) {
            phoneRef.append(span)
        }
    }
    let vetoes = labels.workouts.filter { !$0.real }
    phoneRef.removeAll { r in vetoes.contains { spansOverlap($0.startTs, $0.endTs, r.start, r.end) } }
    let union = whoopRef + phoneRef
    return [
        "whoop": matchSpans(predicted, whoopRef),
        "phone_apple_manual": matchSpans(predicted, phoneRef),
        "union": matchSpans(predicted, union),
    ]
}

func invariantChecks(daily: [DailyRow], apple: [AppleDailyRow], workouts: [WorkoutDBRow],
                     journal: [JournalDBRow], series: [MetricPointRow],
                     whoopQuestions: [String],
                     hrSpan: (from: Int, to: Int)?,
                     db: ReadOnlyDB,
                     appleHRDir: URL? = nil,
                     cfg: CheckConfig) throws -> [InvariantResult] {
    // Apple Health workout HR lives in JSON files named "<startTs>-<sport>.json" beside the DB.
    let appleHRStarts: Set<Int> = {
        guard let dir = appleHRDir,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return Set(names.compactMap { name -> Int? in
            guard name.hasSuffix(".json"),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path),
                  ((attrs[.size] as? NSNumber)?.intValue ?? 0) > 2 else { return nil }
            return Int(name.split(separator: "-").first ?? "")
        })
    }()
    func hasHR(_ w: WorkoutDBRow) throws -> Bool {
        if appleHRStarts.contains(w.startTs) { return true }
        return try db.workoutHasHR(start: w.startTs, end: w.endTs)
    }
    var results: [InvariantResult] = []

    var strapSteps: [String: Int] = [:]
    for r in daily where r.deviceId == cfg.streamDevice {
        if let s = r.steps, s > 0 { strapSteps[r.day] = s }
    }
    for r in daily where r.deviceId == cfg.computedDevice {
        if let s = r.steps, s > 0 { strapSteps[r.day] = s }
    }
    var appleSteps: [String: Int] = [:]
    for r in apple { if let s = r.steps, s > 0 { appleSteps[r.day] = s } }
    let stepsDays = resolveStepsDays(strapByDay: strapSteps, appleByDay: appleSteps)
    let under = stepsUndercount(stepsDays)
    results.append(InvariantResult(
        name: "steps_undercount", pass: under.isEmpty, failCount: under.count,
        checked: stepsDays.filter { $0.strap != nil && $0.apple != nil }.count,
        note: "strap steps < 10% of Apple Health steps"))
    let unresolved = unresolvedSteps(stepsDays)
    results.append(InvariantResult(
        name: "unresolved_steps", pass: unresolved.isEmpty, failCount: unresolved.count,
        checked: stepsDays.count,
        note: "FusionResolver produced no steps value"))

    let dup = try db.duplicateDailyMetricCounts()
    results.append(InvariantResult(
        name: "duplicate_daily_metric", pass: dup == 0, failCount: dup,
        checked: daily.count, note: "duplicate (deviceId, day) rows"))

    let auto = workouts.filter(\.isDetected)
    let others = workouts.filter { !$0.isDetected }
    let overlaps = autoOverlaps(auto: auto, others: others)
    results.append(InvariantResult(
        name: "auto_workout_overlap", pass: overlaps.isEmpty, failCount: overlaps.count,
        checked: auto.count, note: "auto-saved workouts overlapping another workout"))

    var noHR = 0
    var checkedWO = 0
    if let span = hrSpan {
        for w in workouts {
            let inSpan = spansOverlap(w.startTs, w.endTs, span.from, span.to)
            guard inSpan || w.isDetected || w.isManual else { continue }
            checkedWO += 1
            if !(try hasHR(w)) { noHR += 1 }
        }
    } else {
        for w in workouts where w.isDetected || w.isManual {
            checkedWO += 1
            if !(try hasHR(w)) { noHR += 1 }
        }
    }
    results.append(InvariantResult(
        name: "workouts_without_hr", pass: noHR == 0, failCount: noHR,
        checked: checkedWO, note: "workouts overlapping HR history (or auto/manual) with no HR samples"))

    let questions = journal.map(\.question) + whoopQuestions
    let dups = journalDuplicateTitles(questions)
    results.append(InvariantResult(
        name: "journal_duplicate_titles", pass: dups.isEmpty, failCount: dups.count,
        checked: Set(questions).count,
        note: "distinct question ids folding to the same title key"))

    let vo2 = vo2WithoutApple(series: series, apple: apple)
    results.append(InvariantResult(
        name: "metrics_without_source", pass: vo2.isEmpty, failCount: vo2.count,
        checked: series.filter { $0.key == "vo2max" || $0.key == "vo2max_est" }.count,
        note: "vo2max / vo2max_est in metricSeries with no appleDaily.vo2max"))

    if cfg.verbose {
        for d in under { print("    steps_undercount \(d.day)") }
        for (k, vs) in dups.sorted(by: { $0.key < $1.key }) {
            print("    journal_dup \(k) ← \(vs.joined(separator: " | "))")
        }
        for d in vo2 { print("    vo2_without_apple \(d)") }
        for (a, o) in overlaps {
            print("    auto_overlap start=\(a.startTs) dur=\(a.durationSec)s vs \(o.source) start=\(o.startTs)")
        }
    }
    return results
}

/// Time-in-High with vs without post-workout recovery and walk/run gating.
/// Gated high minutes must not exceed ungated. Prints aggregates only.
func stressGateCheck(hrByDay: [String: [HRSample]],
                     gravByDay: [String: [GravitySample]],
                     stepsByDay: [String: [StepSample]],
                     workouts: [WorkoutDBRow],
                     rhrByDay: [String: Double],
                     cfg: CheckConfig) -> (result: InvariantResult, latest: String) {
    let bucket = BandStress.bucketSeconds
    var checked = 0
    var worse = 0
    var latestNote = "no HR days"
    for (day, hr) in hrByDay.sorted(by: { $0.key < $1.key }) {
        guard !hr.isEmpty else { continue }
        let rhr = rhrByDay[day] ?? BandStress.defaultRestingHR
        let baselines = BandStress.Baselines(wakeRestingHR: rhr, sleepRestingHR: rhr, rmssd: nil)
        let lo = hr.map(\.ts).min()!
        let hi = hr.map(\.ts).max()! + 1
        var mean: [Int: (sum: Double, n: Int)] = [:]
        for s in hr {
            let key = (s.ts / bucket) * bucket
            var e = mean[key] ?? (0, 0)
            e.sum += Double(s.bpm)
            e.n += 1
            mean[key] = e
        }
        let bucketTs = mean.keys.sorted()
        let samples = hr.map { (ts: $0.ts, bpm: Double($0.bpm)) }
        let bouts = workouts.filter { $0.startTs < hi && $0.endTs > lo }.map { (start: $0.startTs, end: $0.endTs) }
        let recovery = BandStress.recoveryWindows(workouts: bouts, samples: samples)
        let steps = (stepsByDay[day] ?? []).compactMap { s -> (ts: Int, activityClass: Int)? in
            guard let cls = s.activityClass else { return nil }
            return (s.ts, cls)
        }
        let motion = AutoWorkoutDetector.motionPoints(gravByDay[day] ?? []).map {
            (ts: $0.ts, intensity: $0.intensity)
        }
        let activity = BandStress.activityBuckets(bucketStarts: bucketTs, steps: steps, motion: motion)
        var ungated: [Double?] = []
        var gated: [Double?] = []
        for ts in bucketTs {
            let bpm = mean[ts]!.sum / Double(mean[ts]!.n)
            let workout = bouts.contains { BandStress.overlaps(bucketTs: ts, start: $0.start, end: $0.end) }
            let rec = recovery.contains { BandStress.overlaps(bucketTs: ts, start: $0.start, end: $0.end) }
            let moving = activity.contains(ts)
            switch BandStress.evaluate(bpm: bpm, isWorkout: workout, isAsleep: false, baselines: baselines) {
            case .value(let v): ungated.append(v)
            default: ungated.append(nil)
            }
            switch BandStress.evaluate(bpm: bpm, isWorkout: workout, isAsleep: false, baselines: baselines,
                                       isActivity: moving, isRecovery: rec) {
            case .value(let v): gated.append(v)
            default: gated.append(nil)
            }
        }
        let u = BandStress.highMinutes(levels: ungated)
        let g = BandStress.highMinutes(levels: gated)
        checked += 1
        if g > u + 0.01 { worse += 1 }
        latestNote = String(format: "%@  ungated_high=%.1f min  gated_high=%.1f min  Δ=%.1f  activity_buckets=%d  recovery_spans=%d",
                            day, u, g, g - u, activity.count, recovery.count)
    }
    let result = InvariantResult(
        name: "stress_activity_gate",
        pass: worse == 0,
        failCount: worse,
        checked: checked,
        note: "gated time-in-High must not exceed workout-only exclusion")
    return (result, latestNote)
}

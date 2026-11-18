import Foundation
import WhoopStore
import StrandAnalytics
import WhoopProtocol

/// Counts what a page open touched so the cache can be measured against the live path.
enum NativeDerivedSeriesMetrics {
    static var lastStressSamples = 0
    static var lastStressFromCache = false
    static var lastOvernightSamples = 0
    static var lastOvernightFromCache = false
    static var lastHourlyStepRows = 0
    static var lastHourlyFromCache = false
}

/// One funnel for the cached display series. Home, Stress, Sleep overnight HR, and
/// hourly steps all read here. The live builder is the same function the cache
/// stores, so the two paths cannot disagree.
enum NativeDerivedSeries {
    struct StressDay: Equatable {
        var hours: [NativeHourPoint]
        var exclusions: [BandStress.ExclusionSpan]
    }

    /// Pure builder. Home and the Stress page used to inline this; the cache
    /// encodes this output, so a round-trip is identity with this function.
    static func computeStress(
        buckets: [HRBucket],
        baselines: BandStress.Baselines,
        sleepStart: Date?,
        sleepEnd: Date?,
        workouts: [(start: Date, end: Date)],
        rr: [(ts: Int, ms: Double)],
        steps: [AutoWorkoutDetector.StepTick],
        gravity: [GravitySample]
    ) -> StressDay {
        let samples = buckets.map { (ts: $0.ts, bpm: $0.bpm) }
        let unixBouts = workouts.map {
            (start: Int($0.start.timeIntervalSince1970), end: Int($0.end.timeIntervalSince1970))
        }
        let recovery = BandStress.recoveryWindows(workouts: unixBouts, samples: samples)
        let motion = AutoWorkoutDetector.motionPoints(gravity)
        let activity = BandStress.activityBuckets(
            bucketStarts: buckets.map(\.ts),
            steps: steps.map { (ts: $0.ts, activityClass: $0.activityClass) },
            motion: motion.map { (ts: $0.ts, intensity: $0.intensity) }
        )
        let rmssd = BandStress.rmssdByBucket(rr: rr)
        let timeline = NativeHomeCharts.stressTimeline(
            buckets: buckets,
            baselines: baselines,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            workouts: workouts,
            rmssdByBucket: rmssd,
            activityBuckets: activity,
            recovery: recovery
        )
        return StressDay(hours: timeline.hours, exclusions: timeline.exclusions)
    }

    static func stressDay(
        repo: Repository,
        dayKey: String,
        dayStart: Date,
        days: [DailyMetric],
        sleeps: [CachedSleepSession],
        workouts: [WorkoutRow],
        calendar: Calendar = .current,
        force: Bool = false
    ) async -> StressDay {
        let inputs = stressInputs(dayKey: dayKey, days: days, sleeps: sleeps, workouts: workouts)
        let sleepStart = inputs.sleepStart
        let sleepEnd = inputs.sleepEnd
        let bouts = inputs.bouts
        let baselines = inputs.baselines
        let from = Int(calendar.startOfDay(for: dayStart).timeIntervalSince1970)
        let to = from + 86_400
        // Today's HR frontier belongs in the fingerprint: a 7:15 AM cache must miss at 9:50 AM
        // when new samples arrive. Historical days stay O(1) once fetched.
        let liveDay = dayKey == NativeDayLogic.logicalToday()
        var buckets: [HRBucket] = []
        var fingerprint = inputs.fingerprint
        if liveDay {
            buckets = await repo.hrSamples(from: from, to: to, bucketSeconds: BandStress.bucketSeconds)
            fingerprint += "|\(stressLiveHRFingerprint(bucketCount: buckets.count, lastTs: buckets.last?.ts ?? 0))"
        }
        if !force, let cached = await readStress(repo: repo, dayKey: dayKey, fingerprint: fingerprint) {
            NativeDerivedSeriesMetrics.lastStressFromCache = true
            NativeDerivedSeriesMetrics.lastStressSamples = 0
            return cached
        }
        if !liveDay {
            buckets = await repo.hrSamples(from: from, to: to, bucketSeconds: BandStress.bucketSeconds)
        }
        if Task.isCancelled { return StressDay(hours: [], exclusions: []) }
        let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
        if Task.isCancelled { return StressDay(hours: [], exclusions: []) }
        let ticks = await repo.stepTicks(from: from, to: to)
        if Task.isCancelled { return StressDay(hours: [], exclusions: []) }
        let grav = await repo.gravitySamplesUnion(from: from, to: to)
        if Task.isCancelled { return StressDay(hours: [], exclusions: []) }
        NativeDerivedSeriesMetrics.lastStressFromCache = false
        NativeDerivedSeriesMetrics.lastStressSamples = buckets.count
        let rrPairs = rr.map { (ts: $0.ts, ms: Double($0.rrMs)) }
        let built = await Task.detached(priority: .utility) {
            computeStress(
                buckets: buckets, baselines: baselines, sleepStart: sleepStart, sleepEnd: sleepEnd,
                workouts: bouts, rr: rrPairs, steps: ticks, gravity: grav
            )
        }.value
        await writeStress(repo: repo, dayKey: dayKey, fingerprint: fingerprint, day: built)
        return built
    }

    static func overnightHeart(
        repo: Repository,
        start: Date,
        end: Date,
        dayKey: String,
        force: Bool = false
    ) async -> NativeOvernightHeart.Model {
        let from = Int(start.timeIntervalSince1970)
        let to = Int(end.timeIntervalSince1970)
        let fingerprint = DerivedSeriesCodec.overnightFingerprint(startTs: from, endTs: to)
        if !force, let cached = await readOvernight(repo: repo, dayKey: dayKey, fingerprint: fingerprint) {
            NativeDerivedSeriesMetrics.lastOvernightFromCache = true
            NativeDerivedSeriesMetrics.lastOvernightSamples = 0
            return cached
        }
        let samples = await repo.hrSamples(from: from, to: to, limit: 200_000)
        if Task.isCancelled {
            return NativeOvernightHeart.Model(points: [], average: nil, rawCount: 0)
        }
        NativeDerivedSeriesMetrics.lastOvernightFromCache = false
        NativeDerivedSeriesMetrics.lastOvernightSamples = samples.count
        let model = await Task.detached(priority: .utility) {
            NativeOvernightHeart.make(samples: samples)
        }.value
        await writeOvernight(repo: repo, dayKey: dayKey, fingerprint: fingerprint, model: model)
        return model
    }

    static func hourlySteps(
        repo: Repository,
        dayKey: String,
        dayStart: Date,
        mergedDaily: Double?,
        calendar: Calendar = .current,
        force: Bool = false
    ) async -> [NativeHourPoint] {
        let start = calendar.startOfDay(for: dayStart)
        let from = Int(start.timeIntervalSince1970)
        let appleHours = await repo.appleStepHours(from: from, to: from + 86_400 - 1)
        let appleSum = appleHours.reduce(0) { $0 + $1.steps }
        let appleDaily = (await repo.appleDailyRows(days: 3)).first { $0.day == dayKey }?.steps
        let merged = mergedDaily.map { Int($0.rounded()) }
        let preferApple = NativeResolvedSteps.preferAppleHours(
            appleSum: appleSum, appleDaily: appleDaily, mergedDaily: merged
        )
        let fingerprint = DerivedSeriesCodec.hourlyStepsFingerprint(
            preferApple: preferApple, appleSum: appleSum, mergedDaily: merged
        )
        if !force, let cached = await readHourlySteps(
            repo: repo, dayKey: dayKey, fingerprint: fingerprint, calendar: calendar
        ) {
            NativeDerivedSeriesMetrics.lastHourlyFromCache = true
            NativeDerivedSeriesMetrics.lastHourlyStepRows = 0
            return cached
        }
        NativeDerivedSeriesMetrics.lastHourlyFromCache = false
        NativeDerivedSeriesMetrics.lastHourlyStepRows = appleHours.count
        let points = NativeResolvedSteps.hourPoints(
            appleHours: appleHours, dayStart: start, calendar: calendar, preferApple: preferApple
        )
        await writeHourlySteps(
            repo: repo, dayKey: dayKey, fingerprint: fingerprint,
            dayStartTs: from, points: points
        )
        return points
    }

    /// After `analyzeRecent`, for days whose inputs changed plus today. Off the
    /// caller's actor: each kind's heavy builder already runs in `Task.detached`.
    static func fill(repo: Repository, dayKeys: [String], todayKey: String,
                     calendar: Calendar = .current) async {
        let days = await repo.days
        let sleeps = await repo.sleeps
        let workouts = await repo.workoutRows(days: 40)
        for key in dayKeys {
            guard let dayDate = NativeScopeSeries.date(from: key, calendar: calendar) else { continue }
            let start = calendar.startOfDay(for: dayDate)
            let force = key == todayKey
            _ = await stressDay(
                repo: repo, dayKey: key, dayStart: start, days: days,
                sleeps: sleeps, workouts: workouts, calendar: calendar, force: force
            )
            if let sleep = sleeps.last(where: {
                NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == key
            }) {
                let sleepStart = Date(timeIntervalSince1970: TimeInterval(sleep.effectiveStartTs))
                let sleepEnd = Date(timeIntervalSince1970: TimeInterval(sleep.endTs))
                _ = await overnightHeart(
                    repo: repo, start: sleepStart, end: sleepEnd, dayKey: key, force: force
                )
            }
            let merged = days.last { $0.day == key }?.steps.map(Double.init)
            _ = await hourlySteps(
                repo: repo, dayKey: key, dayStart: start, mergedDaily: merged,
                calendar: calendar, force: force
            )
        }
    }

    private struct StressInputs {
        var sleepStart: Date?
        var sleepEnd: Date?
        var bouts: [(start: Date, end: Date)]
        var baselines: BandStress.Baselines
        var fingerprint: String
    }

    private static func stressInputs(
        dayKey: String,
        days: [DailyMetric],
        sleeps: [CachedSleepSession],
        workouts: [WorkoutRow]
    ) -> StressInputs {
        let sleep = sleeps.last {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == dayKey
        }
        let sleepStart = sleep.map { Date(timeIntervalSince1970: TimeInterval($0.effectiveStartTs)) }
        let sleepEnd = sleep.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) }
        let bouts: [(start: Date, end: Date)] = workouts.compactMap { row in
            let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
            guard NativeDayLogic.sleepSessionDayKey(start) == dayKey else { return nil }
            return (start, Date(timeIntervalSince1970: TimeInterval(row.endTs)))
        }
        let baselines = NativeHomeCharts.stressBaselines(days: days, todayKey: dayKey)
        let fingerprint = DerivedSeriesCodec.stressFingerprint(
            sleepStartTs: sleepStart.map { Int($0.timeIntervalSince1970) },
            sleepEndTs: sleepEnd.map { Int($0.timeIntervalSince1970) },
            workouts: bouts.map { (Int($0.start.timeIntervalSince1970), Int($0.end.timeIntervalSince1970)) },
            wakeRestingHR: baselines.wakeRestingHR,
            sleepRestingHR: baselines.sleepRestingHR,
            rmssd: baselines.rmssd
        ) + "|\(stressCalibrationTag)"
        return StressInputs(
            sleepStart: sleepStart, sleepEnd: sleepEnd, bouts: bouts,
            baselines: baselines, fingerprint: fingerprint
        )
    }

    /// Busts cached minute-stress after the orthostatic waking floor / walking hold landed.
    static let stressCalibrationTag =
        "ortho:\(Int(NativeHomeCharts.wakeOrthostaticBPM)):\(Int(NativeHomeCharts.sleepOrthostaticBPM))"

    static func stressLiveHRFingerprint(bucketCount: Int, lastTs: Int) -> String {
        "hr:\(bucketCount):\(lastTs)"
    }

    // MARK: - Cache I/O

    private static func readStress(repo: Repository, dayKey: String, fingerprint: String) async -> StressDay? {
        guard let row = await repo.derivedSeries(
            kind: DerivedSeriesCodec.stressMinuteKind, day: dayKey,
            version: DerivedSeriesCodec.stressMinuteVersion
        ), let payload = DerivedSeriesCodec.decodeStress(row.payload),
              payload.fingerprint == fingerprint else { return nil }
        let hours = payload.points.map {
            NativeHourPoint(time: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.value)
        }
        return StressDay(hours: hours, exclusions: payload.exclusions)
    }

    private static func writeStress(repo: Repository, dayKey: String, fingerprint: String, day: StressDay) async {
        let payload = DerivedSeriesCodec.encodeStress(DerivedSeriesCodec.StressPayload(
            fingerprint: fingerprint,
            points: day.hours.map {
                DerivedSeriesCodec.Point(ts: Int($0.time.timeIntervalSince1970), value: $0.value)
            },
            exclusions: day.exclusions
        ))
        await repo.upsertDerivedSeries(DerivedSeriesRow(
            kind: DerivedSeriesCodec.stressMinuteKind, day: dayKey,
            version: DerivedSeriesCodec.stressMinuteVersion,
            computedAt: Int(Date().timeIntervalSince1970), payload: payload
        ))
    }

    private static func readOvernight(repo: Repository, dayKey: String, fingerprint: String) async -> NativeOvernightHeart.Model? {
        guard let row = await repo.derivedSeries(
            kind: DerivedSeriesCodec.overnightHRKind, day: dayKey,
            version: DerivedSeriesCodec.overnightHRVersion
        ), let payload = DerivedSeriesCodec.decodeOvernight(row.payload),
              payload.fingerprint == fingerprint else { return nil }
        let points = payload.points.map {
            NativeHourPoint(time: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.value)
        }
        return NativeOvernightHeart.Model(points: points, average: payload.average, rawCount: payload.rawCount)
    }

    private static func writeOvernight(repo: Repository, dayKey: String, fingerprint: String,
                                       model: NativeOvernightHeart.Model) async {
        let payload = DerivedSeriesCodec.encodeOvernight(DerivedSeriesCodec.OvernightPayload(
            fingerprint: fingerprint,
            points: model.points.map {
                DerivedSeriesCodec.Point(ts: Int($0.time.timeIntervalSince1970), value: $0.value)
            },
            average: model.average,
            rawCount: model.rawCount
        ))
        await repo.upsertDerivedSeries(DerivedSeriesRow(
            kind: DerivedSeriesCodec.overnightHRKind, day: dayKey,
            version: DerivedSeriesCodec.overnightHRVersion,
            computedAt: Int(Date().timeIntervalSince1970), payload: payload
        ))
    }

    private static func readHourlySteps(repo: Repository, dayKey: String, fingerprint: String,
                                        calendar: Calendar) async -> [NativeHourPoint]? {
        guard let row = await repo.derivedSeries(
            kind: DerivedSeriesCodec.hourlyStepsKind, day: dayKey,
            version: DerivedSeriesCodec.hourlyStepsVersion
        ), let payload = DerivedSeriesCodec.decodeHourlySteps(row.payload),
              payload.fingerprint == fingerprint else { return nil }
        let start = Date(timeIntervalSince1970: TimeInterval(payload.dayStartTs))
        return payload.hours.enumerated().map { hour, value in
            let time = calendar.date(byAdding: .hour, value: hour, to: start) ?? start
            return NativeHourPoint(time: time, value: value)
        }
    }

    private static func writeHourlySteps(repo: Repository, dayKey: String, fingerprint: String,
                                         dayStartTs: Int, points: [NativeHourPoint]) async {
        let payload = DerivedSeriesCodec.encodeHourlySteps(DerivedSeriesCodec.HourlyStepsPayload(
            fingerprint: fingerprint,
            dayStartTs: dayStartTs,
            hours: points.map(\.value)
        ))
        await repo.upsertDerivedSeries(DerivedSeriesRow(
            kind: DerivedSeriesCodec.hourlyStepsKind, day: dayKey,
            version: DerivedSeriesCodec.hourlyStepsVersion,
            computedAt: Int(Date().timeIntervalSince1970), payload: payload
        ))
    }
}

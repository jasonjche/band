import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Old-vs-new bit-identity (or 1e-12 where summation order changes) for derived-series opts.
final class DerivedSeriesEquivalenceTests: XCTestCase {

    func testRmssdByBucketMatchesLegacy() {
        let cases: [[(ts: Int, ms: Double)]] = [
            [],
            [(0, 800)],
            (0..<10).map { (ts: 1_000 + $0, ms: 800) },
            (0..<40).map { (ts: 1_200 + $0, ms: 800 + Double($0 % 3) * 10) },
            shuffledRR(count: 2_000, dayStart: 1_700_000_000, seed: 1),
            shuffledRR(count: 5_000, dayStart: 1_700_000_000, seed: 2),
            gappedRR(),
        ]
        for rr in cases {
            let got = BandStress.rmssdByBucket(rr: rr)
            let old = legacyRmssdByBucket(rr: rr)
            XCTAssertEqual(got.keys.sorted(), old.keys.sorted())
            for key in got.keys {
                XCTAssertEqual(got[key]!, old[key]!, accuracy: 1e-12)
            }
        }
    }

    func testRecoveryWindowsMatchesLegacy() {
        let samples = (0..<1_440).map { i -> (ts: Int, bpm: Double) in
            (1_700_000_000 + i * 60, 60 + Double(i % 40))
        }
        let workouts: [[(start: Int, end: Int)]] = [
            [],
            [(1_700_000_000 + 7 * 3600, 1_700_000_000 + 7 * 3600 + 2400)],
            overlappingWorkouts(),
            sixWorkouts(),
        ]
        for bouts in workouts {
            let got = BandStress.recoveryWindows(workouts: bouts, samples: samples)
            let old = bouts.compactMap {
                legacyRecoveryWindow(workoutStart: $0.start, workoutEnd: $0.end, samples: samples)
            }
            XCTAssertEqual(got.count, old.count)
            for (a, b) in zip(got, old) {
                XCTAssertEqual(a.start, b.start)
                XCTAssertEqual(a.end, b.end)
            }
        }
        XCTAssertNil(BandStress.recoveryWindow(workoutStart: 10, workoutEnd: 10, samples: samples))
        XCTAssertTrue(BandStress.recoveryWindows(workouts: [], samples: []).isEmpty)
    }

    func testSmoothCenteredMatchesLegacy() {
        let t0 = 10_000
        let full = (0..<1_440).map { (ts: t0 + $0 * 60, value: Double($0 % 5)) }
        let hole = (0..<3).map { (ts: t0 + $0 * 60, value: 1.0) }
            + (0..<3).map { (ts: t0 + 5 * 60 + $0 * 60, value: 2.0) }
        let single = [(ts: t0, value: 1.5)]
        let empty: [(ts: Int, value: Double)] = []
        let unsorted = [(ts: t0 + 120, value: 3.0), (ts: t0, value: 1.0), (ts: t0 + 60, value: 2.0)]
        for points in [full, hole, single, empty, unsorted] {
            for radius in [1, 2, 7] {
                let got = BandStress.smoothCentered(points: points, radius: radius)
                let old = legacySmoothCentered(points: points, radius: radius)
                XCTAssertEqual(got.count, old.count)
                for (a, b) in zip(got, old) {
                    XCTAssertEqual(a.ts, b.ts)
                    XCTAssertEqual(a.value, b.value, accuracy: 1e-12)
                }
            }
        }
    }

    func testTimelineMatchesLegacy() {
        let t0 = 1_700_000_000
        let buckets = (0..<1_440).map { i -> (ts: Int, bpm: Double) in
            (t0 + i * 60, 55 + Double(i % 50) * 0.3)
        }
        let workouts = sixWorkouts()
        let recovery = BandStress.recoveryWindows(workouts: workouts, samples: buckets)
        let activity = Set((0..<40).map { t0 + (700 + $0) * 60 })
        var rmssd: [Int: Double] = [:]
        for i in 0..<200 { rmssd[t0 + i * 60] = 40 + Double(i % 9) }
        let got = BandStress.timeline(
            buckets: buckets, baselines: .fallback,
            sleepStart: t0, sleepEnd: t0 + 8 * 3600,
            workouts: workouts, rmssdByBucket: rmssd,
            activityBuckets: activity, recovery: recovery, smoothRadius: 7
        )
        let old = legacyTimeline(
            buckets: buckets, baselines: .fallback,
            sleepStart: t0, sleepEnd: t0 + 8 * 3600,
            workouts: workouts, rmssdByBucket: rmssd,
            activityBuckets: activity, recovery: recovery, smoothRadius: 7
        )
        XCTAssertEqual(got.hours.count, old.hours.count)
        for (a, b) in zip(got.hours, old.hours) {
            XCTAssertEqual(a.ts, b.ts)
            XCTAssertEqual(a.value, b.value, accuracy: 1e-12)
        }
        XCTAssertEqual(got.exclusions, old.exclusions)

        let empty = BandStress.timeline(
            buckets: [], baselines: .fallback, sleepStart: nil, sleepEnd: nil, workouts: []
        )
        XCTAssertTrue(empty.hours.isEmpty)
        XCTAssertTrue(empty.exclusions.isEmpty)

        let one = BandStress.timeline(
            buckets: [(t0, 70)], baselines: .fallback, sleepStart: nil, sleepEnd: nil,
            workouts: [(t0 - 30, t0 + 90)]
        )
        XCTAssertEqual(one.hours.count, 1)
        XCTAssertEqual(one.exclusions.first?.kind, .workout)
    }

    func testHRVTrendMatchesLegacy() {
        let nights = (0..<90).map { i -> HRVTrend.Night in
            let key = HealthspanEngine.isoString(HealthspanEngine.isoEpochDay("2024-01-01")! + i)!
            let ms: Double? = i % 11 == 0 ? nil : 40 + Double(i % 17)
            return HRVTrend.Night(day: key, rmssdMs: ms)
        }
        let got = HRVTrend.evaluate(nights: nights)
        let old = legacyHRVTrend(nights: nights)
        XCTAssertEqual(got.count, old.count)
        for (a, b) in zip(got, old) {
            XCTAssertEqual(a.day, b.day)
            XCTAssertEqual(a.state, b.state)
            XCTAssertEqual(a.trendNights, b.trendNights)
            XCTAssertEqual(a.baselineNights, b.baselineNights)
            assertOptional(a.trendLn, b.trendLn)
            assertOptional(a.baselineLn, b.baselineLn)
            assertOptional(a.swc, b.swc)
            assertOptional(a.trendCV, b.trendCV)
        }
        XCTAssertTrue(HRVTrend.evaluate(nights: []).isEmpty)
        let dup = HRVTrend.evaluate(nights: [
            .init(day: "2024-03-10", rmssdMs: 40),
            .init(day: "2024-03-01", rmssdMs: 60),
            .init(day: "2024-03-10", rmssdMs: 70),
        ])
        XCTAssertEqual(dup.map(\.day), ["2024-03-01", "2024-03-10"])
        XCTAssertEqual(dup.last?.rmssdMs, 70)
    }

    func testHealthspanSummarizeAndTrendMatchLegacy() {
        let end = HealthspanEngine.isoEpochDay("2026-11-14")!
        var days: [HealthspanEngine.Day] = []
        for i in 0..<180 {
            let key = HealthspanEngine.isoString(end - (179 - i))!
            days.append(.init(
                day: key, sleepHours: 7.0 + Double(i % 4) * 0.1,
                sleepOnsetMin: 23 * 60, sleepWakeMin: 7 * 60,
                steps: 8_000, restingHR: 58, vo2max: 47,
                zone13Min: 20, zone45Min: 2, strengthMin: i % 7 == 0 ? 40 : 0
            ))
        }
        let filled = HealthspanEngine.fillingConsistency(days)
        let six = HealthspanEngine.summarize(filled, ending: "2026-11-14", windowDays: 180)
        let oldSix = legacySummarize(filled, ending: "2026-11-14", windowDays: 180)
        assertWindow(six, oldSix)

        let profile = HealthspanEngine.Profile(chronoAge: 30, sex: "male")
        let got = HealthspanEngine.trendPoints(days: filled, profile: profile, asOfDay: "2026-11-14")
        let old = legacyTrendPoints(days: filled, profile: profile, asOfDay: "2026-11-14")
        XCTAssertEqual(got.count, old.count)
        for (a, b) in zip(got, old) {
            XCTAssertEqual(a.day, b.day)
            XCTAssertEqual(a.bandAge, b.bandAge, accuracy: 1e-12)
            XCTAssertEqual(a.chronoAge, b.chronoAge, accuracy: 1e-12)
            assertOptional(a.pace, b.pace)
        }
        XCTAssertTrue(HealthspanEngine.summarize([], ending: "2026-11-14", windowDays: 180).daysWithData == 0)
    }

    func testDisplaySeriesSmoothAndDownsampleMatchLegacy() {
        let hz = (0..<3_600).map { i -> (ts: Int, value: Double) in
            (1_700_000_000 + i, 60 + Double(i % 17))
        }
        let got = DisplaySeries.smooth(hz, window: 45)
        let old = legacySmooth(hz, window: 45)
        XCTAssertEqual(got.count, old.count)
        for (a, b) in zip(got, old) {
            XCTAssertEqual(a.ts, b.ts)
            XCTAssertEqual(a.value, b.value, accuracy: 1e-12)
        }
        let down = DisplaySeries.downsample(hz, maxPoints: 300)
        let oldDown = legacyDownsample(hz, maxPoints: 300)
        XCTAssertEqual(down.count, oldDown.count)
        for (a, b) in zip(down, oldDown) {
            XCTAssertEqual(a.ts, b.ts)
            XCTAssertEqual(a.value, b.value, accuracy: 1e-12)
        }
        XCTAssertEqual(DisplaySeries.smooth([(0, 1), (1, 2)], window: 45).count, 2)
        XCTAssertTrue(DisplaySeries.downsample([], maxPoints: 300).isEmpty)
    }

    func testHRVCleanMatchesForRandomAndEdges() {
        let series: [[Double]] = [
            [],
            [800],
            Array(repeating: 800, count: 19),
            Array(repeating: 800, count: 30),
            (0..<200).map { 700 + Double($0 % 13) * 8 },
            spikeSeries(),
        ]
        for rr in series {
            let a = HRVAnalyzer.cleanRR(rr)
            let b = HRVAnalyzer.cleanRRGapAware(rr).nn
            XCTAssertEqual(a, b)
            let result = HRVAnalyzer.analyze(rawRR: rr)
            if rr.count >= 20 {
                XCTAssertEqual(result.nInput, rr.count)
            }
        }
        let rr = (0..<400).map { RRInterval(ts: 1_000 + $0, rrMs: 800 + ($0 % 7) * 5) }
        let rolling = HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 60, stepSec: 10, minBeatsPerWindow: 8)
        XCTAssertFalse(rolling.isEmpty)
    }

    func testPerformanceAssessmentHistoryStable() {
        var recovery: [String: Double] = [:]
        var strain: [String: Double] = [:]
        let end = HealthspanEngine.isoEpochDay("2026-11-14")!
        for i in 0..<120 {
            let key = HealthspanEngine.isoString(end - (119 - i))!
            recovery[key] = 50 + Double(i % 20)
            strain[key] = 8 + Double(i % 6)
        }
        let series = PerformanceAssessment.Series(recovery: recovery, strain21: strain)
        let windows = PerformanceAssessment.historyWindows(kind: .weekly, asOfDay: "2026-11-14", limit: 8)
        XCTAssertEqual(windows.count, 8)
        let reports = windows.map { PerformanceAssessment.build(window: $0, series: series) }
        XCTAssertEqual(reports.count, 8)
        XCTAssertEqual(reports[0].window.start, windows[0].start)
    }

    // MARK: - Legacy (pre-opt) implementations

    private func legacyRmssdByBucket(rr: [(ts: Int, ms: Double)], bucketSeconds: Int = 60) -> [Int: Double] {
        guard bucketSeconds > 0 else { return [:] }
        var groups: [Int: [Double]] = [:]
        for sample in rr {
            let key = BandStress.floorDiv(sample.ts, bucketSeconds) * bucketSeconds
            groups[key, default: []].append(sample.ms)
        }
        var out: [Int: Double] = [:]
        for (key, values) in groups {
            if let rmssd = HRVAnalyzer.analyze(rawRR: values).rmssd {
                out[key] = rmssd
            }
        }
        return out
    }

    private func legacyRecoveryWindow(workoutStart: Int, workoutEnd: Int,
                                      samples: [(ts: Int, bpm: Double)]) -> (start: Int, end: Int)? {
        guard workoutEnd > workoutStart else { return nil }
        let preLo = workoutStart - 10 * 60
        let pre = samples.filter { $0.ts >= preLo && $0.ts < workoutStart }.map(\.bpm)
        let during = samples.filter { $0.ts >= workoutStart && $0.ts < workoutEnd }.map(\.bpm)
        let preMean = BandStress.average(pre)
        let boutMean = BandStress.average(during) ?? preMean
        let excess = max(0, (boutMean ?? 0) - (preMean ?? 0))
        let scaled = Int((excess / max(BandStress.recoveryReturnBPM, 1)) * 1_800)
        let cap = min(BandStress.recoveryMaxSeconds,
                      max(BandStress.recoveryMinSeconds, scaled == 0 ? BandStress.recoveryMinSeconds : scaled))
        let capEnd = workoutEnd + cap
        guard let preMean else { return (workoutEnd, capEnd) }
        let threshold = preMean + BandStress.recoveryReturnBPM
        let after = samples.filter { $0.ts >= workoutEnd && $0.ts <= capEnd }.sorted { $0.ts < $1.ts }
        if let hit = after.first(where: { $0.bpm <= threshold }) {
            return (workoutEnd, max(workoutEnd, hit.ts))
        }
        return (workoutEnd, capEnd)
    }

    private func legacySmoothCentered(
        points: [(ts: Int, value: Double)], bucketSeconds: Int = 60, radius: Int
    ) -> [(ts: Int, value: Double)] {
        guard radius > 0, bucketSeconds > 0, points.count > 1 else { return points }
        let sorted = points.sorted { $0.ts < $1.ts }
        var out: [(ts: Int, value: Double)] = []
        var i = 0
        while i < sorted.count {
            var j = i + 1
            while j < sorted.count, sorted[j].ts - sorted[j - 1].ts == bucketSeconds { j += 1 }
            let run = Array(sorted[i..<j])
            if run.count == 1 {
                out.append(run[0])
            } else {
                for k in run.indices {
                    let lo = max(0, k - radius)
                    let hi = min(run.count - 1, k + radius)
                    var sum = 0.0
                    var n = 0
                    for m in lo...hi {
                        sum += run[m].value
                        n += 1
                    }
                    out.append((run[k].ts, n > 0 ? sum / Double(n) : run[k].value))
                }
            }
            i = j
        }
        return out
    }

    private func legacyTimeline(
        buckets: [(ts: Int, bpm: Double)],
        baselines: BandStress.Baselines,
        sleepStart: Int?,
        sleepEnd: Int?,
        workouts: [(start: Int, end: Int)],
        rmssdByBucket: [Int: Double],
        activityBuckets: Set<Int>,
        recovery: [(start: Int, end: Int)],
        smoothRadius: Int
    ) -> (hours: [(ts: Int, value: Double)], exclusions: [BandStress.ExclusionSpan]) {
        var exclusions: [BandStress.ExclusionSpan] = []
        for bout in workouts where bout.end > bout.start {
            exclusions.append(.init(startTs: bout.start, endTs: bout.end, kind: .workout))
        }
        for window in recovery where window.end > window.start {
            exclusions.append(.init(startTs: window.start, endTs: window.end, kind: .recovery))
        }
        exclusions.append(contentsOf: BandStress.mergeSpans(BandStress.spans(fromBuckets: activityBuckets)))
        var scored: [(ts: Int, value: Double)] = []
        for bucket in buckets {
            let asleep: Bool = {
                guard let sleepStart, let sleepEnd else { return false }
                return BandStress.overlaps(bucketTs: bucket.ts, start: sleepStart, end: sleepEnd)
            }()
            let workout = workouts.contains {
                BandStress.overlaps(bucketTs: bucket.ts, start: $0.start, end: $0.end)
            }
            let recovering = recovery.contains {
                BandStress.overlaps(bucketTs: bucket.ts, start: $0.start, end: $0.end)
            }
            let moving = activityBuckets.contains(bucket.ts)
            switch BandStress.evaluate(
                bpm: bucket.bpm, rmssd: rmssdByBucket[bucket.ts],
                isWorkout: workout, isAsleep: asleep, baselines: baselines,
                isActivity: moving, isRecovery: recovering
            ) {
            case .value(let value):
                scored.append((bucket.ts, value))
            case .excluded:
                scored.append((bucket.ts, BandStress.score(
                    bpm: bucket.bpm, rmssd: rmssdByBucket[bucket.ts],
                    isAsleep: asleep, baselines: baselines
                )))
            case .gap:
                break
            }
        }
        return (BandStress.smoothCentered(points: scored, radius: smoothRadius), exclusions)
    }

    private func legacyHRVTrend(nights: [HRVTrend.Night]) -> [HRVTrend.DayResult] {
        var seen: [String: HRVTrend.Night] = [:]
        for n in nights { seen[n.day] = n }
        let ordered = seen.values.sorted { $0.day < $1.day }
        var byDay: [String: Double] = [:]
        for n in ordered {
            if let ln = HRVTrend.lnRmssd(n.rmssdMs) { byDay[n.day] = ln }
        }
        return ordered.map { night in
            legacyHRVResult(day: night.day, rmssdMs: night.rmssdMs, lnByDay: byDay)
        }
    }

    private func legacyHRVResult(day: String, rmssdMs: Double?, lnByDay: [String: Double]) -> HRVTrend.DayResult {
        func windowValues(days: Int) -> [Double] {
            var vals: [Double] = []
            for offset in (1 - days)...0 {
                guard let key = BandDayKey.addDays(day, offset), let v = lnByDay[key] else { continue }
                vals.append(v)
            }
            return vals
        }
        let trendVals = windowValues(days: 7)
        let baseVals = windowValues(days: 60)
        let trendN = trendVals.count
        let baseN = baseVals.count
        let trendLn = HRVTrend.mean(trendVals)
        let baselineLn = HRVTrend.mean(baseVals)
        let trendCV = HRVTrend.coefficientOfVariation(trendVals)
        guard trendN >= 3, baseN >= 30,
              let trendLn, let baselineLn, let sd = HRVTrend.sampleSD(baseVals) else {
            return HRVTrend.DayResult(
                day: day, trendLn: trendLn, baselineLn: baselineLn, swc: nil,
                bandLow: nil, bandHigh: nil, state: .building, trendCV: trendCV,
                trendNights: trendN, baselineNights: baseN, rmssdMs: rmssdMs
            )
        }
        let swc = 0.5 * sd
        let low = baselineLn - swc
        let high = baselineLn + swc
        let state: HRVTrend.State
        if !sd.isFinite || sd < 1e-12 {
            state = .withinNormal
        } else if trendLn < low {
            state = .trendingBelow
        } else if trendLn > high {
            state = .trendingAbove
        } else {
            state = .withinNormal
        }
        return HRVTrend.DayResult(
            day: day, trendLn: trendLn, baselineLn: baselineLn, swc: swc,
            bandLow: low, bandHigh: high, state: state, trendCV: trendCV,
            trendNights: trendN, baselineNights: baseN, rmssdMs: rmssdMs
        )
    }

    private func legacySummarize(_ days: [HealthspanEngine.Day], ending: String, windowDays: Int)
        -> HealthspanEngine.Window {
        guard windowDays > 0, let endEpoch = HealthspanEngine.isoEpochDay(ending) else {
            return HealthspanEngine.Window()
        }
        let startEpoch = endEpoch - (windowDays - 1)
        let slice = days.filter { day in
            guard let e = HealthspanEngine.isoEpochDay(day.day) else { return false }
            return e >= startEpoch && e <= endEpoch
        }
        let weeks = Double(windowDays) / 7.0
        let sleepHours = mean(slice.compactMap(\.sleepHours))
        let consistency: Double?
        let precomputed = slice.compactMap(\.sleepConsistency)
        if precomputed.count >= 3 {
            consistency = mean(precomputed)
        } else {
            let clocks: [(Int, Int)] = slice.compactMap {
                guard let a = $0.sleepOnsetMin, let b = $0.sleepWakeMin else { return nil }
                return (a, b)
            }
            let mapped = HealthspanEngine.sleepConsistency(nights: clocks).filter { $0.isFinite }
            consistency = mapped.count >= 3 ? mean(mapped) : nil
        }
        let z13 = sum(slice.compactMap(\.zone13Min))
        let z45 = sum(slice.compactMap(\.zone45Min))
        let strength = sum(slice.compactMap(\.strengthMin))
        let used = Set(slice.compactMap { d -> String? in
            if d.sleepHours != nil || d.restingHR != nil || d.steps != nil
                || d.zone13Min != nil || d.vo2max != nil { return d.day }
            return nil
        })
        return HealthspanEngine.Window(
            sleepHours: sleepHours,
            sleepConsistency: consistency,
            weeklyZone13Min: z13 > 0 ? z13 / weeks : nil,
            weeklyZone45Min: z45 > 0 ? z45 / weeks : nil,
            weeklyStrengthMin: strength > 0 ? strength / weeks : nil,
            dailySteps: mean(slice.compactMap(\.steps)),
            restingHR: mean(slice.compactMap(\.restingHR)),
            vo2max: mean(slice.compactMap(\.vo2max)),
            leanMassPct: mean(slice.compactMap(\.leanMassPct)),
            daysWithData: used.count
        )
    }

    private func legacyTrendPoints(days: [HealthspanEngine.Day], profile: HealthspanEngine.Profile,
                                   asOfDay: String) -> [HealthspanEngine.TrendPoint] {
        guard let end = HealthspanEngine.isoEpochDay(asOfDay) else { return [] }
        var points: [HealthspanEngine.TrendPoint] = []
        var cursor = end
        let oldest = days.compactMap { HealthspanEngine.isoEpochDay($0.day) }.min() ?? end
        let start = max(oldest + 21, end - 180)
        while cursor >= start {
            guard let key = HealthspanEngine.isoString(cursor) else { break }
            let six = legacySummarize(days, ending: key, windowDays: 180)
            let thirty = legacySummarize(days, ending: key, windowDays: 30)
            let ageThen = profile.chronoAge - Double(end - cursor) / 365.25
            let r = HealthspanEngine.compute(
                profile: HealthspanEngine.Profile(chronoAge: ageThen, sex: profile.sex),
                sixMonth: six, thirtyDay: thirty, coverageDays: six.daysWithData
            )
            if let band = r.bandAge {
                points.append(.init(day: key, bandAge: band, chronoAge: ageThen, pace: r.pace))
            }
            cursor -= 7
        }
        return points.reversed()
    }

    private func legacySmooth(
        _ points: [(ts: Int, value: Double)], window: Int
    ) -> [(ts: Int, value: Double)] {
        guard points.count >= 3, window > 0 else { return points }
        let ordered = points.sorted { $0.ts < $1.ts }
        let spacings = zip(ordered, ordered.dropFirst()).map { $1.ts - $0.ts }.filter { $0 > 0 }.sorted()
        let medianSpacing = spacings.isEmpty ? window : spacings[spacings.count / 2]
        let gap = max(window, medianSpacing * 2)
        var out: [(ts: Int, value: Double)] = []
        var current: [(ts: Int, value: Double)] = []
        var last: Int?
        func flush() {
            guard !current.isEmpty else { return }
            let prepared: [(ts: Int, value: Double)]
            if let first = current.first, let last = current.last, last.ts - first.ts > 3 * 3600 {
                var sums: [Int: (total: Double, n: Int)] = [:]
                for point in current {
                    let key = point.ts / 20
                    let cur = sums[key] ?? (0, 0)
                    sums[key] = (cur.total + point.value, cur.n + 1)
                }
                prepared = sums.keys.sorted().map { key in
                    let b = sums[key]!
                    return (key * 20, b.total / Double(b.n))
                }
            } else {
                prepared = current
            }
            out.append(contentsOf: legacySmoothRun(prepared, window: window))
            current = []
        }
        for point in ordered {
            if let last, point.ts - last > gap { flush() }
            current.append(point)
            last = point.ts
        }
        flush()
        return out
    }

    private func legacySmoothRun(
        _ points: [(ts: Int, value: Double)], window: Int
    ) -> [(ts: Int, value: Double)] {
        guard points.count >= 3 else { return points }
        func rolling(reduce: ([Double]) -> Double) -> [(ts: Int, value: Double)] {
            let half = window / 2
            var lo = 0, hi = 0
            return points.map { point in
                let start = point.ts - half
                let end = point.ts + half
                while lo < points.count, points[lo].ts < start { lo += 1 }
                if hi < lo { hi = lo }
                while hi < points.count, points[hi].ts <= end { hi += 1 }
                let values = points[lo..<hi].map(\.value)
                return (point.ts, values.isEmpty ? point.value : reduce(values))
            }
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let mid = sorted.count / 2
            if sorted.count.isMultiple(of: 2) { return (sorted[mid - 1] + sorted[mid]) / 2 }
            return sorted[mid]
        }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        let medians = rolling(reduce: median)
        let tmp = points
        _ = tmp
        let half = window / 2
        var lo = 0, hi = 0
        return medians.map { point in
            let start = point.ts - half
            let end = point.ts + half
            while lo < medians.count, medians[lo].ts < start { lo += 1 }
            if hi < lo { hi = lo }
            while hi < medians.count, medians[hi].ts <= end { hi += 1 }
            let values = medians[lo..<hi].map(\.value)
            return (point.ts, values.isEmpty ? point.value : mean(values))
        }
    }

    private func legacyDownsample(
        _ points: [(ts: Int, value: Double)], maxPoints: Int
    ) -> [(ts: Int, value: Double)] {
        guard maxPoints >= 2, points.count > maxPoints else { return points }
        let ordered = points.sorted { $0.ts < $1.ts }
        guard let first = ordered.first, let last = ordered.last else { return [] }
        let span = Double(last.ts - first.ts)
        guard span > 0 else { return Array(ordered.prefix(maxPoints)) }
        let width = span / Double(maxPoints)
        var sums: [Int: (total: Double, n: Int)] = [:]
        for point in ordered {
            let key = min(maxPoints - 1, Int(Double(point.ts - first.ts) / width))
            let cur = sums[key] ?? (0, 0)
            sums[key] = (cur.total + point.value, cur.n + 1)
        }
        return sums.keys.sorted().map { key in
            let bucket = sums[key]!
            let ts = first.ts + Int((Double(key) * width + width / 2).rounded())
            return (ts, bucket.total / Double(bucket.n))
        }
    }

    // MARK: - Helpers

    private func shuffledRR(count: Int, dayStart: Int, seed: UInt64) -> [(ts: Int, ms: Double)] {
        var rng = seed
        func next() -> UInt64 {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1
            return rng
        }
        var out: [(ts: Int, ms: Double)] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let ts = dayStart + Int(next() % 86_400)
            let ms = 600.0 + Double(next() % 400)
            out.append((ts, ms))
            _ = i
        }
        return out
    }

    private func gappedRR() -> [(ts: Int, ms: Double)] {
        var out: [(ts: Int, ms: Double)] = []
        for i in 0..<80 { out.append((1_000 + i, 800)) }
        for i in 0..<80 { out.append((10_000 + i, 810)) }
        return out
    }

    private func sixWorkouts() -> [(start: Int, end: Int)] {
        let t0 = 1_700_000_000
        return [
            (t0 + 7 * 3600, t0 + 7 * 3600 + 2400),
            (t0 + 12 * 3600, t0 + 12 * 3600 + 3600),
            (t0 + 15 * 3600, t0 + 15 * 3600 + 1800),
            (t0 + 17 * 3600, t0 + 17 * 3600 + 2700),
            (t0 + 19 * 3600, t0 + 19 * 3600 + 1500),
            (t0 + 21 * 3600, t0 + 21 * 3600 + 1200),
        ]
    }

    private func overlappingWorkouts() -> [(start: Int, end: Int)] {
        let t0 = 1_700_000_000
        return [
            (t0 + 8 * 3600, t0 + 9 * 3600),
            (t0 + 8 * 3600 + 1800, t0 + 9 * 3600 + 900),
        ]
    }

    private func spikeSeries() -> [Double] {
        var nn = Array(repeating: 800.0, count: 80)
        nn[10] = 1400
        nn[40] = 250
        nn[60] = 2100
        return nn
    }

    private func assertOptional(_ a: Double?, _ b: Double?, file: StaticString = #filePath, line: UInt = #line) {
        switch (a, b) {
        case (nil, nil): break
        case let (x?, y?): XCTAssertEqual(x, y, accuracy: 1e-12, file: file, line: line)
        default: XCTFail("optional mismatch \(String(describing: a)) vs \(String(describing: b))", file: file, line: line)
        }
    }

    private func assertWindow(_ a: HealthspanEngine.Window, _ b: HealthspanEngine.Window) {
        assertOptional(a.sleepHours, b.sleepHours)
        assertOptional(a.sleepConsistency, b.sleepConsistency)
        assertOptional(a.weeklyZone13Min, b.weeklyZone13Min)
        assertOptional(a.weeklyZone45Min, b.weeklyZone45Min)
        assertOptional(a.weeklyStrengthMin, b.weeklyStrengthMin)
        assertOptional(a.dailySteps, b.dailySteps)
        assertOptional(a.restingHR, b.restingHR)
        assertOptional(a.vo2max, b.vo2max)
        XCTAssertEqual(a.daysWithData, b.daysWithData)
    }

    private func mean(_ xs: [Double]) -> Double? {
        let ys = xs.filter { $0.isFinite }
        guard !ys.isEmpty else { return nil }
        return ys.reduce(0, +) / Double(ys.count)
    }

    private func sum(_ xs: [Double]) -> Double {
        xs.filter(\.isFinite).reduce(0, +)
    }
}

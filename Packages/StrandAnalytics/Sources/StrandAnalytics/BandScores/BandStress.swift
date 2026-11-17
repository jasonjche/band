import Foundation
import WhoopProtocol

/// Baseline-relative 0–3 stress for Band's Native Stress Monitor.
///
/// Estimate only. There is no WHOOP stress series to fit. HR (and optional RMSSD)
/// versus the wearer's own overnight resting HR / HRV, 1-minute grain with a
/// centred ~5-minute smooth (US20240188896A1), existing Low (<1) / Medium (<2) /
/// High (≥2) bands.
///
/// DaytimeStress.baselineRelative is the unused hourly Oura-style scorer: waking
/// 06–22 only, logistic squash that maps baseline to 1.5 Medium, gravity masking,
/// RMSSD gated off. It does not meet sitting-at-rest → Low, sleep scoring, or
/// logged-workout exclusion, so this type does not call it.
public enum BandStress {

    /// Documented fallback when no night's resting HR exists.
    /// Same default `BandStrain` uses for %HRR.
    public static let defaultRestingHR = BandStrain.defaultRestingHR

    /// Prior nights used when today's `restingHr` / `avgHrv` is missing.
    public static let recentBaselineDays = 30

    /// Linear bpm per 0–3 band. High (2.0) is +24 bpm over the state baseline.
    /// DaytimeStress's validated High margin is +15 bpm over a daytime P10 floor
    /// via logistic squash (baseline → 1.5). Sitting at rest must read Low, so
    /// this is a linear ramp from overnight RHR instead. 12 is the round width
    /// that puts ordinary daytime (about RHR+14 on the plausibility set) in
    /// Medium and sitting near RHR in Low.
    public static let bpmPerBand: Double = 12

    /// RMSSD milliseconds per band, used only when the bucket has enough R-R.
    /// Typical night-to-night RMSSD spread is about 10–20 ms.
    public static let rmssdPerBand: Double = 20

    /// Mix on the HRV term. Daytime wrist RMSSD is artifact-dominated
    /// (`DaytimeStress.daytimeRMSSDScoringEnabled` is false); 0.25 keeps HR-only
    /// in charge when R-R is sparse or noisy.
    public static let hrvWeight: Double = 0.25

    /// Clamp on the HRV term so an artifact 400 ms RMSSD cannot zero the score.
    public static let hrvTermClamp: Double = 2

    /// Shared High-band floor (2.0) with the existing Native labels.
    public static let highBandFloor: Double = 2.0

    /// Native chart / store grain. Score every minute from 1 Hz HR (and RR).
    public static let bucketSeconds: Int = 60

    /// Centred smoothing window, matching the patent's ~5-minute score.
    public static let smoothWindowSeconds: Int = 300

    /// Neighbours on each side of a minute so `(2 * radius + 1) * bucketSeconds`
    /// equals `smoothWindowSeconds`.
    public static let smoothRadiusBuckets: Int = 2

    /// Overnight High-share still uses a 5-minute window so Sleep scoring stays put.
    public static let overnightWindowSeconds: Int = 300

    /// A hole larger than 1.5 buckets is a break, not a High minute.
    public static var chartGapSeconds: Int { bucketSeconds + bucketSeconds / 2 }

    /// Merge short walking spans that sit within this many seconds so the chart
    /// does not grow one icon per minute of walking.
    public static let activityMergeGapSeconds: Int = 10 * 60

    public struct Baselines: Equatable, Sendable {
        public var wakeRestingHR: Double
        public var sleepRestingHR: Double
        public var rmssd: Double?

        public init(wakeRestingHR: Double, sleepRestingHR: Double, rmssd: Double?) {
            self.wakeRestingHR = wakeRestingHR
            self.sleepRestingHR = sleepRestingHR
            self.rmssd = rmssd
        }

        /// No personal history: both states use `defaultRestingHR`, HR-only.
        public static let fallback = Baselines(
            wakeRestingHR: BandStress.defaultRestingHR,
            sleepRestingHR: BandStress.defaultRestingHR,
            rmssd: nil
        )

        /// Day's overnight RHR, else median of recent nights, else 60.
        /// HRV baseline is day's `avgHrv`, else recent median, else nil (HR-only).
        /// Wake and sleep slots currently share that overnight RHR so a later
        /// daytime floor cannot leak into sleep scoring.
        public static func resolve(dayRestingHR: Double?, recentRestingHRs: [Double],
                                   dayRMSSD: Double?, recentRMSSDs: [Double]) -> Baselines {
            let rhr = positive(dayRestingHR) ?? median(recentRestingHRs) ?? BandStress.defaultRestingHR
            let hrv = positive(dayRMSSD) ?? median(recentRMSSDs)
            return Baselines(wakeRestingHR: rhr, sleepRestingHR: rhr, rmssd: hrv)
        }
    }

    public enum Outcome: Equatable, Sendable {
        case value(Double)
        case excluded
        case gap
    }

    /// Why a bucket is omitted from the 0–3 series. The chart draws these as
    /// excluded spans (WHOOP uses a walker icon for activity).
    public enum ExclusionKind: Equatable, Sendable, Hashable {
        case workout
        case recovery
        case activity
    }

    public struct ExclusionSpan: Equatable, Sendable {
        public var startTs: Int
        public var endTs: Int
        public var kind: ExclusionKind
        public init(startTs: Int, endTs: Int, kind: ExclusionKind) {
            self.startTs = startTs
            self.endTs = endTs
            self.kind = kind
        }
    }

    /// After a logged workout, keep excluding until HR is back within this many bpm
    /// of the pre-workout mean, or the intensity-scaled cap elapses.
    public static let recoveryReturnBPM: Double = 15
    /// Hard cap on the post-workout recovery exclusion (seconds).
    public static let recoveryMaxSeconds: Int = 3_600
    /// Floor on that cap so a short easy bout still has a few minutes of shadow.
    public static let recoveryMinSeconds: Int = 15 * 60
    /// Walk/run share of classed step ticks that marks a minute bucket as activity.
    /// `AutoWorkoutDetector.minNonStillShare` is 0.05 for workout detection; stress
    /// uses a higher bar so a few steps around the kitchen do not mask sitting.
    public static let activityWalkShare: Double = 0.15
    /// Gravity-delta floor copied from `WorkoutDetector.motionThreshold` (walk).
    public static let activityMotionThreshold: Double = 0.20
    /// Fraction of gravity samples above `activityMotionThreshold` that confirms activity
    /// when step class is missing. Same 0.30 as `DaytimeStress.activityMaskFraction`.
    public static let activityMotionShare: Double = 0.30
    /// Samples needed in a bucket before motion/steps are trusted.
    public static let activityMinSamples: Int = 5

    /// Workout, then post-workout recovery, then walking/running. Missing HR is a gap.
    public static func evaluate(bpm: Double?, rmssd: Double? = nil,
                                isWorkout: Bool, isAsleep: Bool,
                                baselines: Baselines,
                                isActivity: Bool = false,
                                isRecovery: Bool = false) -> Outcome {
        if isWorkout || isRecovery || isActivity { return .excluded }
        guard let bpm else { return .gap }
        return .value(score(bpm: bpm, rmssd: rmssd, isAsleep: isAsleep, baselines: baselines))
    }

    public static func exclusionKind(isWorkout: Bool, isRecovery: Bool, isActivity: Bool) -> ExclusionKind? {
        if isWorkout { return .workout }
        if isRecovery { return .recovery }
        if isActivity { return .activity }
        return nil
    }

    /// 0–3 for a bucket that has HR and is not a workout.
    public static func score(bpm: Double, rmssd: Double? = nil, isAsleep: Bool,
                             baselines: Baselines) -> Double {
        let ref = isAsleep ? baselines.sleepRestingHR : baselines.wakeRestingHR
        let hrTerm = (bpm - ref) / bpmPerBand
        let raw: Double
        if let rmssd, let base = baselines.rmssd, rmssdPerBand > 0 {
            let hrvTerm = clamp((base - rmssd) / rmssdPerBand, -hrvTermClamp, hrvTermClamp)
            raw = (1 - hrvWeight) * hrTerm + hrvWeight * hrvTerm
        } else {
            raw = hrTerm
        }
        return clamp(raw, 0, 3)
    }

    /// RMSSD per `bucketSeconds` bucket via `HRVAnalyzer`. Buckets with too few
    /// clean beats are omitted (HR-only).
    public static func rmssdByBucket(rr: [(ts: Int, ms: Double)],
                                     bucketSeconds: Int = bucketSeconds) -> [Int: Double] {
        guard bucketSeconds > 0, !rr.isEmpty else { return [:] }
        var buf: [Double] = []
        buf.reserveCapacity(256)
        var out: [Int: Double] = [:]
        out.reserveCapacity(min(rr.count, 1_440))

        var monotonic = true
        var prevKey = Int.min
        for sample in rr {
            let key = floorDiv(sample.ts, bucketSeconds) * bucketSeconds
            if key < prevKey { monotonic = false; break }
            prevKey = key
        }

        if monotonic {
            var i = 0
            while i < rr.count {
                let key = floorDiv(rr[i].ts, bucketSeconds) * bucketSeconds
                buf.removeAll(keepingCapacity: true)
                var j = i
                while j < rr.count && floorDiv(rr[j].ts, bucketSeconds) * bucketSeconds == key {
                    buf.append(rr[j].ms)
                    j += 1
                }
                if let rmssd = HRVAnalyzer.rmssdOnly(buf) { out[key] = rmssd }
                i = j
            }
            return out
        }

        var counts: [Int: Int] = [:]
        counts.reserveCapacity(min(rr.count, 1_440))
        for sample in rr {
            let key = floorDiv(sample.ts, bucketSeconds) * bucketSeconds
            counts[key, default: 0] += 1
        }
        var offsets: [Int: Int] = [:]
        offsets.reserveCapacity(counts.count)
        var total = 0
        for (key, n) in counts {
            offsets[key] = total
            total += n
        }
        var storage = [Double](repeating: 0, count: total)
        var cursor = offsets
        for sample in rr {
            let key = floorDiv(sample.ts, bucketSeconds) * bucketSeconds
            let p = cursor[key]!
            storage[p] = sample.ms
            cursor[key] = p + 1
        }
        storage.withUnsafeBufferPointer { all in
            for (key, off) in offsets {
                let n = counts[key]!
                let slice = UnsafeBufferPointer(start: all.baseAddress! + off, count: n)
                if let rmssd = HRVAnalyzer.rmssdOnly(ms: slice, start: 0, end: n, minBeats: HRVAnalyzer.minBeats) {
                    out[key] = rmssd
                }
            }
        }
        return out
    }

    /// Share of scored overnight windows in the High band, 0...100. Nil when
    /// nothing scored. Empty windows are gaps, not Low.
    public static func overnightHighShare(hr: [HRSample], startTs: Int, endTs: Int,
                                          baselines: Baselines,
                                          windowSeconds: Int = overnightWindowSeconds) -> Double? {
        overnightHighShare(
            samples: hr.map { (ts: $0.ts, bpm: Double($0.bpm)) },
            startTs: startTs, endTs: endTs, baselines: baselines,
            windowSeconds: windowSeconds
        )
    }

    public static func overnightHighShare(samples: [(ts: Int, bpm: Double)],
                                          startTs: Int, endTs: Int,
                                          baselines: Baselines,
                                          windowSeconds: Int = overnightWindowSeconds) -> Double? {
        let levels = windowLevels(
            samples: samples, startTs: startTs, endTs: endTs,
            baselines: baselines, windowSeconds: windowSeconds
        )
        return highShare(levels)
    }

    public static func windowLevels(samples: [(ts: Int, bpm: Double)],
                                    startTs: Int, endTs: Int,
                                    baselines: Baselines,
                                    windowSeconds: Int = overnightWindowSeconds) -> [Double?] {
        guard endTs > startTs, windowSeconds > 0 else { return [] }
        var buckets: [Int: (sum: Double, n: Int)] = [:]
        for sample in samples where sample.ts >= startTs && sample.ts < endTs {
            let idx = (sample.ts - startTs) / windowSeconds
            var entry = buckets[idx] ?? (0, 0)
            entry.sum += sample.bpm
            entry.n += 1
            buckets[idx] = entry
        }
        return buckets.keys.sorted().map { key in
            let entry = buckets[key]!
            let mean = entry.sum / Double(entry.n)
            return score(bpm: mean, isAsleep: true, baselines: baselines)
        }
    }

    public static func highShare(_ levels: [Double?], floor: Double = highBandFloor) -> Double? {
        var high = 0
        var scored = 0
        for level in levels {
            guard let level else { continue }
            scored += 1
            if level >= floor { high += 1 }
        }
        guard scored > 0 else { return nil }
        return Double(high) / Double(scored) * 100
    }

    /// True when `[bucketTs, bucketTs + bucketSeconds)` overlaps `[start, end)`.
    public static func overlaps(bucketTs: Int, start: Int, end: Int,
                                bucketSeconds: Int = bucketSeconds) -> Bool {
        guard end > start, bucketSeconds > 0 else { return false }
        return bucketTs < end && (bucketTs + bucketSeconds) > start
    }

    /// Post-workout exclusion: from `workoutEnd` until HR is within `recoveryReturnBPM`
    /// of the pre-workout mean, or an intensity-scaled cap (15–60 min).
    ///
    /// Cap scales with how far the bout mean sat above the pre-workout level:
    /// +15 bpm → 30 min, +30 bpm → 60 min (clamped). Empty HR → cap only.
    public static func recoveryWindow(workoutStart: Int, workoutEnd: Int,
                                      samples: [(ts: Int, bpm: Double)],
                                      returnWithinBPM: Double = recoveryReturnBPM,
                                      minSeconds: Int = recoveryMinSeconds,
                                      maxSeconds: Int = recoveryMaxSeconds) -> (start: Int, end: Int)? {
        guard workoutEnd > workoutStart else { return nil }
        let sorted = samples.sorted { $0.ts < $1.ts }
        return recoveryWindowSorted(
            workoutStart: workoutStart, workoutEnd: workoutEnd, samples: sorted,
            returnWithinBPM: returnWithinBPM, minSeconds: minSeconds, maxSeconds: maxSeconds
        )
    }

    public static func recoveryWindows(workouts: [(start: Int, end: Int)],
                                       samples: [(ts: Int, bpm: Double)]) -> [(start: Int, end: Int)] {
        guard !workouts.isEmpty else { return [] }
        let sorted = samples.sorted { $0.ts < $1.ts }
        return workouts.compactMap {
            recoveryWindowSorted(workoutStart: $0.start, workoutEnd: $0.end, samples: sorted)
        }
    }

    /// Minute buckets where the wearer is walking or running (activity class 1/2),
    /// or gravity intensity is at walk floor for enough of the bucket.
    public static func activityBuckets(bucketStarts: [Int],
                                       bucketSeconds: Int = bucketSeconds,
                                       steps: [(ts: Int, activityClass: Int)] = [],
                                       motion: [(ts: Int, intensity: Double)] = []) -> Set<Int> {
        guard bucketSeconds > 0 else { return [] }
        var stepHits: [Int: (walk: Int, n: Int)] = [:]
        for sample in steps where sample.activityClass >= 0 {
            let key = floorDiv(sample.ts, bucketSeconds) * bucketSeconds
            var entry = stepHits[key] ?? (0, 0)
            entry.n += 1
            if sample.activityClass >= 1 { entry.walk += 1 }
            stepHits[key] = entry
        }
        var motionHits: [Int: (hot: Int, n: Int)] = [:]
        for sample in motion {
            let key = floorDiv(sample.ts, bucketSeconds) * bucketSeconds
            var entry = motionHits[key] ?? (0, 0)
            entry.n += 1
            if sample.intensity >= activityMotionThreshold { entry.hot += 1 }
            motionHits[key] = entry
        }
        var out: Set<Int> = []
        let keys = Set(bucketStarts).union(stepHits.keys).union(motionHits.keys)
        for key in keys {
            if let step = stepHits[key], step.n >= activityMinSamples {
                if Double(step.walk) / Double(step.n) >= activityWalkShare {
                    out.insert(key)
                    continue
                }
            }
            if let mot = motionHits[key], mot.n >= activityMinSamples {
                if Double(mot.hot) / Double(mot.n) >= activityMotionShare {
                    out.insert(key)
                }
            }
        }
        if !bucketStarts.isEmpty {
            let wanted = Set(bucketStarts)
            return out.intersection(wanted)
        }
        return out
    }

    /// Merge adjacent minute activity buckets into `[start, end)` spans.
    public static func spans(fromBuckets buckets: Set<Int>,
                             bucketSeconds: Int = bucketSeconds) -> [ExclusionSpan] {
        guard bucketSeconds > 0 else { return [] }
        let sorted = buckets.sorted()
        var out: [ExclusionSpan] = []
        var i = 0
        while i < sorted.count {
            let start = sorted[i]
            var end = start + bucketSeconds
            var j = i + 1
            while j < sorted.count, sorted[j] <= end {
                end = sorted[j] + bucketSeconds
                j += 1
            }
            out.append(ExclusionSpan(startTs: start, endTs: end, kind: .activity))
            i = j
        }
        return out
    }

    /// Minute scores plus exclusion spans. Unix-seconds form of the Native Stress chart
    /// builder: workout / recovery / activity omit nothing from the line (WHOOP keeps it
    /// running) but still record the span. Gaps stay omitted. Contiguous runs are
    /// centred-smoothed.
    public static func timeline(
        buckets: [(ts: Int, bpm: Double)],
        baselines: Baselines,
        sleepStart: Int?,
        sleepEnd: Int?,
        workouts: [(start: Int, end: Int)],
        rmssdByBucket: [Int: Double] = [:],
        activityBuckets: Set<Int> = [],
        recovery: [(start: Int, end: Int)] = [],
        smoothRadius: Int = smoothRadiusBuckets,
        bucketSeconds: Int = bucketSeconds
    ) -> (hours: [(ts: Int, value: Double)], exclusions: [ExclusionSpan]) {
        var exclusions: [ExclusionSpan] = []
        exclusions.reserveCapacity(workouts.count + recovery.count + 8)
        for bout in workouts where bout.end > bout.start {
            exclusions.append(ExclusionSpan(startTs: bout.start, endTs: bout.end, kind: .workout))
        }
        for window in recovery where window.end > window.start {
            exclusions.append(ExclusionSpan(startTs: window.start, endTs: window.end, kind: .recovery))
        }
        exclusions.append(contentsOf: mergeSpans(spans(fromBuckets: activityBuckets, bucketSeconds: bucketSeconds)))

        let workoutSorted = workouts.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        let recoverySorted = recovery.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var scored: [(ts: Int, value: Double)] = []
        scored.reserveCapacity(buckets.count)
        var wi = 0
        var ri = 0
        for bucket in buckets {
            let asleep: Bool
            if let sleepStart, let sleepEnd {
                asleep = overlaps(bucketTs: bucket.ts, start: sleepStart, end: sleepEnd,
                                  bucketSeconds: bucketSeconds)
            } else {
                asleep = false
            }
            let bEnd = bucket.ts + bucketSeconds
            while wi < workoutSorted.count, workoutSorted[wi].end <= bucket.ts { wi += 1 }
            var workout = false
            var k = wi
            while k < workoutSorted.count, workoutSorted[k].start < bEnd {
                if overlaps(bucketTs: bucket.ts, start: workoutSorted[k].start, end: workoutSorted[k].end,
                            bucketSeconds: bucketSeconds) {
                    workout = true
                    break
                }
                k += 1
            }
            while ri < recoverySorted.count, recoverySorted[ri].end <= bucket.ts { ri += 1 }
            var recovering = false
            var r = ri
            while r < recoverySorted.count, recoverySorted[r].start < bEnd {
                if overlaps(bucketTs: bucket.ts, start: recoverySorted[r].start, end: recoverySorted[r].end,
                            bucketSeconds: bucketSeconds) {
                    recovering = true
                    break
                }
                r += 1
            }
            let moving = activityBuckets.contains(bucket.ts)
            switch evaluate(
                bpm: bucket.bpm,
                rmssd: rmssdByBucket[bucket.ts],
                isWorkout: workout,
                isAsleep: asleep,
                baselines: baselines,
                isActivity: moving,
                isRecovery: recovering
            ) {
            case .value(let value):
                scored.append((bucket.ts, value))
            case .excluded:
                scored.append((bucket.ts, score(
                    bpm: bucket.bpm, rmssd: rmssdByBucket[bucket.ts],
                    isAsleep: asleep, baselines: baselines
                )))
            case .gap:
                break
            }
        }
        let hours = smoothCentered(points: scored, bucketSeconds: bucketSeconds, radius: smoothRadius)
        return (hours, exclusions)
    }

    /// Merge same-kind spans that overlap or sit within `gapSeconds`.
    /// Walking uses `activityMergeGapSeconds` so a cluster of short walks is one span.
    public static func mergeSpans(_ spans: [ExclusionSpan],
                                 gapSeconds: Int = activityMergeGapSeconds) -> [ExclusionSpan] {
        guard gapSeconds >= 0 else { return spans }
        var byKind: [ExclusionKind: [ExclusionSpan]] = [:]
        for span in spans where span.endTs > span.startTs {
            byKind[span.kind, default: []].append(span)
        }
        var out: [ExclusionSpan] = []
        for kind in [ExclusionKind.workout, .recovery, .activity] {
            let sorted = (byKind[kind] ?? []).sorted { $0.startTs < $1.startTs }
            var merged: [ExclusionSpan] = []
            for span in sorted {
                if let last = merged.last, span.startTs <= last.endTs + gapSeconds {
                    merged[merged.count - 1].endTs = max(last.endTs, span.endTs)
                } else {
                    merged.append(span)
                }
            }
            out.append(contentsOf: merged)
        }
        return out.sorted { $0.startTs < $1.startTs }
    }

    /// Centred rolling mean over contiguous minute scores. Gaps and exclusions
    /// stay omitted: a missing bucket starts a new run, never filled from neighbours.
    public static func smoothCentered(
        points: [(ts: Int, value: Double)],
        bucketSeconds: Int = bucketSeconds,
        radius: Int = smoothRadiusBuckets
    ) -> [(ts: Int, value: Double)] {
        guard radius > 0, bucketSeconds > 0, points.count > 1 else { return points }
        let sorted = points.sorted { $0.ts < $1.ts }
        var out: [(ts: Int, value: Double)] = []
        out.reserveCapacity(sorted.count)
        var i = 0
        while i < sorted.count {
            var j = i + 1
            while j < sorted.count, sorted[j].ts - sorted[j - 1].ts == bucketSeconds {
                j += 1
            }
            let runCount = j - i
            if runCount == 1 {
                out.append(sorted[i])
            } else {
                var prefix = [0.0]
                prefix.reserveCapacity(runCount + 1)
                var acc = 0.0
                for k in i..<j {
                    acc += sorted[k].value
                    prefix.append(acc)
                }
                for k in 0..<runCount {
                    let lo = max(0, k - radius)
                    let hi = min(runCount - 1, k + radius)
                    let n = hi - lo + 1
                    let sum = prefix[hi + 1] - prefix[lo]
                    out.append((sorted[i + k].ts, n > 0 ? sum / Double(n) : sorted[i + k].value))
                }
            }
            i = j
        }
        return out
    }

    public static func highMinutes(levels: [Double?],
                                   bucketSeconds: Int = bucketSeconds,
                                   floor: Double = highBandFloor) -> Double {
        var n = 0
        for level in levels {
            guard let level, level >= floor else { continue }
            n += 1
        }
        return Double(n) * Double(bucketSeconds) / 60.0
    }

    static func recoveryWindowSorted(
        workoutStart: Int, workoutEnd: Int,
        samples: [(ts: Int, bpm: Double)],
        returnWithinBPM: Double = recoveryReturnBPM,
        minSeconds: Int = recoveryMinSeconds,
        maxSeconds: Int = recoveryMaxSeconds
    ) -> (start: Int, end: Int)? {
        guard workoutEnd > workoutStart else { return nil }
        let preLo = workoutStart - 10 * 60
        let pre = bpmRange(samples, from: preLo, toExclusive: workoutStart)
        let during = bpmRange(samples, from: workoutStart, toExclusive: workoutEnd)
        let preMean = average(pre)
        let boutMean = average(during) ?? preMean
        let excess = max(0, (boutMean ?? 0) - (preMean ?? 0))
        let scaled = Int((excess / max(returnWithinBPM, 1)) * 1_800)
        let cap = min(maxSeconds, max(minSeconds, scaled == 0 ? minSeconds : scaled))
        let capEnd = workoutEnd + cap
        guard let preMean else {
            return (workoutEnd, capEnd)
        }
        let threshold = preMean + returnWithinBPM
        let lo = lowerBound(samples, ts: workoutEnd)
        let hi = lowerBound(samples, ts: capEnd + 1)
        if lo < hi {
            for i in lo..<hi where samples[i].bpm <= threshold {
                return (workoutEnd, max(workoutEnd, samples[i].ts))
            }
        }
        return (workoutEnd, capEnd)
    }

    static func bpmRange(_ samples: [(ts: Int, bpm: Double)], from: Int, toExclusive: Int) -> [Double] {
        let lo = lowerBound(samples, ts: from)
        let hi = lowerBound(samples, ts: toExclusive)
        guard lo < hi else { return [] }
        var out: [Double] = []
        out.reserveCapacity(hi - lo)
        for i in lo..<hi { out.append(samples[i].bpm) }
        return out
    }

    static func lowerBound(_ samples: [(ts: Int, bpm: Double)], ts: Int) -> Int {
        var lo = 0
        var hi = samples.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if samples[mid].ts < ts { lo = mid + 1 }
            else { hi = mid }
        }
        return lo
    }

    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b, r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, x))
    }

    static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    static func median(_ values: [Double]) -> Double? {
        let xs = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !xs.isEmpty else { return nil }
        let n = xs.count
        if n % 2 == 1 { return xs[n / 2] }
        return 0.5 * (xs[n / 2 - 1] + xs[n / 2])
    }

    static func average(_ values: [Double]) -> Double? {
        let xs = values.filter { $0.isFinite && $0 > 0 }
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }
}

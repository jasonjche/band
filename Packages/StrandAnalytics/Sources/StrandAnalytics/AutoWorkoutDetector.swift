import Foundation
import WhoopProtocol

// AutoWorkoutDetector.swift — opt-in MVP "did you just work out?" detector.
//
// Detection logic is frozen for byte-parity with the historical twin. The two MUST
// stay BYTE-PARITY on the detection logic (same thresholds, same span/merge/overlap rules, same
// outputs), verified by the mirrored unit tests on each platform.
//
// This is DELIBERATELY SEPARATE from `WorkoutDetector` (the exercise.py port that computes
// calories / zones / strain for daily analytics and enriches already logged workouts). This one
// is the lightweight, OPT-IN, NON-DESTRUCTIVE confirmation detector that only ever SUGGESTS a
// workout via a dismissible Today card — it never writes a row on its own. The user taps "Save"
// to turn a suggestion into a manual workout, or X to dismiss it forever. Its published policy
// remains frozen while the duration alternatives collect local shadow evidence.
//
// The published thresholds here are intentionally CONSERVATIVE (low sensitivity): a sustained ≥ 12-min
// elevation of HR ≥ resting + 30 bpm, brief (≤ 90 s) dips tolerated, near windows merged, plus a
// cooldown after any saved workout. When step-class or gravity samples cover the window, motion must
// corroborate (walk/run share or median gravity-delta). With no motion series it falls back to a
// stricter mean %HRR gate. Tuned to avoid false positives from stress / caffeine / post-workout
// wandering, at the cost of missing the odd short or gentle session.
//
// The 10- and 15-minute alternatives are SHADOW policies only. Test Centre may run them beside the
// published 12-minute result to compare against labelled workouts, but they must not drive the Today
// card, persistence, classification, or downstream scores until real-world validation supports a change.
//
// Pure / headless: no I/O, no clock. All ts/start/end are unix SECONDS. NOT medical advice.

/// A candidate workout window the user can accept (Save) or reject (dismiss). All fields are
/// derived purely from the HR samples inside the window. Mirrors the Kotlin `DetectedWorkout`.
public struct DetectedWorkout: Equatable, Sendable {
    public let startSec: Int
    public let endSec: Int
    public let avgBpm: Int
    public let peakBpm: Int
    /// Whole minutes, floor of (endSec - startSec) / 60 — what the prompt shows.
    public let durationMin: Int

    public init(startSec: Int, endSec: Int, avgBpm: Int, peakBpm: Int, durationMin: Int) {
        self.startSec = startSec
        self.endSec = endSec
        self.avgBpm = avgBpm
        self.peakBpm = peakBpm
        self.durationMin = durationMin
    }
}

/// A [startSec, endSec] span of an already-saved workout, used to exclude windows that overlap a
/// session the user has already logged (so we never re-suggest one). Mirrors the Kotlin
/// `Pair<Long, Long>` saved-workout argument.
public struct SavedWorkoutSpan: Equatable, Sendable {
    public let startSec: Int
    public let endSec: Int
    public init(startSec: Int, endSec: Int) {
        self.startSec = startSec
        self.endSec = endSec
    }
}

public enum AutoWorkoutDetector {

    // MARK: - Constants (keep byte-identical with the Kotlin twin)

    /// Elevated gate: bpm must be at least restingHR + this margin to count as "working".
    public static let elevatedMarginBPM = 30
    /// A candidate must hold the elevated gate for a contiguous span of at least this long (12 min).
    public static let minSustainedMin: Double = 12.0
    /// Candidate duration policies evaluated only by local Test Centre shadow diagnostics.
    /// The published confirmation path continues to use `minSustainedMin` (12 minutes).
    public static let shadowSustainedMinutes: [Double] = [10.0, 15.0]
    /// A dip below the gate no longer than this does NOT break the span (a red light, a sip of water).
    public static let maxDipS = 90
    /// Two detected windows whose gap is strictly less than this are merged into one (5 min).
    public static let mergeGapS = 5 * 60
    /// Legacy mean-gravity confirm used only when a caller still passes gravity without steps.
    /// New detection uses `minMedianMotion` because a few large deltas inflate the mean.
    public static let motionConfirmMean = 0.05
    /// Walk+run share of classed step ticks that confirms locomotion (0 still / 1 walk / 2 run).
    /// Post-run wandering is ~2%; a real session is ~15–27%.
    public static let minNonStillShare = 0.05
    /// Median L2 gravity-delta that confirms motion when steps are mostly still (strength).
    /// Post-run wandering median is ~0.02; a real session median is ~0.10.
    public static let minMedianMotion = 0.05
    /// Samples needed in the window before a motion series is trusted.
    public static let minMotionSamples = 30
    /// Mean Karvonen %HRR required when the window has no motion series. HRmax defaults to 197.
    /// Recovery at ~92 bpm / RHR 60 is ~23%; a 74-min session at ~103 bpm is ~31%.
    public static let hrOnlyMinMeanHRR = 0.28
    /// Default HRmax for the HR-only %HRR gate when the caller does not pass one.
    public static let defaultMaxHR = 197
    /// Seconds appended to each saved workout's end so a cooldown is not a new session.
    public static let cooldownAfterSavedS = 10 * 60
    /// Resting-HR fallback when the caller has no nightly RHR for the day.
    public static let defaultRestingHR = 60

    // MARK: - Inputs

    /// One motion-intensity reading aligned to the HR timeline (optional confirmation signal).
    /// `intensity` is on the same L2-gravity-delta scale as `WorkoutDetector.activitySeries`.
    /// (The Kotlin twin takes raw `GravitySample`s and derives this internally; the Swift call site
    /// — `Repository.autoDetectCandidate` — has the gravity already decoded, so it passes the points.)
    public struct MotionPoint: Equatable, Sendable {
        public let ts: Int
        public let intensity: Double
        public init(ts: Int, intensity: Double) {
            self.ts = ts
            self.intensity = intensity
        }
    }

    /// One strap step tick with its gait class (0 still / 1 walk / 2 run).
    public struct StepTick: Equatable, Sendable {
        public let ts: Int
        public let activityClass: Int
        public init(ts: Int, activityClass: Int) {
            self.ts = ts
            self.activityClass = activityClass
        }
    }

    /// Whether a window has motion evidence, and whether that evidence confirms a workout.
    public enum MotionVerdict: Equatable, Sendable {
        case confirmed
        case rejected
        case missing
    }

    /// Per-second motion intensity = L2 magnitude of the gravity change vs the previous record.
    /// First row → 0. Empty input → []. Mirrors the Kotlin `motionIntensityByTs` (and
    /// `WorkoutDetector.activitySeries`) so a caller can build the optional `motion` argument.
    public static func motionPoints(_ gravity: [GravitySample]) -> [MotionPoint] {
        if gravity.isEmpty { return [] }
        let rows = gravity.sorted { $0.ts < $1.ts }
        var out: [MotionPoint] = []
        out.reserveCapacity(rows.count)
        var prev: GravitySample? = nil
        for (i, row) in rows.enumerated() {
            let intensity: Double
            if i == 0, prev == nil {
                intensity = 0.0
            } else if let p = prev {
                let dx = row.x - p.x, dy = row.y - p.y, dz = row.z - p.z
                intensity = (dx * dx + dy * dy + dz * dz).squareRoot()
            } else {
                intensity = 0.0
            }
            out.append(MotionPoint(ts: row.ts, intensity: intensity))
            prev = row
        }
        return out
    }

    // MARK: - Public API

    /// Detect candidate sustained-elevated-HR workout windows.
    ///
    /// Algorithm (kept byte-identical with the Kotlin twin):
    ///  1. Sort HR ascending. Floor = restingHR + `elevatedMarginBPM`. A sample is "elevated" when
    ///     bpm >= floor.
    ///  2. Grow a contiguous span across elevated samples. A run of NON-elevated samples is tolerated
    ///     (does not end the span) ONLY while the dip's wall-clock duration (from the first sub-threshold
    ///     sample) stays <= `maxDipS`; a longer dip closes the span. The span's [start, end] are the
    ///     first/last ELEVATED sample timestamps.
    ///  3. Keep a span only when it lasts >= `minimumSustainedMinutes` (applied per-span, BEFORE merge).
    ///  4. Merge two kept spans when the gap between them is strictly < `mergeGapS`.
    ///  5. Drop a window that OVERLAPS any saved span, including `cooldownAfterSavedS` after each
    ///     saved end (touching endpoints count) — never re-suggest a cooldown as a new session.
    ///  6. Motion corroboration when step-class or gravity samples cover the window: keep it only
    ///     when walk+run share >= `minNonStillShare` OR median gravity-delta >= `minMedianMotion`.
    ///     With no motion series, require mean %HRR >= `hrOnlyMinMeanHRR`.
    ///  7. Emit a `DetectedWorkout` per surviving window (avg/peak bpm + whole-minute duration).
    ///
    /// - Parameters:
    ///   - hr: the day's (or last day or two's) HR samples `[(ts, bpm)]`; any order; empty → [].
    ///   - restingBpm: the nightly resting HR for the day; nil → `defaultRestingHR` (60).
    ///   - motion: OPTIONAL gravity-delta series; nil/empty with no steps → HR-only fallback.
    ///   - steps: OPTIONAL gait-class ticks (0 still / 1 walk / 2 run).
    ///   - savedSpans: already-saved workout windows to exclude by overlap (plus cooldown).
    ///   - minimumSustainedMinutes: duration policy. The default is the published 12-minute policy;
    ///     callers may pass values from `shadowSustainedMinutes` only for local shadow diagnostics.
    ///   - maxHeartRate: HRmax for the HR-only %HRR gate; default `defaultMaxHR` (197).
    public static func detect(hr: [(ts: Int, bpm: Int)],
                              restingBpm: Int?,
                              motion: [MotionPoint]? = nil,
                              steps: [StepTick]? = nil,
                              savedSpans: [SavedWorkoutSpan] = [],
                              minimumSustainedMinutes: Double = minSustainedMin,
                              maxHeartRate: Int = defaultMaxHR) -> [DetectedWorkout] {
        let seg = hr.sorted { $0.ts < $1.ts }
        if seg.isEmpty { return [] }

        let floor = (restingBpm ?? defaultRestingHR) + elevatedMarginBPM

        // --- 1 + 2 + 3: grow sustained spans tolerating brief dips ---
        // A span is [spanStart, spanEnd] over ELEVATED-sample timestamps. `dipStart` marks where the
        // current sub-threshold run began (nil = not in a dip); a dip longer than maxDipS closes the span.
        var spans: [(start: Int, end: Int)] = []
        var spanStart: Int? = nil
        var spanEnd = 0
        var dipStart: Int? = nil

        func closeSpan() {
            if let s = spanStart, Double(spanEnd - s) >= minimumSustainedMinutes * 60.0 {
                spans.append((s, spanEnd))
            }
            spanStart = nil
            dipStart = nil
        }

        for sample in seg {
            if sample.bpm >= floor {
                if spanStart == nil { spanStart = sample.ts }
                spanEnd = sample.ts
                dipStart = nil   // the dip (if any) is bridged
            } else if spanStart != nil {
                // In a span: tolerate the dip until it runs longer than maxDipS. `dipStart` is the
                // first sub-threshold sample of the current dip (set once, cleared on the next elevated).
                if dipStart == nil { dipStart = sample.ts }
                if let d = dipStart, sample.ts - d > maxDipS { closeSpan() }
            }
        }
        closeSpan()

        if spans.isEmpty { return [] }

        // --- 4: merge spans whose gap is strictly < mergeGapS (spans are start-ascending by build) ---
        var merged: [(start: Int, end: Int)] = []
        var curStart = spans[0].start
        var curEnd = spans[0].end
        for k in 1..<spans.count {
            let next = spans[k]
            if next.start - curEnd < mergeGapS {
                curEnd = max(curEnd, next.end)
            } else {
                merged.append((curStart, curEnd))
                curStart = next.start
                curEnd = next.end
            }
        }
        merged.append((curStart, curEnd))

        // --- 5 + 6 + 7 ---
        let gravity = (motion?.isEmpty ?? true) ? nil : motion
        let stepTicks = (steps?.isEmpty ?? true) ? nil : steps
        var results: [DetectedWorkout] = []
        for (start, end) in merged {
            if savedSpans.contains(where: {
                overlaps(start, end, $0.startSec, $0.endSec + cooldownAfterSavedS)
            }) { continue }

            let window = tsSlice(seg, start: start, end: end)
            if window.isEmpty { continue }

            let bpms = window.map { $0.bpm }
            let avg = Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
            let peak = bpms.max() ?? avg

            switch motionVerdict(start: start, end: end, gravity: gravity, steps: stepTicks) {
            case .rejected:
                continue
            case .confirmed:
                break
            case .missing:
                if !hrOnlyQualifies(avgBpm: avg, restingBpm: restingBpm, maxHeartRate: maxHeartRate) {
                    continue
                }
            }

            let durMin = (end - start) / 60
            results.append(DetectedWorkout(startSec: start, endSec: end,
                                           avgBpm: avg, peakBpm: peak, durationMin: durMin))
        }
        return results
    }

    /// Motion corroboration for one window. Steps and gravity are independent: locomotion
    /// share OR median gravity-delta is enough, so a strength session with still ticks can
    /// still qualify. Mean gravity is not used — a few large deltas inflate it.
    public static func motionVerdict(start: Int, end: Int,
                                     gravity: [MotionPoint]?,
                                     steps: [StepTick]?) -> MotionVerdict {
        let gravIn = (gravity ?? []).filter { $0.ts >= start && $0.ts <= end }
        let stepIn = (steps ?? []).filter { $0.ts >= start && $0.ts <= end }
        let hasSteps = stepIn.count >= minMotionSamples
        let hasGrav = gravIn.count >= minMotionSamples
        if !hasSteps && !hasGrav { return .missing }

        var nonStill = 0.0
        if hasSteps {
            let classed = stepIn.filter { $0.activityClass >= 0 }
            if !classed.isEmpty {
                nonStill = Double(classed.filter { $0.activityClass >= 1 }.count) / Double(classed.count)
            }
        }
        var medianMotion = 0.0
        if hasGrav {
            let vals = gravIn.map(\.intensity).sorted()
            medianMotion = vals[vals.count / 2]
        }
        if nonStill >= minNonStillShare || medianMotion >= minMedianMotion {
            return .confirmed
        }
        return .rejected
    }

    /// Stricter HR-only bar when the window has no motion series.
    public static func hrOnlyQualifies(avgBpm: Int, restingBpm: Int?, maxHeartRate: Int) -> Bool {
        let rhr = restingBpm ?? defaultRestingHR
        let reserve = max(1, maxHeartRate - rhr)
        return Double(avgBpm - rhr) / Double(reserve) >= hrOnlyMinMeanHRR
    }

    /// Two closed [aStart, aEnd] / [bStart, bEnd] intervals overlap (touching endpoints count).
    /// Mirrors the Kotlin `overlaps`.
    static func overlaps(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Bool {
        aStart <= bEnd && bStart <= aEnd
    }

    /// Closed [start, end] slice of a timestamp-sorted series.
    static func tsSlice<T>(_ seg: [T], start: Int, end: Int, ts: (T) -> Int) -> ArraySlice<T> {
        var lo = 0, hi = seg.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ts(seg[mid]) < start { lo = mid + 1 } else { hi = mid }
        }
        let a = lo
        hi = seg.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ts(seg[mid]) <= end { lo = mid + 1 } else { hi = mid }
        }
        return seg[a..<lo]
    }

    static func tsSlice(_ seg: [(ts: Int, bpm: Int)], start: Int, end: Int) -> ArraySlice<(ts: Int, bpm: Int)> {
        tsSlice(seg, start: start, end: end, ts: { $0.ts })
    }
}

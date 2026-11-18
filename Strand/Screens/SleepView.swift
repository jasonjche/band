import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Non-UI sleep helpers kept after the legacy Sleep tab was removed.
/// `SleepModel` and StrandTests still call these as `SleepView.*`.
enum SleepView {
    static func stageSparseNoteApplies(stagingSparse: Bool,
                                       asleepMin: Double,
                                       needHours: Double = AnalyticsEngine.Rest.defaultNeedHours) -> Bool {
        guard stagingSparse else { return false }
        return asleepMin < needHours * 60.0
    }

    static func isStagingLowConfidence(asleepMin: Double, deepMin: Double, remMin: Double,
                                       efficiency: Double) -> Bool {
        guard asleepMin > 0 else { return false }
        let restorativeMin = max(0, deepMin) + max(0, remMin)
        // An UNSTAGED night (no deep+REM at all) has no staging split to doubt — its base Rest
        // confidence already reads honestly as `.building` (NOT a downgrade), so it must never be
        // flagged. Only a night that DID stage some sleep can be a suspicious "high efficiency yet
        // implausibly little restorative" staging miss.
        guard restorativeMin > 0 else { return false }
        let tier = ScoreConfidence.rest(
            hasSession: true,
            hasStagedSleep: true,
            asleepSeconds: asleepMin * 60.0,
            restorativeSeconds: restorativeMin * 60.0,
            efficiency: efficiency)
        // The H9 overload only DOWNGRADES solid → building on the suspicious case; a genuinely
        // low-restorative-AND-low-efficiency night keeps its honest base tier and isn't flagged here.
        return tier == .building
            && (restorativeMin / asleepMin) < ScoreConfidence.restorativeLowConfidenceShare
            && efficiency >= ScoreConfidence.highEfficiencyThreshold
    }

    static var tzOffsetSec: Int { TimeZone.current.secondsFromGMT() }

    static func mainNightSession(_ sessions: [CachedSleepSession],
                                 habitualMidsleepSec: Int? = nil) -> CachedSleepSession? {
        SleepStageTotals.mainNightIndex(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec).map { sessions[$0] }
    }

    /// The day's MAIN-night GROUP — the winning block PLUS any adjacent fragments bridged into it (a wake
    /// gap shorter than `gapBridgeMaxMin`), so a briefly-interrupted / biphasic night reads as ONE
    /// continuous sleep exactly the way `AnalyticsEngine.analyzeDay` rolls it up for the daily total (#561).
    /// The hero aggregates this whole group and ONLY blocks outside it are naps. Without it the tab used the
    /// un-bridged single-block pick and rendered the bridged siblings as phantom naps (#555). A night with
    /// no bridgeable gap collapses to the single block `mainNightSession` picks, so the common case is byte-
    /// identical. Returns ascending by effective onset. (#561 / #555)
    static func mainNightGroup(_ sessions: [CachedSleepSession],
                               habitualMidsleepSec: Int? = nil) -> [CachedSleepSession] {
        guard let idx = SleepStageTotals.mainNightGroupIndices(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec) else { return [] }
        return idx.map { sessions[$0] }.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// Actual asleep minutes in blocks outside a day's canonical main-night group. The Repository's
    /// all-session union has already removed cross-namespace duplicates; this helper only applies the
    /// same main-vs-nap classification the hero uses and decodes persisted stages. A stage-less nap
    /// contributes nothing rather than substituting its in-bed window. Mirrors Android
    /// `napSleepMinutesByDay`.
    static func napSleepMinutes(_ sessions: [CachedSleepSession],
                                habitualMidsleepSec: Int? = nil) -> Double {
        let mainStarts = Set(mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
            .map { $0.startTs })
        return sessions
            .filter { !mainStarts.contains($0.startTs) }
            .reduce(0) { total, nap in
                total + decodedAsleepMinutes(nap.stagesJSON, effectiveStartTs: nap.effectiveStartTs)
            }
    }

    /// The day's main-night bridged SPAN (onset → wake), the same window `mainNightGroup` bridges into
    /// one continuous night. The ONE canonical bed/wake read every glance screen (Coupled, Today's HR
    /// band) should show — never a screen-local "freshest" or "longest single block" heuristic, which
    /// can silently disagree with each other and with the Sleep tab hero on a night stored as more than
    /// one block (#294). nil only when `sessions` has nothing bridgeable.
    static func mainNightSpan(_ sessions: [CachedSleepSession],
                              habitualMidsleepSec: Int? = nil) -> (start: Int, end: Int)? {
        let group = mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
        guard let first = group.first, let last = group.last else { return nil }
        return (first.effectiveStartTs, last.endTs)
    }

    /// Classify a block as a nap: it's a nap exactly when it is NOT the day's chosen main block. Derived
    /// from the pick (never an independent onset/duration gate), so the label can't contradict the
    /// selection — the contradiction the audit flagged. The main block is never a nap. (#518/#547)
    static func isNap(_ s: CachedSleepSession, main: CachedSleepSession?) -> Bool {
        guard let main else { return false }
        return s.startTs != main.startTs
    }

    static let preOnsetStubMaxMin: Double = 240
    /// Most asleep minutes a fragment can carry and still count as a (sleepless) pre-onset awake stub. A real
    /// first sleep fragment of a biphasic night carries far more, so it's never mistaken for a stub. (#736)
    static let preOnsetStubAsleepMaxMin: Double = 3
    /// A leading pre-onset fragment carrying SOME sleep is still spurious when it is minor RELATIVE to the
    /// night's main block: its asleep minutes are below this fraction of the largest fragment's. A genuine
    /// biphasic first sleep is comparable to the main block (well above this) and is kept; only a small stray
    /// lead is dropped. Extends the essentially-sleepless `preOnsetStubAsleepMaxMin` rule (#736), which missed
    /// a lead carrying a few minutes more than 3. Mirrors Android PRE_ONSET_STUB_MINOR_FRAC. (#259)
    static let preOnsetStubMinorFrac: Double = 0.15

    /// Absolute floor (ASLEEP minutes) under the #259 relative "minor lead" test: a leading fragment that
    /// carries at least this much real sleep is a genuine first sleep — a real sleep episode — and is NEVER
    /// a spurious pre-onset lead, however large the main block is. Without it a long main sleep inflates the
    /// 15% relative bar (a 6h night → ~54 min) so a genuine ~34-min first sleep was swallowed and the shown
    /// bedtime jumped hours late, hiding the real onset the bridged night (and the Health write-back, #364)
    /// already spans. 20 min ≈ the shortest standalone sleep episode; below it a handful of asleep minutes
    /// beside a long night is a stray lead. Mirrors Android PRE_ONSET_STUB_MINOR_ASLEEP_FLOOR_MIN.
    /// (bridged-night headline: a real 2026-07-14 12:16 first sleep hidden behind the 1:29 main block)
    static let preOnsetStubMinorAsleepFloorMin: Double = 20

    /// Pure stub test on a fragment's span + asleep minutes, so the rule is unit-testable without decoding
    /// JSON or building a view. Spurious when BRIEF and EITHER essentially sleepless OR minor relative to the
    /// main block (`refAsleepMin`, the group's largest asleep span): asleep below `preOnsetStubMinorFrac` of
    /// it AND below the absolute `preOnsetStubMinorAsleepFloorMin` real-sleep-episode floor. `refAsleepMin`
    /// defaults to 0 (relative test off) so existing callers/tests are byte-identical. (#736 / #259)
    static func isPreOnsetAwakeStub(spanMin: Double, asleepMin: Double, refAsleepMin: Double = 0) -> Bool {
        guard spanMin <= preOnsetStubMaxMin else { return false }
        if asleepMin <= preOnsetStubAsleepMaxMin { return true }
        // #259 relative "minor lead" test, floored: a real sleep episode (>= the floor) is never a stray
        // lead, so a long main block can't inflate the 15% bar past a genuine short first sleep.
        return refAsleepMin > 0
            && asleepMin < preOnsetStubMinorFrac * refAsleepMin
            && asleepMin < preOnsetStubMinorAsleepFloorMin
    }

    /// The index into an ascending-by-onset group whose fragment supplies the DISPLAYED bedtime: the first
    /// fragment that is NOT a spurious leading pre-onset awake stub, falling back to 0 when every fragment is
    /// stub-like. Pure mirror of `nightOnsetTs`'s walk, driven by per-fragment (spanMin, asleepMin) so a
    /// golden test can pin the #736 behaviour without view internals. (#736)
    static func nightOnsetIndex(spansMin: [Double], asleepsMin: [Double]) -> Int {
        let refAsleepMin = asleepsMin.max() ?? 0
        for i in spansMin.indices {
            let asleep = i < asleepsMin.count ? asleepsMin[i] : 0
            if !isPreOnsetAwakeStub(spanMin: spansMin[i], asleepMin: asleep, refAsleepMin: refAsleepMin) { return i }
        }
        return 0
    }

    static func stubDaySession(_ blocks: [CachedSleepSession],
                               habitualMidsleepSec: Int? = nil) -> CachedSleepSession? {
        guard let main = mainNightSession(blocks, habitualMidsleepSec: habitualMidsleepSec) ?? blocks.first
        else { return nil }
        return CachedSleepSession(startTs: main.effectiveStartTs, endTs: main.endTs,
                                  efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    static func decodedAsleepMinutes(_ json: String?, effectiveStartTs: Int) -> Double {
        decodeStages(json)?.asleep
            ?? decodeSegments(json, sessionStart: effectiveStartTs)?.stages.asleep
            ?? 0
    }

    /// Decode the imported stagesJSON dict of MINUTES {"light","deep","rem","awake"}.
    /// Internal (not private) so `SleepModel.mergeDay` (SleepModel.swift) can call it.
    static func decodeStages(_ json: String?) -> Stages? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        func val(_ key: String) -> Double {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            if let d = dict[key] as? Double { return d }
            if let i = dict[key] as? Int { return Double(i) }
            return 0
        }
        let s = Stages(awake: val("awake"), light: val("light"),
                       deep: val("deep"), rem: val("rem"))
        return s.total > 0 ? s : nil
    }

    /// Decode the COMPUTED stagesJSON segment array [{"start":epoch,"end":epoch,"stage":"wake"|
    /// "light"|"deep"|"rem"}] into stage totals plus the real timeline (seconds relative to the
    /// session start, the Hypnogram's domain). The on-device SleepStager calls awake "wake". (#77)
    /// Internal (not private) so `SleepModel.mergeDay` (SleepModel.swift) can call it.
    static func decodeSegments(
        _ json: String?, sessionStart: Int
    ) -> (stages: Stages, intervals: [SleepInterval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var intervals: [SleepInterval] = []
        for seg in arr {
            guard let rawStart = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue,
                  let name = seg["stage"] as? String else { continue }
            // #259: trim each segment to the effective onset (`sessionStart`) so a hand-edited bedtime the
            // raw was too sparse to re-stage (WHOOP 4.0) can't sum pre-onset stages past time-in-bed — nor
            // draw bars before the onset. No-op when segments already start at/after it (the common case).
            let start = max(rawStart, sessionStart)
            guard end > start else { continue }
            let minutes = Double(end - start) / 60.0
            let stage: SleepStage
            switch name {
            case "wake", "awake": stage = .awake; stages.awake += minutes
            case "light": stage = .light; stages.light += minutes
            case "deep": stage = .deep; stages.deep += minutes
            case "rem": stage = .rem; stages.rem += minutes
            default: continue
            }
            intervals.append(SleepInterval(
                stage: stage,
                start: TimeInterval(start - sessionStart),
                end: TimeInterval(end - sessionStart)))
        }
        return stages.total > 0 ? (stages, intervals) : nil
    }

}

enum SleepFreshnessStatus: Equatable {
    case syncing, calculating, syncFailed, awaitingSync, notDetected
}

/// Pure priority ladder behind the Sleep status banner.
func resolveSleepFreshness(hasCurrentNight: Bool, morningReady: Bool, syncing: Bool,
                           calculating: Bool, syncedSinceDayStart: Bool,
                           syncFailed: Bool) -> SleepFreshnessStatus? {
    if syncing { return .syncing }
    if hasCurrentNight { return nil }
    if calculating { return .calculating }
    if !morningReady { return nil }
    if syncFailed { return .syncFailed }
    return syncedSinceDayStart ? .notDetected : .awaitingSync
}

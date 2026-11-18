import Foundation
import WhoopProtocol

// SleepStageLearned.swift — the learned stage model, staging a night in `SleepStagerV2`'s place.
//
// Ported from denismanulov/reNOOP (PolyForm Noncommercial 1.0.0, same licence as this tree).
// `SleepStagerV2` finds nothing here: when the wearer slept is still the detector's answer. What changes is
// the hypnogram inside an accepted window. The recipe's coefficients were set a priori; the model's were
// fit to human-scored polysomnography (`Tools/SleepML` in reNOOP: 122 people, every one staged by a model
// trained without them — kappa 0.56 against 0.36 for the recipe, stage shares within 1.1 points of the PSG).
//
// The model is two boosted-tree classifiers evaluated in pure Swift from the tree-as-text export
// (`SleepStageTrees`, resources in `SleepModel/`). Feature extraction, the second-stage context, the
// decoder and the tiling into `StageSegment`s stay in this package so `swift test` covers them with no
// app target and no Core ML.
//
// A night the model cannot be trusted with is not staged by it. It was trained on wrists that report
// motion and heart rate nearly every second, so a window either of them covers thinly comes back nil
// and the caller falls back to the recipe.

/// The two models and the decoder settings fit with them.
public struct SleepStageModel: Sendable {
    /// Class probabilities for each row, in `SleepStageDecoder.stages` order; nil when the model could
    /// not answer. Rows are one night's, in order.
    public typealias Predict = @Sendable (_ rows: [[Double]]) -> [[Double]]?

    /// Names the fit. A night staged under one version is staged again under another, so this goes
    /// into every key that caches a hypnogram.
    public let version: String
    /// Each stage's share of the training epochs, and how much of it the decoder divides out.
    public let prior: [Double]?
    public let weight: Double
    public let smoothing: Double
    /// Takes rows of `SleepStageContext.firstNames`.
    public let first: Predict
    /// Takes rows of `SleepStageContext.secondNames`.
    public let second: Predict

    public init(version: String, prior: [Double]?, weight: Double, smoothing: Double,
                first: @escaping Predict, second: @escaping Predict) {
        self.version = version
        self.prior = prior
        self.weight = weight
        self.smoothing = smoothing
        self.first = first
        self.second = second
    }
}

public enum SleepStageLearned {

    private static let lock = NSLock()
    private static var installed: SleepStageModel?

    /// Test override. Production uses `bundled()` when the learned-stager flag is on.
    /// A later change re-keys every cached hypnogram through `version`.
    public static var model: SleepStageModel? {
        get { lock.lock(); defer { lock.unlock() }; return installed }
        set { lock.lock(); installed = newValue; lock.unlock() }
    }

    /// The installed model's version, empty when there is none. The bundled trees are keyed
    /// separately through `resolved(useBundled:)`.
    public static var version: String { model?.version ?? "" }

    private static let bundledLock = NSLock()
    private static var bundledModel: SleepStageModel?

    /// The tree pair shipped in this package. nil when the resource is missing or refuses to load.
    public static func bundled() -> SleepStageModel? {
        bundledLock.lock()
        defer { bundledLock.unlock() }
        if let bundledModel { return bundledModel }
        guard let first = SleepStageTrees.bundled("SleepStageFirst"),
              let second = SleepStageTrees.bundled("SleepStageSecond"),
              let loaded = SleepStageModel(first: first, second: second,
                                           version: "renoop-trees-1:\(first.source.prefix(12)):\(second.source.prefix(12))")
        else { return nil }
        bundledModel = loaded
        return loaded
    }

    /// Installed test model, else the bundled trees when `useBundled` is true.
    public static func resolved(useBundled: Bool) -> SleepStageModel? {
        if let installed = model { return installed }
        return useBundled ? bundled() : nil
    }

    /// The least share of a window's seconds that must carry a gravity sample, and of its 10 s bins a
    /// heart-rate sample, before the model stages it. The training wrists covered both nearly in full;
    /// below this the model has not been measured, and a sparse-motion night (a strap that banks motion
    /// coarsely) is the recipe's to stage.
    static let minCoverage = 0.8

    private struct Key: Hashable {
        let version: String
        let start: Int; let end: Int
        let grav: StreamFingerprint; let hr: StreamFingerprint; let rr: StreamFingerprint
    }
    private struct Staged { let segments: [StageSegment]? }
    /// As `SleepStagerV2.stageCache`: the scoring loop and the edited-night self-heal ask for the same
    /// window with the same streams pass after pass.
    private static let cache = AnalyticsMemoCache<Key, Staged>(capacity: 24)

    /// The hypnogram of `[start, end]` by the resolved model, tiled as `SleepStagerV2.stageSession`
    /// tiles its own: the first segment begins at `start`, the last ends at `end`. nil when no model is
    /// available, when motion or heart rate cover the window too thinly, or when the model does not
    /// answer; the caller then stages with the recipe.
    ///
    /// `useBundled` is the product flag: when true and no test model is installed, the shipped trees run.
    /// Tests that do not install a model leave it false so they stay on the recipe.
    public static func stageSession(start: Int, end: Int, grav: [GravitySample],
                                    hr: [HRSample], rr: [RRInterval],
                                    useBundled: Bool = false) -> [StageSegment]? {
        guard let model = resolved(useBundled: useBundled), end > start else { return nil }
        // Only what the features read: the window and `reach` either side.
        let lo = start - SleepStageFeatures.reach - 30, hi = end + SleepStageFeatures.reach + 30
        let gravW = grav.filter { $0.ts >= lo && $0.ts < hi }
        let hrW = hr.filter { $0.ts >= lo && $0.ts < hi }
        let rrW = rr.filter { $0.ts >= lo && $0.ts < hi }
        let key = Key(version: model.version, start: start, end: end,
                      grav: StreamFingerprint.of(gravW, ts: { $0.ts }, quant: {
                          StreamFingerprint.gravityQuant(x: $0.x, y: $0.y, z: $0.z)
                      }),
                      hr: StreamFingerprint.of(hrW, ts: { $0.ts }, quant: { Int($0.bpm) }),
                      rr: StreamFingerprint.of(rrW, ts: { $0.ts }, quant: { Int($0.rrMs) }))
        return cache.value(key) {
            Staged(segments: stageUncached(model, start: start, end: end, grav: gravW, hr: hrW, rr: rrW))
        }.segments
    }

    /// Whether motion and heart rate cover `[start, end)` densely enough for the model.
    static func covers(start: Int, end: Int, grav: [GravitySample], hr: [HRSample]) -> Bool {
        let seconds = end - start
        if seconds <= 0 { return false }
        var moved = [Bool](repeating: false, count: seconds)
        var movedN = 0
        for g in grav where g.ts >= start && g.ts < end {
            let t = g.ts - start
            if !moved[t] { moved[t] = true; movedN += 1 }
        }
        let bins = (seconds + SleepStageFeatures.hrBin - 1) / SleepStageFeatures.hrBin
        var beat = [Bool](repeating: false, count: bins)
        var beatN = 0
        for h in hr where h.ts >= start && h.ts < end {
            let b = (h.ts - start) / SleepStageFeatures.hrBin
            if !beat[b] { beat[b] = true; beatN += 1 }
        }
        return Double(movedN) >= minCoverage * Double(seconds)
            && Double(beatN) >= minCoverage * Double(bins)
    }

    private static func stageUncached(_ model: SleepStageModel, start: Int, end: Int, grav: [GravitySample],
                                      hr: [HRSample], rr: [RRInterval]) -> [StageSegment]? {
        guard covers(start: start, end: end, grav: grav, hr: hr) else { return nil }
        let rows = SleepStageFeatures.rows(start: start, end: end, grav: grav, hr: hr, rr: rr)
        if rows.isEmpty { return nil }
        let xs = SleepStageContext.firstInput(rows)
        guard let p1 = model.first(xs), valid(p1, rows.count),
              let p = model.second(SleepStageContext.secondInput(first: xs, probabilities: p1)),
              valid(p, rows.count) else { return nil }
        let labels = SleepStageDecoder.decode(p, prior: model.prior, weight: model.weight,
                                              smoothing: model.smoothing)
        var segments: [StageSegment] = []
        for (i, row) in rows.enumerated() {
            let segStart = i == 0 ? start : row.start
            let segEnd = i == rows.count - 1 ? end : rows[i + 1].start
            if let last = segments.last, last.stage == labels[i] {
                segments[segments.count - 1].end = segEnd
            } else {
                segments.append(StageSegment(start: segStart, end: segEnd, stage: labels[i]))
            }
        }
        return segments
    }

    /// A model's answer is usable when it is one finite row of four per epoch.
    private static func valid(_ p: [[Double]], _ epochs: Int) -> Bool {
        p.count == epochs && p.allSatisfy { $0.count == SleepStageDecoder.stages.count && $0.allSatisfy { $0.isFinite } }
    }
}

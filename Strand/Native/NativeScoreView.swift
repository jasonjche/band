import SwiftUI
import Charts
import WhoopStore
import StrandDesign
import StrandAnalytics
import WhoopProtocol

// One score page, shared by Sleep, Recovery, and Strain.
// Screenshot shape: back is the system bar, then the ring, four contributor
// rows, the comparison legend, one sentence, and a week of bars.

enum NativeScoreKind { case recovery, strain, sleep }

/// Pushed from Home. Same model as the rings, so the number cannot disagree.
private struct NativeSleepEditTarget: Identifiable {
    var session: CachedSleepSession
    var id: Int { session.startTs }
}

struct NativeScorePage: View {
    var kind: NativeScoreKind
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""
    @State private var repoHandle: Repository?
    @State private var intelligenceHandle: IntelligenceEngine?
    @State private var refreshSeq = 0
    @State private var handlesReady = false
    @State private var workouts: [WorkoutRow] = []
    @State private var workoutsSeq = -1
    @State private var overnightHr: [NativeHourPoint] = []
    @State private var overnightHrAverage: Double?
    @State private var overnightPlot = NativeOvernightPlotModel.empty
    @State private var highSleepStress: Double?
    @State private var sleepStress: NativeSleepStress.Model?
    @State private var sleepEdit: NativeSleepEditTarget?
    @State private var dayModel: NativeDay.Model?
    @State private var weekCards: [NativeWeek.Card] = []
    @State private var sleepDetail: NativeSleepPageDetail?
    @State private var nightSession: CachedSleepSession?
    @State private var strainTarget: BandStrainTarget.Result?
    @State private var hrvTrend: HRVTrend.DayResult?
    @State private var overnightLoad: BandIllnessSignal.DayResult?

    private var selectedDay: Date {
        NativeDaySelection.date(from: selectedDayKey)
    }

    private var dayKey: String {
        NativeDayLogic.resolvedDayKey(stored: selectedDayKey)
    }

    private var rebuildID: String {
        handlesReady ? "\(refreshSeq)-\(dayKey)-\(effortScaleRaw)" : "boot"
    }

    private var sleepBoundsID: String {
        "\(dayModel?.sleepStart?.timeIntervalSince1970 ?? 0)-\(dayModel?.sleepEnd?.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {
        Group {
            if let model = dayModel {
                NativeScoreView(
                    score: kind == .recovery ? model.recovery : kind == .strain ? model.strain : model.sleep,
                    weekCards: weekCards,
                    kind: kind,
                    sleepHours: model.sleepHours,
                    asleepMinutes: model.asleepMinutes,
                    stages: model.sleepStages,
                    activities: model.activities,
                    sleepStart: model.sleepStart,
                    sleepEnd: model.sleepEnd,
                    overnightHr: overnightHr,
                    overnightHrAverage: overnightHrAverage,
                    overnightPlot: overnightPlot,
                    awakeTypical: model.awakeTypical,
                    dayKey: dayKey,
                    needMinutes: NativeSleepNeed.needMinutes(sleepDetail?.need) ?? model.sleepNeedMin,
                    debtMinutes: model.sleepDebtMin,
                    sleepDetail: sleepDetail,
                    onEditSleep: kind == .sleep && nightSession != nil ? { sleepEdit = nightSession.map(NativeSleepEditTarget.init) } : nil,
                    strainTarget: strainTarget,
                    hrvTrend: hrvTrend,
                    overnightLoad: overnightLoad
                )
            } else {
                NativeChrome.screen {
                    ProgressView("Loading")
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
                    .navigationTitle(kind == .recovery ? "Recovery" : kind == .strain ? "Strain" : "Sleep")
                    .modifier(NativeInlineTitle())
            }
        }
        .nativeDateSubtitle(selectedDay)
        .background {
            NativeRepoSink(refreshSeq: $refreshSeq, ready: $handlesReady) { repoHandle = $0 }
            NativeIntelligenceSink { intelligenceHandle = $0 }
        }
        .sheet(item: $sleepEdit) { target in
            let session = target.session
            let coverageLo = min(session.startTs, session.effectiveStartTs)
            SleepTimeEditor(
                bedTs: session.effectiveStartTs,
                wakeTs: session.endTs,
                coverage: coverageLo...max(session.endTs, coverageLo + 1),
                suppressesReDetection: !session.userEdited,
                onSave: { newBedTs, newWakeTs in
                    await repoHandle?.editSleepTimes(
                        detectedStartTs: session.startTs, oldEndTs: session.endTs,
                        storedStagesJSON: session.stagesJSON,
                        newStartTs: newBedTs, newEndTs: newWakeTs
                    )
                    await intelligenceHandle?.analyzeRecent()
                    await repoHandle?.refresh()
                },
                onDelete: {
                    _ = await repoHandle?.deleteSleepSession(detectedStartTs: session.startTs, endTs: session.endTs)
                    await intelligenceHandle?.analyzeRecent()
                    await repoHandle?.refresh()
                }
            )
        }
        .task(id: rebuildID) {
            guard handlesReady else { return }
            if workoutsSeq != refreshSeq {
                let rows = await repoHandle?.workoutRows(days: 120) ?? workouts
                if Task.isCancelled { return }
                workouts = rows
                workoutsSeq = refreshSeq
            }
            await rebuild(includingSleepDetail: kind != .sleep)
        }
        .task(id: sleepBoundsID) {
            guard handlesReady else { return }
            guard let repo = repoHandle, let start = dayModel?.sleepStart, let end = dayModel?.sleepEnd else {
                overnightHr = []
                overnightHrAverage = nil
                overnightPlot = .empty
                highSleepStress = nil
                sleepStress = nil
                await rebuild(includingSleepDetail: true)
                return
            }
            let from = Int(start.timeIntervalSince1970)
            let to = Int(end.timeIntervalSince1970)
            guard kind == .sleep else {
                let overnightHR = await repo.hrSamples(from: from, to: to, limit: 8_000)
                if Task.isCancelled { return }
                let heart = NativeOvernightHeart.make(samples: overnightHR)
                let plot = await Task.detached(priority: .utility) {
                    NativeOvernightPlotModel.make(points: heart.points)
                }.value
                if Task.isCancelled { return }
                overnightHr = heart.points
                overnightHrAverage = heart.average
                overnightPlot = plot
                highSleepStress = nil
                sleepStress = nil
                return
            }
            let heart = await NativeDerivedSeries.overnightHeart(
                repo: repo, start: start, end: end, dayKey: dayKey
            )
            if Task.isCancelled { return }
            let mapped = heart.points
            let baselines = NativeHomeCharts.stressBaselines(days: repo.days, todayKey: dayKey)
            let overnightHR = await repo.hrSamples(from: from, to: to, limit: 200_000)
            if Task.isCancelled { return }
            let stressModel = await Task.detached(priority: .utility) {
                NativeSleepStress.make(
                    hr: overnightHR, startTs: from, endTs: to, baselines: baselines
                )
            }.value
            if Task.isCancelled { return }
            let plot = await Task.detached(priority: .utility) {
                NativeOvernightPlotModel.make(points: mapped)
            }.value
            if Task.isCancelled { return }
            overnightHr = mapped
            overnightHrAverage = heart.average
            overnightPlot = plot
            sleepStress = stressModel
            // One source: the row reads the chart's own share so the two cannot disagree.
            highSleepStress = stressModel?.highShare ?? BandStress.overnightHighShare(
                hr: overnightHR, startTs: from, endTs: to, baselines: baselines
            )
            await rebuild(includingSleepDetail: true)
        }
        .task(id: "hrv-sws-\(sleepBoundsID)") {
            guard handlesReady, kind == .recovery,
                  let repo = repoHandle,
                  let start = dayModel?.sleepStart, let end = dayModel?.sleepEnd else { return }
            let from = Int(start.timeIntervalSince1970)
            let to = Int(end.timeIntervalSince1970)
            let rr = await repo.rrIntervals(from: from, to: to, limit: 50_000)
            let beats = rr.map { BandHrvSws.Beat(tSec: Double($0.ts), rrMs: Double($0.rrMs)) }
            let session = repo.sleeps.last {
                NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs)))
                    == dayKey
            }
            let epochs = NativeBandScores.epochs(from: session?.stagesJSON, sessionStart: session?.effectiveStartTs ?? from)
            let nightly = repo.days.last { $0.day == dayKey }?.avgHrv
            NativeBandScores.logHrvSws(
                beats: beats, epochs: epochs, sleepStart: start, sleepEnd: end, nightlyHrv: nightly
            )
        }
    }

    /// Rings, week cards, sleep detail — once per data change, off the main actor.
    /// Sleep-page detail cards wait for overnight HR so they do not appear in a second layout pass.
    private func rebuild(includingSleepDetail: Bool = true) async {
        guard let repo = repoHandle else { return }
        let viewingKey = dayKey
        let days = repo.days
        let sleeps = repo.sleeps
        let imported = repo.importedSleep
        let rows = workouts
        let scale = UnitPrefs.resolveEffortScale(effortScaleRaw)
        let kind = kind
        let highStress = highSleepStress
        let liveStrain = NativeLiveStrainMemo.latest(day: viewingKey)
        let stress = sleepStress
        let night = sleeps
            .filter {
                NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == viewingKey
            }
            .sorted { ($0.endTs - $0.effectiveStartTs) > ($1.endTs - $1.effectiveStartTs) }
            .first
        let parsed = night.map { repo.parsedStages(for: $0) } ?? []
        let built = await Task.detached(priority: .userInitiated) {
            NativeScoreRebuild.run(
                kind: kind,
                dayKey: viewingKey,
                days: days,
                sleeps: sleeps,
                workouts: rows,
                importedSleep: imported,
                effortScale: scale,
                highSleepStress: highStress,
                liveStrain: liveStrain,
                sleepStress: stress,
                parsedStages: parsed,
                includingSleepDetail: includingSleepDetail
            )
        }.value
        guard viewingKey == dayKey else { return }
        nightSession = night
        dayModel = built.dayModel
        weekCards = built.weekCards
        if includingSleepDetail {
            sleepDetail = built.sleepDetail
        }
        strainTarget = built.strainTarget
        hrvTrend = built.hrvTrend
        overnightLoad = built.overnightLoad
    }
}

enum NativeScoreRebuild {
    struct Snapshot {
        var dayModel: NativeDay.Model
        var weekCards: [NativeWeek.Card]
        var sleepDetail: NativeSleepPageDetail?
        var strainTarget: BandStrainTarget.Result?
        var hrvTrend: HRVTrend.DayResult?
        var overnightLoad: BandIllnessSignal.DayResult?
    }

    static func run(
        kind: NativeScoreKind,
        dayKey: String,
        days: [DailyMetric],
        sleeps: [CachedSleepSession],
        workouts: [WorkoutRow],
        importedSleep: [String: ImportedSleepFigures],
        effortScale: EffortScale,
        highSleepStress: Double?,
        liveStrain: Double?,
        sleepStress: NativeSleepStress.Model?,
        parsedStages: [ParsedSleepStage],
        includingSleepDetail: Bool
    ) -> Snapshot {
        let dayModel = NativeDay.make(
            days: days, sleeps: sleeps, workouts: workouts,
            todayKey: dayKey,
            connected: false,
            effortScale: effortScale,
            importedSleep: importedSleep,
            highSleepStress: kind == .sleep ? highSleepStress : nil,
            liveStrain: liveStrain
        )
        let baseWeek = NativeWeek.cards(
            kind: kind, days: days, todayKey: dayKey,
            effortScale: effortScale,
            sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        let weekCards = NativeSleepWeek.cards(
            kind: kind, base: baseWeek, days: days, todayKey: dayKey,
            sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        var sleepDetail: NativeSleepPageDetail?
        if includingSleepDetail, kind == .sleep {
            var detail = NativeSleepPageDetail.make(
                dayKey: dayKey, days: days, sleeps: sleeps, workouts: workouts,
                importedSleep: importedSleep, stress: sleepStress, parsedStages: parsedStages
            )
            if let start = dayModel.sleepStart, let end = dayModel.sleepEnd, end > start,
               !detail.hypnogram.isEmpty {
                detail.hypnogramLayout = NativeSleepHypnogramLayout.make(
                    spans: detail.hypnogram, nightStart: start, nightEnd: end
                )
            }
            if let stress = detail.stress {
                detail.stressPlot = NativeSleepStressPlotModel.make(points: stress.points)
            }
            if let hoursCard = weekCards.first(where: { $0.title == "Hours vs. Needed" }) {
                detail.dualLine = NativeSleepDualLineModel.make(
                    slept: hoursCard.points,
                    needed: detail.hoursNeededWeek,
                    typical: detail.hoursTypical
                )
            }
            if let bedCard = weekCards.first(where: { $0.title == "Time in Bed" }) {
                detail.timeInBedPlot = NativeSleepTimeInBedPlotModel.make(points: bedCard.points)
            }
            if let restCard = weekCards.first(where: { $0.title == "Restorative Sleep" }) {
                detail.restorativePlot = NativeSleepRestorativePlotModel.make(
                    deep: restCard.stacks.first { $0.title == "Deep" }?.points ?? [],
                    rem: restCard.stacks.first { $0.title == "REM" }?.points ?? []
                )
            }
            sleepDetail = detail
        } else {
            sleepDetail = nil
        }
        return Snapshot(
            dayModel: dayModel,
            weekCards: weekCards,
            sleepDetail: sleepDetail,
            strainTarget: kind == .strain
                ? NativeStrainTarget.resolve(
                    viewingKey: dayKey,
                    todayKey: NativeDayLogic.logicalToday(),
                    days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
                )
                : nil,
            hrvTrend: kind == .recovery ? NativeHRVTrend.result(days: days, dayKey: dayKey) : nil,
            overnightLoad: kind == .recovery ? NativeIllnessSignal.result(days: days, dayKey: dayKey) : nil
        )
    }
}

struct NativeScoreView: View {
    var score: NativeScore
    var weekCards: [NativeWeek.Card] = []
    var kind: NativeScoreKind = .recovery
    var sleepHours: String? = nil
    var asleepMinutes: Double? = nil
    var stages: [NativeStage] = []
    var activities: [NativeDay.Activity] = []
    var sleepStart: Date? = nil
    var sleepEnd: Date? = nil
    var overnightHr: [NativeHourPoint] = []
    var overnightHrAverage: Double? = nil
    var overnightPlot: NativeOvernightPlotModel? = nil
    var awakeTypical: Double? = nil
    var dayKey: String? = nil
    var needMinutes: Double? = nil
    var debtMinutes: Double? = nil
    var scrolls: Bool = true
    var sleepDetail: NativeSleepPageDetail? = nil
    var onEditSleep: (() -> Void)? = nil
    var strainTarget: BandStrainTarget.Result? = nil
    var hrvTrend: HRVTrend.DayResult? = nil
    var overnightLoad: BandIllnessSignal.DayResult? = nil
    private var visibleRows: [NativeScore.Row] {
        var rows = score.rows.filter { NativeScoreMath.hasValue($0.value) }
        if kind == .sleep, let restorative = NativeSleepContributors.restorative(from: stages),
           NativeScoreMath.hasValue(restorative.value),
           !rows.contains(where: { $0.title == restorative.title }) {
            if let idx = rows.firstIndex(where: { $0.title == "High Sleep Stress" }) {
                rows.insert(restorative, at: idx)
            } else {
                rows.append(restorative)
            }
        }
        return rows
    }

    var body: some View {
        Group {
            if scrolls {
                NativeChrome.screen(lazy: true) { scoreBody }
            } else {
                NativeChrome.stack { scoreBody }
            }
        }
        .navigationTitle(score.name)
        .modifier(NativeInlineTitle())
        .navigationDestination(for: NativeScoreMetricRoute.self) { route in
            NativeMetricPage(key: route.key)
        }
        .navigationDestination(for: NativeScoreTrendRoute.self) { route in
            if let card = weekCards.first(where: { $0.title == route.title }) {
                NativeScoreTrendPage(
                    card: card,
                    dayKey: dayKey,
                    format: { NativeScoreWeekFormat.label(card, $0) },
                    axisFormat: { NativeScoreWeekFormat.axisLabel(card, $0) },
                    unit: NativeScoreWeekFormat.unit(card),
                    symbol: NativeScoreWeekFormat.symbol(card),
                    tint: NativeScoreWeekFormat.tint(card, style: style),
                    color: card.band ? NativeScoreWeekFormat.band(kind: kind, style: style) : nil
                )
            }
        }
        .navigationDestination(for: NativeSleepConsistencyRoute.self) { _ in
            NativeSleepConsistencyPage(
                nights: sleepDetail?.consistencyNights ?? [],
                percent: NativeScoreMath.percentValue(
                    score.rows.first { $0.title == "Sleep Consistency" }?.value ?? ""
                )
            )
        }
        .navigationDestination(for: NativeSleepHypnogramRoute.self) { _ in
            NativeSleepHypnogramPage(
                spans: sleepDetail?.hypnogram ?? [],
                layout: sleepDetail?.hypnogramLayout,
                nightStart: sleepStart,
                nightEnd: sleepEnd,
                stages: stages,
                asleepMinutes: asleepMinutes,
                awakeTypical: awakeTypical,
                estimated: sleepDetail?.hypnogramEstimated ?? false
            )
        }
    }

    @Environment(\.nativeStyle) private var style

    // Each block below is its own non-generic view. The page's body type stays a short tuple of
    // nominal types, so SwiftUI only instantiates a block's (deeply generic) body type when that
    // block is actually built — the Sleep page never pays for the Recovery or Strain cards.
    @ViewBuilder private var scoreBody: some View {
        NativeScoreHero(score: score, kind: kind, dayKey: dayKey, strainTarget: strainTarget)
        if !visibleRows.isEmpty {
            NativeScoreContributors(rows: visibleRows, kind: kind, score: score, dayKey: dayKey)
        }
        switch kind {
        case .sleep:
            NativeSleepScoreSection(
                score: score,
                sleepHours: sleepHours,
                asleepMinutes: asleepMinutes,
                stages: stages,
                sleepStart: sleepStart,
                sleepEnd: sleepEnd,
                overnightHr: overnightHr,
                overnightHrAverage: overnightHrAverage,
                overnightPlot: overnightPlot,
                awakeTypical: awakeTypical,
                needMinutes: needMinutes,
                debtMinutes: debtMinutes,
                sleepDetail: sleepDetail,
                onEditSleep: onEditSleep
            )
        case .recovery:
            NativeHRVTrendCard(result: hrvTrend)
            NativeIllnessSignalCard(result: overnightLoad)
        case .strain:
            NativeStrainActivitiesCard(activities: activities)
        }
        if !weekCards.isEmpty {
            NativeChrome.section("Weekly Trends")
            ForEach(weekCards) { card in
                NativeScoreWeekCard(card: card, kind: kind, dayKey: dayKey, sleepDetail: sleepDetail)
            }
        }
    }

    static func ringCaption(_ kind: NativeScoreKind) -> String {
        switch kind {
        case .sleep: return "Sleep Performance"
        case .recovery: return "Recovery"
        case .strain: return "Strain"
        }
    }

    static func ringTint(kind: NativeScoreKind, score: NativeScore, style: NativeStyle) -> Color {
        switch kind {
        case .sleep: return NativePaint.sleep(style)
        case .strain: return NativePaint.strain(style)
        case .recovery:
            if let percent = NativeScoreMath.percentValue(score.value) {
                return NativePaint.recoveryBand(percent, style: style)
            }
            return NativePaint.recovery(style)
        }
    }

    static func shortTitle(_ title: String) -> String {
        switch title {
        case "Hours vs. Needed": return "Hours"
        case "Heart Rate Variability": return "HRV"
        case "Resting Heart Rate": return "Resting HR"
        case "Respiratory Rate": return "Respiratory"
        default: return title
        }
    }

    static func stageTint(_ stage: NativeStage, style: NativeStyle = .apple) -> Color {
        NativePaint.sleepStage(named: stage.name, style: style)
    }
}

/// Ring (or "No data") plus the Strain target caption.
private struct NativeScoreHero: View {
    var score: NativeScore
    var kind: NativeScoreKind
    var dayKey: String?
    var strainTarget: BandStrainTarget.Result?
    @Environment(\.nativeStyle) private var style

    var body: some View {
        Group {
            if score.known {
                NativeRing(
                    fraction: score.fraction,
                    tint: NativeScoreView.ringTint(kind: kind, score: score, style: style),
                    value: score.value,
                    caption: NativeScoreView.ringCaption(kind),
                    diameter: 184,
                    targetFraction: kind == .strain ? strainTarget.map { NativeStrainTarget.ringFraction($0.range) } : nil
                )
                .frame(maxWidth: .infinity)
            } else {
                NativeHeroValue(
                    value: "No data",
                    date: dayKey.map { NativeChartDay.mediumDate($0) }
                )
            }
        }
        .frame(minHeight: 200)
        .padding(.vertical, 8)
        if kind == .strain, let strainTarget {
            Text(NativeStrainTarget.caption(result: strainTarget, strain21: score.fraction.map { $0 * 21 }))
                .font(style == .whoop ? NativeTokens.whoopCaps(11) : .subheadline)
                .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
        }
    }
}

/// Contributor rows panel and the "vs. last 30 days" footnote.
private struct NativeScoreContributors: View {
    var rows: [NativeScore.Row]
    var kind: NativeScoreKind
    var score: NativeScore
    var dayKey: String?
    @Environment(\.nativeStyle) private var style
    @Environment(\.nativeNavigationPath) private var path

    var body: some View {
        NativeChrome.panel {
            VStack(spacing: 0) {
                let firstRowID = rows.first?.id
                ForEach(rows) { row in
                    if row.id != firstRowID {
                        Divider().padding(.leading, 34)
                    }
                    Button {
                        NativeScoreRoutes.openRow(row, path: path)
                    } label: {
                        HStack(spacing: 8) {
                            NativeContributorRow(
                                symbol: row.symbol,
                                title: row.title,
                                value: row.value,
                                prior: NativeScoreMath.hasValue(row.prior) ? row.prior : nil,
                                delta: row.delta,
                                tint: tint(row),
                                // Contributor values are all drawn the same; the arrow carries the comparison.
                                valueTint: .primary
                            )
                            Image(systemName: "chevron.forward")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if style == .whoop {
            NativeWhoopCompareChip(kind: kind, dayKey: dayKey)
        } else {
            NativeChrome.footnote("Compared with your last 30 days")
        }
    }

    private func tint(_ row: NativeScore.Row) -> Color {
        switch row.title {
        case "Heart Rate Variability", "Resting Heart Rate": return NativePaint.heart(style)
        case "Respiratory Rate": return NativePaint.respiratory(style)
        case "Sleep Performance", "Sleep Efficiency", "Hours vs. Needed", "Sleep Consistency",
             "Restorative Sleep", "High Sleep Stress": return NativePaint.sleep(style)
        case "Steps", "Calories": return NativePaint.activity(style)
        case "Heart Rate Zones 1–3", "Heart Rate Zones 4–5": return NativePaint.heart(style)
        case "Strength Activity Time": return NativePaint.strain(style)
        default: return NativeScoreView.ringTint(kind: kind, score: score, style: style)
        }
    }
}

/// Sleep-only cards between the contributors and the weekly trends.
private struct NativeSleepScoreSection: View {
    var score: NativeScore
    var sleepHours: String?
    var asleepMinutes: Double?
    var stages: [NativeStage]
    var sleepStart: Date?
    var sleepEnd: Date?
    var overnightHr: [NativeHourPoint]
    var overnightHrAverage: Double?
    var overnightPlot: NativeOvernightPlotModel?
    var awakeTypical: Double?
    var needMinutes: Double?
    var debtMinutes: Double?
    var sleepDetail: NativeSleepPageDetail?
    var onEditSleep: (() -> Void)?
    @Environment(\.nativeNavigationPath) private var path

    private var hasLastNight: Bool {
        asleepMinutes != nil || sleepHours != nil || !stages.isEmpty || sleepStart != nil
    }

    var body: some View {
        if hasLastNight {
            NativeLastNightCard(
                asleepMinutes: asleepMinutes,
                sleepHours: sleepHours,
                stages: stages,
                sleepStart: sleepStart,
                sleepEnd: sleepEnd,
                awakeTypical: awakeTypical,
                needMinutes: needMinutes,
                debtMinutes: debtMinutes,
                onEdit: onEditSleep,
                spans: sleepDetail?.hypnogram ?? [],
                hypnogramLayout: sleepDetail?.hypnogramLayout,
                hypnogramEstimated: sleepDetail?.hypnogramEstimated ?? false,
                onHypnogram: { path.wrappedValue.append(NativeSleepHypnogramRoute()) }
            )
        }
        NativeSleepPlannerLink(needMinutes: needMinutes ?? sleepDetail?.need?.needMin)
        NativeOvernightHeartCard(
            points: overnightHr,
            average: overnightHrAverage,
            plot: overnightPlot,
            onOpen: { path.wrappedValue.append(NativeScoreMetricRoute(key: "avg_hr")) }
        )
        if let need = sleepDetail?.need ?? hoursNeededFromPage,
           need.percent != nil || need.hoursSleptMin != nil {
            NativeSleepHoursVsNeededCard(
                model: need,
                onOpen: { path.wrappedValue.append(NativeScoreMetricRoute(key: "hours_vs_needed_pct")) }
            )
        }
        if let nights = sleepDetail?.consistencyNights, !nights.isEmpty {
            NativeSleepConsistencyCard(
                nights: nights,
                percent: NativeScoreMath.percentValue(
                    score.rows.first { $0.title == "Sleep Consistency" }?.value ?? ""
                ),
                onOpen: { path.wrappedValue.append(NativeSleepConsistencyRoute()) }
            )
        }
        if let efficiency = sleepDetail?.efficiency {
            NativeSleepEfficiencyCard(
                model: efficiency,
                onOpen: { path.wrappedValue.append(NativeScoreMetricRoute(key: "sleep_efficiency")) }
            )
        }
        if let stress = sleepDetail?.stress {
            NativeSleepStressCard(
                model: stress,
                plot: sleepDetail?.stressPlot,
                onOpen: { path.wrappedValue.append(TabRoute.stress) }
            )
        }
    }

    private var hoursNeededFromPage: NativeSleepNeed.Resolved? {
        guard let needMinutes, needMinutes > 0 else { return nil }
        return NativeSleepNeed.Resolved(
            needMin: needMinutes,
            hoursSleptMin: asleepMinutes,
            percent: asleepMinutes.flatMap { needMinutes > 0 ? $0 / needMinutes * 100 : nil },
            imported: true,
            baselineMin: nil,
            strainMin: nil,
            debtMin: nil
        )
    }
}

private struct NativeSleepPlannerLink: View {
    var needMinutes: Double?
    @Environment(\.nativeStyle) private var style
    @AppStorage("native.sleepPlanner.wakeMinutes") private var plannerWakeMinutes = 7 * 60
    @AppStorage("native.sleepPlanner.goal") private var plannerGoalRaw = SleepPlanner.Goal.peak.rawValue

    var body: some View {
        NavigationLink {
            NativeSleepPlanner()
        } label: {
            NativeChrome.panel {
                NativeCardHeader(
                    title: "Sleep Planner",
                    symbol: "bed.double.fill",
                    tint: NativePaint.sleep(style),
                    chevron: true
                )
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sleep Planner, \(subtitle)")
    }

    private var subtitle: String {
        NativeSleepPlannerLogic.cardSubtitle(
            needMin: needMinutes,
            wakeMinutes: plannerWakeMinutes,
            goal: SleepPlanner.Goal(rawValue: plannerGoalRaw) ?? .peak
        )
    }
}

private struct NativeStrainActivitiesCard: View {
    var activities: [NativeDay.Activity]
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            NativeCardHeader(title: "Activities", symbol: "figure.run", tint: NativeChrome.strain)
            if activities.isEmpty {
                Text("No activities")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    let firstActivityID = activities.first?.id
                    ForEach(activities) { activity in
                        if activity.id != firstActivityID {
                            Divider().padding(.vertical, 4)
                        }
                        NavigationLink(value: NativeActivityRoute(startTs: activity.startTs)) {
                            NativeActivityRow(
                                symbol: activity.symbol,
                                tint: NativePaint.strain(style),
                                title: activity.sport,
                                trailing: activity.strainText,
                                startClock: activity.startClock,
                                endClock: activity.endClock
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// One "Weekly Trends" card. Sleep's three bespoke charts, else the shared chart block.
private struct NativeScoreWeekCard: View {
    var card: NativeWeek.Card
    var kind: NativeScoreKind
    var dayKey: String?
    var sleepDetail: NativeSleepPageDetail?
    @Environment(\.nativeNavigationPath) private var path

    var body: some View {
        if kind == .sleep, card.title == "Hours vs. Needed", let detail = sleepDetail {
            NativeSleepDualLineCard(
                title: card.title,
                slept: card.points,
                needed: detail.hoursNeededWeek,
                highlightKey: dayKey,
                typical: detail.hoursTypical,
                plot: detail.dualLine,
                onOpen: open
            )
        } else if kind == .sleep, card.title == "Time in Bed" {
            NativeSleepTimeInBedWeekCard(
                points: card.points,
                highlightKey: dayKey,
                plot: sleepDetail?.timeInBedPlot,
                onOpen: open
            )
        } else if kind == .sleep, card.title == "Restorative Sleep" {
            NativeSleepRestorativeWeekCard(
                deep: card.stacks.first { $0.title == "Deep" }?.points ?? [],
                rem: card.stacks.first { $0.title == "REM" }?.points ?? [],
                highlightKey: dayKey,
                plot: sleepDetail?.restorativePlot,
                onOpen: open
            )
        } else {
            NativeScoreWeekChartCard(card: card, kind: kind, dayKey: dayKey, onOpen: open)
        }
    }

    private func open() {
        NativeScoreRoutes.openCard(card, path: path)
    }
}

private struct NativeScoreWeekChartCard: View {
    var card: NativeWeek.Card
    var kind: NativeScoreKind
    var dayKey: String?
    var onOpen: () -> Void
    @Environment(\.nativeStyle) private var style

    var body: some View {
        let tint = NativeScoreWeekFormat.tint(card, style: style)
        NativeChrome.panel {
            NativeCardHeader(
                title: card.title,
                symbol: NativeScoreWeekFormat.symbol(card),
                tint: tint,
                chevron: true
            )
            NativeChartBlock(
                points: card.points,
                bars: card.bars,
                tint: tint,
                format: { [card] in NativeScoreWeekFormat.label(card, $0) },
                axisFormat: { [card] in NativeScoreWeekFormat.axisLabel(card, $0) },
                unit: NativeScoreWeekFormat.unit(card),
                maxY: card.maxY,
                color: card.band ? NativeScoreWeekFormat.band(kind: kind, style: style) : nil,
                highlightKey: dayKey,
                plotHeight: 200,
                accessibilityName: card.title,
                clockHero: card.format == .duration,
                yTicks: NativeScoreWeekFormat.yTicks(card),
                stacks: card.stacks
            )
        }
        .contentShape(Rectangle())
        .nativeChartButton(action: onOpen)
    }
}

/// Labels, units, tints, and symbols for a week card. Shared by the card and its trend page.
enum NativeScoreWeekFormat {
    static func label(_ card: NativeWeek.Card, _ value: Double) -> String {
        guard value.isFinite else { return "—" }
        switch card.format {
        case .percent: return "\(Int(value.rounded()))"
        case .strain: return String(format: "%.1f", value)
        case .duration: return NativeScoreMath.duration(value)
        case .number:
            if card.title == "Steps" || card.title == "Calories" {
                return NativeDayLogic.countText(value)
            }
            return "\(Int(value.rounded()))"
        case .oneDecimal: return String(format: "%.1f", value)
        }
    }

    static func axisLabel(_ card: NativeWeek.Card, _ value: Double) -> String {
        guard value.isFinite else { return "" }
        switch card.format {
        case .percent: return "\(Int(value.rounded()))"
        case .strain: return String(format: "%.0f", value)
        case .duration: return NativeScoreMath.duration(value)
        case .number:
            if abs(value) >= 1000 { return "\(Int((value / 1000).rounded()))k" }
            return "\(Int(value.rounded()))"
        case .oneDecimal: return String(format: "%.1f", value)
        }
    }

    static func unit(_ card: NativeWeek.Card) -> String? {
        switch card.format {
        case .percent: return "%"
        case .strain: return nil
        case .duration: return nil
        case .number:
            switch card.title {
            case "Heart Rate Variability": return "ms"
            case "Resting Heart Rate": return "BPM"
            case "Steps": return "steps"
            case "Calories": return "cal"
            default: return nil
            }
        case .oneDecimal:
            return card.title == "Respiratory Rate" ? "breaths/min" : nil
        }
    }

    static func tint(_ card: NativeWeek.Card, style: NativeStyle) -> Color {
        switch card.title {
        case "Heart Rate Variability", "Resting Heart Rate": return NativePaint.heart(style)
        case "Respiratory Rate": return NativePaint.respiratory(style)
        case "Steps", "Calories": return NativePaint.activity(style)
        case "Heart Rate Zones 1–3", "Heart Rate Zones 4–5": return NativePaint.heart(style)
        case "Strength Activity Time": return NativePaint.strain(style)
        case "Strain": return NativePaint.strain(style)
        case "Recovery": return NativePaint.recovery(style)
        case "Sleep Performance", "Hours of Sleep", "Sleep Efficiency", "Hours vs. Needed",
             "Hours vs. Needed %", "Restorative Sleep", "Sleep Consistency", "Time in Bed",
             "Sleep Debt", "Sleep Stress": return NativePaint.sleep(style)
        default: return card.tint
        }
    }

    static func symbol(_ card: NativeWeek.Card) -> String {
        switch card.title {
        case "Sleep Performance", "Sleep Efficiency", "Time in Bed": return "bed.double.fill"
        case "Hours of Sleep", "Hours vs. Needed", "Hours vs. Needed %": return "clock.fill"
        case "Restorative Sleep": return "sparkles"
        case "Sleep Consistency": return "calendar"
        case "Sleep Debt": return "moon.fill"
        case "Sleep Stress": return "waveform.path"
        case "Recovery": return "heart.fill"
        case "Heart Rate Variability": return "waveform.path.ecg"
        case "Resting Heart Rate": return "heart.fill"
        case "Respiratory Rate": return "lungs.fill"
        case "Strain": return "bolt.fill"
        case "Steps": return "figure.walk"
        case "Calories": return "flame.fill"
        case "Heart Rate Zones 1–3": return "heart"
        case "Heart Rate Zones 4–5": return "heart.fill"
        case "Strength Activity Time": return "dumbbell.fill"
        default: return "chart.bar.fill"
        }
    }

    static func yTicks(_ card: NativeWeek.Card) -> [Double]? {
        switch card.format {
        case .percent: return NativeChartTicks.percent
        case .strain: return NativeDayLogic.strainYTicks(maxY: card.maxY)
        default: return nil
        }
    }

    /// Recovery week bars take the red/yellow/green band; other kinds use the card tint.
    static func band(kind: NativeScoreKind, style: NativeStyle) -> ((Double) -> Color)? {
        guard kind == .recovery else { return nil }
        return { NativePaint.recoveryBand($0, style: style) }
    }
}

/// Where a contributor row or week card pushes.
enum NativeScoreRoutes {
    static func openRow(_ row: NativeScore.Row, path: Binding<NavigationPath>) {
        if row.title == "Sleep Consistency" {
            path.wrappedValue.append(NativeSleepConsistencyRoute())
            return
        }
        if case .metric(let key) = row.route {
            path.wrappedValue.append(NativeScoreMetricRoute(key: key))
            return
        }
        path.wrappedValue.append(row.route)
    }

    static func openCard(_ card: NativeWeek.Card, path: Binding<NavigationPath>) {
        switch card.title {
        case "Hours of Sleep", "Time in Bed", "Heart Rate Zones 1–3", "Heart Rate Zones 4–5",
             "Strength Activity Time", "Restorative Sleep":
            path.wrappedValue.append(NativeScoreTrendRoute(title: card.title))
        case "Sleep Stress":
            path.wrappedValue.append(TabRoute.stress)
        case "Sleep Consistency":
            path.wrappedValue.append(NativeSleepConsistencyRoute())
        case "Sleep Debt":
            path.wrappedValue.append(NativeScoreMetricRoute(key: "sleep_debt_min"))
        default:
            if let route = card.route, case .metric(let key) = route {
                path.wrappedValue.append(NativeScoreMetricRoute(key: key))
            } else if let key = metricKey(for: card.title) {
                path.wrappedValue.append(NativeScoreMetricRoute(key: key))
            } else if let route = card.route {
                path.wrappedValue.append(route)
            } else {
                path.wrappedValue.append(NativeScoreTrendRoute(title: card.title))
            }
        }
    }

    static func metricKey(for title: String) -> String? {
        switch title {
        case "Sleep Performance": return "sleep_performance"
        case "Sleep Efficiency": return "sleep_efficiency"
        case "Hours vs. Needed", "Hours vs. Needed %": return "hours_vs_needed_pct"
        case "Sleep Consistency": return "sleep_consistency"
        case "Heart Rate Variability": return "hrv"
        case "Resting Heart Rate": return "resting_hr"
        case "Respiratory Rate": return "resp_rate"
        case "Recovery": return "recovery"
        case "Strain": return "strain"
        case "Steps": return "steps"
        case "Calories": return "energy_kcal"
        case "Blood Oxygen": return "spo2"
        case "Skin Temperature": return "skin_temp"
        default: return nil
        }
    }
}

struct NativeLastNightCard: View {
    var asleepMinutes: Double? = nil
    var sleepHours: String? = nil
    var stages: [NativeStage] = []
    var sleepStart: Date? = nil
    var sleepEnd: Date? = nil
    var awakeTypical: Double? = nil
    var needMinutes: Double? = nil
    var debtMinutes: Double? = nil
    var onEdit: (() -> Void)? = nil
    var spans: [NativeSleepStageSpan] = []
    var hypnogramLayout: NativeSleepHypnogramLayout? = nil
    var hypnogramEstimated: Bool = false
    var onHypnogram: (() -> Void)? = nil
    @Environment(\.nativeStyle) private var style
    @State private var selectedStage: NativeSleepStageKind?
    @State private var hapticTick = 0

    private var inBedMinutes: Double? {
        NativeDayLogic.inBedMinutes(start: sleepStart, end: sleepEnd)
    }

    private var needDebtLine: String? {
        let need = needMinutes.map { NativeScoreMath.duration($0) }
        let debt = debtMinutes.map { NativeScoreMath.duration($0) }
        switch (need, debt) {
        case let (n?, d?): return "Need \(n) · Debt \(d)"
        case let (n?, nil): return "Need \(n)"
        case let (nil, d?): return "Debt \(d)"
        default: return nil
        }
    }

    // Each style is its own nominal view so only the active layout's body type is instantiated.
    var body: some View {
        if style == .whoop {
            NativeLastNightWhoopLayout(card: self)
        } else {
            NativeLastNightAppleLayout(card: self)
        }
    }

    fileprivate var apple: some View {
        NativeChrome.panel {
            lastNightHeader(title: "Last Night")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    if let asleepMinutes {
                        NativeClockHero(caption: "Hours of sleep", minutes: asleepMinutes)
                    } else if let sleepHours {
                        NativeHeroValue(caption: "Hours of sleep", value: sleepHours)
                    }
                    if let needDebtLine {
                        Text(needDebtLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                if let inBedMinutes {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Time in bed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(NativeDayLogic.durationText(inBedMinutes))
                            .font(StrandFont.rounded(17, weight: .semibold))
                            .monospacedDigit()
                    }
                }
            }
            hypnogram
            appleStages
        }
        .modifier(NativeSleepLightHaptic(trigger: hapticTick))
    }

    fileprivate var whoop: some View {
        NativeChrome.panel {
            lastNightHeader(title: "Last Night's Sleep")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HOURS OF SLEEP")
                        .font(NativeTokens.whoopCaps(11))
                        .tracking(NativeTokens.whoopCapsTracking)
                        .foregroundStyle(NativeTokens.whoopLabel)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(asleepMinutes.map { NativeScoreMath.duration($0) } ?? sleepHours ?? "—")
                            .font(NativeTokens.whoopNumber(34))
                    }
                    if let needDebtLine {
                        Text(needDebtLine)
                            .font(NativeTokens.whoopNumber(13, weight: .regular))
                            .foregroundStyle(NativeTokens.whoopLabel)
                    }
                    if let inBedMinutes {
                        Text(NativeDayLogic.durationText(inBedMinutes))
                            .font(NativeTokens.whoopNumber(13, weight: .regular))
                            .foregroundStyle(NativeTokens.whoopLabel)
                    }
                }
                Spacer(minLength: 0)
            }
            hypnogram
            if !lastNightStages.isEmpty {
                HStack {
                    if drawsTypicalRange {
                        Text("TYPICAL RANGE")
                            .font(NativeTokens.whoopCaps(10))
                            .tracking(NativeTokens.whoopCapsTracking)
                            .foregroundStyle(NativeTokens.whoopLabel)
                    }
                    Spacer()
                    if let asleepMinutes {
                        Text("DURATION")
                            .font(NativeTokens.whoopCaps(10))
                            .tracking(NativeTokens.whoopCapsTracking)
                            .foregroundStyle(NativeTokens.whoopLabel)
                        Text(NativeDayLogic.durationText(asleepMinutes))
                            .font(NativeTokens.whoopNumber(15, weight: .semibold))
                    }
                }
                stageRows
            }
        }
        .modifier(NativeSleepLightHaptic(trigger: hapticTick))
    }

    private func lastNightHeader(title: String) -> some View {
        NativeCardHeader(title: title, symbol: "bed.double.fill", tint: NativePaint.sleep(style))
            .overlay(alignment: .trailing) {
                if let onEdit {
                    Button("Edit", action: onEdit)
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                }
            }
    }

    private var lastNightStages: [NativeStage] {
        NativeSleepNightRows.make(
            stages: stages,
            inBedMinutes: inBedMinutes,
            asleepMinutes: asleepMinutes,
            awakeTypical: awakeTypical
        )
    }

    private var drawsTypicalRange: Bool {
        lastNightStages.contains { ($0.typical ?? 0) > 0 }
    }

    private var stageScale: Double {
        max(inBedMinutes ?? lastNightStages.compactMap(\.minutes).reduce(0, +), 1)
    }

    @ViewBuilder private var hypnogram: some View {
        if let sleepStart, let sleepEnd, sleepEnd > sleepStart, !spans.isEmpty {
            NativeSleepHypnogram(
                spans: spans,
                nightStart: sleepStart,
                nightEnd: sleepEnd,
                layout: hypnogramLayout,
                highlight: selectedStage,
                estimated: hypnogramEstimated,
                onOpen: onHypnogram
            )
        }
    }

    @ViewBuilder private var appleStages: some View {
        if !lastNightStages.isEmpty {
            HStack {
                if drawsTypicalRange {
                    Text("Typical range")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let asleepMinutes {
                    Text("Duration \(NativeDayLogic.durationText(asleepMinutes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            stageRows
        }
    }

    @ViewBuilder private var stageRows: some View {
        let scale = stageScale
        ForEach(lastNightStages) { stage in
            let kind = NativeSleepStageKind.parse(stage.name)
            let minutes = stage.minutes ?? 0
            Button { selectStage(kind) } label: {
                NativeSleepStageRow(
                    kind: kind,
                    minutes: minutes,
                    percent: NativeSleepHypnogramMath.share(minutes: minutes, inBed: scale) * 100,
                    typical: stage.typical,
                    scale: scale,
                    selected: selectedStage == kind,
                    dimmed: selectedStage != nil && selectedStage != kind,
                    tappable: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func selectStage(_ kind: NativeSleepStageKind) {
        selectedStage = NativeSleepHypnogramMath.toggleHighlight(selectedStage, tapped: kind)
        hapticTick += 1
    }
}

private struct NativeLastNightAppleLayout: View {
    var card: NativeLastNightCard
    var body: some View { card.apple }
}

private struct NativeLastNightWhoopLayout: View {
    var card: NativeLastNightCard
    var body: some View { card.whoop }
}

enum NativeOvernightHeart {
    /// Display budget for the Sleep HR chart (300–600 Chart marks).
    static let displayTarget = 480
    static let displayMin = 300
    static let displayMax = 600

    struct Model: Equatable {
        var points: [NativeHourPoint]
        var average: Double?
        var rawCount: Int
        var plotCount: Int { points.count }
    }

    /// Downsample for the Sleep HR chart. Stats still use the raw samples.
    static func points(from samples: [HRSample], every: Int = 2, cap: Int = 8_000) -> [NativeHourPoint] {
        samples.prefix(cap).enumerated().compactMap { index, sample in
            guard every <= 1 || index % every == 0 else { return nil }
            return NativeHourPoint(
                time: Date(timeIntervalSince1970: TimeInterval(sample.ts)),
                value: Double(sample.bpm)
            )
        }
    }

    /// Mean-per-bucket downsample onto `target` points (clamped to 300...600 when the
    /// raw series is denser than that). Nights shorter than `target` keep every sample.
    static func displayPoints(from samples: [HRSample], target: Int = displayTarget) -> [NativeHourPoint] {
        let budget = min(max(target, displayMin), displayMax)
        let ordered = samples.sorted { $0.ts < $1.ts }
        guard let first = ordered.first, let last = ordered.last else { return [] }
        if ordered.count <= budget {
            return ordered.map {
                NativeHourPoint(
                    time: Date(timeIntervalSince1970: TimeInterval($0.ts)),
                    value: Double($0.bpm)
                )
            }
        }
        let span = max(last.ts - first.ts, 1)
        let width = max(1, Int((Double(span) / Double(budget)).rounded(.up)))
        var buckets: [Int: (sum: Int, n: Int)] = [:]
        for sample in ordered {
            let key = (sample.ts - first.ts) / width
            let cur = buckets[key] ?? (0, 0)
            buckets[key] = (cur.sum + sample.bpm, cur.n + 1)
        }
        return buckets.keys.sorted().map { key in
            let bucket = buckets[key]!
            let ts = first.ts + key * width + width / 2
            return NativeHourPoint(
                time: Date(timeIntervalSince1970: TimeInterval(ts)),
                value: Double(bucket.sum) / Double(bucket.n)
            )
        }
    }

    static func make(samples: [HRSample], target: Int = displayTarget) -> Model {
        Model(
            points: displayPoints(from: samples, target: target),
            average: NativeScoreMath.mean(samples.map { Double($0.bpm) }),
            rawCount: samples.count
        )
    }
}

struct NativeOvernightHeartCard: View {
    var points: [NativeHourPoint]
    var average: Double? = nil
    var plot: NativeOvernightPlotModel? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        NativeOvernightHeartHost(points: points, average: average, plot: plot, onOpen: onOpen)
            .equatable()
    }
}

private struct NativeOvernightHeartHost: View, Equatable {
    var points: [NativeHourPoint]
    var average: Double?
    var plot: NativeOvernightPlotModel?
    var onOpen: (() -> Void)?
    @Environment(\.nativeStyle) private var style
    @State private var selectedTime: Date?

    static func == (lhs: NativeOvernightHeartHost, rhs: NativeOvernightHeartHost) -> Bool {
        lhs.points == rhs.points && lhs.average == rhs.average && lhs.plot == rhs.plot
    }

    private var displayedAverage: Double? {
        average ?? NativeScoreMath.mean(points.map(\.value).filter(\.isFinite))
    }

    private var selectedPoint: NativeHourPoint? {
        guard let selectedTime else { return nil }
        return NativeChartScrubMath.nearestHour(
            to: selectedTime,
            in: points,
            maxGap: NativeChartScrubMath.inferredMaxGap(in: points)
        )
    }

    var body: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: "Heart Rate",
                symbol: "heart.fill",
                tint: NativePaint.heart(style),
                chevron: onOpen != nil
            )
            if let point = selectedPoint {
                NativeHeroValue(
                    caption: "Heart Rate",
                    value: "\(Int(point.value.rounded()))",
                    unit: "BPM",
                    date: NativeScopeFormat.time(point.time)
                )
            } else if let displayedAverage {
                NativeHeroValue(caption: "Average", value: "\(Int(displayedAverage.rounded()))", unit: "BPM")
            } else {
                NativeHeroValue(caption: "Average", value: "—", unit: "BPM")
            }
            NativeOvernightLine(
                points: points,
                tint: NativePaint.heart(style),
                selectedTime: $selectedTime,
                plot: plot
            )
        }
        .contentShape(Rectangle())
        .nativeChartButton(action: onOpen)
    }
}

struct NativeWhoopCompareChip: View {
    var kind: NativeScoreKind
    var dayKey: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowtriangle.up.fill")
                .foregroundStyle(NativeTokens.whoopPositiveDelta)
            Image(systemName: "arrowtriangle.down.fill")
                .foregroundStyle(NativeTokens.whoopNegativeDelta)
            Text(label)
                .font(NativeTokens.whoopCaps(11))
                .tracking(NativeTokens.whoopCapsTracking)
                .foregroundStyle(NativeTokens.whoopLabel)
            Spacer(minLength: 0)
        }
        .font(NativeTokens.whoopCaps(9))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
        .accessibilityLabel(label)
    }

    private var label: String {
        let day = dayKey.map { NativeChartDay.longLabel($0) } ?? "This day"
        return "\(day) vs. last 30 days"
    }
}

/// TIME ASLEEP / TIME IN BED pair: 34 pt hours + baseline unit, then minutes.
struct NativeClockHero: View {
    var caption: String? = nil
    var minutes: Double
    var date: String? = nil

    var body: some View {
        let parts = NativeScoreMath.clockParts(minutes)
        VStack(alignment: .leading, spacing: 2) {
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if parts.hours > 0 {
                    Text("\(parts.hours)")
                        .font(StrandFont.rounded(34))
                    Text("hr")
                        .font(StrandFont.rounded(17, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text("\(parts.minutes)")
                    .font(StrandFont.rounded(34))
                Text("min")
                    .font(StrandFont.rounded(17, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            if let date, !date.isEmpty {
                Text(date)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption ?? "Duration"), \(parts.hours) hours \(parts.minutes) minutes")
    }
}



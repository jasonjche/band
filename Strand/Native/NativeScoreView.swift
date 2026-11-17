import SwiftUI
import Charts
import WhoopStore
import StrandDesign
import StrandAnalytics

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
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""
    @State private var workouts: [WorkoutRow] = []
    @State private var overnightHr: [NativeHourPoint] = []
    @State private var highSleepStress: Double?
    @State private var sleepStress: NativeSleepStress.Model?
    @State private var sleepEdit: NativeSleepEditTarget?
    @State private var dayModel: NativeDay.Model?
    @State private var weekCards: [NativeWeek.Card] = []
    @State private var sleepDetail: NativeSleepPageDetail?

    private var selectedDay: Date {
        NativeDaySelection.date(from: selectedDayKey)
    }

    private var dayKey: String {
        NativeDayLogic.resolvedDayKey(stored: selectedDayKey)
    }

    private var nightSession: CachedSleepSession? {
        repo.sleeps
            .filter {
                NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == dayKey
            }
            .sorted { ($0.endTs - $0.effectiveStartTs) > ($1.endTs - $1.effectiveStartTs) }
            .first
    }

    private var rebuildID: String {
        "\(repo.refreshSeq)-\(dayKey)-\(effortScaleRaw)"
    }

    private var sleepBoundsID: String {
        "\(dayModel?.sleepStart?.timeIntervalSince1970 ?? 0)-\(dayModel?.sleepEnd?.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {
        let model = resolvedModel
        NativeScoreView(
            score: kind == .recovery ? model.recovery : kind == .strain ? model.strain : model.sleep,
            weekCards: resolvedWeekCards,
            kind: kind,
            sleepHours: model.sleepHours,
            asleepMinutes: model.asleepMinutes,
            stages: model.sleepStages,
            activities: model.activities,
            sleepStart: model.sleepStart,
            sleepEnd: model.sleepEnd,
            overnightHr: overnightHr,
            awakeTypical: model.awakeTypical,
            dayKey: dayKey,
            needMinutes: NativeSleepNeed.needMinutes(resolvedSleepDetail?.need) ?? model.sleepNeedMin,
            debtMinutes: model.sleepDebtMin,
            sleepDetail: resolvedSleepDetail,
            onEditSleep: kind == .sleep && nightSession != nil ? { sleepEdit = nightSession.map(NativeSleepEditTarget.init) } : nil
        )
        .nativeDateSubtitle(selectedDay)
        .sheet(item: $sleepEdit) { target in
            let session = target.session
            let coverageLo = min(session.startTs, session.effectiveStartTs)
            SleepTimeEditor(
                bedTs: session.effectiveStartTs,
                wakeTs: session.endTs,
                coverage: coverageLo...max(session.endTs, coverageLo + 1),
                suppressesReDetection: !session.userEdited,
                onSave: { newBedTs, newWakeTs in
                    await repo.editSleepTimes(
                        detectedStartTs: session.startTs, oldEndTs: session.endTs,
                        storedStagesJSON: session.stagesJSON,
                        newStartTs: newBedTs, newEndTs: newWakeTs
                    )
                    await intelligence.analyzeRecent()
                    await repo.refresh()
                },
                onDelete: {
                    _ = await repo.deleteSleepSession(detectedStartTs: session.startTs, endTs: session.endTs)
                    await intelligence.analyzeRecent()
                    await repo.refresh()
                }
            )
        }
        .onAppear { if dayModel == nil { rebuild() } }
        .task(id: rebuildID) {
            rebuild()
            workouts = await repo.workoutRows(days: 120)
            rebuild()
        }
        .onChange(of: highSleepStress) { _ in rebuild() }
        .onChange(of: sleepStress) { _ in rebuild() }
        .task(id: sleepBoundsID) {
            guard let start = dayModel?.sleepStart, let end = dayModel?.sleepEnd else {
                overnightHr = []
                highSleepStress = nil
                return
            }
            let from = Int(start.timeIntervalSince1970)
            let to = Int(end.timeIntervalSince1970)
            let raw = await repo.hrSamples(from: from, to: to, limit: 8_000)
            overnightHr = raw.enumerated().compactMap { i, sample in
                guard i % 2 == 0 else { return nil }
                return NativeHourPoint(time: Date(timeIntervalSince1970: TimeInterval(sample.ts)), value: Double(sample.bpm))
            }
            guard kind == .sleep else {
                highSleepStress = nil
                sleepStress = nil
                return
            }
            // Overnight scoring needs the full night of HR (the sparkline above is capped at 8_000).
            let overnightHR = await repo.hrSamples(from: from, to: to, limit: 200_000)
            highSleepStress = SleepStressShare.percent(hr: overnightHR, startTs: from, endTs: to)
            sleepStress = NativeSleepStress.make(hr: overnightHR, startTs: from, endTs: to)
        }
        .task(id: "hrv-sws-\(sleepBoundsID)") {
            guard kind == .recovery, let start = dayModel?.sleepStart, let end = dayModel?.sleepEnd else { return }
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

    private var resolvedModel: NativeDay.Model { dayModel ?? buildModel() }
    private var resolvedWeekCards: [NativeWeek.Card] { dayModel == nil ? buildWeekCards() : weekCards }
    private var resolvedSleepDetail: NativeSleepPageDetail? { dayModel == nil ? buildSleepDetail() : sleepDetail }

    /// Rings, week cards, sleep detail — once per data change, not per `body` pass.
    private func rebuild() {
        dayModel = buildModel()
        weekCards = buildWeekCards()
        sleepDetail = buildSleepDetail()
    }

    private func buildModel() -> NativeDay.Model {
        NativeDay.make(
            days: repo.days, sleeps: repo.sleeps, workouts: workouts,
            todayKey: dayKey,
            connected: false,
            effortScale: UnitPrefs.resolveEffortScale(effortScaleRaw),
            importedSleep: repo.importedSleep,
            highSleepStress: kind == .sleep ? highSleepStress : nil
        )
    }

    private func buildWeekCards() -> [NativeWeek.Card] {
        let baseWeek = NativeWeek.cards(
            kind: kind, days: repo.days, todayKey: dayKey,
            effortScale: UnitPrefs.resolveEffortScale(effortScaleRaw),
            sleeps: repo.sleeps, workouts: workouts, importedSleep: repo.importedSleep
        )
        return NativeSleepWeek.cards(
            kind: kind, base: baseWeek, days: repo.days, todayKey: dayKey,
            sleeps: repo.sleeps, workouts: workouts, importedSleep: repo.importedSleep
        )
    }

    private func buildSleepDetail() -> NativeSleepPageDetail? {
        guard kind == .sleep else { return nil }
        let parsed = nightSession.map { repo.parsedStages(for: $0) } ?? []
        return NativeSleepPageDetail.make(
            dayKey: dayKey, days: repo.days, sleeps: repo.sleeps, workouts: workouts,
            importedSleep: repo.importedSleep, stress: sleepStress, parsedStages: parsed
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
    var awakeTypical: Double? = nil
    var dayKey: String? = nil
    var needMinutes: Double? = nil
    var debtMinutes: Double? = nil
    var scrolls: Bool = true
    var sleepDetail: NativeSleepPageDetail? = nil
    var onEditSleep: (() -> Void)? = nil
    @Environment(\.nativeNavigationPath) private var path

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
                NativeChrome.screen { scoreBody }
            } else {
                NativeChrome.stack { scoreBody }
            }
        }
        .navigationTitle(score.name)
        .modifier(NativeInlineTitle())
        .navigationDestination(for: NativeScoreMetricRoute.self) { route in
            NativeMetricPage(key: route.key)
        }
        .navigationDestination(for: NativeSleepStageRoute.self) { route in
            NativeSleepStageDetailView(
                detail: stageDetail(for: route.kind),
                spans: sleepDetail?.hypnogram ?? [],
                nightStart: sleepStart,
                nightEnd: sleepEnd,
                dayKey: dayKey
            )
        }
        .navigationDestination(for: NativeScoreTrendRoute.self) { route in
            if let card = weekCards.first(where: { $0.title == route.title }) {
                NativeScoreTrendPage(
                    card: card,
                    dayKey: dayKey,
                    format: { weekLabel(card, $0) },
                    axisFormat: { weekAxisLabel(card, $0) },
                    unit: weekUnit(card),
                    symbol: weekSymbol(card),
                    tint: weekTint(card),
                    color: card.band ? weekBand : nil
                )
            }
        }
    }

    @Environment(\.nativeStyle) private var style

    @ViewBuilder private var scoreBody: some View {
        if score.known {
            NativeRing(
                fraction: score.fraction,
                tint: ringTint,
                value: score.value,
                caption: ringCaption,
                diameter: 184
            )
            .id(dayKey ?? score.value)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            NativeHeroValue(
                value: "No Data",
                date: dayKey.map { NativeChartDay.mediumDate($0) }
            )
            .padding(.vertical, 8)
        }

        if !visibleRows.isEmpty {
            NativeChrome.panel {
                VStack(spacing: 0) {
                    ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, 34)
                        }
                        Button {
                            openRow(row)
                        } label: {
                            HStack(spacing: 8) {
                                NativeContributorRow(
                                    symbol: row.symbol,
                                    title: row.title,
                                    value: row.value,
                                    prior: NativeScoreMath.hasValue(row.prior) ? row.prior : nil,
                                    delta: row.delta,
                                    tint: contributorTint(row),
                                    valueTint: valueTint(row)
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

        if kind == .sleep, hasLastNight {
            NativeLastNightCard(
                asleepMinutes: asleepValue,
                sleepHours: sleepHours,
                stages: stages,
                sleepStart: sleepStart,
                sleepEnd: sleepEnd,
                awakeTypical: awakeTypical,
                needMinutes: needMinutes,
                debtMinutes: debtMinutes,
                onEdit: onEditSleep,
                spans: sleepDetail?.hypnogram ?? [],
                onStage: { path.wrappedValue.append(NativeSleepStageRoute(kind: $0)) }
            )
        }
        if kind == .sleep, !overnightHr.isEmpty {
            NativeOvernightHeartCard(points: overnightHr)
        }
        if kind == .sleep {
            sleepDetailCards
        }
        if kind == .strain {
            activitiesCard
        }
        if !weekCards.isEmpty {
            NativeChrome.section("Weekly Trends")
            ForEach(weekCards) { card in
                weekCard(card)
            }
        }
    }

    private var ringCaption: String {
        switch kind {
        case .sleep: return "Sleep Performance"
        case .recovery: return "Recovery"
        case .strain: return "Strain"
        }
    }

    private var ringTint: Color {
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

    private func contributorTint(_ row: NativeScore.Row) -> Color {
        switch row.title {
        case "Heart Rate Variability", "Resting Heart Rate": return NativePaint.heart(style)
        case "Respiratory Rate": return NativePaint.respiratory(style)
        case "Sleep Performance", "Sleep Efficiency", "Hours vs. Needed", "Sleep Consistency",
             "Restorative Sleep", "High Sleep Stress": return NativePaint.sleep(style)
        case "Steps", "Calories": return NativePaint.activity(style)
        case "Heart Rate Zones 1–3", "Heart Rate Zones 4–5": return NativePaint.heart(style)
        case "Strength Activity Time": return NativePaint.strain(style)
        default: return ringTint
        }
    }

    private func valueTint(_ row: NativeScore.Row) -> Color {
        guard let percent = NativeScoreMath.percentValue(row.value) else { return .primary }
        switch kind {
        case .sleep:
            return NativePaint.sleepBand(percent, style: style)
        case .recovery where row.title == "Sleep Performance":
            return NativePaint.sleepBand(percent, style: style)
        case .recovery:
            return .primary
        case .strain:
            return .primary
        }
    }

    private func weekLabel(_ card: NativeWeek.Card, _ value: Double) -> String {
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

    private func weekAxisLabel(_ card: NativeWeek.Card, _ value: Double) -> String {
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

    private func weekUnit(_ card: NativeWeek.Card) -> String? {
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

    private func weekTint(_ card: NativeWeek.Card) -> Color {
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

    private func weekSymbol(_ card: NativeWeek.Card) -> String {
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

    @ViewBuilder private func weekCard(_ card: NativeWeek.Card) -> some View {
        if kind == .sleep, card.title == "Hours vs. Needed", let detail = sleepDetail {
            NativeSleepDualLineCard(
                title: card.title,
                slept: card.points,
                needed: detail.hoursNeededWeek,
                highlightKey: dayKey,
                typical: detail.hoursTypical,
                onOpen: { openCard(card) }
            )
        } else if kind == .sleep, card.title == "Time in Bed" {
            NativeSleepTimeInBedWeekCard(
                points: card.points,
                highlightKey: dayKey,
                onOpen: { openCard(card) }
            )
        } else {
            weekChartCard(card)
        }
    }

    @ViewBuilder private func weekChartCard(_ card: NativeWeek.Card) -> some View {
        let tint = weekTint(card)
        NativeChrome.panel {
            Button { openCard(card) } label: {
                NativeCardHeader(
                    title: card.title,
                    symbol: weekSymbol(card),
                    tint: tint,
                    chevron: true
                )
            }
            .buttonStyle(.plain)
            NativeChartBlock(
                points: card.points,
                bars: card.bars,
                tint: tint,
                format: { weekLabel(card, $0) },
                axisFormat: { weekAxisLabel(card, $0) },
                unit: weekUnit(card),
                maxY: card.maxY,
                color: card.band ? weekBand : nil,
                highlightKey: dayKey,
                plotHeight: 200,
                accessibilityName: card.title,
                clockHero: card.format == .duration,
                yTicks: card.format == .strain ? NativeDayLogic.strainYTicks(maxY: card.maxY) : nil,
                stacks: card.stacks
            )
        }
    }

    private func openRow(_ row: NativeScore.Row) {
        if case .metric(let key) = row.route {
            path.wrappedValue.append(NativeScoreMetricRoute(key: key))
            return
        }
        path.wrappedValue.append(row.route)
    }

    private func openCard(_ card: NativeWeek.Card) {
        switch card.title {
        case "Hours of Sleep", "Time in Bed", "Heart Rate Zones 1–3", "Heart Rate Zones 4–5",
             "Strength Activity Time", "Restorative Sleep":
            path.wrappedValue.append(NativeScoreTrendRoute(title: card.title))
        case "Sleep Stress":
            path.wrappedValue.append(TabRoute.stress)
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

    private func metricKey(for title: String) -> String? {
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

    private func stageDetail(for kind: NativeSleepStageKind) -> NativeSleepStageDetail {
        if let existing = sleepDetail?.stageDetails.first(where: { $0.kind == kind }) {
            return existing
        }
        let stage = stages.first { NativeSleepStageKind.parse($0.name) == kind }
        let inBed = NativeDayLogic.inBedMinutes(start: sleepStart, end: sleepEnd)
            ?? stages.compactMap(\.minutes).reduce(0, +)
        let minutes = stage?.minutes
        let percent: Double? = {
            guard let minutes, inBed > 0 else { return nil }
            return NativeSleepHypnogramMath.share(minutes: minutes, inBed: inBed) * 100
        }()
        return NativeSleepStageDetail(
            kind: kind,
            minutes: minutes,
            percent: percent,
            typical: stage?.typical,
            trend: []
        )
    }

    @ViewBuilder private var sleepDetailCards: some View {
        if let need = sleepDetail?.need ?? hoursNeededFromPage,
           need.percent != nil || need.hoursSleptMin != nil {
            NativeSleepHoursVsNeededCard(model: need)
        }
        if let nights = sleepDetail?.consistencyNights, !nights.isEmpty {
            NativeSleepConsistencyCard(
                nights: nights,
                percent: NativeScoreMath.percentValue(
                    score.rows.first { $0.title == "Sleep Consistency" }?.value ?? ""
                ),
                onOpen: { path.wrappedValue.append(NativeScoreMetricRoute(key: "sleep_consistency")) }
            )
        }
        if let efficiency = sleepDetail?.efficiency {
            NativeSleepEfficiencyCard(model: efficiency)
        }
        if let stress = sleepDetail?.stress {
            NativeSleepStressCard(model: stress)
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

    private var asleepValue: Double? { asleepMinutes }

    private var hasLastNight: Bool {
        asleepValue != nil || sleepHours != nil || !stages.isEmpty || sleepStart != nil
    }

    private var weekBand: ((Double) -> Color)? {
        if kind == .recovery {
            return { NativePaint.recoveryBand($0, style: style) }
        }
        return nil
    }

    static func stageTint(_ stage: NativeStage) -> Color {
        switch stage.name {
        case "Awake": return NativeTokens.sleepAwake
        case "REM": return NativeTokens.sleepREM
        case "Deep": return NativeTokens.sleepDeep
        default: return NativeTokens.sleepCore
        }
    }

    @ViewBuilder private var activitiesCard: some View {
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
                    ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                        if index > 0 {
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
    var onStage: ((NativeSleepStageKind) -> Void)? = nil
    @Environment(\.nativeStyle) private var style

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

    var body: some View {
        if style == .whoop {
            whoop
        } else {
            apple
        }
    }

    private var apple: some View {
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
    }

    private var whoop: some View {
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
        var rows = stages
        if !rows.contains(where: { $0.name == "Awake" }),
           let inBedMinutes, let asleepMinutes, inBedMinutes > asleepMinutes {
            let awake = inBedMinutes - asleepMinutes
            rows.insert(
                NativeStage(name: "Awake", minutes: awake, typical: awakeTypical, tint: NativeTokens.sleepAwake),
                at: 0
            )
        } else if let idx = rows.firstIndex(where: { $0.name == "Awake" }),
                  rows[idx].typical == nil, let awakeTypical {
            rows[idx].typical = awakeTypical
        }
        let order = ["Awake", "Light", "Deep", "REM"]
        return rows.sorted { (order.firstIndex(of: $0.name) ?? 99) < (order.firstIndex(of: $1.name) ?? 99) }
    }

    private var drawsTypicalRange: Bool {
        lastNightStages.contains { ($0.typical ?? 0) > 0 }
    }

    private var stageScale: Double {
        max(inBedMinutes ?? lastNightStages.compactMap(\.minutes).reduce(0, +), 1)
    }

    @ViewBuilder private var hypnogram: some View {
        if !spans.isEmpty, let sleepStart, let sleepEnd, sleepEnd > sleepStart {
            NativeSleepHypnogram(
                spans: spans,
                nightStart: sleepStart,
                nightEnd: sleepEnd
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
            let row = NativeSleepStageRow(
                kind: kind,
                minutes: minutes,
                percent: NativeSleepHypnogramMath.share(minutes: minutes, inBed: scale) * 100,
                typical: stage.typical,
                scale: scale,
                chevron: onStage != nil
            )
            if let onStage {
                Button { onStage(kind) } label: { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
        }
    }
}

struct NativeOvernightHeartCard: View {
    var points: [NativeHourPoint]
    @Environment(\.nativeStyle) private var style

    private var average: Double? {
        NativeScoreMath.mean(points.map(\.value).filter(\.isFinite))
    }

    var body: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: "Heart Rate",
                symbol: "heart.fill",
                tint: NativePaint.heart(style)
            )
            if let average {
                NativeHeroValue(caption: "Average", value: "\(Int(average.rounded()))", unit: "BPM")
            }
            NativeOvernightLine(points: points, tint: NativePaint.heart(style))
                .frame(height: 160)
        }
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
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption ?? "Duration"), \(parts.hours) hours \(parts.minutes) minutes")
    }
}



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
struct NativeScorePage: View {
    var kind: NativeScoreKind
    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""
    @State private var workouts: [WorkoutRow] = []
    @State private var overnightHr: [NativeHourPoint] = []
    @State private var highSleepStress: Double?
    @AppStorage(PuffinExperiment.experimentalSleepStressKey) private var sleepStressEnabled = false

    private var selectedDay: Date {
        NativeDaySelection.date(from: selectedDayKey)
    }

    var body: some View {
        let dayKey = NativeDayLogic.resolvedDayKey(stored: selectedDayKey)
        let model = NativeDay.make(
            days: repo.days, sleeps: repo.sleeps, workouts: workouts,
            todayKey: dayKey,
            connected: false,
            effortScale: UnitPrefs.resolveEffortScale(effortScaleRaw),
            importedSleep: repo.importedSleep,
            highSleepStress: kind == .sleep ? highSleepStress : nil
        )
        let score = kind == .recovery ? model.recovery : kind == .strain ? model.strain : model.sleep
        NativeScoreView(
            score: score,
            weekCards: NativeWeek.cards(
                kind: kind, days: repo.days, todayKey: dayKey,
                effortScale: UnitPrefs.resolveEffortScale(effortScaleRaw),
                sleeps: repo.sleeps, workouts: workouts, importedSleep: repo.importedSleep
            ),
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
            needMinutes: model.sleepNeedMin,
            debtMinutes: model.sleepDebtMin
        )
        .nativeDateSubtitle(selectedDay)
        .task(id: repo.refreshSeq) { workouts = await repo.workoutRows(days: 120) }
        .task(id: "\(model.sleepStart?.timeIntervalSince1970 ?? 0)-\(model.sleepEnd?.timeIntervalSince1970 ?? 0)-\(sleepStressEnabled)") {
            guard let start = model.sleepStart, let end = model.sleepEnd else {
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
            guard kind == .sleep, sleepStressEnabled else {
                highSleepStress = nil
                return
            }
            // Overnight scoring needs the full night of HR (the sparkline above is capped at 8_000).
            let overnightHR = await repo.hrSamples(from: from, to: to, limit: 200_000)
            highSleepStress = SleepStressShare.percent(hr: overnightHR, startTs: from, endTs: to)
        }
        .task(id: "hrv-sws-\(model.sleepStart?.timeIntervalSince1970 ?? 0)-\(model.sleepEnd?.timeIntervalSince1970 ?? 0)") {
            guard kind == .recovery, let start = model.sleepStart, let end = model.sleepEnd else { return }
            let from = Int(start.timeIntervalSince1970)
            let to = Int(end.timeIntervalSince1970)
            let rr = await repo.rrIntervals(from: from, to: to, limit: 50_000)
            let beats = rr.map { BandHrvSws.Beat(tSec: Double($0.ts), rrMs: Double($0.rrMs)) }
            let session = repo.sleeps.last {
                NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs)))
                    == NativeDayLogic.resolvedDayKey(stored: selectedDayKey)
            }
            let epochs = NativeBandScores.epochs(from: session?.stagesJSON, sessionStart: session?.effectiveStartTs ?? from)
            let nightly = repo.days.last { $0.day == NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }?.avgHrv
            NativeBandScores.logHrvSws(
                beats: beats, epochs: epochs, sleepStart: start, sleepEnd: end, nightlyHrv: nightly
            )
        }
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
    @Environment(\.nativeNavigationPath) private var path

    private var visibleRows: [NativeScore.Row] {
        score.rows.filter { NativeScoreMath.hasValue($0.value) }
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
                            path.wrappedValue.append(row.route)
                        } label: {
                            NativeContributorRow(
                                symbol: row.symbol,
                                title: row.title,
                                value: row.value,
                                prior: NativeScoreMath.hasValue(row.prior) ? row.prior : nil,
                                delta: row.delta,
                                tint: contributorTint(row),
                                valueTint: valueTint(row)
                            )
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
                debtMinutes: debtMinutes
            )
        }
        if kind == .sleep, !overnightHr.isEmpty {
            NativeOvernightHeartCard(points: overnightHr)
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
        case "Sleep Performance", "Sleep Efficiency", "Hours vs. Needed", "Sleep Consistency": return NativePaint.sleep(style)
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
        case "Sleep Performance", "Hours of Sleep", "Sleep Efficiency": return NativePaint.sleep(style)
        default: return card.tint
        }
    }

    private func weekSymbol(_ card: NativeWeek.Card) -> String {
        switch card.title {
        case "Sleep Performance", "Sleep Efficiency": return "bed.double.fill"
        case "Hours of Sleep": return "clock.fill"
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
        let tint = weekTint(card)
        let body = NativeChrome.panel {
            NativeCardHeader(
                title: card.title,
                symbol: weekSymbol(card),
                tint: tint,
                chevron: card.route != nil
            )
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
        if let route = card.route {
            Button { path.wrappedValue.append(route) } label: { body }
                .buttonStyle(.plain)
        } else {
            body
        }
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
            NativeCardHeader(title: "Last Night", symbol: "bed.double.fill", tint: NativePaint.sleep(style))
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
            appleStages
        }
    }

    private var whoop: some View {
        NativeChrome.panel {
            NativeCardHeader(title: "Last Night's Sleep", symbol: "bed.double.fill", tint: NativePaint.sleep(style))
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
                let total = max(lastNightStages.compactMap(\.minutes).reduce(0, +), 1)
                ForEach(lastNightStages) { stage in
                    NativeWhoopStageRow(stage: stage, total: total)
                }
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

    @ViewBuilder private var appleStages: some View {
        if !lastNightStages.isEmpty {
            let total = max(lastNightStages.compactMap(\.minutes).reduce(0, +), 1)
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
            ForEach(lastNightStages) { stage in
                NativeWhoopStageRow(stage: stage, total: total)
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
                Text("\(parts.hours)")
                    .font(StrandFont.rounded(34))
                Text("hr")
                    .font(StrandFont.rounded(17, weight: .medium))
                    .foregroundStyle(.secondary)
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

struct NativeActivityView: View {
    var startTs: Int
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @State private var workout: WorkoutRow?
    @State private var prior: [WorkoutRow] = []
    @State private var hr: [NativeHourPoint] = []

    var body: some View {
        Group {
            if let workout {
                let model = NativeActivity.make(workout, prior: prior, scale: UnitPrefs.resolveEffortScale(effortScaleRaw))
                NativeActivityBody(
                    model: model,
                    hr: hr,
                    zoneSet: HRZones.zones(maxHR: Double(profile.hrMax))
                )
            } else {
                ProgressView("Loading activity")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(NativePageFill())
        .navigationTitle(workout?.sport.localizedCapitalized ?? "Activity")
        .modifier(NativeInlineTitle())
        .task { await load() }
    }

    private func load() async {
        let rows = await repo.workoutRows(days: 120)
        workout = rows.first { $0.startTs == startTs }
        prior = rows
        guard let workout else { hr = []; return }
        let raw = await repo.hrSamples(from: workout.startTs, to: workout.endTs, limit: 8_000)
        hr = raw.enumerated().compactMap { i, sample in
            guard i % 2 == 0 else { return nil }
            return NativeHourPoint(time: Date(timeIntervalSince1970: TimeInterval(sample.ts)), value: Double(sample.bpm))
        }
    }
}

struct NativeActivityBody: View {
    var model: NativeActivity.Model
    var hr: [NativeHourPoint] = []
    var zoneSet: HRZoneSet? = nil
    var scrolls: Bool = true
    @Environment(\.nativeStyle) private var style
    @State private var selectedZone: Int?

    var body: some View {
        Group {
            if scrolls {
                NativeChrome.screen { activityBody }
            } else {
                NativeChrome.stack { activityBody }
            }
        }
    }

    @ViewBuilder private var activityBody: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.sport.localizedCapitalized)
                    .font(.title2.bold())
                Text(model.timeRange)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        NativeValueText(value: model.strainText, size: 34)
                        NativeDelta(delta: model.strainDelta)
                    }
                    Text("Activity strain")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.duration)
                        .font(NativePaint.number(28, style: style))
                        .monospacedDigit()
                    Text("Duration")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if !hr.isEmpty {
                NativeChrome.panel {
                    NativeActivityHRChart(points: hr, zoneSet: zoneSet, selectedZone: $selectedZone)
                        .frame(height: 180)
                }
            }

            let activeZones = model.zones.filter { $0.minutes > 0 }
            if !activeZones.isEmpty {
                NativeChrome.panel {
                    HStack {
                        Text("Typical range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Duration \(model.duration)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    let total = max(model.zones.reduce(0) { $0 + $1.minutes }, 1)
                    ForEach(model.zones.reversed()) { zone in
                        Button {
                            selectedZone = selectedZone == zone.zone ? nil : zone.zone
                        } label: {
                            NativeActivityZoneRow(
                                zone: zone,
                                total: total,
                                bounds: zoneSet?.zones.first { $0.number == zone.zone },
                                highlighted: selectedZone == zone.zone
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !model.stats.isEmpty {
                NativeChrome.section("Key statistics")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(model.stats) { stat in
                        NativeChrome.panel {
                            Label(stat.title, systemImage: stat.symbol)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(stat.value)
                                .font(.title3.weight(.semibold))
                                .monospacedDigit()
                            if NativeScoreMath.hasValue(stat.comparison) {
                                Text(stat.comparison)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
    }
}

struct NativeActivityHRChart: View {
    var points: [NativeHourPoint]
    var zoneSet: HRZoneSet? = nil
    @Binding var selectedZone: Int?
    @Environment(\.nativeStyle) private var style
    @State private var selectedTime: Date?

    private var yDomain: ClosedRange<Double> {
        let data = NativeChartDay.fittedDomain(points.map(\.value), fallback: 80...180)
        if let maxHR = zoneSet?.maxHR {
            return min(data.lowerBound, 50)...max(data.upperBound, maxHR)
        }
        return data
    }

    var body: some View {
        Chart {
            if let zoneSet, let first = points.first, let last = points.last, let selectedZone {
                ForEach(zoneSet.zones.filter { $0.number == selectedZone }, id: \.number) { zone in
                    RectangleMark(
                        xStart: .value("Start", first.time),
                        xEnd: .value("End", last.time),
                        yStart: .value("Lo", zone.lower),
                        yEnd: .value("Hi", zone.upper)
                    )
                    .foregroundStyle(NativeActivityZoneRow.color(zone.number).opacity(0.28))
                }
            }
            ForEach(points) { point in
                LineMark(x: .value("Time", point.time), y: .value("HR", point.value))
                    .foregroundStyle(lineTint)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let selectedTime, let point = nearest(to: selectedTime) {
                RuleMark(x: .value("Scrub", point.time))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .trailing, values: NativeChartTicks.values(in: yDomain, maxCount: 3)) { _ in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 2)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.hour().minute())
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .modifier(NativeTimeSelect(selected: $selectedTime, onChange: { time in
            guard let time, let point = nearest(to: time) else { return }
            if let zoneSet {
                selectedZone = zoneSet.zoneNumber(forBPM: point.value)
            }
        }))
        .accessibilityLabel("Heart rate")
    }

    private var lineTint: Color {
        style == .whoop ? NativeTokens.whoopLabel : Color.primary
    }

    private func nearest(to time: Date) -> NativeHourPoint? {
        points.min(by: { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) })
    }
}

struct NativeActivityZoneRow: View {
    var zone: NativeActivity.Zone
    var total: Double
    var bounds: HRZone?
    var highlighted: Bool = false
    @Environment(\.nativeStyle) private var style

    var body: some View {
        let share = total > 0 ? zone.minutes / total : 0
        let duration = style == .whoop
            ? NativeScoreMath.durationHMS(zone.minutes)
            : NativeScoreMath.duration(zone.minutes)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Self.color(zone.zone))
                    .frame(width: 8, height: 8)
                Text(zone.label)
                    .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline.weight(.semibold))
                if let bounds {
                    Text("\(Int(bounds.lower.rounded()))–\(Int(bounds.upper.rounded())) BPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(Int((share * 100).rounded()))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Self.color(zone.zone))
                Spacer(minLength: 8)
                Text(duration)
                    .font(style == .whoop ? NativeTokens.whoopNumber(15, weight: .semibold) : StrandFont.rounded(15, weight: .semibold))
                    .monospacedDigit()
            }
            NativeWhoopRangeBar(minutes: zone.minutes, typical: 0, tint: Self.color(zone.zone))
                .opacity(highlighted ? 1 : 0.55)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(zone.label), \(duration)")
    }

    static func color(_ zone: Int) -> Color {
        NativeTokens.hrZone(zone)
    }
}

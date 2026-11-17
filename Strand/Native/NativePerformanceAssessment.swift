import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// Weekly / monthly performance assessment. Pushed from More.
struct NativePerformanceAssessmentView: View {
    @State private var repoHandle: Repository?
    @State private var refreshSeq = 0
    @State private var handlesReady = false
    @State private var kind: PerformanceAssessment.Kind = .weekly
    @State private var model: NativePerformanceAssessmentModel?
    @State private var selectedStart: String?
    @AppStorage("behavior.weeklyReportNudge") private var notifyReady = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                NativeChrome.screen { ProgressView("Loading") }
                    .navigationTitle("Assessments")
                    .modifier(NativeInlineTitle())
            }
        }
        .background {
            NativeRepoSink(refreshSeq: $refreshSeq, ready: $handlesReady) { repoHandle = $0 }
        }
        .task(id: handlesReady ? "\(refreshSeq)-\(kind.rawValue)" : "boot") {
            guard handlesReady else { return }
            await load()
        }
        .onChangeCompat(of: notifyReady) { on in
            if on {
                WeeklyReportNotifier.requestAuthorization()
                WeeklyReportNotifier.evaluate(asOfDay: NativeDayLogic.logicalToday(), enabled: true)
            }
        }
    }

    @ViewBuilder private func content(_ model: NativePerformanceAssessmentModel) -> some View {
        NativeChrome.screen {
            Picker("Period", selection: $kind) {
                Text("Weekly").tag(PerformanceAssessment.Kind.weekly)
                Text("Monthly").tag(PerformanceAssessment.Kind.monthly)
            }
            .pickerStyle(.segmented)

            if let report = model.report(starting: selectedStart) {
                reportBody(report, history: model.history)
            } else {
                NativeChrome.panel {
                    NativeEmptyState(
                        text: "A report appears after a full week or month of days",
                        symbol: "calendar"
                    )
                }
            }

            NativeChrome.panel {
                Toggle("Notify when a weekly report is ready", isOn: $notifyReady)
                    .font(.body)
            }
        }
        .navigationTitle("Assessments")
        .modifier(NativeInlineTitle())
    }

    @ViewBuilder private func reportBody(_ report: PerformanceAssessment.Report,
                                         history: [PerformanceAssessment.Report]) -> some View {
        NativeChrome.panel {
            NativeHeroValue(
                caption: report.balance.state == .insufficient ? "Assessment" : report.balance.state.rawValue.capitalized,
                value: NativePerformanceAssessmentCopy.heroValue(report),
                unit: nil,
                date: PerformanceAssessment.rangeLabel(report.window),
                valueTint: NativePerformanceAssessmentCopy.balanceTint(report.balance.state)
            )
            Text(report.balance.sentence)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        if !report.averages.isEmpty {
            NativeChrome.section("Averages")
            NativeChrome.panel {
                ForEach(Array(report.averages.enumerated()), id: \.element.metric) { index, row in
                    if index > 0 { Divider() }
                    NativeContributorRow(
                        symbol: NativePerformanceAssessmentCopy.symbol(row.metric),
                        title: row.metric.label,
                        value: NativePerformanceAssessmentCopy.valueText(row),
                        prior: NativePerformanceAssessmentCopy.priorText(row),
                        delta: NativePerformanceAssessmentCopy.delta(row),
                        tint: NativePerformanceAssessmentCopy.tint(row.metric),
                        valueTint: NativePerformanceAssessmentCopy.valueTint(row)
                    )
                }
            }
            NativeChrome.footnote("Compared with the prior \(report.window.kind == .weekly ? "week" : "month").")
        }

        if !report.sports.isEmpty {
            NativeChrome.section("Workouts")
            NativeChrome.panel {
                ForEach(Array(report.sports.enumerated()), id: \.element.sport) { index, sport in
                    if index > 0 { Divider() }
                    NativeContributorRow(
                        symbol: "figure.run",
                        title: sport.sport,
                        value: NativePerformanceAssessmentCopy.sportValue(sport),
                        prior: NativePerformanceAssessmentCopy.sportPrior(sport),
                        delta: NativePerformanceAssessmentCopy.sportDelta(sport),
                        tint: NativeChrome.strain,
                        neutralDelta: true
                    )
                }
            }
        }

        if !report.sleep.sentences.isEmpty {
            NativeChrome.section("Sleep")
            NativeChrome.panel {
                ForEach(Array(report.sleep.sentences.enumerated()), id: \.offset) { index, line in
                    if index > 0 { Divider() }
                    Text(line)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        if !report.drivers.isEmpty {
            NativeChrome.section("Drivers")
            NativeChrome.panel {
                ForEach(Array(report.drivers.enumerated()), id: \.element.behaviorId) { index, driver in
                    if index > 0 { Divider() }
                    NativePerformanceDriverRow(driver: driver, kind: report.window.kind)
                }
            }
        }

        if !report.highlights.isEmpty {
            NativeChrome.section("Highlights")
            NativeChrome.panel {
                ForEach(Array(report.highlights.enumerated()), id: \.offset) { index, line in
                    if index > 0 { Divider() }
                    Text(line)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        if history.count > 1 {
            NativeChrome.section("History")
            NativeChrome.panel {
                ForEach(Array(history.enumerated()), id: \.element.window.start) { index, past in
                    if index > 0 { Divider() }
                    Button {
                        selectedStart = past.window.start
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PerformanceAssessment.rangeLabel(past.window))
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(NativePerformanceAssessmentCopy.historyCaption(past))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if past.window.start == report.window.start {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(NativeTokens.strain)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func load() async {
        guard let repo = repoHandle else { return }
        let days = repo.days
        let sleeps = repo.sleeps
        let importedSleep = repo.importedSleep
        let asOf = days.map(\.day).max() ?? NativeDayLogic.logicalToday()
        let entries = await repo.journalEntries(days: 4000)
        let workouts = await repo.workoutRows(days: 4000)
        let kind = self.kind
        let series = NativePerformanceAssessmentModel.series(
            days: days, sleeps: sleeps, workouts: workouts,
            importedSleep: importedSleep, entries: entries
        )
        let built = await Task.detached(priority: .userInitiated) {
            let windows = PerformanceAssessment.historyWindows(
                kind: kind, asOfDay: asOf, limit: kind == .weekly ? 12 : 6
            )
            let reports = windows.map { PerformanceAssessment.build(window: $0, series: series) }
            return NativePerformanceAssessmentModel(asOfDay: asOf, kind: kind, history: reports)
        }.value
        model = built
        if selectedStart == nil {
            selectedStart = built.history.first?.window.start
        } else if built.history.contains(where: { $0.window.start == selectedStart }) == false {
            selectedStart = built.history.first?.window.start
        }
        WeeklyReportNotifier.evaluate(asOfDay: asOf, enabled: notifyReady)
    }
}

struct NativePerformanceAssessmentModel: Equatable {
    var asOfDay: String
    var kind: PerformanceAssessment.Kind
    var history: [PerformanceAssessment.Report]

    func report(starting start: String?) -> PerformanceAssessment.Report? {
        if let start, let hit = history.first(where: { $0.window.start == start }) {
            return hit
        }
        return history.first
    }

    static func series(
        days: [DailyMetric],
        sleeps: [CachedSleepSession],
        workouts: [WorkoutRow],
        importedSleep: [String: ImportedSleepFigures],
        entries: [JournalEntry]
    ) -> PerformanceAssessment.Series {
        let scores = NativeBandScores.resolve(
            days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        let workoutMax = NativeStrain.workoutMaxByDay(workouts)
        let mainSession = NativePerformanceAssessmentModel.mainSession(byDay: sleeps)
        var recovery: [String: Double] = [:]
        var sleepPerf: [String: Double] = [:]
        var sleepNeed: [String: Double] = [:]
        var sleepCons: [String: Double] = [:]
        var strain21: [String: Double] = [:]
        var hours: [String: Double] = [:]
        var hrv: [String: Double] = [:]
        var rhr: [String: Double] = [:]
        var resp: [String: Double] = [:]
        var steps: [String: Double] = [:]
        var cal: [String: Double] = [:]
        for day in days {
            if let value = scores.byDay[day.day]?.recovery { recovery[day.day] = value }
            if let value = scores.byDay[day.day]?.sleepPerformance { sleepPerf[day.day] = value }
            if let value = scores.byDay[day.day]?.sleepNeed { sleepNeed[day.day] = value / 60 }
            if let value = scores.byDay[day.day]?.sleepConsistency { sleepCons[day.day] = value }
            if let stored = NativeStrain.day(
                stored: day.strain, live: nil,
                imported: NativeStrain.isImportedDay(importedSleep[day.day]),
                workoutMax: workoutMax[day.day]
            ) {
                strain21[day.day] = NativeDayLogic.strainDisplayValue(stored, scale: .whoop)
            } else if let stored = day.strain {
                strain21[day.day] = PerformanceAssessment.strain21(fromStored: stored)
            }
            if let min = PerformanceAssessment.asleepMinutes(
                light: day.lightMin, deep: day.deepMin, rem: day.remMin,
                totalSleepMin: day.totalSleepMin,
                mainSessionAsleepMin: NativePerformanceAssessmentModel.sessionAsleep(mainSession[day.day])
            ) {
                hours[day.day] = min / 60
            }
            if let value = day.avgHrv { hrv[day.day] = value }
            if let value = day.restingHr { rhr[day.day] = Double(value) }
            if let value = day.respRateBpm { resp[day.day] = value }
            if let value = day.steps { steps[day.day] = Double(value) }
            if let value = day.activeKcalEst { cal[day.day] = value }
        }
        let events: [PerformanceAssessment.WorkoutEvent] = workouts.compactMap { row in
            let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.startTs)))
            let seconds = row.durationS ?? Double(max(0, row.endTs - row.startTs))
            let minutes = seconds / 60
            guard minutes > 0 else { return nil }
            let zones = WorkoutZones.percents(row.zonesJSON).map { percents in
                percents.map { $0 / 100 * minutes }
            }
            return PerformanceAssessment.WorkoutEvent(
                day: day, sport: row.sport, durationMin: minutes, zoneMinutes: zones
            )
        }
        let answers = NativeJournalIdentity.winningEntries(entries).map {
            JournalImpact.Answer(day: $0.day, behaviorId: $0.question, yes: $0.answeredYes)
        }
        return PerformanceAssessment.Series(
            recovery: recovery, strain21: strain21, sleepPerformance: sleepPerf,
            sleepHours: hours, sleepNeedHours: sleepNeed, sleepConsistency: sleepCons,
            hrv: hrv, rhr: rhr, respRate: resp, steps: steps, calories: cal,
            workouts: events, journal: answers
        )
    }

    /// Longest session ending on each day — same pick Sleep uses for time-in-bed.
    static func mainSession(byDay sleeps: [CachedSleepSession]) -> [String: CachedSleepSession] {
        var best: [String: CachedSleepSession] = [:]
        for session in sleeps {
            let key = NativeDayLogic.sleepSessionDayKey(
                Date(timeIntervalSince1970: TimeInterval(session.endTs))
            )
            let span = session.endTs - session.effectiveStartTs
            if let existing = best[key], (existing.endTs - existing.effectiveStartTs) >= span {
                continue
            }
            best[key] = session
        }
        return best
    }

    static func sessionAsleep(_ session: CachedSleepSession?) -> Double? {
        guard let session else { return nil }
        if let staged = PerformanceAssessment.asleepMinutes(stagesJSON: session.stagesJSON) {
            return staged
        }
        let minutes = Double(session.endTs - session.effectiveStartTs) / 60
        return minutes > 0 ? minutes : nil
    }
}

private struct NativePerformanceDriverRow: View {
    var driver: PerformanceAssessment.Driver
    var kind: PerformanceAssessment.Kind

    var body: some View {
        let title = NativeJournalImpactCopy.title(for: driver.behaviorId)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body)
            Text(NativeJournalImpactCopy.recoverySentence(title: title, effect: driver.effect))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(NativePerformanceAssessmentCopy.driverNights(driver.yesInPeriod, kind: kind))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum NativePerformanceAssessmentCopy {
    static func heroValue(_ report: PerformanceAssessment.Report) -> String {
        if let rec = report.average(.recovery), rec.current.n > 0 {
            return "\(Int(rec.current.mean.rounded()))%"
        }
        return PerformanceAssessment.rangeLabel(report.window)
    }

    static func valueText(_ row: PerformanceAssessment.MetricDelta) -> String {
        guard row.current.n > 0 else { return "No data" }
        return format(row.current.mean, metric: row.metric)
    }

    static func priorText(_ row: PerformanceAssessment.MetricDelta) -> String? {
        guard row.previous.n > 0 else { return nil }
        return format(row.previous.mean, metric: row.metric)
    }

    static func format(_ value: Double, metric: PerformanceAssessment.Metric) -> String {
        switch metric {
        case .recovery, .sleepPerformance:
            return "\(Int(value.rounded()))%"
        case .strain:
            return String(format: "%.1f", value)
        case .sleepHours:
            return String(format: "%.1f hr", value)
        case .hrv:
            return "\(Int(value.rounded())) ms"
        case .rhr:
            return "\(Int(value.rounded())) bpm"
        case .respRate:
            return String(format: "%.1f breaths/min", value)
        case .steps:
            return NativeDayLogic.countText(value)
        case .calories:
            return "\(NativeDayLogic.countText(value)) cal"
        case .zones13, .zones45, .stressHigh:
            return NativeDayLogic.durationText(value)
        }
    }

    static func delta(_ row: PerformanceAssessment.MetricDelta) -> NativeScore.Delta {
        guard row.current.n > 0, row.previous.n > 0 else { return .none }
        return NativeScoreMath.delta(row.current.mean, [row.previous.mean])
    }

    static func symbol(_ metric: PerformanceAssessment.Metric) -> String {
        switch metric {
        case .recovery: return "heart.fill"
        case .strain: return "bolt.fill"
        case .sleepPerformance, .sleepHours: return "bed.double.fill"
        case .hrv: return "waveform.path.ecg"
        case .rhr: return "heart.fill"
        case .respRate: return "lungs.fill"
        case .steps: return "figure.walk"
        case .calories: return "flame.fill"
        case .zones13, .zones45: return "heart.fill"
        case .stressHigh: return "brain.head.profile"
        }
    }

    static func tint(_ metric: PerformanceAssessment.Metric) -> Color {
        switch metric {
        case .recovery: return NativeTokens.recoveryHigh
        case .strain, .zones13, .zones45: return NativeTokens.strain
        case .sleepPerformance, .sleepHours: return NativeTokens.sleep
        case .hrv, .rhr: return NativeTokens.heart
        case .respRate: return NativeTokens.respiratory
        case .steps, .calories: return NativeTokens.activity
        case .stressHigh: return NativeTokens.stressHigh
        }
    }

    static func valueTint(_ row: PerformanceAssessment.MetricDelta) -> Color {
        if row.metric == .recovery, row.current.n > 0 {
            return NativeTokens.recoveryBand(row.current.mean)
        }
        if row.metric == .sleepPerformance, row.current.n > 0 {
            return NativeTokens.sleepBand(row.current.mean)
        }
        return .primary
    }

    static func balanceTint(_ state: PerformanceAssessment.Balance) -> Color {
        switch state {
        case .optimal: return NativeTokens.recoveryHigh
        case .overreaching: return NativeTokens.recoveryLow
        case .restoring: return NativeTokens.strain
        case .insufficient: return .secondary
        }
    }

    static func sportValue(_ sport: PerformanceAssessment.SportDelta) -> String {
        let sessions = sport.sessions == 1 ? "1" : "\(sport.sessions)"
        return "\(sessions) · \(NativeDayLogic.durationText(sport.minutes))"
    }

    static func sportPrior(_ sport: PerformanceAssessment.SportDelta) -> String? {
        guard sport.priorSessions > 0 || sport.priorMinutes > 0 else { return nil }
        let sessions = sport.priorSessions == 1 ? "1" : "\(sport.priorSessions)"
        return "\(sessions) · \(NativeDayLogic.durationText(sport.priorMinutes))"
    }

    static func sportDelta(_ sport: PerformanceAssessment.SportDelta) -> NativeScore.Delta {
        guard sport.priorMinutes > 0 else { return .none }
        return NativeScoreMath.delta(sport.minutes, [sport.priorMinutes])
    }

    static func driverNights(_ n: Int, kind: PerformanceAssessment.Kind) -> String {
        let period = kind == .weekly ? "this week" : "this month"
        if n == 1 { return "Logged on 1 night \(period)." }
        return "Logged on \(n) nights \(period)."
    }

    static func historyCaption(_ report: PerformanceAssessment.Report) -> String {
        let word = report.balance.state.rawValue.capitalized
        if let rec = report.average(.recovery), rec.current.n > 0 {
            return "\(word) · \(Int(rec.current.mean.rounded()))% recovery"
        }
        return word
    }
}

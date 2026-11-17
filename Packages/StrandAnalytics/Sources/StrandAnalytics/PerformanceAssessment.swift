import Foundation

/// WHOOP-style weekly / monthly performance assessment.
///
/// Pure, deterministic, DB-free. A report covers the last complete Mon–Sun week
/// or calendar month relative to `asOfDay`. History is derived on demand from
/// the same daily maps — nothing is stored.
///
/// Strain–recovery balance uses `BandStrainTarget` (Restore / Maintain / Push
/// range on the 0–21 axis) and labels the period Optimal / Overreaching /
/// Restoring the way WHOOP Training Zones did.
public enum PerformanceAssessment {

    public enum Kind: String, Equatable, Sendable, Hashable {
        case weekly
        case monthly
    }

    public enum Balance: String, Equatable, Sendable {
        case optimal
        case overreaching
        case restoring
        case insufficient
    }

    public enum Metric: String, CaseIterable, Equatable, Sendable, Hashable {
        case recovery
        case strain
        case sleepPerformance
        case sleepHours
        case hrv
        case rhr
        case respRate
        case steps
        case calories
        case zones13
        case zones45
        case stressHigh

        public var label: String {
            switch self {
            case .recovery: return "Recovery"
            case .strain: return "Day Strain"
            case .sleepPerformance: return "Sleep Performance"
            case .sleepHours: return "Sleep Hours"
            case .hrv: return "HRV"
            case .rhr: return "Resting HR"
            case .respRate: return "Respiratory Rate"
            case .steps: return "Steps"
            case .calories: return "Calories"
            case .zones13: return "Zones 1–3"
            case .zones45: return "Zones 4–5"
            case .stressHigh: return "Time in High Stress"
            }
        }

        public var unit: String {
            switch self {
            case .recovery, .sleepPerformance: return "%"
            case .strain: return ""
            case .sleepHours: return "hr"
            case .hrv: return "ms"
            case .rhr: return "bpm"
            case .respRate: return "breaths/min"
            case .steps: return "steps"
            case .calories: return "cal"
            case .zones13, .zones45, .stressHigh: return "min"
            }
        }

        public var higherIsBetter: Bool {
            switch self {
            case .rhr, .respRate, .stressHigh: return false
            default: return true
            }
        }

        public var decimals: Int {
            switch self {
            case .strain, .sleepHours, .respRate: return 1
            default: return 0
            }
        }
    }

    public struct WorkoutEvent: Equatable, Sendable {
        public var day: String
        public var sport: String
        public var durationMin: Double
        /// Z1…Z5 minutes when known.
        public var zoneMinutes: [Double]?

        public init(day: String, sport: String, durationMin: Double, zoneMinutes: [Double]? = nil) {
            self.day = day
            self.sport = sport
            self.durationMin = durationMin
            self.zoneMinutes = zoneMinutes
        }
    }

    public struct Series: Equatable, Sendable {
        public var recovery: [String: Double]
        public var strain21: [String: Double]
        public var sleepPerformance: [String: Double]
        public var sleepHours: [String: Double]
        public var sleepNeedHours: [String: Double]
        public var sleepConsistency: [String: Double]
        public var hrv: [String: Double]
        public var rhr: [String: Double]
        public var respRate: [String: Double]
        public var steps: [String: Double]
        public var calories: [String: Double]
        public var stressHighMinutes: [String: Double]
        public var workouts: [WorkoutEvent]
        public var journal: [JournalImpact.Answer]

        public init(
            recovery: [String: Double] = [:],
            strain21: [String: Double] = [:],
            sleepPerformance: [String: Double] = [:],
            sleepHours: [String: Double] = [:],
            sleepNeedHours: [String: Double] = [:],
            sleepConsistency: [String: Double] = [:],
            hrv: [String: Double] = [:],
            rhr: [String: Double] = [:],
            respRate: [String: Double] = [:],
            steps: [String: Double] = [:],
            calories: [String: Double] = [:],
            stressHighMinutes: [String: Double] = [:],
            workouts: [WorkoutEvent] = [],
            journal: [JournalImpact.Answer] = []
        ) {
            self.recovery = recovery
            self.strain21 = strain21
            self.sleepPerformance = sleepPerformance
            self.sleepHours = sleepHours
            self.sleepNeedHours = sleepNeedHours
            self.sleepConsistency = sleepConsistency
            self.hrv = hrv
            self.rhr = rhr
            self.respRate = respRate
            self.steps = steps
            self.calories = calories
            self.stressHighMinutes = stressHighMinutes
            self.workouts = workouts
            self.journal = journal
        }

        public func map(for metric: Metric) -> [String: Double] {
            switch metric {
            case .recovery: return recovery
            case .strain: return strain21
            case .sleepPerformance: return sleepPerformance
            case .sleepHours: return sleepHours
            case .hrv: return hrv
            case .rhr: return rhr
            case .respRate: return respRate
            case .steps: return steps
            case .calories: return calories
            case .zones13: return [:]
            case .zones45: return [:]
            case .stressHigh: return stressHighMinutes
            }
        }
    }

    public struct Window: Equatable, Sendable {
        public var kind: Kind
        public var start: String
        public var end: String
        public var priorStart: String
        public var priorEnd: String

        public init(kind: Kind, start: String, end: String, priorStart: String, priorEnd: String) {
            self.kind = kind
            self.start = start
            self.end = end
            self.priorStart = priorStart
            self.priorEnd = priorEnd
        }
    }

    public struct MetricDelta: Equatable, Sendable {
        public var metric: Metric
        public var current: SeriesStat
        public var previous: SeriesStat
        public var comparison: PeriodComparison

        public init(metric: Metric, current: SeriesStat, previous: SeriesStat, comparison: PeriodComparison) {
            self.metric = metric
            self.current = current
            self.previous = previous
            self.comparison = comparison
        }
    }

    public struct SportDelta: Equatable, Sendable {
        public var sport: String
        public var sessions: Int
        public var minutes: Double
        public var priorSessions: Int
        public var priorMinutes: Double

        public init(sport: String, sessions: Int, minutes: Double, priorSessions: Int, priorMinutes: Double) {
            self.sport = sport
            self.sessions = sessions
            self.minutes = minutes
            self.priorSessions = priorSessions
            self.priorMinutes = priorMinutes
        }
    }

    public struct Night: Equatable, Sendable {
        public var day: String
        public var value: Double

        public init(day: String, value: Double) {
            self.day = day
            self.value = value
        }
    }

    public struct SleepRead: Equatable, Sendable {
        public var hoursSD: Double?
        public var consistencyMean: Double?
        public var debtStartMin: Double?
        public var debtEndMin: Double?
        public var best: Night?
        public var worst: Night?
        public var sentences: [String]

        public init(hoursSD: Double?, consistencyMean: Double?, debtStartMin: Double?,
                    debtEndMin: Double?, best: Night?, worst: Night?, sentences: [String]) {
            self.hoursSD = hoursSD
            self.consistencyMean = consistencyMean
            self.debtStartMin = debtStartMin
            self.debtEndMin = debtEndMin
            self.best = best
            self.worst = worst
            self.sentences = sentences
        }
    }

    public struct Driver: Equatable, Sendable {
        public var behaviorId: String
        public var effect: Double
        public var verdict: JournalImpact.Verdict
        public var yesInPeriod: Int
        public var sentence: String

        public init(behaviorId: String, effect: Double, verdict: JournalImpact.Verdict,
                    yesInPeriod: Int, sentence: String) {
            self.behaviorId = behaviorId
            self.effect = effect
            self.verdict = verdict
            self.yesInPeriod = yesInPeriod
            self.sentence = sentence
        }
    }

    public struct BalanceRead: Equatable, Sendable {
        public var state: Balance
        public var optimalDays: Int
        public var overreachingDays: Int
        public var restoringDays: Int
        public var classifiedDays: Int
        public var meanStrain: Double?
        public var meanTargetLo: Double?
        public var meanTargetHi: Double?
        public var sentence: String

        public init(state: Balance, optimalDays: Int, overreachingDays: Int, restoringDays: Int,
                    classifiedDays: Int, meanStrain: Double?, meanTargetLo: Double?,
                    meanTargetHi: Double?, sentence: String) {
            self.state = state
            self.optimalDays = optimalDays
            self.overreachingDays = overreachingDays
            self.restoringDays = restoringDays
            self.classifiedDays = classifiedDays
            self.meanStrain = meanStrain
            self.meanTargetLo = meanTargetLo
            self.meanTargetHi = meanTargetHi
            self.sentence = sentence
        }
    }

    public struct Report: Equatable, Sendable {
        public var window: Window
        public var daysWithData: Int
        public var averages: [MetricDelta]
        public var sports: [SportDelta]
        public var balance: BalanceRead
        public var sleep: SleepRead
        public var drivers: [Driver]
        public var highlights: [String]

        public init(window: Window, daysWithData: Int, averages: [MetricDelta], sports: [SportDelta],
                    balance: BalanceRead, sleep: SleepRead, drivers: [Driver], highlights: [String]) {
            self.window = window
            self.daysWithData = daysWithData
            self.averages = averages
            self.sports = sports
            self.balance = balance
            self.sleep = sleep
            self.drivers = drivers
            self.highlights = highlights
        }

        public var isEmpty: Bool { daysWithData == 0 }

        public func average(_ metric: Metric) -> MetricDelta? {
            averages.first { $0.metric == metric }
        }
    }

    /// Stored 0–100 Effort onto the WHOOP 0–21 axis (`UnitFormatter.effortScaleFactor`).
    public static func strain21(fromStored stored: Double) -> Double {
        stored * 21.0 / 100.0
    }

    /// Asleep minutes for one night.
    ///
    /// Order: main-session stage minutes (light+deep+REM from that session's
    /// `stagesJSON`) when present; else daily stage minutes when all three
    /// exist; else the stored daily total. The Native Sleep page's
    /// `NativeDayLogic.asleepMinutes` is the daily-metric wrapper (no session).
    /// Assessments pass the longest session for the day (same pick Sleep uses
    /// for time-in-bed) so stacked daily rows cannot inflate hours.
    public static func asleepMinutes(light: Double?, deep: Double?, rem: Double?,
                                     totalSleepMin: Double?,
                                     mainSessionAsleepMin: Double? = nil) -> Double? {
        if let main = mainSessionAsleepMin, main > 0 { return main }
        if let light, let deep, let rem {
            let sum = light + deep + rem
            return sum > 0 ? sum : nil
        }
        return totalSleepMin.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Asleep minutes from a WHOOP/Band session `stagesJSON` object
    /// (`light` / `deep` / `rem` minutes). Nil when any stage is missing.
    public static func asleepMinutes(stagesJSON: String?) -> Double? {
        guard let stagesJSON, let data = stagesJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func num(_ key: String) -> Double? {
            if let d = obj[key] as? Double { return d }
            if let i = obj[key] as? Int { return Double(i) }
            if let n = obj[key] as? NSNumber { return n.doubleValue }
            return nil
        }
        return asleepMinutes(light: num("light"), deep: num("deep"), rem: num("rem"),
                             totalSleepMin: nil)
    }

    public static let minDaysForBalanceWeekly = 4
    public static let minDaysForBalanceMonthly = 12
    public static let minDriverEffect = 4.0
    public static let maxDrivers = 3
    public static let maxHighlights = 3

    // MARK: - Windows

    /// Last complete Mon–Sun week, or last complete calendar month, ending on or before `asOfDay`.
    public static func lastCompleteWindow(kind: Kind, asOfDay: String) -> Window? {
        switch kind {
        case .weekly:
            guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: asOfDay) else { return nil }
            let sunday = WeeklyDigestEngine.addDays(monday, 6)
            let completeStart: String
            if asOfDay >= sunday {
                completeStart = monday
            } else {
                completeStart = WeeklyDigestEngine.addDays(monday, -7)
            }
            let completeEnd = WeeklyDigestEngine.addDays(completeStart, 6)
            let priorStart = WeeklyDigestEngine.addDays(completeStart, -7)
            let priorEnd = WeeklyDigestEngine.addDays(completeStart, -1)
            return Window(kind: .weekly, start: completeStart, end: completeEnd,
                          priorStart: priorStart, priorEnd: priorEnd)
        case .monthly:
            guard let (y, m, _) = WeeklyDigestEngine.parseYMD(asOfDay) else { return nil }
            let last = lastDayOfMonth(year: y, month: m)
            let completeY: Int
            let completeM: Int
            if asOfDay >= last {
                completeY = y
                completeM = m
            } else if m == 1 {
                completeY = y - 1
                completeM = 12
            } else {
                completeY = y
                completeM = m - 1
            }
            let start = formatYMD(completeY, completeM, 1)
            let end = lastDayOfMonth(year: completeY, month: completeM)
            let (py, pm) = completeM == 1 ? (completeY - 1, 12) : (completeY, completeM - 1)
            let priorStart = formatYMD(py, pm, 1)
            let priorEnd = lastDayOfMonth(year: py, month: pm)
            return Window(kind: .monthly, start: start, end: end,
                          priorStart: priorStart, priorEnd: priorEnd)
        }
    }

    /// Past complete periods, newest first. Computed on demand — nothing is stored.
    public static func historyWindows(kind: Kind, asOfDay: String, limit: Int) -> [Window] {
        guard limit > 0, var window = lastCompleteWindow(kind: kind, asOfDay: asOfDay) else { return [] }
        var out: [Window] = [window]
        while out.count < limit {
            let priorAsOf = window.end
            guard let previous = lastCompleteWindow(kind: kind, asOfDay: WeeklyDigestEngine.addDays(window.start, -1)),
                  previous.end < priorAsOf else { break }
            out.append(previous)
            window = previous
        }
        return out
    }

    // MARK: - Build

    public static func build(kind: Kind, series: Series, asOfDay: String) -> Report? {
        guard let window = lastCompleteWindow(kind: kind, asOfDay: asOfDay) else { return nil }
        return build(window: window, series: series)
    }

    public static func build(window: Window, series: Series) -> Report {
        let zoneMaps = zoneMaps(from: series.workouts)
        var averages: [MetricDelta] = []
        var days: Set<String>? = []
        for metric in Metric.allCases {
            let map: [String: Double]
            switch metric {
            case .zones13: map = zoneMaps.z13
            case .zones45: map = zoneMaps.z45
            default: map = series.map(for: metric)
            }
            let current = values(map, start: window.start, end: window.end, days: &days)
            var unused: Set<String>? = nil
            let previous = values(map, start: window.priorStart, end: window.priorEnd, days: &unused)
            guard !current.isEmpty || !previous.isEmpty else { continue }
            let curStat = ComparisonEngine.stat(current)
            let prevStat = ComparisonEngine.stat(previous)
            let cmp = ComparisonEngine.compare(current: current, previous: previous)
            averages.append(MetricDelta(metric: metric, current: curStat, previous: prevStat, comparison: cmp))
        }
        let sports = sportDeltas(workouts: series.workouts, window: window)
        let balance = balanceRead(window: window, series: series)
        let sleep = sleepRead(window: window, series: series)
        let drivers = drivers(window: window, series: series)
        let highlights = highlightSentences(window: window, series: series, averages: averages,
                                            sports: sports, balance: balance, sleep: sleep)
        return Report(window: window, daysWithData: days?.count ?? 0, averages: averages, sports: sports,
                      balance: balance, sleep: sleep, drivers: drivers, highlights: highlights)
    }

    // MARK: - Balance (BandStrainTarget)

    /// Load label from days that have both strain and recovery.
    ///
    /// - Restoring only when below-target days are a strict majority (`> 1/2`).
    ///   A large minority (e.g. 12 of 29) is not a restore.
    /// - Else overreaching when above-target days are a strict third (`> 1/3`).
    ///   Overreach is the risk flag even as a large minority.
    /// - Else optimal, including mixed months where neither extreme dominates.
    static func classifyBalance(optimal: Int, overreaching: Int, restoring: Int,
                                minDays: Int) -> Balance {
        let n = optimal + overreaching + restoring
        if n < minDays { return .insufficient }
        if restoring * 2 > n { return .restoring }
        if overreaching * 3 > n { return .overreaching }
        return .optimal
    }

    static func balanceRead(window: Window, series: Series) -> BalanceRead {
        let minDays = window.kind == .weekly ? minDaysForBalanceWeekly : minDaysForBalanceMonthly
        let days = dayKeys(start: window.start, end: window.end)
        var optimal = 0
        var over = 0
        var restore = 0
        var strains: [Double] = []
        var lo: [Double] = []
        var hi: [Double] = []
        for day in days {
            guard let recovery = series.recovery[day], recovery.isFinite else { continue }
            guard let strain = series.strain21[day], strain.isFinite else { continue }
            let history = daysBefore(day, in: series.strain21)
            guard let target = BandStrainTarget.recommend(recovery: recovery, recentStrain21: history) else {
                continue
            }
            strains.append(strain)
            lo.append(target.range.lowerBound)
            hi.append(target.range.upperBound)
            if strain < target.range.lowerBound {
                restore += 1
            } else if strain > target.range.upperBound {
                over += 1
            } else {
                optimal += 1
            }
        }
        let classified = optimal + over + restore
        let meanS = mean(strains)
        let meanLo = mean(lo)
        let meanHi = mean(hi)
        let state = classifyBalance(optimal: optimal, overreaching: over, restoring: restore,
                                    minDays: minDays)
        let sentence = balanceSentence(state: state, optimal: optimal, over: over, restore: restore,
                                       classified: classified, meanStrain: meanS, meanLo: meanLo, meanHi: meanHi,
                                       kind: window.kind)
        return BalanceRead(state: state, optimalDays: optimal, overreachingDays: over,
                           restoringDays: restore, classifiedDays: classified, meanStrain: meanS,
                           meanTargetLo: meanLo, meanTargetHi: meanHi, sentence: sentence)
    }

    static func balanceSentence(state: Balance, optimal: Int, over: Int, restore: Int,
                                classified: Int, meanStrain: Double?, meanLo: Double?,
                                meanHi: Double?, kind: Kind) -> String {
        let period = kind == .weekly ? "week" : "month"
        switch state {
        case .insufficient:
            return "Not enough strain and recovery days this \(period) to read the load."
        case .optimal:
            if optimal * 2 > classified {
                var line = "Strain sat inside the recovery target on \(optimal) of \(classified) days"
                if let meanStrain, let meanLo, let meanHi {
                    line += " (mean \(fmt1(meanStrain)) against \(fmt1(meanLo))–\(fmt1(meanHi)))"
                }
                line += " — load matched what recovery could take."
                return line
            }
            return "Strain mixed this \(period): \(optimal) days inside the target, \(restore) below, \(over) above — neither a restore nor an overreach."
        case .overreaching:
            var line = "Strain ran above the recovery target on \(over) of \(classified) days"
            if let meanStrain, let meanHi {
                line += " (mean \(fmt1(meanStrain)), band top \(fmt1(meanHi)))"
            }
            line += " — more than a third of days, so the \(period) asked for more than recovery had."
            return line
        case .restoring:
            var line = "Strain stayed below the recovery target on \(restore) of \(classified) days"
            if let meanStrain, let meanLo {
                line += " (mean \(fmt1(meanStrain)), band floor \(fmt1(meanLo)))"
            }
            line += " — a majority of days, so the \(period) paid down load more than it added."
            return line
        }
    }

    static func daysBefore(_ day: String, in strain: [String: Double]) -> [Double] {
        strain
            .filter { $0.key < day && $0.value.isFinite }
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    // MARK: - Sleep

    static func sleepRead(window: Window, series: Series) -> SleepRead {
        var unused: Set<String>? = nil
        let hours = keyedValues(series.sleepHours, start: window.start, end: window.end)
        let hoursStat = ComparisonEngine.stat(hours.map(\.value))
        let hoursSD: Double? = hoursStat.n >= 2 ? hoursStat.stdev : nil
        let cons = values(series.sleepConsistency, start: window.start, end: window.end, days: &unused)
        let consMean = cons.isEmpty ? nil : mean(cons)

        let sleepDays = Set(series.sleepHours.keys).union(series.sleepNeedHours.keys).sorted()
        let sleepSeries = sleepDays.map { ($0, series.sleepHours[$0].map { $0 * 60 }) }
        let needHours = mean(Array(series.sleepNeedHours.values.filter(\.isFinite).suffix(14)))
            ?? AnalyticsEngine.Rest.defaultNeedHours
        let beforeStart = WeeklyDigestEngine.addDays(window.start, -1)
        let startSeries = sleepSeries.filter { $0.0 <= beforeStart }
        let endSeries = sleepSeries.filter { $0.0 <= window.end }
        let debtStart = startSeries.isEmpty ? nil : SleepDebt.ledger(series: startSeries, needHours: needHours).balanceMin
        let debtEnd = endSeries.isEmpty ? nil : SleepDebt.ledger(series: endSeries, needHours: needHours).balanceMin

        let perf = keyedValues(series.sleepPerformance, start: window.start, end: window.end)
        let ranking = perf.count >= 2 ? perf : hours
        let best = ranking.max { $0.value < $1.value }.map { Night(day: $0.day, value: $0.value) }
        let worst = ranking.min { $0.value < $1.value }.map { Night(day: $0.day, value: $0.value) }

        var sentences: [String] = []
        if let consMean {
            if consMean >= 85 {
                sentences.append("Sleep consistency stayed high (\(Int(consMean.rounded()))%).")
            } else if consMean < 70 {
                sentences.append("Sleep consistency averaged \(Int(consMean.rounded()))% — timing drifted across the \(window.kind == .weekly ? "week" : "month").")
            }
        } else if let hoursSD, let meanH = mean(hours.map(\.value)), meanH >= 3, meanH <= 11 {
            let minutes = Int((hoursSD * 60).rounded())
            if hoursSD < 0.25 {
                sentences.append("Sleep length held within \(max(minutes, 1)) minutes of the mean.")
            } else if hoursSD >= 0.75 {
                sentences.append("Sleep length varied by \(minutes) minutes night to night.")
            }
        }

        if let debtStart, let debtEnd {
            // balanceMin is negative when in debt. A falling balance is a growing debt.
            let delta = debtEnd - debtStart
            if delta <= -15 {
                sentences.append("Sleep debt grew by \(Int((-delta).rounded())) minutes.")
            } else if delta >= 15 {
                sentences.append("The \(window.kind == .weekly ? "week" : "month") paid down \(Int(delta.rounded())) minutes of sleep debt.")
            }
        }

        if let best, let worst, best.day != worst.day {
            let usingPerf = perf.count >= 2
            if usingPerf {
                sentences.append("Best night \(shortDate(best.day)) (\(Int(best.value.rounded()))%); worst \(shortDate(worst.day)) (\(Int(worst.value.rounded()))%).")
            } else {
                sentences.append("Longest night \(shortDate(best.day)) (\(fmt1(best.value)) hr); shortest \(shortDate(worst.day)) (\(fmt1(worst.value)) hr).")
            }
        }

        return SleepRead(hoursSD: hoursSD, consistencyMean: consMean, debtStartMin: debtStart,
                         debtEndMin: debtEnd, best: best, worst: worst, sentences: sentences)
    }

    // MARK: - Drivers

    static func drivers(window: Window, series: Series) -> [Driver] {
        guard !series.journal.isEmpty, !series.recovery.isEmpty else { return [] }
        let ranked = JournalImpact.rank(
            answers: series.journal,
            recoveryByDay: series.recovery,
            sleepByDay: series.sleepPerformance,
            asOfDay: window.end,
            windowDays: JournalImpact.defaultWindowDays
        )
        var yesCounts: [String: Int] = [:]
        for a in series.journal where a.yes && a.day >= window.start && a.day <= window.end {
            yesCounts[a.behaviorId, default: 0] += 1
        }
        var out: [Driver] = []
        for insight in ranked {
            guard let rec = insight.recovery, rec.verdict.isClear else { continue }
            guard abs(rec.effect) >= minDriverEffect else { continue }
            let yes = yesCounts[insight.behaviorId] ?? 0
            guard yes > 0 else { continue }
            let name = shortBehavior(insight.behaviorId)
            let points = Int(abs(rec.effect).rounded())
            let word = rec.effect < 0 ? "lower" : "higher"
            let unit = points == 1 ? "point" : "points"
            let nights = yes == 1 ? "1 night" : "\(yes) nights"
            let sentence = "\(name) lined up with \(points) \(unit) \(word) recovery, and it was logged on \(nights)."
            out.append(Driver(behaviorId: insight.behaviorId, effect: rec.effect,
                              verdict: rec.verdict, yesInPeriod: yes, sentence: sentence))
            if out.count >= maxDrivers { break }
        }
        return out
    }

    // MARK: - Highlights

    static func highlightSentences(window: Window, series: Series, averages: [MetricDelta],
                                   sports: [SportDelta], balance: BalanceRead,
                                   sleep: SleepRead) -> [String] {
        var lines: [String] = []
        if let line = outlierHighlight(window: window, series: series) { lines.append(line) }
        if let line = splitHighlight(window: window, series: series, averages: averages, sleep: sleep) {
            lines.append(line)
        }
        if let line = compositionHighlight(window: window, series: series, averages: averages,
                                           sports: sports) {
            lines.append(line)
        }
        if lines.count < maxHighlights, let line = capacityHighlight(averages: averages, balance: balance) {
            lines.append(line)
        }
        return Array(lines.prefix(maxHighlights))
    }

    /// A single night that the period mean hides.
    static func outlierHighlight(window: Window, series: Series) -> String? {
        let rec = keyedValues(series.recovery, start: window.start, end: window.end)
        guard rec.count >= 5 else { return nil }
        guard let worst = rec.min(by: { $0.value < $1.value }) else { return nil }
        let others = rec.filter { $0.day != worst.day }.map(\.value)
        guard let otherMean = mean(others) else { return nil }
        let gap = otherMean - worst.value
        guard gap >= 20, worst.value < 34 else { return nil }
        return "\(shortDate(worst.day)) is the only red recovery day at \(Int(worst.value.rounded()))%; the other \(others.count) averaged \(Int(otherMean.rounded()))%."
    }

    /// Two metrics that disagree, so the average row is not the story.
    static func splitHighlight(window: Window, series: Series, averages: [MetricDelta],
                               sleep: SleepRead) -> String? {
        let rec = averages.first { $0.metric == .recovery }
        let hrv = averages.first { $0.metric == .hrv }
        let hours = averages.first { $0.metric == .sleepHours }
        let perf = averages.first { $0.metric == .sleepPerformance }
        let period = window.kind == .weekly ? "last week" : "last month"

        if let hours, let perf,
           hours.comparison.previous.n >= 4, perf.comparison.previous.n >= 4,
           abs(hours.comparison.delta) < 0.25, abs(perf.comparison.delta) >= 6 {
            let dir = perf.comparison.delta < 0 ? "fell" : "rose"
            return "Hours matched \(period), but sleep performance \(dir) \(Int(abs(perf.comparison.delta).rounded())) points, so the same time covered \(perf.comparison.delta < 0 ? "less" : "more") of the need."
        }

        if let rec, let hrv,
           rec.comparison.previous.n >= 4, hrv.comparison.previous.n >= 4,
           abs(rec.comparison.delta) >= 5, abs(pct(hrv) ?? 100) < 4 {
            let dir = rec.comparison.delta < 0 ? "dropped" : "rose"
            return "Recovery \(dir) \(Int(abs(rec.comparison.delta).rounded())) points while HRV held near \(Int(hrv.current.mean.rounded())) ms — the score moved with sleep, not tone."
        }

        if let rec, let hrv,
           rec.comparison.previous.n >= 4, hrv.comparison.previous.n >= 4,
           abs(pct(hrv) ?? 0) >= 8, abs(rec.comparison.delta) < 3 {
            let dir = hrv.comparison.delta < 0 ? "fell" : "rose"
            return "HRV \(dir) \(Int(abs(hrv.comparison.delta).rounded())) ms while recovery barely moved — autonomic tone shifted without a matching score."
        }

        if let start = sleep.debtStartMin, let end = sleep.debtEndMin, let hours,
           hours.comparison.previous.n >= 4, abs(hours.comparison.delta) < 0.3 {
            let delta = end - start
            if delta <= -25 {
                return "Sleep hours held, yet debt grew \(Int((-delta).rounded())) minutes because more nights landed under need."
            }
            if delta >= 25 {
                return "Sleep hours held, but debt shrank \(Int(delta.rounded())) minutes — more nights cleared need instead of adding volume."
            }
        }
        return nil
    }

    /// Where the load actually came from.
    static func compositionHighlight(window: Window, series: Series, averages: [MetricDelta],
                                     sports: [SportDelta]) -> String? {
        let strain = averages.first { $0.metric == .strain }
        let steps = averages.first { $0.metric == .steps }
        let z45 = averages.first { $0.metric == .zones45 }
        let period = window.kind == .weekly ? "week" : "month"

        if let strain, let steps,
           strain.comparison.previous.n >= 4, steps.comparison.previous.n >= 4,
           strain.comparison.delta >= 0.8, (pct(steps) ?? 0) <= -8 {
            return "Strain rose \(fmt1(strain.comparison.delta)) while steps fell — the extra load came from workouts, not walking."
        }
        if let strain, let steps,
           strain.comparison.previous.n >= 4, steps.comparison.previous.n >= 4,
           strain.comparison.delta <= -0.8, (pct(steps) ?? 0) >= 8 {
            return "Steps were up but strain fell \(fmt1(abs(strain.comparison.delta))) — more movement, less hard work."
        }

        if let z45, z45.previous.mean >= 15, z45.current.mean >= 20,
           z45.current.mean / max(z45.previous.mean, 0.01) >= 1.8 {
            return "Time in zones 4–5 ran \(fmt1(z45.current.mean / max(z45.previous.mean, 0.01)))× the prior \(period), which is the intensity change the strain average understates."
        }
        if let z45, let rec = averages.first(where: { $0.metric == .recovery }),
           z45.previous.n > 0, z45.previous.mean < 5, z45.current.mean >= 15,
           rec.comparison.previous.n >= 4, rec.comparison.delta >= 5 {
            return "Zones 4–5 picked up while recovery rose — the extra intensity didn't take the \(period) down."
        }

        let inPeriod = series.workouts.filter { $0.day >= window.start && $0.day <= window.end }
        if inPeriod.count >= 4 {
            var byDay: [String: Double] = [:]
            for w in inPeriod { byDay[w.day, default: 0] += w.durationMin }
            let total = byDay.values.reduce(0, +)
            let top2 = byDay.values.sorted(by: >).prefix(2).reduce(0, +)
            if total >= 60, top2 / total >= 0.7 {
                return "Most of the \(period)'s training minutes landed on two days, so average strain looks calmer than the hard days felt."
            }
        }

        if let top = sports.first, top.sessions >= 3, sports.count >= 2 {
            let totalMin = sports.reduce(0.0) { $0 + $1.minutes }
            if totalMin > 0, top.minutes / totalMin >= 0.65 {
                return "\(top.sport) made up \(Int((top.minutes / totalMin * 100).rounded()))% of training time — the \(period)'s load is that sport, not a mixed week."
            }
        }
        return nil
    }

    static func capacityHighlight(averages: [MetricDelta], balance: BalanceRead) -> String? {
        let rec = averages.first { $0.metric == .recovery }?.current.mean
        switch balance.state {
        case .restoring:
            if let rec, rec >= 67 {
                return "Green recoveries and strain below target: the period stored capacity rather than using it."
            }
        case .overreaching:
            if let rec, rec >= 34, rec < 67 {
                return "Yellow recoveries still took strain above the target on \(balance.overreachingDays) days, so the period spent more than it had."
            }
        default:
            break
        }
        return nil
    }

    // MARK: - Sports / zones

    static func sportDeltas(workouts: [WorkoutEvent], window: Window) -> [SportDelta] {
        func bag(_ start: String, _ end: String) -> [String: (n: Int, min: Double)] {
            var out: [String: (n: Int, min: Double)] = [:]
            for w in workouts where w.day >= start && w.day <= end {
                var row = out[w.sport] ?? (0, 0)
                row.n += 1
                row.min += max(w.durationMin, 0)
                out[w.sport] = row
            }
            return out
        }
        let cur = bag(window.start, window.end)
        let prev = bag(window.priorStart, window.priorEnd)
        let names = Set(cur.keys).union(prev.keys)
        return names.map { name in
            let c = cur[name] ?? (0, 0)
            let p = prev[name] ?? (0, 0)
            return SportDelta(sport: name, sessions: c.n, minutes: c.min,
                              priorSessions: p.n, priorMinutes: p.min)
        }
        .filter { $0.sessions > 0 }
        .sorted { a, b in
            if a.minutes != b.minutes { return a.minutes > b.minutes }
            return a.sport < b.sport
        }
    }

    static func zoneMaps(from workouts: [WorkoutEvent]) -> (z13: [String: Double], z45: [String: Double]) {
        var z13: [String: Double] = [:]
        var z45: [String: Double] = [:]
        for w in workouts {
            guard let zones = w.zoneMinutes, zones.count >= 5 else { continue }
            let a = zones[0] + zones[1] + zones[2]
            let b = zones[3] + zones[4]
            if a > 0 { z13[w.day, default: 0] += a }
            if b > 0 { z45[w.day, default: 0] += b }
        }
        return (z13, z45)
    }

    // MARK: - Notify

    /// Default-off local notification: fire once when a newly complete week exists.
    public enum NotifyPolicy {
        public static func shouldNotify(enabled: Bool, asOfDay: String,
                                        lastNotifiedEnd: String?) -> String? {
            guard enabled else { return nil }
            guard let window = lastCompleteWindow(kind: .weekly, asOfDay: asOfDay) else { return nil }
            if lastNotifiedEnd == window.end { return nil }
            return window.end
        }

        public static func copy(weekStart: String, weekEnd: String) -> (title: String, body: String) {
            (title: "Weekly assessment ready",
             body: "The week of \(shortDate(weekStart))–\(dayOnly(weekEnd)) is in.")
        }
    }

    // MARK: - Formatting (locale-free, from ISO days)

    public static func shortDate(_ ymd: String) -> String {
        guard let (y, m, d) = WeeklyDigestEngine.parseYMD(ymd),
              let w = weekday(y, m, d) else { return ymd }
        let wd = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][w]
        let mo = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][m - 1]
        return "\(wd) \(d) \(mo)"
    }

    public static func rangeLabel(_ window: Window) -> String {
        if window.kind == .monthly {
            guard let (_, m, _) = WeeklyDigestEngine.parseYMD(window.start),
                  let (y, _, _) = WeeklyDigestEngine.parseYMD(window.end) else {
                return "\(window.start) – \(window.end)"
            }
            let mo = ["January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December"][m - 1]
            return "\(mo) \(y)"
        }
        return "\(shortDate(window.start)) – \(dayOnly(window.end))"
    }

    static func dayOnly(_ ymd: String) -> String {
        guard let (_, m, d) = WeeklyDigestEngine.parseYMD(ymd) else { return ymd }
        let mo = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][m - 1]
        return "\(d) \(mo)"
    }

    static func shortBehavior(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") {
            return String(trimmed.dropLast()).lowercased()
        }
        return trimmed
    }

    static func lastDayOfMonth(year: Int, month: Int) -> String {
        let (ny, nm) = month == 12 ? (year + 1, 1) : (year, month + 1)
        return WeeklyDigestEngine.addDays(formatYMD(ny, nm, 1), -1)
    }

    static func formatYMD(_ y: Int, _ m: Int, _ d: Int) -> String {
        String(format: "%04d-%02d-%02d", y, m, d)
    }

    static func weekday(_ y: Int, _ m: Int, _ d: Int) -> Int? {
        WeeklyDigestEngine.weekday(y, m, d)
    }

    static func dayKeys(start: String, end: String) -> [String] {
        var keys: [String] = []
        var day = start
        var guardCount = 0
        while day <= end, guardCount < 62 {
            keys.append(day)
            day = WeeklyDigestEngine.addDays(day, 1)
            guardCount += 1
        }
        return keys
    }

    static func values(_ series: [String: Double], start: String, end: String,
                       days: inout Set<String>?) -> [Double] {
        keyedValues(series, start: start, end: end).map { row in
            days?.insert(row.day)
            return row.value
        }
    }

    static func keyedValues(_ series: [String: Double], start: String, end: String)
        -> [(day: String, value: Double)] {
        series
            .filter { $0.key >= start && $0.key <= end && $0.value.isFinite }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func pct(_ delta: MetricDelta) -> Double? {
        delta.comparison.pctChange
    }

    static func fmt1(_ x: Double) -> String {
        String(format: "%.1f", (x * 10).rounded() / 10)
    }
}

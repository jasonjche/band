import Foundation
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

// Sleep-page facts that NativeBandScores does not expose. Views in NativeSleepCards
// read these; NativeScoreView only composes them.

enum NativeSleepNeed {
    /// Tonight / Last Night / Hours vs. Needed all read `needMin` from this value.
    struct Resolved: Equatable {
        var needMin: Double
        var hoursSleptMin: Double?
        var percent: Double?
        var imported: Bool
        var baselineMin: Double?
        var strainMin: Double?
        var debtMin: Double?

        var hasBreakdown: Bool {
            !imported && baselineMin != nil && strainMin != nil && debtMin != nil
        }
    }

    /// Single resolver for Hours vs. Needed, Last Night's need line, and Home's Tonight's Sleep.
    static func resolve(
        dayKey: String,
        days: [DailyMetric],
        sleeps: [CachedSleepSession] = [],
        workouts: [WorkoutRow] = [],
        importedSleep: [String: ImportedSleepFigures] = [:]
    ) -> Resolved? {
        let scores = NativeBandScores.resolve(
            days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        guard let scored = scores.byDay[dayKey], let need = scored.sleepNeed, need > 0 else {
            return nil
        }
        let metric = days.last { $0.day == dayKey }
        let hours = NativeDayLogic.asleepMinutes(
            light: metric?.lightMin, deep: metric?.deepMin, rem: metric?.remMin,
            totalSleepMin: metric?.totalSleepMin
        )
        let percent = scored.hoursVsNeeded ?? hours.flatMap { asleep in
            asleep > 0 ? asleep / need * 100 : nil
        }
        let imported = scored.source == .imported
        var baseline: Double?
        var strain: Double?
        var debt: Double?
        if !imported, let parts = bandParts(dayKey: dayKey, days: days, sleeps: sleeps,
                                            workouts: workouts, importedSleep: importedSleep) {
            strain = parts.strain
            debt = parts.debt
            baseline = need - parts.strain - parts.debt
        }
        return Resolved(
            needMin: need,
            hoursSleptMin: hours,
            percent: percent,
            imported: imported,
            baselineMin: baseline,
            strainMin: strain,
            debtMin: debt
        )
    }

    /// The minutes Home's Tonight's Sleep and Last Night already take as `needMin`.
    static func needMinutes(_ resolved: Resolved?) -> Double? {
        resolved.flatMap { $0.needMin > 0 ? $0.needMin : nil }
    }

    static func signedDuration(_ minutes: Double) -> String {
        let sign = minutes < 0 ? "−" : "+"
        return sign + NativeScoreMath.duration(abs(minutes))
    }

    private static func bandParts(
        dayKey: String,
        days: [DailyMetric],
        sleeps: [CachedSleepSession],
        workouts: [WorkoutRow],
        importedSleep: [String: ImportedSleepFigures]
    ) -> (strain: Double, debt: Double)? {
        guard let params = NativeBandScores.params() else { return nil }
        let inputs = NativeBandScores.dayInputs(
            days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        let outputs = BandScores.evaluate(days: inputs, params: params)
        guard let out = outputs.first(where: { $0.day == dayKey }) else { return nil }
        let strain = params.sleepLedger.a * (out.loadForNeed ?? 0)
        let debt = params.sleepLedger.b * (out.debt ?? 0)
        return (strain, debt)
    }
}

enum NativeSleepContributors {
    static func restorative(from stages: [NativeStage]) -> NativeScore.Row? {
        let rest = NativeDay.restorative(from: stages)
        guard let minutes = rest.minutes else { return nil }
        let prior = rest.typical.map { [$0] } ?? []
        return NativeScore.Row(
            title: "Restorative Sleep",
            value: NativeDayLogic.durationText(minutes),
            prior: rest.typical.map { NativeDayLogic.durationText($0) } ?? "—",
            symbol: "sparkles",
            delta: NativeScoreMath.delta(minutes, prior),
            route: .metric("restorative_min")
        )
    }

    static func highSleepStress(_ percent: Double?) -> NativeScore.Row? {
        guard let percent else { return nil }
        return NativeScore.Row(
            title: "High Sleep Stress",
            value: NativeScoreMath.percent(percent),
            prior: "—",
            symbol: "waveform.path",
            delta: .none,
            route: .stress
        )
    }
}

struct NativeSleepNight: Identifiable, Equatable {
    var id: String { key }
    var key: String
    var bedtime: Date
    var wake: Date
    var isToday: Bool

    var bedFromEvening: Double { NativeSleepClock.minutesFromEvening(bedtime) }
    var wakeFromEvening: Double { NativeSleepClock.minutesFromEvening(wake) }
}

enum NativeSleepClock {
    static let eveningHour = 18
    static let axisMarks: [Double] = [180, 420, 660, 900, 1140]

    static func minutesFromEvening(_ date: Date) -> Double {
        let cal = Calendar.current
        let tod = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        let sixPM = eveningHour * 60
        if tod >= sixPM { return Double(tod - sixPM) }
        return Double(tod + (24 * 60 - sixPM))
    }

    static func plotY(_ minutesFromEvening: Double) -> Double {
        -minutesFromEvening
    }

    private static let hourOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h a"
        return formatter
    }()

    private static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static func label(_ minutesFromEvening: Double) -> String {
        var total = (eveningHour * 60 + Int(minutesFromEvening.rounded())) % (24 * 60)
        if total < 0 { total += 24 * 60 }
        var comps = DateComponents()
        comps.year = 2000
        comps.month = 1
        comps.day = 1
        comps.hour = total / 60
        comps.minute = total % 60
        let date = Calendar(identifier: .gregorian).date(from: comps) ?? Date()
        return hourOnly.string(from: date).replacingOccurrences(of: " ", with: "")
    }

    static func clock(_ date: Date) -> String {
        hourMinute.string(from: date)
    }
}

enum NativeSleepConsistency {
    static func nights(
        dayKey: String,
        sleeps: [CachedSleepSession],
        limit: Int = 7
    ) -> [NativeSleepNight] {
        let keys = NativeWeek.lastSevenKeys(ending: dayKey).suffix(limit)
        let byDay = Dictionary(grouping: sleeps) {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs)))
        }
        return keys.compactMap { key in
            let blocks = (byDay[key] ?? []).sorted {
                ($0.endTs - $0.effectiveStartTs) > ($1.endTs - $1.effectiveStartTs)
            }
            guard let main = blocks.first, main.endTs > main.effectiveStartTs else { return nil }
            return NativeSleepNight(
                key: key,
                bedtime: Date(timeIntervalSince1970: TimeInterval(main.effectiveStartTs)),
                wake: Date(timeIntervalSince1970: TimeInterval(main.endTs)),
                isToday: key == dayKey
            )
        }
    }

    static func averageBed(_ nights: [NativeSleepNight]) -> Double? {
        NativeScoreMath.mean(nights.map(\.bedFromEvening))
    }

    static func averageWake(_ nights: [NativeSleepNight]) -> Double? {
        NativeScoreMath.mean(nights.map(\.wakeFromEvening))
    }
}

struct NativeSleepStageSpan: Identifiable, Equatable {
    var id: Int { startTs }
    var startTs: Int
    var endTs: Int
    var name: String

    var minutes: Double { Double(max(0, endTs - startTs)) / 60 }
}

enum NativeSleepEfficiency {
    struct Model: Equatable {
        var percent: Double
        var prior: Double?
        var spans: [NativeSleepStageSpan]
        var wakeEvents: Int?
    }

    static func make(
        day: DailyMetric?,
        prior: [DailyMetric],
        segments: [StageSegment]
    ) -> Model? {
        guard let raw = day?.efficiency, raw > 0 else { return nil }
        let percent = raw <= 1 ? raw * 100 : raw
        let priorValues = prior.compactMap { $0.efficiency }.map { $0 <= 1 ? $0 * 100 : $0 }
        let spans = spans(from: segments)
        let wakes = wakeEvents(in: segments)
        return Model(
            percent: percent,
            prior: NativeScoreMath.mean(priorValues),
            spans: spans,
            wakeEvents: spans.isEmpty ? nil : wakes
        )
    }

    static func spans(from segments: [StageSegment]) -> [NativeSleepStageSpan] {
        segments.filter { $0.end > $0.start }.map {
            NativeSleepStageSpan(startTs: $0.start, endTs: $0.end, name: displayName($0.stage))
        }
    }

    static func wakeEvents(in segments: [StageSegment]) -> Int {
        guard segments.count > 1 else { return 0 }
        var count = 0
        for i in 1..<segments.count {
            if isAwake(segments[i].stage) && !isAwake(segments[i - 1].stage) {
                count += 1
            }
        }
        return count
    }

    static func displayName(_ stage: String) -> String {
        switch stage.lowercased() {
        case "wake", "awake": return "Awake"
        case "rem": return "REM"
        case "deep", "sws": return "Deep"
        default: return "Light"
        }
    }

    static func isAwake(_ stage: String) -> Bool {
        let name = stage.lowercased()
        return name == "wake" || name == "awake"
    }
}

enum NativeSleepStress {
    struct Band: Identifiable, Equatable {
        var id: String { title }
        var title: String
        var minutes: Double
        var percent: Double
    }

    struct Model: Equatable {
        var points: [NativeHourPoint]
        var high: Band
        var medium: Band
        var low: Band
        var highShare: Double
    }

    static func make(hr: [HRSample], startTs: Int, endTs: Int) -> Model? {
        let window = SleepStressShare.windowSeconds
        guard endTs > startTs, window > 0, !hr.isEmpty else { return nil }
        var buckets: [Int: [Double]] = [:]
        for sample in hr where sample.ts >= startTs && sample.ts < endTs {
            let idx = (sample.ts - startTs) / window
            buckets[idx, default: []].append(Double(sample.bpm))
        }
        guard !buckets.isEmpty else { return nil }
        let minN = SleepStressShare.minWindowHRSamples(windowSeconds: window)
        let keys = buckets.keys.sorted()
        let meanHRs: [Double?] = keys.map { key in
            let xs = buckets[key]!
            return xs.count >= minN ? xs.reduce(0, +) / Double(xs.count) : nil
        }
        let scored = meanHRs.compactMap { $0 }
        guard !scored.isEmpty else { return nil }
        let ref = calmReference(scored)
        let sd = populationStd(scored, mean: scored.reduce(0, +) / Double(scored.count))
        var points: [NativeHourPoint] = []
        var levels: [Double?] = []
        for (offset, mean) in zip(keys, meanHRs) {
            guard let mean else {
                levels.append(nil)
                continue
            }
            let raw = sd > 0.0001 ? (mean - ref) / sd : 0
            let level = min(max(3.0 / (1.0 + exp(-raw)), 0), 3)
            levels.append(level)
            let time = Date(timeIntervalSince1970: TimeInterval(startTs + offset * window + window / 2))
            points.append(NativeHourPoint(time: time, value: level))
        }
        guard let share = SleepStressShare.percent(levels: levels) else { return nil }
        let scoredLevels = levels.compactMap { $0 }
        let windowMin = Double(window) / 60
        func band(_ title: String, predicate: (Double) -> Bool) -> Band {
            let count = scoredLevels.filter(predicate).count
            let minutes = Double(count) * windowMin
            let percent = scoredLevels.isEmpty ? 0 : Double(count) / Double(scoredLevels.count) * 100
            return Band(title: title, minutes: minutes, percent: percent)
        }
        return Model(
            points: points,
            high: band("High") { $0 >= SleepStressShare.highBandFloor },
            medium: band("Medium") { $0 >= 1 && $0 < SleepStressShare.highBandFloor },
            low: band("Low") { $0 < 1 },
            highShare: share
        )
    }

    private static func calmReference(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard s.count >= 4 else { return xs.reduce(0, +) / Double(xs.count) }
        let q = 0.25 * Double(s.count - 1)
        let lo = Int(q.rounded(.down))
        let hi = min(lo + 1, s.count - 1)
        let t = q - Double(lo)
        return s[lo] * (1 - t) + s[hi] * t
    }

    private static func populationStd(_ xs: [Double], mean: Double) -> Double {
        guard xs.count > 1 else { return 0 }
        let v = xs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(xs.count)
        return v.squareRoot()
    }
}

enum NativeSleepWeek {
    static func cards(
        kind: NativeScoreKind,
        base: [NativeWeek.Card],
        days: [DailyMetric],
        todayKey: String,
        sleeps: [CachedSleepSession] = [],
        workouts: [WorkoutRow] = [],
        importedSleep: [String: ImportedSleepFigures] = [:],
        sleepStressByDay: [String: Double] = [:]
    ) -> [NativeWeek.Card] {
        switch kind {
        case .sleep:
            return mergeSleep(
                base: base, days: days, todayKey: todayKey, sleeps: sleeps,
                workouts: workouts, importedSleep: importedSleep,
                sleepStressByDay: sleepStressByDay
            )
        case .recovery:
            return mergeRecovery(base: base, days: days, todayKey: todayKey,
                                 sleeps: sleeps, workouts: workouts, importedSleep: importedSleep)
        case .strain:
            return base
        }
    }

    private static func mergeSleep(
        base: [NativeWeek.Card],
        days: [DailyMetric],
        todayKey: String,
        sleeps: [CachedSleepSession],
        workouts: [WorkoutRow],
        importedSleep: [String: ImportedSleepFigures],
        sleepStressByDay: [String: Double]
    ) -> [NativeWeek.Card] {
        let scores = NativeBandScores.resolve(
            days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        let filled: (NativeWeek.Card) -> Bool = {
            $0.points.contains { $0.value.isFinite }
                || $0.stacks.contains { stack in stack.points.contains { $0.value.isFinite } }
        }
        let hours = NativeWeek.series(days, todayKey: todayKey) {
            NativeDayLogic.asleepMinutes(light: $0.lightMin, deep: $0.deepMin, rem: $0.remMin,
                                         totalSleepMin: $0.totalSleepMin)
        }
        let needed = NativeWeek.series(days, todayKey: todayKey) { scores.byDay[$0.day]?.sleepNeed }
        let hvnPct = NativeWeek.series(days, todayKey: todayKey) { scores.byDay[$0.day]?.hoursVsNeeded }
        let deep = NativeWeek.series(days, todayKey: todayKey) { $0.deepMin }
        let rem = NativeWeek.series(days, todayKey: todayKey) { $0.remMin }
        let restorative = NativeWeek.sumSeries(deep, rem)
        let cons = NativeWeek.series(days, todayKey: todayKey) { scores.byDay[$0.day]?.sleepConsistency }
        let inBed = timeInBedPoints(todayKey: todayKey, sleeps: sleeps)
        let debt = NativeWeek.series(days, todayKey: todayKey) { scores.byDay[$0.day]?.sleepDebt }
        let stress = NativeWeek.lastSevenKeys(ending: todayKey).map { key in
            NativeDayPoint(key: key, value: sleepStressByDay[key] ?? .nan)
        }

        let extra: [NativeWeek.Card] = [
            NativeWeek.Card(
                title: "Hours vs. Needed",
                points: hours,
                maxY: max(hours.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0,
                          needed.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 480),
                bars: false, tint: NativeChrome.sleep, route: .metric("hours_vs_needed_pct"),
                format: .duration, band: false
            ),
            NativeWeek.Card(
                title: "Hours vs. Needed %",
                points: hvnPct,
                maxY: 100, bars: true, tint: NativeChrome.sleep, route: .metric("hours_vs_needed_pct"),
                format: .percent, band: false
            ),
            NativeWeek.Card(
                title: "Restorative Sleep",
                points: restorative,
                maxY: max(restorative.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 120),
                bars: true, tint: NativeChrome.sleep, route: .metric("restorative_min"),
                format: .duration, band: false,
                stacks: [
                    NativeWeek.Card.Stack(title: "Deep", points: deep, tint: NativeTokens.sleepDeep),
                    NativeWeek.Card.Stack(title: "REM", points: rem, tint: NativeTokens.sleepREM),
                ]
            ),
            NativeWeek.Card(
                title: "Sleep Consistency",
                points: cons,
                maxY: 100, bars: true, tint: NativeChrome.sleep, route: .metric("sleep_consistency"),
                format: .percent, band: false
            ),
            NativeWeek.Card(
                title: "Time in Bed",
                points: inBed,
                maxY: max(inBed.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 480),
                bars: false, tint: NativeChrome.sleep, route: nil,
                format: .duration, band: false
            ),
            NativeWeek.Card(
                title: "Sleep Debt",
                points: debt,
                maxY: max(debt.compactMap { $0.value.isFinite ? $0.value : nil }.max() ?? 0, 60),
                bars: true, tint: NativeChrome.sleep, route: nil,
                format: .duration, band: false
            ),
            NativeWeek.Card(
                title: "Sleep Stress",
                points: stress,
                maxY: 100, bars: false, tint: NativeChrome.sleep, route: .stress,
                format: .percent, band: false
            ),
        ].filter(filled)

        var ordered: [NativeWeek.Card] = []
        let titles = [
            "Sleep Performance", "Hours of Sleep", "Hours vs. Needed", "Hours vs. Needed %",
            "Restorative Sleep", "Sleep Consistency", "Time in Bed", "Sleep Efficiency",
            "Sleep Debt", "Sleep Stress",
        ]
        let byTitle = Dictionary(uniqueKeysWithValues: (base + extra).map { ($0.title, $0) })
        for title in titles {
            if let card = byTitle[title] { ordered.append(card) }
        }
        for card in base where !ordered.contains(where: { $0.title == card.title }) {
            ordered.append(card)
        }
        return ordered
    }

    private static func mergeRecovery(
        base: [NativeWeek.Card],
        days: [DailyMetric],
        todayKey: String,
        sleeps: [CachedSleepSession],
        workouts: [WorkoutRow],
        importedSleep: [String: ImportedSleepFigures]
    ) -> [NativeWeek.Card] {
        let points = NativeWeek.points(
            kind: .sleep, days: days, todayKey: todayKey, sleeps: sleeps,
            workouts: workouts, importedSleep: importedSleep
        )
        guard points.contains(where: { $0.value.isFinite }) else { return base }
        let card = NativeWeek.Card(
            title: "Sleep Performance",
            points: points,
            maxY: 100, bars: true, tint: NativeChrome.sleep, route: .sleep,
            format: .percent, band: false
        )
        if base.contains(where: { $0.title == "Sleep Performance" }) { return base }
        var cards = base
        let idx = cards.firstIndex(where: { $0.title == "Recovery" }).map { $0 + 1 } ?? cards.count
        cards.insert(card, at: min(idx, cards.count))
        return cards
    }

    static func timeInBedPoints(todayKey: String, sleeps: [CachedSleepSession]) -> [NativeDayPoint] {
        let byDay = Dictionary(grouping: sleeps) {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs)))
        }
        return NativeWeek.lastSevenKeys(ending: todayKey).map { key in
            let blocks = (byDay[key] ?? []).sorted {
                ($0.endTs - $0.effectiveStartTs) > ($1.endTs - $1.effectiveStartTs)
            }
            guard let main = blocks.first, main.endTs > main.effectiveStartTs else {
                return NativeDayPoint(key: key, value: .nan)
            }
            let bed = Date(timeIntervalSince1970: TimeInterval(main.effectiveStartTs))
            let wake = Date(timeIntervalSince1970: TimeInterval(main.endTs))
            let minutes = Double(main.endTs - main.effectiveStartTs) / 60
            return NativeDayPoint(
                key: key,
                value: minutes,
                low: NativeSleepClock.minutesFromEvening(bed),
                high: NativeSleepClock.minutesFromEvening(wake)
            )
        }
    }

    static func neededSeries(
        days: [DailyMetric],
        todayKey: String,
        sleeps: [CachedSleepSession],
        workouts: [WorkoutRow],
        importedSleep: [String: ImportedSleepFigures]
    ) -> [NativeDayPoint] {
        let scores = NativeBandScores.resolve(
            days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        return NativeWeek.series(days, todayKey: todayKey) { scores.byDay[$0.day]?.sleepNeed }
    }
}

struct NativeSleepPageDetail {
    var need: NativeSleepNeed.Resolved?
    var consistencyNights: [NativeSleepNight]
    var efficiency: NativeSleepEfficiency.Model?
    var stress: NativeSleepStress.Model?
    var hoursNeededWeek: [NativeDayPoint]
    var timeInBedWeek: [NativeDayPoint]

    static func make(
        dayKey: String,
        days: [DailyMetric],
        sleeps: [CachedSleepSession],
        workouts: [WorkoutRow],
        importedSleep: [String: ImportedSleepFigures],
        stress: NativeSleepStress.Model? = nil
    ) -> NativeSleepPageDetail {
        let metric = days.last { $0.day == dayKey }
        let prior = Array(days.filter { $0.day < dayKey }.suffix(30))
        let session = sleeps.last {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == dayKey
        }
        let segments = AnalyticsEngine.decodeStages(session?.stagesJSON)
        return NativeSleepPageDetail(
            need: NativeSleepNeed.resolve(
                dayKey: dayKey, days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
            ),
            consistencyNights: NativeSleepConsistency.nights(dayKey: dayKey, sleeps: sleeps),
            efficiency: NativeSleepEfficiency.make(day: metric, prior: prior, segments: segments),
            stress: stress,
            hoursNeededWeek: NativeSleepWeek.neededSeries(
                days: days, todayKey: dayKey, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
            ),
            timeInBedWeek: NativeSleepWeek.timeInBedPoints(todayKey: dayKey, sleeps: sleeps)
        )
    }
}

enum NativeSleepSnapshot {
    static let highlightKey = "2026-11-15"

    static let weekKeys = [
        "2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12",
        "2026-11-13", "2026-11-14", "2026-11-15",
    ]

    static var sleepStart: Date { local(2026, 11, 15, 0, 37) }
    static var sleepEnd: Date { local(2026, 11, 15, 8, 0) }

    static func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    static var stagesJSON: String {
        let start = Int(sleepStart.timeIntervalSince1970)
        let segs = [
            StageSegment(start: start, end: start + 1_800, stage: "wake"),
            StageSegment(start: start + 1_800, end: start + 9_000, stage: "light"),
            StageSegment(start: start + 9_000, end: start + 13_200, stage: "deep"),
            StageSegment(start: start + 13_200, end: start + 13_800, stage: "wake"),
            StageSegment(start: start + 13_800, end: start + 20_400, stage: "rem"),
            StageSegment(start: start + 20_400, end: start + 25_800, stage: "light"),
            StageSegment(start: start + 25_800, end: start + 26_580, stage: "wake"),
        ]
        return AnalyticsEngine.encodeStages(segs) ?? "[]"
    }

    static var snapshotSleeps: [CachedSleepSession] {
        weekKeys.enumerated().compactMap { index, key in
            if key == "2026-11-12" { return nil }
            let day = local(2026, 11, 9 + index, 0, 0)
            let bedHour = index == 6 ? 0 : 23
            let bedMin = index == 6 ? 37 : (10 + index * 4)
            let bedDayOffset = bedHour == 0 ? 0 : -1
            let bed = Calendar.current.date(byAdding: .day, value: bedDayOffset, to: day)
                .flatMap { Calendar.current.date(bySettingHour: bedHour, minute: bedMin, second: 0, of: $0) }
                ?? sleepStart
            let wake = Calendar.current.date(bySettingHour: 7 + (index % 2), minute: index == 6 ? 0 : 12, second: 0, of: day)
                ?? sleepEnd
            return CachedSleepSession(
                startTs: Int(bed.timeIntervalSince1970),
                endTs: Int(wake.timeIntervalSince1970),
                efficiency: 92.5, restingHr: 51, avgHrv: 66,
                stagesJSON: key == highlightKey ? stagesJSON : nil
            )
        }
    }

    static var snapshotDays: [DailyMetric] {
        weekKeys.enumerated().map { index, key in
            if key == "2026-11-12" {
                return DailyMetric(
                    day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                    strain: nil, exerciseCount: nil
                )
            }
            return DailyMetric(
                day: key,
                totalSleepMin: [412, 430, 410, 0, 440, 390, 410][index],
                efficiency: 0.925,
                deepMin: [70, 80, 75, nil, 72, 80, 70][index],
                remMin: [90, 95, 88, nil, 92, 100, 90][index],
                lightMin: [250, 240, 245, nil, 260, 220, 250][index],
                disturbances: 2, restingHr: 51, avgHrv: 66, recovery: 45, strain: 34,
                exerciseCount: 1
            )
        }
    }

    static var snapshotImported: [String: ImportedSleepFigures] {
        Dictionary(uniqueKeysWithValues: weekKeys.filter { $0 != "2026-11-12" }.map { key in
            (key, ImportedSleepFigures(performancePct: key == highlightKey ? 87 : 85,
                                       consistencyPct: key == highlightKey ? 79 : 82,
                                       needMin: 465, debtMin: 36))
        })
    }

    static var bandNeed: NativeSleepNeed.Resolved {
        NativeSleepNeed.Resolved(
            needMin: 480,
            hoursSleptMin: 410,
            percent: 410 / 480 * 100,
            imported: false,
            baselineMin: 420,
            strainMin: 12,
            debtMin: 48
        )
    }

    static var importedNeed: NativeSleepNeed.Resolved {
        NativeSleepNeed.Resolved(
            needMin: 465,
            hoursSleptMin: 410,
            percent: 88.2,
            imported: true,
            baselineMin: nil,
            strainMin: nil,
            debtMin: nil
        )
    }

    static var stages: [NativeStage] {
        [
            NativeStage(name: "Light", minutes: 250, typical: 240, tint: NativeTokens.sleepCore),
            NativeStage(name: "Deep", minutes: 70, typical: 80, tint: NativeTokens.sleepDeep),
            NativeStage(name: "REM", minutes: 90, typical: 95, tint: NativeTokens.sleepREM),
        ]
    }

    static var consistencyNights: [NativeSleepNight] {
        NativeSleepConsistency.nights(dayKey: highlightKey, sleeps: snapshotSleeps)
    }

    static var efficiency: NativeSleepEfficiency.Model {
        NativeSleepEfficiency.make(
            day: snapshotDays.last { $0.day == highlightKey },
            prior: snapshotDays.filter { $0.day < highlightKey },
            segments: AnalyticsEngine.decodeStages(stagesJSON)
        )!
    }

    static var stress: NativeSleepStress.Model {
        let start = Int(sleepStart.timeIntervalSince1970)
        let end = Int(sleepEnd.timeIntervalSince1970)
        var samples: [HRSample] = []
        var ts = start
        while ts < end {
            let minute = Double(ts - start) / 60
            let bpm = 54 + 10 * sin(minute / 40) + (minute > 360 ? 18 : 0)
            samples.append(HRSample(ts: ts, bpm: Int(bpm.rounded())))
            ts += 5
        }
        return NativeSleepStress.make(hr: samples, startTs: start, endTs: end)
            ?? NativeSleepStress.Model(
                points: [
                    NativeHourPoint(time: sleepStart, value: 0.8),
                    NativeHourPoint(time: sleepStart.addingTimeInterval(3 * 3600), value: 1.4),
                    NativeHourPoint(time: sleepStart.addingTimeInterval(6 * 3600), value: 2.2),
                ],
                high: .init(title: "High", minutes: 45, percent: 12),
                medium: .init(title: "Medium", minutes: 120, percent: 31),
                low: .init(title: "Low", minutes: 220, percent: 57),
                highShare: 12
            )
    }

    static var extraWeekCards: [NativeWeek.Card] {
        NativeSleepWeek.cards(
            kind: .sleep,
            base: NativeWeek.cards(
                kind: .sleep, days: snapshotDays, todayKey: highlightKey,
                sleeps: snapshotSleeps, importedSleep: snapshotImported
            ),
            days: snapshotDays,
            todayKey: highlightKey,
            sleeps: snapshotSleeps,
            importedSleep: snapshotImported,
            sleepStressByDay: Dictionary(uniqueKeysWithValues: weekKeys.compactMap { key in
                key == "2026-11-12" ? nil : (key, key == highlightKey ? 12.0 : 8.0)
            })
        )
    }

    static var pageDetail: NativeSleepPageDetail {
        NativeSleepPageDetail(
            need: importedNeed,
            consistencyNights: consistencyNights,
            efficiency: efficiency,
            stress: stress,
            hoursNeededWeek: NativeSleepWeek.neededSeries(
                days: snapshotDays, todayKey: highlightKey, sleeps: snapshotSleeps,
                workouts: [], importedSleep: snapshotImported
            ),
            timeInBedWeek: NativeSleepWeek.timeInBedPoints(todayKey: highlightKey, sleeps: snapshotSleeps)
        )
    }
}

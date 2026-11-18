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
        var baseline = scored.needBaselineMin
        var strain = scored.needStrainMin
        var debt = scored.needDebtMin
        if !imported, baseline == nil, let parts = bandParts(dayKey: dayKey, days: days, sleeps: sleeps,
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

    struct PlotWindow: Equatable {
        var domain: ClosedRange<Double>
        var marks: [Double]
    }

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

    /// Wake is later on the evening axis. A span that crosses the 6 PM wrap gets +24 h on wake.
    static func alignedOvernight(bed: Double, wake: Double) -> (bed: Double, wake: Double) {
        wake < bed ? (bed, wake + 24 * 60) : (bed, wake)
    }

    static func fittedPlot(points: [NativeDayPoint]) -> PlotWindow {
        var beds: [Double] = []
        var wakes: [Double] = []
        beds.reserveCapacity(points.count)
        wakes.reserveCapacity(points.count)
        for point in points {
            guard let bed = point.low, let wake = point.high, bed.isFinite, wake.isFinite else { continue }
            let pair = alignedOvernight(bed: bed, wake: wake)
            beds.append(pair.bed)
            wakes.append(pair.wake)
        }
        return fittedPlot(beds: beds, wakes: wakes)
    }

    /// Earliest bedtime − 1 h … latest wake + 1 h, rounded to the hour, with 3–4 hour labels.
    static func fittedPlot(beds: [Double], wakes: [Double]) -> PlotWindow {
        guard let earliest = beds.filter(\.isFinite).min(),
              let latest = wakes.filter(\.isFinite).max(),
              latest > earliest else {
            return PlotWindow(
                domain: plotY(axisMarks.last!)...plotY(axisMarks.first!),
                marks: axisMarks
            )
        }
        let lo = floor((earliest - 60) / 60) * 60
        let hi = ceil((latest + 60) / 60) * 60
        let top = min(lo, hi - 60)
        let bottom = max(hi, lo + 60)
        // The domain is the fitted window itself. Labels sit inside it; rounding the domain out to
        // the next label stretched an 8-hour night across 16 hours of axis.
        let marks = hourMarks(from: top, to: bottom).filter { $0 >= top - 0.5 && $0 <= bottom + 0.5 }
        return PlotWindow(domain: plotY(bottom)...plotY(top), marks: marks)
    }

    static func hourMarks(from lo: Double, to hi: Double) -> [Double] {
        let loH = floor(lo / 60) * 60
        var hiH = ceil(hi / 60) * 60
        if hiH <= loH { hiH = loH + 60 }
        let hours = (hiH - loH) / 60
        let stepHours: Double
        if hours <= 3 { stepHours = 1 }
        else if hours <= 6 { stepHours = 2 }
        else if hours <= 9 { stepHours = 3 }
        else { stepHours = 4 }
        var marks: [Double] = []
        var t = loH
        while t <= hiH + 0.5 {
            marks.append(t)
            t += stepHours * 60
            if marks.count > 8 { break }
        }
        // Extend by a whole step rather than adding the bare end hour, which put "9 AM" and
        // "10 AM" on top of each other.
        if let last = marks.last, last < hiH - 0.5 { marks.append(last + stepHours * 60) }
        return marks
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
        hourOnly.string(from: date(fromEvening: minutesFromEvening))
    }

    static func clockFromEvening(_ minutesFromEvening: Double) -> String {
        hourMinute.string(from: date(fromEvening: minutesFromEvening))
    }

    static func clock(_ date: Date) -> String {
        hourMinute.string(from: date)
    }

    private static func date(fromEvening minutesFromEvening: Double) -> Date {
        var total = (eveningHour * 60 + Int(minutesFromEvening.rounded())) % (24 * 60)
        if total < 0 { total += 24 * 60 }
        var comps = DateComponents()
        comps.year = 2000
        comps.month = 1
        comps.day = 1
        comps.hour = total / 60
        comps.minute = total % 60
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }
}

enum NativeSleepStageKind: String, Hashable, CaseIterable, Identifiable {
    case awake = "Awake"
    case rem = "REM"
    case light = "Light"
    case deep = "Deep"

    var id: String { rawValue }
    var title: String { rawValue }

    /// WHOOP hypnogram lanes, top to bottom.
    static let hypnogramLanes: [NativeSleepStageKind] = [.awake, .rem, .light, .deep]
    /// Last Night duration rows.
    static let durationOrder: [NativeSleepStageKind] = [.awake, .light, .deep, .rem]

    static func parse(_ name: String) -> NativeSleepStageKind {
        switch name.lowercased() {
        case "wake", "awake": return .awake
        case "rem": return .rem
        case "deep", "sws": return .deep
        default: return .light
        }
    }

    var about: String {
        switch self {
        case .awake: return "Time spent awake during the night."
        case .rem: return "Rapid-eye-movement sleep."
        case .light: return "Lighter sleep between deep and REM."
        case .deep: return "Slow-wave sleep."
        }
    }
}

/// Classifies a sleep row's `stagesJSON`: epoch timeline vs imported minute totals.
enum NativeSleepStagesJSON {
    /// On-device segment array `[{start,end,stage}]` — enough to draw a hypnogram.
    static func hasEpochTimeline(_ json: String?) -> Bool {
        !AnalyticsEngine.decodeStages(json).isEmpty
    }

    /// Imported WHOOP minute dict `{light,deep,rem,awake}` with no epoch timestamps.
    static func isTotalsOnly(_ json: String?) -> Bool {
        !hasEpochTimeline(json) && SleepStageTotals.minutes(fromStagesJSON: json) != nil
    }
}

/// Display-only hypnogram for imported WHOOP nights that store minute totals
/// (`{light,deep,rem,awake}`) and no epoch timeline. Never persisted, never scored.
enum NativeSleepEstimatedHypnogram {
    static let cycleSeconds = 90 * 60
    static let caption = "Estimated timing from stage totals"
    /// WHOOP import example: minute totals, no epochs.
    static let sampleTotalsJSON = "{\"light\":157,\"rem\":113,\"deep\":125,\"awake\":47}"

    struct Budget: Equatable {
        var awake: Int
        var light: Int
        var deep: Int
        var rem: Int
        var total: Int { awake + light + deep + rem }
    }

    /// `[{start,end,stage}]` spans covering `[startTs, endTs)`. Empty when the JSON
    /// is an epoch timeline or has no usable totals.
    static func spansIfTotalsOnly(startTs: Int, endTs: Int, json: String?) -> [NativeSleepStageSpan]? {
        guard NativeSleepStagesJSON.isTotalsOnly(json),
              let totals = SleepStageTotals.minutes(fromStagesJSON: json) else { return nil }
        let spans = spans(startTs: startTs, endTs: endTs, totals: totals)
        return spans.isEmpty ? nil : spans
    }

    static func spans(startTs: Int, endTs: Int, totals: SleepStageTotals.Minutes) -> [NativeSleepStageSpan] {
        let span = endTs - startTs
        guard span > 0, totals.inBed > 0 else { return [] }
        let budget = scaledSeconds(span: span, totals: totals)
        guard budget.total == span else { return [] }
        let pieces = layout(budget: budget, seed: startTs)
        return materialize(pieces, startTs: startTs, endTs: endTs)
    }

    static func scaledSeconds(span: Int, totals: SleepStageTotals.Minutes) -> Budget {
        let raw = [max(0, totals.awake), max(0, totals.light), max(0, totals.deep), max(0, totals.rem)]
        let sumMin = raw.reduce(0, +)
        guard span > 0, sumMin > 0 else {
            return Budget(awake: 0, light: max(span, 0), deep: 0, rem: 0)
        }
        let seconds = raw.map { $0 * Double(span) / sumMin }
        var floors = seconds.map { Int($0.rounded(.down)) }
        var left = span - floors.reduce(0, +)
        let order = seconds.indices.sorted {
            let fa = seconds[$0] - Double(floors[$0])
            let fb = seconds[$1] - Double(floors[$1])
            if fa != fb { return fa > fb }
            return $0 < $1
        }
        var i = 0
        while left > 0 {
            floors[order[i % order.count]] += 1
            left -= 1
            i += 1
        }
        while left < 0 {
            if let idx = floors.indices.reversed().first(where: { floors[$0] > 0 }) {
                floors[idx] -= 1
                left += 1
            } else {
                break
            }
        }
        return Budget(awake: floors[0], light: floors[1], deep: floors[2], rem: floors[3])
    }

    static func seconds(_ spans: [NativeSleepStageSpan], kind: NativeSleepStageKind) -> Int {
        spans.filter { $0.kind == kind }.reduce(0) { $0 + max(0, $1.endTs - $1.startTs) }
    }

    static func overlapSeconds(span: NativeSleepStageSpan, from: Int, to: Int) -> Int {
        max(0, min(span.endTs, to) - max(span.startTs, from))
    }

    // MARK: - Layout

    private struct Piece {
        var kind: NativeSleepStageKind
        var seconds: Int
    }

    private static func layout(budget: Budget, seed: Int) -> [Piece] {
        let n = max(1, Int((Double(budget.total) / Double(cycleSeconds)).rounded()))
        var cycleLen = Array(repeating: budget.total / n, count: n)
        let extra = budget.total % n
        let rot = n == 0 ? 0 : abs(seed) % n
        for i in 0..<extra { cycleLen[(rot + i) % n] += 1 }

        let bouts = awakeBouts(awake: budget.awake, cycles: n, seed: seed)
        var onset = bouts.onset
        var waso = bouts.waso
        var finale = bouts.finale

        var interiors = cycleLen
        interiors[0] -= onset
        if n > 1 {
            for i in 0..<(n - 1) { interiors[i] -= waso[i] }
        }
        interiors[n - 1] -= finale

        for i in 0..<n where interiors[i] < 0 {
            var deficit = -interiors[i]
            interiors[i] = 0
            if i < waso.count {
                let take = min(waso[i], deficit)
                waso[i] -= take
                deficit -= take
            }
            if i == 0 && deficit > 0 {
                let take = min(onset, deficit)
                onset -= take
                deficit -= take
            }
            if i == n - 1 && deficit > 0 {
                let take = min(finale, deficit)
                finale -= take
                deficit -= take
            }
            if deficit > 0 { finale += deficit }
        }

        let interiorTotal = interiors.reduce(0, +)
        var deep = fit(distribute(budget.deep, weights: deepWeights(n)), caps: interiors)
        let remCaps = zip(interiors, deep).map { max(0, $0 - $1) }
        var rem = fit(distribute(budget.rem, weights: remWeights(n)), caps: remCaps)
        var light = zip(zip(interiors, deep), rem).map { max(0, $0.0.0 - $0.0.1 - $0.1) }

        let placed = light.reduce(0, +) + deep.reduce(0, +) + rem.reduce(0, +)
        var leftoverLight = budget.light - light.reduce(0, +)
        var leftoverDeep = budget.deep - deep.reduce(0, +)
        var leftoverRem = budget.rem - rem.reduce(0, +)
        var leftover = interiorTotal - placed
        // Index-addressed so no inout alias of a stage array overlaps the reads of all three
        // (Release enforces exclusivity statically).
        enum PourStage { case deep, rem, light }
        func pour(_ extra: inout Int, into stage: PourStage) {
            guard extra > 0 else { return }
            for i in 0..<n {
                let room = interiors[i] - light[i] - deep[i] - rem[i]
                let take = min(room, extra)
                switch stage {
                case .deep: deep[i] += take
                case .rem: rem[i] += take
                case .light: light[i] += take
                }
                extra -= take
                leftover -= take
                if extra == 0 { break }
            }
        }
        pour(&leftoverDeep, into: .deep)
        pour(&leftoverRem, into: .rem)
        pour(&leftoverLight, into: .light)
        if leftover > 0 { light[n - 1] += leftover }

        var pieces: [Piece] = []
        func add(_ kind: NativeSleepStageKind, _ seconds: Int) {
            guard seconds > 0 else { return }
            if let last = pieces.indices.last, pieces[last].kind == kind {
                pieces[last].seconds += seconds
            } else {
                pieces.append(Piece(kind: kind, seconds: seconds))
            }
        }

        add(.awake, onset)
        for i in 0..<n {
            let early = (Double(i) + 0.5) / Double(n) < 0.5
            for piece in interiorSequence(light: light[i], deep: deep[i], rem: rem[i], early: early) {
                add(piece.kind, piece.seconds)
            }
            if i < n - 1 { add(.awake, waso[i]) }
        }
        add(.awake, finale)
        return pieces
    }

    private static func awakeBouts(awake: Int, cycles: Int, seed: Int) -> (onset: Int, waso: [Int], finale: Int) {
        let boundaries = max(cycles - 1, 0)
        guard awake > 0 else { return (0, Array(repeating: 0, count: boundaries), 0) }
        if cycles == 1 {
            let onset = min(awake, awake * 20 / 100)
            return (onset, [], awake - onset)
        }
        var onset = awake * 20 / 100
        var finale = awake * 30 / 100
        var rest = awake - onset - finale
        if rest < 0 {
            finale = awake - onset
            rest = 0
        }
        var waso = Array(repeating: 0, count: boundaries)
        if rest > 0, boundaries > 0 {
            let base = rest / boundaries
            var extra = rest % boundaries
            let rot = abs(seed) % boundaries
            for i in 0..<boundaries { waso[i] = base }
            var i = 0
            while extra > 0 {
                waso[(rot + i) % boundaries] += 1
                extra -= 1
                i += 1
            }
        }
        return (onset, waso, finale)
    }

    private static func deepWeights(_ n: Int) -> [Double] {
        (0..<n).map { i in
            let t = (Double(i) + 0.5) / Double(n)
            return max(0.02, pow(max(0, 1 - t * 1.35), 1.4))
        }
    }

    private static func remWeights(_ n: Int) -> [Double] {
        (0..<n).map { i in
            let t = (Double(i) + 0.5) / Double(n)
            return max(0.02, pow(max(0, t * 1.35 - 0.2), 1.4))
        }
    }

    private static func distribute(_ total: Int, weights: [Double]) -> [Int] {
        guard !weights.isEmpty else { return [] }
        let w = weights.map { max(0, $0) }
        let sumW = w.reduce(0, +)
        guard total > 0, sumW > 0 else { return Array(repeating: 0, count: w.count) }
        let raw = w.map { Double(total) * $0 / sumW }
        var floors = raw.map { Int($0.rounded(.down)) }
        var left = total - floors.reduce(0, +)
        let order = floors.indices.sorted {
            let fa = raw[$0] - Double(floors[$0])
            let fb = raw[$1] - Double(floors[$1])
            if fa != fb { return fa > fb }
            return $0 < $1
        }
        var i = 0
        while left > 0 {
            floors[order[i % order.count]] += 1
            left -= 1
            i += 1
        }
        return floors
    }

    private static func fit(_ want: [Int], caps: [Int]) -> [Int] {
        var out = want
        var spill = 0
        for i in 0..<out.count {
            let cap = i < caps.count ? max(0, caps[i]) : 0
            if out[i] > cap {
                spill += out[i] - cap
                out[i] = cap
            }
        }
        guard spill > 0 else { return out }
        for i in 0..<out.count {
            let cap = i < caps.count ? max(0, caps[i]) : 0
            let room = cap - out[i]
            let take = min(room, spill)
            out[i] += take
            spill -= take
            if spill == 0 { break }
        }
        return out
    }

    private static func interiorSequence(light: Int, deep: Int, rem: Int, early: Bool) -> [Piece] {
        var out: [Piece] = []
        func add(_ kind: NativeSleepStageKind, _ n: Int) {
            if n > 0 { out.append(Piece(kind: kind, seconds: n)) }
        }
        if early {
            let lead = light * 2 / 5
            add(.light, lead)
            add(.deep, deep)
            add(.light, light - lead)
            add(.rem, rem)
        } else {
            let lead = light / 3
            add(.light, lead)
            add(.deep, deep)
            add(.rem, rem)
            add(.light, light - lead)
        }
        return out
    }

    private static func materialize(_ pieces: [Piece], startTs: Int, endTs: Int) -> [NativeSleepStageSpan] {
        var t = startTs
        var spans: [NativeSleepStageSpan] = []
        for piece in pieces where piece.seconds > 0 {
            let end = min(endTs, t + piece.seconds)
            if end > t {
                spans.append(NativeSleepStageSpan(startTs: t, endTs: end, name: piece.kind.title))
            }
            t = end
            if t >= endTs { break }
        }
        if t < endTs {
            if let last = spans.indices.last {
                spans[last].endTs = endTs
            } else {
                spans.append(NativeSleepStageSpan(startTs: startTs, endTs: endTs, name: "Light"))
            }
        }
        return spans
    }
}

/// Last Night duration rows. Built once; views do not sort in `body`.
enum NativeSleepNightRows {
    static let order = ["Awake", "Light", "Deep", "REM"]

    static func make(
        stages: [NativeStage],
        inBedMinutes: Double?,
        asleepMinutes: Double?,
        awakeTypical: Double?
    ) -> [NativeStage] {
        var rows = stages
        if !rows.contains(where: { $0.name == "Awake" }),
           let inBedMinutes, let asleepMinutes, inBedMinutes > asleepMinutes {
            rows.insert(
                NativeStage(
                    name: "Awake",
                    minutes: inBedMinutes - asleepMinutes,
                    typical: awakeTypical,
                    tint: NativeChrome.sleepAwake
                ),
                at: 0
            )
        } else if let idx = rows.firstIndex(where: { $0.name == "Awake" }),
                  rows[idx].typical == nil, let awakeTypical {
            rows[idx].typical = awakeTypical
        }
        return rows.sorted {
            (order.firstIndex(of: $0.name) ?? 99) < (order.firstIndex(of: $1.name) ?? 99)
        }
    }
}

struct NativeSleepStageDetail: Equatable, Identifiable {
    var id: NativeSleepStageKind { kind }
    var kind: NativeSleepStageKind
    var minutes: Double?
    var percent: Double?
    var typical: Double?
    var trend: [NativeDayPoint]
}

enum NativeSleepHypnogramMath {
    /// Unit interval in `[0, 1]` for a segment on the true night axis.
    static func unitRange(start: Int, end: Int, nightStart: Int, nightEnd: Int) -> (lo: Double, hi: Double)? {
        let span = nightEnd - nightStart
        guard span > 0, end > start else { return nil }
        let lo = Double(start - nightStart) / Double(span)
        let hi = Double(end - nightStart) / Double(span)
        return (min(max(lo, 0), 1), min(max(hi, 0), 1))
    }

    static func xRange(
        start: Int, end: Int, nightStart: Int, nightEnd: Int, width: Double
    ) -> (x: Double, width: Double)? {
        guard width > 0, let unit = unitRange(start: start, end: end, nightStart: nightStart, nightEnd: nightEnd)
        else { return nil }
        let x = unit.lo * width
        let w = max(0, (unit.hi - unit.lo) * width)
        return (x, w)
    }

    static func share(minutes: Double, inBed: Double) -> Double {
        guard inBed > 0, minutes >= 0 else { return 0 }
        return minutes / inBed
    }

    static func barWidth(minutes: Double, inBed: Double, width: Double) -> Double {
        max(0, width * share(minutes: minutes, inBed: inBed))
    }

    static func timestamp(x: Double, width: Double, nightStart: Int, nightEnd: Int) -> Int {
        guard width > 0 else { return nightStart }
        let t = min(max(x / width, 0), 1)
        return nightStart + Int((Double(nightEnd - nightStart) * t).rounded())
    }

    static func span(at ts: Int, spans: [NativeSleepStageSpan]) -> NativeSleepStageSpan? {
        spans.first { ts >= $0.startTs && ts < $0.endTs }
            ?? spans.last { ts >= $0.startTs && ts <= $0.endTs }
    }

    /// Full opacity for the selected (or highlighted) segment; others dim while a selection is active.
    /// Activity-page zone toggle: tap again to clear.
    static func toggleHighlight(
        _ current: NativeSleepStageKind?,
        tapped: NativeSleepStageKind
    ) -> NativeSleepStageKind? {
        current == tapped ? nil : tapped
    }

    static func spanOpacity(
        span: NativeSleepStageSpan,
        selected: NativeSleepStageSpan?,
        highlight: NativeSleepStageKind?
    ) -> Double {
        if let selected {
            return span.startTs == selected.startTs && span.endTs == selected.endTs ? 1 : 0.18
        }
        if let highlight {
            return span.kind == highlight ? 1 : 0.18
        }
        return 1
    }

    static func axisTimes(start: Date, end: Date, count: Int = 4) -> [Date] {
        let span = end.timeIntervalSince(start)
        guard span > 0, count > 1 else { return [start] }
        return (0..<count).map { index in
            start.addingTimeInterval(span * Double(index) / Double(count - 1))
        }
    }
}

/// Pixel-independent hypnogram geometry. Built once per night; the plot only multiplies by width.
struct NativeSleepHypnogramLayout: Equatable {
    struct SpanDraw: Identifiable, Equatable {
        var id: Int
        var kind: NativeSleepStageKind
        var unitLo: Double
        var unitHi: Double
        var lane: Int
        /// Top of the stage bar as a fraction of plot height (`(lane + 0.22) / 4`).
        var unitY: Double
        /// Bar height as a fraction of plot height (`0.55 / 4`), before the 6 pt floor.
        var unitH: Double
        var startTs: Int
        var endTs: Int
    }

    var startTs: Int
    var endTs: Int
    var spans: [SpanDraw]
    var sourceSpans: [NativeSleepStageSpan]
    var axisTimes: [Date]
    var axisLabels: [String]
    var nightStartLabel: String
    var nightEndLabel: String

    static func make(
        spans: [NativeSleepStageSpan],
        nightStart: Date,
        nightEnd: Date
    ) -> NativeSleepHypnogramLayout {
        let startTs = Int(nightStart.timeIntervalSince1970)
        let endTs = Int(nightEnd.timeIntervalSince1970)
        let draws: [SpanDraw] = spans.compactMap { span in
            guard let unit = NativeSleepHypnogramMath.unitRange(
                start: span.startTs, end: span.endTs, nightStart: startTs, nightEnd: endTs
            ) else { return nil }
            let lane = NativeSleepStageKind.hypnogramLanes.firstIndex(of: span.kind) ?? 2
            return SpanDraw(
                id: span.startTs,
                kind: span.kind,
                unitLo: unit.lo,
                unitHi: unit.hi,
                lane: lane,
                unitY: (Double(lane) + 0.22) / 4,
                unitH: 0.55 / 4,
                startTs: span.startTs,
                endTs: span.endTs
            )
        }
        let axisTimes = NativeSleepHypnogramMath.axisTimes(start: nightStart, end: nightEnd)
        return NativeSleepHypnogramLayout(
            startTs: startTs,
            endTs: endTs,
            spans: draws,
            sourceSpans: spans,
            axisTimes: axisTimes,
            axisLabels: axisTimes.map(NativeSleepClock.clock),
            nightStartLabel: NativeSleepClock.clock(nightStart),
            nightEndLabel: NativeSleepClock.clock(nightEnd)
        )
    }

    static func barRect(span: SpanDraw, plotWidth: CGFloat, plotHeight: CGFloat) -> CGRect {
        CGRect(
            x: 48 + CGFloat(span.unitLo) * plotWidth,
            y: CGFloat(span.unitY) * plotHeight,
            width: max(CGFloat(span.unitHi - span.unitLo) * plotWidth, 1),
            height: max(CGFloat(span.unitH) * plotHeight, 6)
        )
    }
}

/// Poor / Sufficient / Optimal cut-offs for sleep percents.
/// WHOOP published Sleep Performance: ≥85 optimal, 70–84 sufficient, <70 poor.
/// Hours vs. Needed, Consistency, and Efficiency use the same published bands.
/// High Sleep Stress is a 0…3 stress scale, not this percent ladder.
enum NativeSleepBands {
    static let poorBelow: Double = 70
    static let optimalAt: Double = 85

    enum Band: String, Equatable {
        case poor, sufficient, optimal
    }

    static func band(_ percent: Double) -> Band {
        if percent < poorBelow { return .poor }
        if percent < optimalAt { return .sufficient }
        return .optimal
    }
}

enum NativeSleepConsistency {
    /// Chart window: last 7 nights (bed and wake), with gaps for missing nights.
    /// Score uses BandConsistency's 5-night last-vs-each window (today vs the prior 4, recency 0.7).
    static let chartNights = 7
    static let scoreNights = 5

    static func chartKeys(dayKey: String) -> [String] {
        NativeWeek.lastSevenKeys(ending: dayKey)
    }

    static func nights(
        dayKey: String,
        sleeps: [CachedSleepSession],
        limit: Int = chartNights
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
    var kind: NativeSleepStageKind { NativeSleepStageKind.parse(name) }
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

    static func spans(from parsed: [ParsedSleepStage]) -> [NativeSleepStageSpan] {
        parsed.filter { $0.end > $0.start }.map {
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

    /// With `baselines`, levels are `BandStress` (the same scale as the Stress Monitor and the
    /// High Sleep Stress row). Without, the legacy night-relative squash.
    static func make(hr: [HRSample], startTs: Int, endTs: Int,
                     baselines: BandStress.Baselines? = nil) -> Model? {
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
            let level: Double
            if let baselines {
                level = BandStress.score(bpm: mean, isAsleep: true, baselines: baselines)
            } else {
                let raw = sd > 0.0001 ? (mean - ref) / sd : 0
                level = min(max(3.0 / (1.0 + exp(-raw)), 0), 3)
            }
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
                    // REM at the bottom, Deep on top — WHOOP IMG_9434.
                    NativeWeek.Card.Stack(title: "REM", points: rem, tint: NativeChrome.sleepREM),
                    NativeWeek.Card.Stack(title: "Deep", points: deep, tint: NativeChrome.sleepDeep),
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
            maxY: 100, bars: true, tint: NativeChrome.sleep, route: .metric("sleep_performance"),
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

/// Hours vs. Needed week chart. Built in the Sleep page loader, not in `body`.
struct NativeSleepDualLineModel: Equatable {
    var slept: [NativeDayPoint]
    var needed: [NativeDayPoint]
    var sleptLine: [NativeChartDay.LinePoint]
    var neededLine: [NativeChartDay.LinePoint]
    var axisTicks: [Double]
    var yDomain: ClosedRange<Double>
    var typicalClipped: ClosedRange<Double>?
    var averageSlept: Double?
    var rangeLabel: String?

    static func make(
        slept: [NativeDayPoint],
        needed: [NativeDayPoint],
        typical: ClosedRange<Double>?
    ) -> NativeSleepDualLineModel {
        let knownSlept = slept.filter { $0.value.isFinite }
        let knownNeeded = needed.filter { $0.value.isFinite }
        let typicalBounds = typical.map { [$0.lowerBound, $0.upperBound] } ?? []
        let values = (knownSlept + knownNeeded).map(\.value) + typicalBounds
        let axisTicks = NativeChartTicks.nice(
            min: values.min() ?? 0, max: values.max() ?? 480, targetCount: 4
        )
        let yDomain = NativeChartTicks.domain(from: axisTicks, fallback: 0...480)
        let typicalClipped: ClosedRange<Double>? = typical.flatMap { range in
            let lo = max(range.lowerBound, yDomain.lowerBound)
            let hi = min(range.upperBound, yDomain.upperBound)
            return hi > lo ? lo...hi : nil
        }
        let sleptLine = NativeChartDay.linePoints(slept).filter {
            $0.value >= yDomain.lowerBound && $0.value <= yDomain.upperBound
        }
        let neededLine = NativeChartDay.linePoints(needed).filter {
            $0.value >= yDomain.lowerBound && $0.value <= yDomain.upperBound
        }
        let rangeLabel: String? = {
            guard let first = slept.first?.key, let last = slept.last?.key else { return nil }
            return NativeChartDay.rangeLabel(from: first, to: last)
        }()
        return NativeSleepDualLineModel(
            slept: slept,
            needed: needed,
            sleptLine: sleptLine,
            neededLine: neededLine,
            axisTicks: axisTicks,
            yDomain: yDomain,
            typicalClipped: typicalClipped,
            averageSlept: NativeScoreMath.mean(knownSlept.map(\.value)),
            rangeLabel: rangeLabel
        )
    }
}

/// Time in Bed week chart. Built in the Sleep page loader, not in `body`.
struct NativeSleepTimeInBedPlotModel: Equatable {
    var points: [NativeDayPoint]
    var window: NativeSleepClock.PlotWindow
    var average: Double?
    var rangeLabel: String?

    static func make(points: [NativeDayPoint]) -> NativeSleepTimeInBedPlotModel {
        let known = points.filter { $0.value.isFinite || ($0.low != nil && $0.high != nil) }
        let rangeLabel: String? = {
            guard let first = points.first?.key, let last = points.last?.key else { return nil }
            return NativeChartDay.rangeLabel(from: first, to: last)
        }()
        return NativeSleepTimeInBedPlotModel(
            points: points,
            window: NativeSleepClock.fittedPlot(points: points),
            average: NativeScoreMath.mean(known.compactMap { $0.value.isFinite ? $0.value : nil }),
            rangeLabel: rangeLabel
        )
    }
}

/// Restorative Sleep week chart. Built in the Sleep page loader, not in `body`.
struct NativeSleepRestorativePlotModel: Equatable {
    struct Slice: Equatable, Identifiable {
        var key: String
        var value: Double
        var series: String
        var id: String { series + key }
    }

    var deep: [NativeDayPoint]
    var rem: [NativeDayPoint]
    var totals: [NativeDayPoint]
    var slices: [Slice]
    var keys: [String]
    var axisTicks: [Double]
    var ceiling: Double
    var average: Double?
    var rangeLabel: String?

    static func stackOrder() -> [String] { ["REM", "Deep"] }

    static func make(deep: [NativeDayPoint], rem: [NativeDayPoint]) -> NativeSleepRestorativePlotModel {
        let totals = NativeWeek.sumSeries(deep, rem)
        let known = totals.filter { $0.value.isFinite }
        var seen = Set<String>()
        let keys = (rem + deep).map(\.key).filter { seen.insert($0).inserted }
        let slices = stackOrder().flatMap { series -> [Slice] in
            let points = series == "REM" ? rem : deep
            return points.compactMap { point -> Slice? in
                guard point.value.isFinite, point.value > 0 else { return nil }
                return Slice(key: point.key, value: point.value, series: series)
            }
        }
        let hi = max(known.map(\.value).max() ?? 0, 120)
        let axisTicks = NativeChartTicks.nice(min: 0, max: hi, targetCount: 4)
        let rangeLabel: String? = {
            guard let first = totals.first?.key, let last = totals.last?.key else { return nil }
            return NativeChartDay.rangeLabel(from: first, to: last)
        }()
        return NativeSleepRestorativePlotModel(
            deep: deep,
            rem: rem,
            totals: totals,
            slices: slices,
            keys: keys,
            axisTicks: axisTicks,
            ceiling: max(axisTicks.last ?? 120, 1),
            average: NativeScoreMath.mean(known.map(\.value)),
            rangeLabel: rangeLabel
        )
    }
}

/// Overnight sleep-stress polyline. Built in the Sleep page loader, not in `body`.
struct NativeSleepStressPlotModel: Equatable {
    var points: [NativeHourPoint]
    var domainPoints: [NativeHourPoint]
    var xDomain: ClosedRange<Date>?
    var hourLabels: [Date]
    var hourLabelText: [TimeInterval: String]
    var pointTimeText: [TimeInterval: String]
    var maxGap: TimeInterval?
    var average: Double

    static func make(points: [NativeHourPoint], calendar: Calendar = .current) -> NativeSleepStressPlotModel {
        let xDomain: ClosedRange<Date>? = {
            guard let first = points.map(\.time).min(), let last = points.map(\.time).max(), last > first else {
                return nil
            }
            return first...last
        }()
        let domainPoints: [NativeHourPoint] = {
            guard let xDomain else { return points.filter { $0.value >= 0 && $0.value <= 3 } }
            return points.filter {
                $0.time >= xDomain.lowerBound && $0.time <= xDomain.upperBound
                    && $0.value >= 0 && $0.value <= 3
            }
        }()
        let hourLabels = xDomain.map {
            NativeChartTicks.hourDates(from: $0.lowerBound, to: $0.upperBound, calendar: calendar)
        } ?? []
        var hourLabelText: [TimeInterval: String] = [:]
        hourLabelText.reserveCapacity(hourLabels.count)
        for date in hourLabels {
            hourLabelText[date.timeIntervalSince1970] = NativeScopeFormat.hourClock(date, calendar: calendar)
        }
        var pointTimeText: [TimeInterval: String] = [:]
        pointTimeText.reserveCapacity(domainPoints.count)
        for point in domainPoints {
            pointTimeText[point.time.timeIntervalSince1970] = NativeScopeFormat.time(point.time, calendar: calendar)
        }
        return NativeSleepStressPlotModel(
            points: points,
            domainPoints: domainPoints,
            xDomain: xDomain,
            hourLabels: hourLabels,
            hourLabelText: hourLabelText,
            pointTimeText: pointTimeText,
            maxGap: NativeChartScrubMath.inferredMaxGap(in: points),
            average: NativeScoreMath.mean(points.map(\.value)) ?? 0
        )
    }
}

struct NativeSleepPageDetail {
    var need: NativeSleepNeed.Resolved?
    var consistencyNights: [NativeSleepNight]
    var efficiency: NativeSleepEfficiency.Model?
    var stress: NativeSleepStress.Model?
    var hoursNeededWeek: [NativeDayPoint]
    var timeInBedWeek: [NativeDayPoint]
    var hypnogram: [NativeSleepStageSpan]
    var hoursTypical: ClosedRange<Double>?
    var stageDetails: [NativeSleepStageDetail]
    /// True when the hypnogram was synthesized from minute totals. Display only.
    var hypnogramEstimated: Bool = false
    var hypnogramLayout: NativeSleepHypnogramLayout? = nil
    var dualLine: NativeSleepDualLineModel? = nil
    var timeInBedPlot: NativeSleepTimeInBedPlotModel? = nil
    var restorativePlot: NativeSleepRestorativePlotModel? = nil
    var stressPlot: NativeSleepStressPlotModel? = nil
    var hasHypnogram: Bool { !hypnogram.isEmpty }

    static func make(
        dayKey: String,
        days: [DailyMetric],
        sleeps: [CachedSleepSession],
        workouts: [WorkoutRow],
        importedSleep: [String: ImportedSleepFigures],
        stress: NativeSleepStress.Model? = nil,
        parsedStages: [ParsedSleepStage] = []
    ) -> NativeSleepPageDetail {
        let metric = days.last { $0.day == dayKey }
        let prior = Array(days.filter { $0.day < dayKey }.suffix(30))
        let session = sleeps.last {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == dayKey
        }
        // Prefer the Repository per-row cache. Re-decoding stagesJSON here used to run on every
        // Sleep-page body rebuild (400 nights × JSONSerialization).
        let segments: [StageSegment]
        if parsedStages.isEmpty {
            segments = AnalyticsEngine.decodeStages(session?.stagesJSON)
        } else {
            segments = parsedStages.map { StageSegment(start: $0.start, end: $0.end, stage: $0.stage) }
        }
        let epoch = parsedStages.isEmpty
            ? NativeSleepEfficiency.spans(from: segments)
            : NativeSleepEfficiency.spans(from: parsedStages)
        let estimated = epoch.isEmpty
            ? NativeSleepEstimatedHypnogram.spansIfTotalsOnly(
                startTs: session?.effectiveStartTs ?? 0,
                endTs: session?.endTs ?? 0,
                json: session?.stagesJSON
            )
            : nil
        let hypnogram = epoch.isEmpty ? (estimated ?? []) : epoch
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
            timeInBedWeek: NativeSleepWeek.timeInBedPoints(todayKey: dayKey, sleeps: sleeps),
            hypnogram: hypnogram,
            hoursTypical: hoursTypicalRange(days: days, dayKey: dayKey),
            stageDetails: stageDetails(dayKey: dayKey, days: days, sleeps: sleeps),
            hypnogramEstimated: epoch.isEmpty && estimated != nil
        )
    }

    static func hoursTypicalRange(days: [DailyMetric], dayKey: String) -> ClosedRange<Double>? {
        let prior = days.filter { $0.day < dayKey }.suffix(30)
        let hours = prior.compactMap {
            NativeDayLogic.asleepMinutes(
                light: $0.lightMin, deep: $0.deepMin, rem: $0.remMin, totalSleepMin: $0.totalSleepMin
            )
        }
        guard hours.count >= 7, let lo = hours.min(), let hi = hours.max(), hi > lo else { return nil }
        return lo...hi
    }

    static func stageDetails(
        dayKey: String,
        days: [DailyMetric],
        sleeps: [CachedSleepSession]
    ) -> [NativeSleepStageDetail] {
        let metric = days.last { $0.day == dayKey }
        let prior = Array(days.filter { $0.day < dayKey }.suffix(30))
        let inBed = inBedMinutes(dayKey: dayKey, sleeps: sleeps)
        let asleep = NativeDayLogic.asleepMinutes(
            light: metric?.lightMin, deep: metric?.deepMin, rem: metric?.remMin,
            totalSleepMin: metric?.totalSleepMin
        )
        let scale = inBed ?? ((asleep ?? 0) + (awakeMinutes(day: metric) ?? 0))
        return NativeSleepStageKind.durationOrder.compactMap { kind in
            let minutes = stageMinutes(kind, day: metric, inBed: inBed, asleep: asleep)
            let typical = NativeScoreMath.mean(prior.compactMap { stageMinutes(kind, day: $0, inBed: nil, asleep: nil) })
            guard (minutes ?? 0) > 0 || (typical ?? 0) > 0 else { return nil }
            let percent: Double? = {
                guard let minutes, scale > 0 else { return nil }
                return NativeSleepHypnogramMath.share(minutes: minutes, inBed: scale) * 100
            }()
            return NativeSleepStageDetail(
                kind: kind,
                minutes: minutes,
                percent: percent,
                typical: typical,
                trend: NativeWeek.series(days, todayKey: dayKey) {
                    stageMinutes(kind, day: $0, inBed: nil, asleep: nil)
                }
            )
        }
    }

    static func inBedMinutes(dayKey: String, sleeps: [CachedSleepSession]) -> Double? {
        let session = sleeps
            .filter {
                NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == dayKey
            }
            .sorted { ($0.endTs - $0.effectiveStartTs) > ($1.endTs - $1.effectiveStartTs) }
            .first
        guard let session, session.endTs > session.effectiveStartTs else { return nil }
        return Double(session.endTs - session.effectiveStartTs) / 60
    }

    static func awakeMinutes(day: DailyMetric?) -> Double? {
        let asleep = NativeDayLogic.asleepMinutes(
            light: day?.lightMin, deep: day?.deepMin, rem: day?.remMin, totalSleepMin: day?.totalSleepMin
        )
        guard let asleep, let raw = day?.efficiency, asleep > 0, raw > 0 else { return nil }
        let eff = raw <= 1 ? raw : raw / 100
        guard eff > 0, eff < 1 else { return nil }
        let awake = asleep / eff - asleep
        return awake > 0 ? awake : nil
    }

    static func stageMinutes(
        _ kind: NativeSleepStageKind,
        day: DailyMetric?,
        inBed: Double?,
        asleep: Double?
    ) -> Double? {
        switch kind {
        case .light: return day?.lightMin.flatMap { $0 > 0 ? $0 : nil }
        case .deep: return day?.deepMin.flatMap { $0 > 0 ? $0 : nil }
        case .rem: return day?.remMin.flatMap { $0 > 0 ? $0 : nil }
        case .awake:
            if let inBed, let asleep, inBed > asleep { return inBed - asleep }
            return awakeMinutes(day: day)
        }
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
        // 443 min in bed matching 00:37–08:00. Minutes: Light 250, Deep 70, REM 90, Awake 33.
        let minutes: [(Int, Int, String)] = [
            (0, 12, "wake"),
            (12, 52, "light"),
            (52, 92, "deep"),
            (92, 122, "light"),
            (122, 152, "rem"),
            (152, 192, "light"),
            (192, 222, "deep"),
            (222, 262, "light"),
            (262, 307, "rem"),
            (307, 357, "light"),
            (357, 365, "wake"),
            (365, 415, "light"),
            (415, 430, "rem"),
            (430, 443, "wake"),
        ]
        let segs = minutes.map { lo, hi, stage in
            StageSegment(start: start + lo * 60, end: start + hi * 60, stage: stage)
        }
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
            NativeStage(name: "Awake", minutes: 33, typical: 45, tint: NativeChrome.sleepAwake),
            NativeStage(name: "Light", minutes: 250, typical: 240, tint: NativeChrome.sleepLight),
            NativeStage(name: "Deep", minutes: 70, typical: 80, tint: NativeChrome.sleepDeep),
            NativeStage(name: "REM", minutes: 90, typical: 95, tint: NativeChrome.sleepREM),
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

    static var hypnogram: [NativeSleepStageSpan] {
        NativeSleepEfficiency.spans(from: AnalyticsEngine.decodeStages(stagesJSON))
    }

    static var stageDetails: [NativeSleepStageDetail] {
        NativeSleepPageDetail.stageDetails(
            dayKey: highlightKey, days: snapshotDays, sleeps: snapshotSleeps
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
            timeInBedWeek: NativeSleepWeek.timeInBedPoints(todayKey: highlightKey, sleeps: snapshotSleeps),
            hypnogram: hypnogram,
            hoursTypical: NativeSleepPageDetail.hoursTypicalRange(days: snapshotDays, dayKey: highlightKey),
            stageDetails: stageDetails,
            hypnogramEstimated: false
        )
    }
}

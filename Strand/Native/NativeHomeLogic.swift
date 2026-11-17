import Foundation
import SwiftUI
import WhoopStore

/// Fixed leading-pill geometry for Home activity rows so sleep and workouts share one grid.
enum HomeActivityLayout {
    static let pillWidth: CGFloat = 92
    static let iconWidth: CGFloat = 22
    static let paddingH: CGFloat = 10
    static let paddingV: CGFloat = 8
    static let dashboardIconWidth: CGFloat = 22
    static let dashboardValueMinWidth: CGFloat = 52
}

/// Collapse overlapping stored workouts for Home. Preference: manual, then strap-detected, then imported.
/// Does not write the store.
enum HomeActivityDedupe {
    /// Walk once; when two rows overlap by more than half of the shorter span, keep the preferred one.
    static func collapse(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        var kept: [WorkoutRow] = []
        kept.reserveCapacity(rows.count)
        for row in rows {
            if let index = kept.firstIndex(where: { overlapsMoreThanHalf($0, row) }) {
                kept[index] = preferred(kept[index], row)
            } else {
                kept.append(row)
            }
        }
        return kept
    }

    static func overlapsMoreThanHalf(_ a: WorkoutRow, _ b: WorkoutRow) -> Bool {
        let overlap = min(a.endTs, b.endTs) - max(a.startTs, b.startTs)
        guard overlap > 0 else { return false }
        let shorter = max(1, min(span(a), span(b)))
        return Double(overlap) > 0.5 * Double(shorter)
    }

    static func preferred(_ a: WorkoutRow, _ b: WorkoutRow) -> WorkoutRow {
        let pa = priority(a)
        let pb = priority(b)
        if pa != pb { return pa < pb ? a : b }
        let da = span(a)
        let db = span(b)
        if da != db { return da > db ? a : b }
        return a.startTs <= b.startTs ? a : b
    }

    /// 0 manual, 1 strap-detected, 2 imported (WHOOP export, Apple, files, lifting).
    static func priority(_ row: WorkoutRow) -> Int {
        switch WorkoutSource.classify(row.source) {
        case .manual: return 0
        case .detected: return 1
        case .whoop, .apple, .lifting, .activityFile: return 2
        }
    }

    static func span(_ row: WorkoutRow) -> Int {
        if let seconds = row.durationS { return max(1, Int(seconds.rounded())) }
        return max(1, row.endTs - row.startTs)
    }
}

/// Consecutive nights with recorded sleep (strap session or WHOOP import).
/// Count ends at `todayKey`. When that key is the live day and tonight is not recorded yet,
/// yesterday still counts so a live streak does not read 0 all day.
enum HomeSleepStreak {
    static func days(
        sleeps: [CachedSleepSession],
        imported: [String: ImportedSleepFigures],
        todayKey: String,
        calendar: Calendar = .current,
        viewingToday: Bool = true
    ) -> Int {
        let keys = recordedDays(sleeps: sleeps, imported: imported)
        guard !keys.isEmpty else { return 0 }
        let formatter = dayFormatter
        guard let today = formatter.date(from: todayKey) else { return 0 }
        func key(_ date: Date) -> String { formatter.string(from: calendar.startOfDay(for: date)) }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let start: Date
        if keys.contains(todayKey) {
            start = today
        } else if viewingToday, keys.contains(key(yesterday)) {
            start = yesterday
        } else {
            return 0
        }
        var count = 0
        var cursor = start
        while keys.contains(key(cursor)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    static func recordedDays(
        sleeps: [CachedSleepSession],
        imported: [String: ImportedSleepFigures]
    ) -> Set<String> {
        var keys = Set<String>()
        for session in sleeps {
            keys.insert(
                NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval(session.endTs)))
            )
        }
        for day in imported.keys {
            keys.insert(day)
        }
        return keys
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Metrics the Home "My Dashboard" editor can offer. Ids are the persisted JSON strings.
enum HomeDashboardMetric: String, CaseIterable, Identifiable {
    case hrv = "hrv"
    case restingHr = "resting_hr"
    case respiratory = "respiratory"
    case spo2 = "spo2"
    case skinTemp = "skin_temp"
    case steps = "steps"
    case calories = "calories"
    case sleepPerformance = "sleep_performance"
    case sleepHours = "sleep_hours"
    case sleepNeed = "sleep_need"
    case sleepDebt = "sleep_debt"
    case vo2max = "vo2max"
    case hrZones13 = "hr_zones_13"
    case hrZones45 = "hr_zones_45"
    case strength = "strength"
    case stress = "stress"

    var id: String { rawValue }

    /// Empty dashboard readout. Rows stay on screen and stay tappable.
    static let emptyValue = "—"

    /// WHOOP My Dashboard pins (9418/9419), plus respiratory which Band tracks.
    static let defaultIds = [
        "hrv", "resting_hr", "respiratory", "steps",
        "hr_zones_13", "hr_zones_45", "strength", "vo2max", "calories",
    ]

    static let healthMonitorIds: Set<String> = ["hrv", "resting_hr", "respiratory"]

    var title: String {
        switch self {
        case .hrv: return "Heart Rate Variability"
        case .restingHr: return "Resting Heart Rate"
        case .respiratory: return "Respiratory Rate"
        case .spo2: return "Blood Oxygen"
        case .skinTemp: return "Skin Temperature"
        case .steps: return "Steps"
        case .calories: return "Calories"
        case .sleepPerformance: return "Sleep Performance"
        case .sleepHours: return "Sleep"
        case .sleepNeed: return "Sleep Need"
        case .sleepDebt: return "Sleep Debt"
        case .vo2max: return "VO₂ Max"
        case .hrZones13: return "Heart Rate Zones 1–3"
        case .hrZones45: return "Heart Rate Zones 4–5"
        case .strength: return "Strength Activity Time"
        case .stress: return "Stress"
        }
    }

    var symbol: String {
        switch self {
        case .hrv: return "waveform.path.ecg"
        case .restingHr: return "heart.fill"
        case .respiratory: return "lungs.fill"
        case .spo2: return "drop.fill"
        case .skinTemp: return "thermometer.medium"
        case .steps: return "figure.walk"
        case .calories: return "flame.fill"
        case .sleepPerformance, .sleepHours, .sleepNeed, .sleepDebt: return "moon.fill"
        case .vo2max: return "lungs.fill"
        case .hrZones13: return "heart"
        case .hrZones45: return "heart.fill"
        case .strength: return "dumbbell.fill"
        case .stress: return "chart.xyaxis.line"
        }
    }

    var tint: Color {
        switch self {
        case .hrv, .restingHr, .hrZones13, .hrZones45: return NativeChrome.heart
        case .respiratory, .vo2max: return NativeChrome.respiratory
        case .spo2: return NativeChrome.heart
        case .skinTemp: return NativeChrome.heart
        case .steps, .calories: return NativeChrome.activity
        case .sleepPerformance, .sleepHours, .sleepNeed, .sleepDebt: return NativeChrome.sleep
        case .strength: return NativeChrome.strain
        case .stress: return NativeChrome.stress
        }
    }

    var route: TabRoute {
        switch self {
        case .hrv: return .metric("hrv")
        case .restingHr: return .metric("resting_hr")
        case .respiratory: return .metric("resp_rate")
        case .spo2: return .metric("spo2")
        case .skinTemp: return .metric("skin_temp")
        case .steps: return .metric("steps")
        case .calories: return .metric("energy_kcal")
        case .sleepPerformance, .sleepHours, .sleepNeed, .sleepDebt: return .sleep
        case .vo2max: return .metric("vo2max")
        case .hrZones13: return .metric("hr_zones13_min")
        case .hrZones45: return .metric("hr_zones45_min")
        case .strength: return .metric("strength_min")
        case .stress: return .stress
        }
    }

    var unit: String? {
        switch self {
        case .hrv: return "ms"
        case .restingHr: return "BPM"
        case .respiratory: return "breaths/min"
        case .steps: return "steps"
        case .calories: return "cal"
        case .vo2max: return "ml/kg·min"
        default: return nil
        }
    }
}

/// One day's steps. Home, the metric page, and `Repository.days` all go through
/// `Repository.resolvedSteps` / `mergeAppleSteps` so two readouts cannot disagree.
enum NativeResolvedSteps {
    /// Prefer Apple Health's hourly series when that day Apple is the larger source.
    static func preferAppleHours(appleSum: Int, appleDaily: Int?, mergedDaily: Int?) -> Bool {
        let apple = max(appleSum, appleDaily ?? 0)
        guard apple > 0 else { return false }
        let merged = mergedDaily ?? 0
        return merged <= apple
    }

    /// 24 hourly slots for a local day. Missing hours are 0 so the day chart is never empty.
    static func hourPoints(
        appleHours: [(ts: Int, steps: Int)],
        dayStart: Date,
        calendar: Calendar,
        preferApple: Bool
    ) -> [NativeHourPoint] {
        let start = calendar.startOfDay(for: dayStart)
        var byHour: [Int: Int] = [:]
        if preferApple {
            for row in appleHours where row.steps > 0 {
                let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(row.ts)))
                byHour[hour, default: 0] += row.steps
            }
        }
        return (0..<24).map { hour in
            let time = calendar.date(byAdding: .hour, value: hour, to: start) ?? start
            return NativeHourPoint(time: time, value: Double(byHour[hour] ?? 0))
        }
    }
}

/// Measured VO₂ max from Apple Health. Never a RHR/age formula estimate.
enum NativeVo2Max {
    static let sourceLabel = "From Apple Health"

    struct Reading: Equatable {
        var day: String
        var value: Double
    }

    static func latest(_ rows: [AppleDaily]) -> Reading? {
        Repository.latestAppleVo2Max(rows).map { Reading(day: $0.day, value: $0.value) }
    }

    static func points(_ rows: [AppleDaily]) -> [NativeDayPoint] {
        rows.compactMap { row in
            guard let value = row.vo2max, value > 0 else { return nil }
            return NativeDayPoint(key: row.day, value: value)
        }
    }
}

/// One JSON string in UserDefaults: the enabled metric ids in display order.
enum HomeDashboardStore {
    static let key = "native.home.dashboard.ids"

    static func load(_ defaults: UserDefaults = .standard) -> [String] {
        decode(defaults.string(forKey: key))
    }

    static func decode(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return HomeDashboardMetric.defaultIds }
        let known = Set(HomeDashboardMetric.allCases.map(\.rawValue))
        let filtered = ids.filter { known.contains($0) }
        return filtered.isEmpty ? HomeDashboardMetric.defaultIds : filtered
    }

    static func encode(_ ids: [String]) -> String {
        let data = (try? JSONEncoder().encode(ids)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func save(_ ids: [String], to defaults: UserDefaults = .standard) {
        defaults.set(encode(ids), forKey: key)
    }
}

/// Copy for the compact Home Stress Monitor tile. Level and time match the chart card.
enum HomeMonitorTile {
    struct Stress: Equatable {
        var value: String?
        var band: String?
        var time: String?

        var accessibility: String {
            if let value, let band {
                var parts = ["Stress \(value)", band]
                if let time { parts.append(time) }
                return parts.joined(separator: ", ")
            }
            return "No Data"
        }
    }

    static func stress(level: Double?, at time: Date?) -> Stress {
        let clock = time.map { NativeScopeFormat.time($0) }
        guard let level else { return Stress(value: nil, band: nil, time: clock) }
        return Stress(
            value: String(format: "%.1f", level),
            band: NativeHomeCharts.stressBandWord(level),
            time: clock
        )
    }

    /// Home Health Monitor primary line. Green path is "Within Range"; any out-of-range count is "N Outside Range".
    static func healthPrimary(_ summary: NativeHealthRange.Summary) -> String {
        guard summary.measured > 0 else { return "No Data" }
        if summary.judged == 0 { return "Building baseline" }
        if summary.outside == 0 { return "Within Range" }
        return "\(summary.outside) Outside Range"
    }
}

/// Strap battery glyph/percentage colour. Charging is its own level so the bolt stays green.
enum HomeBatteryTint {
    enum Level: Equatable {
        case low
        case mid
        case high
        case charging
    }

    /// Red at ≤20%, amber 21–49%, green ≥50%. Charging wins at any percent.
    static func level(percent: Int, charging: Bool) -> Level {
        if charging { return .charging }
        if percent <= 20 { return .low }
        if percent < 50 { return .mid }
        return .high
    }
}

/// Month grid for the Home day picker. Pure; the sheet never folds this in `body`.
enum HomeCalendarMath {
    static let columns = 7
    static let rows = 6
    static var cellsPerMonth: Int { columns * rows }

    static func monthStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        guard first >= 0, first < symbols.count else { return symbols }
        return Array(symbols[first...] + symbols[..<first])
    }

    /// 42 slots. `nil` is a leading or trailing blank, never a day of another month.
    static func cells(month: Date, calendar: Calendar) -> [Date?] {
        let start = monthStart(month, calendar: calendar)
        let weekday = calendar.component(.weekday, from: start)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        let daysInMonth = calendar.range(of: .day, in: .month, for: start)?.count ?? 0
        var cells: [Date?] = Array(repeating: nil, count: lead)
        cells.reserveCapacity(cellsPerMonth)
        for day in 0..<daysInMonth {
            cells.append(calendar.date(byAdding: .day, value: day, to: start))
        }
        while cells.count < cellsPerMonth { cells.append(nil) }
        return Array(cells.prefix(cellsPerMonth))
    }

    static func canPage(from month: Date, delta: Int, range: ClosedRange<Date>, calendar: Calendar) -> Bool {
        let start = monthStart(month, calendar: calendar)
        guard let next = calendar.date(byAdding: .month, value: delta, to: start) else { return false }
        let nextStart = monthStart(next, calendar: calendar)
        guard let nextEnd = calendar.date(byAdding: .month, value: 1, to: nextStart) else { return false }
        return nextStart <= range.upperBound && nextEnd > range.lowerBound
    }

    static func isEnabled(_ date: Date, range: ClosedRange<Date>, calendar: Calendar) -> Bool {
        let day = calendar.startOfDay(for: date)
        return day >= calendar.startOfDay(for: range.lowerBound)
            && day <= calendar.startOfDay(for: range.upperBound)
    }

    static func isSameDay(_ a: Date, _ b: Date, calendar: Calendar) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }

    static func monthTitle(_ date: Date, calendar: Calendar) -> String {
        alignedMonthTitle.calendar = calendar
        alignedMonthTitle.locale = calendar.locale ?? Locale.current
        alignedMonthTitle.timeZone = calendar.timeZone
        return alignedMonthTitle.string(from: date)
    }

    private static let alignedMonthTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()
}

/// Stress chart window for the selected civil day. Built once per model rebuild, not in `body`.
enum HomeStressWindow {
    static func dayStart(for selected: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: selected)
    }

    static func now(
        dayStart: Date,
        calendar: Calendar = .current,
        clock: Date = Date()
    ) -> Date {
        let end = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? clock
        return min(clock, end)
    }
}

/// Recovery colours for the day picker. Same `NativeBandScores` values the Home ring uses.
enum HomeCalendarRecovery {
    static func values(
        days: [DailyMetric],
        sleeps: [CachedSleepSession] = [],
        workouts: [WorkoutRow] = [],
        importedSleep: [String: ImportedSleepFigures] = [:]
    ) -> [String: Double] {
        var map: [String: Double] = [:]
        for (key, day) in NativeBandScores.resolve(
            days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        ).byDay {
            if let recovery = day.recovery { map[key] = recovery }
        }
        return map
    }
}

extension HomeRingsRow: Equatable {
    static func == (lhs: HomeRingsRow, rhs: HomeRingsRow) -> Bool {
        lhs.sleep == rhs.sleep
            && lhs.recovery == rhs.recovery
            && lhs.strain == rhs.strain
            && lhs.strainTargetFraction == rhs.strainTargetFraction
    }
}

extension HomeHealthMonitorTile: Equatable {
    static func == (lhs: HomeHealthMonitorTile, rhs: HomeHealthMonitorTile) -> Bool {
        lhs.report == rhs.report
    }
}

extension HomeStressMonitorTile: Equatable {
    static func == (lhs: HomeStressMonitorTile, rhs: HomeStressMonitorTile) -> Bool {
        lhs.level == rhs.level && lhs.updated == rhs.updated
    }
}

extension HomeWeekCard: Equatable {
    static func == (lhs: HomeWeekCard, rhs: HomeWeekCard) -> Bool {
        lhs.recovery == rhs.recovery
            && lhs.strain == rhs.strain
            && lhs.highlightKey == rhs.highlightKey
            && lhs.previewSelected == rhs.previewSelected
    }
}

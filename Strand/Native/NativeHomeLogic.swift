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

/// Consecutive days with a recorded sleep (strap session or WHOOP import), ending today or yesterday.
enum HomeSleepStreak {
    static func days(
        sleeps: [CachedSleepSession],
        imported: [String: ImportedSleepFigures],
        todayKey: String,
        calendar: Calendar = .current
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
        } else if keys.contains(key(yesterday)) {
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

    /// Current Home rows minus Health Monitor duplicates (HRV, resting HR, respiratory rate).
    static let defaultIds = [
        "steps", "hr_zones_13", "hr_zones_45", "strength", "vo2max", "calories",
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
        case .vo2max: return .metric("vo2max_est")
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
        default: return nil
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

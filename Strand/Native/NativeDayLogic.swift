import Foundation
import StrandAnalytics
import WhoopStore

/// One funnel for the Native shell's selected day, strain scale, sleep day key, and journal ticks.
/// Screens read these; they do not re-derive the same fact.
enum NativeDayLogic {
    /// Process-lifetime id so a stepped day dies on the next cold launch.
    static let launchId = UUID().uuidString

    /// App "today": logical day with the 04:00 rollover, same key the rings use.
    /// Uses the nonisolated local-day helper so this funnel is callable off the main actor.
    static func logicalToday(now: Date = Date()) -> String {
        Repository.localDayKey(now.addingTimeInterval(-Double(Repository.logicalDayRolloverHour) * 3_600))
    }

    /// Global Home empty: the store has no days, no sleeps, and no imported WHOOP sleep figures.
    /// Home shows the single "No data yet" card only when this is true (and the first load finished).
    static func isEmptyStore(days: [DailyMetric], sleeps: [CachedSleepSession],
                             importedSleep: [String: ImportedSleepFigures]) -> Bool {
        days.isEmpty && sleeps.isEmpty && importedSleep.isEmpty
    }

    /// Persist a stepped calendar day together with the logical day and launch it was set on.
    static func persistSteppedDay(_ date: Date, now: Date = Date(), launchId: String = NativeDayLogic.launchId) -> String {
        "\(Repository.localDayKey(date))|\(logicalToday(now: now))|\(launchId)"
    }

    /// The only way a Native screen gets the selected day key.
    /// Empty, bare, or expired storage is logical today. A stepped day lasts until the logical
    /// day changes or the process is new.
    static func resolvedDayKey(stored: String, now: Date = Date(), launchId: String = NativeDayLogic.launchId) -> String {
        let today = logicalToday(now: now)
        guard let parsed = parse(stored), parsed.launchId == launchId, parsed.setOn == today else {
            return today
        }
        return parsed.dayKey
    }

    /// Start of the resolved calendar day, for the Home stepper.
    static func date(forStored stored: String, now: Date = Date(), launchId: String = NativeDayLogic.launchId) -> Date {
        startOfLocalDay(resolvedDayKey(stored: stored, now: now, launchId: launchId))
            ?? Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(Repository.logicalDayRolloverHour) * 3_600))
    }

    /// The one Effort figure Home and Today must show (#1001).
    /// `live` is today's in-progress TRIMP over the raw HR stream; `stored` is the daily row
    /// `analyzeRecent` writes. Same max-of-the-two rule `StrainScorer.effectiveEffort` uses.
    static func effectiveStrain(live: Double?, stored: Double?) -> Double? {
        StrainScorer.effectiveEffort(live: live, stored: stored)
    }

    /// Stored 0–100 strain mapped onto the EffortScale the user picked.
    static func strainDisplayValue(_ stored: Double, scale: EffortScale) -> Double {
        UnitFormatter.effortValue(stored, scale: scale)
    }

    static func strainText(_ stored: Double?, scale: EffortScale) -> String {
        guard let stored else { return "—" }
        let shown = strainDisplayValue(stored, scale: scale)
        return scale == .whoop ? String(format: "%.1f", shown) : String(Int(shown.rounded()))
    }

    static func strainMaxY(_ scale: EffortScale) -> Double {
        scale == .whoop ? 21 : 100
    }

    /// WHOOP 0–21: 0 / 7 / 14 / 21. 0–100: 0 / 50 / 100.
    static func strainYTicks(_ scale: EffortScale) -> [Double] {
        scale == .whoop ? [0, 7, 14, 21] : [0, 50, 100]
    }

    static func strainYTicks(maxY: Double) -> [Double] {
        if abs(maxY - 21) < 0.01 { return [0, 7, 14, 21] }
        if abs(maxY - 100) < 0.01 { return [0, 50, 100] }
        return [0, maxY / 2, maxY]
    }

    /// Asleep minutes. Delegates to `PerformanceAssessment.asleepMinutes` so the Sleep
    /// page and Assessments cannot disagree.
    static func asleepMinutes(light: Double?, deep: Double?, rem: Double?, totalSleepMin: Double?) -> Double? {
        PerformanceAssessment.asleepMinutes(light: light, deep: deep, rem: rem, totalSleepMin: totalSleepMin)
    }

    /// In bed = session end − start. No session → nothing (do not invent from efficiency).
    static func inBedMinutes(start: Date?, end: Date?) -> Double? {
        guard let start, let end, end > start else { return nil }
        let minutes = end.timeIntervalSince(start) / 60
        return minutes > 0 ? minutes : nil
    }

    /// Compact `7:11` for pills, rows, axis labels.
    static func durationText(_ minutes: Double) -> String {
        NativeScoreMath.duration(minutes)
    }

    /// Grouped integer (`6,545`) for steps and calories. One formatter for Home and Strain.
    static func countText(_ value: Double?) -> String {
        NativeScoreMath.labeled(value, unit: "", grouped: true)
    }

    /// Sleep sessions key off the same logical day the rings use, not midnight local.
    static func sleepSessionDayKey(_ end: Date) -> String {
        logicalToday(now: end)
    }

    /// Seven ticks ending `todayKey`. A day is checked only when a journal entry exists for it.
    static func journalChecks(entries: [JournalEntry], todayKey: String) -> [Bool] {
        let days = Set(entries.map(\.day))
        return NativeWeek.lastSevenKeys(ending: todayKey).map { days.contains($0) }
    }

    private static func parse(_ stored: String) -> (dayKey: String, setOn: String, launchId: String)? {
        let parts = stored.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, isDayKey(parts[0]), isDayKey(parts[1]), !parts[2].isEmpty else {
            return nil
        }
        return (parts[0], parts[1], parts[2])
    }

    private static func isDayKey(_ value: String) -> Bool {
        value.count == 10 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }

    /// Civil `yyyy-MM-dd` parts. Nil when the key is not three integer fields.
    static func civilDate(_ key: String) -> (year: Int, month: Int, day: Int)? {
        guard key.utf8.count == 10 else { return nil }
        let bytes = key.utf8
        func digit(_ offset: Int) -> Int? {
            let byte = bytes[bytes.index(bytes.startIndex, offsetBy: offset)]
            guard byte >= 48, byte <= 57 else { return nil }
            return Int(byte - 48)
        }
        guard let y0 = digit(0), let y1 = digit(1), let y2 = digit(2), let y3 = digit(3),
              bytes[bytes.index(bytes.startIndex, offsetBy: 4)] == 45,
              let m0 = digit(5), let m1 = digit(6),
              bytes[bytes.index(bytes.startIndex, offsetBy: 7)] == 45,
              let d0 = digit(8), let d1 = digit(9)
        else { return nil }
        let month = m0 * 10 + m1
        let day = d0 * 10 + d1
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        return (y0 * 1000 + y1 * 100 + y2 * 10 + y3, month, day)
    }

    /// Proleptic Gregorian day number for a `yyyy-MM-dd` key (Howard Hinnant civil days).
    /// Same order as local calendar dates; no `DateFormatter` / `Calendar` per point.
    static func epochDay(_ key: String) -> Int? {
        guard let civil = civilDate(key) else { return nil }
        return epochDay(year: civil.year, month: civil.month, day: civil.day)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar.
    static func epochDay(year: Int, month: Int, day: Int) -> Int {
        var year = year
        year -= month <= 2 ? 1 : 0
        let era = (year >= 0 ? year : year - 399) / 400
        let yoe = year - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func startOfLocalDay(_ key: String) -> Date? {
        if let cached = startOfDayCache.lock({ $0[key] }) { return cached }
        guard let civil = civilDate(key) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        guard let date = calendar.date(from: DateComponents(year: civil.year, month: civil.month, day: civil.day))
        else { return nil }
        let start = calendar.startOfDay(for: date)
        startOfDayCache.lock { $0[key] = start }
        return start
    }

    private static let startOfDayCache = NativeDayStartCache()
}

/// Tiny lock around a day-key → start-of-day map. Charts and Home both hit the same keys.
private final class NativeDayStartCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Date] = [:]

    func lock<T>(_ body: (inout [String: Date]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

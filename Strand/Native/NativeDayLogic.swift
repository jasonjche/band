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

    private static let localDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func startOfLocalDay(_ key: String) -> Date? {
        guard let date = localDayFormatter.date(from: key) else { return nil }
        return Calendar.current.startOfDay(for: date)
    }
}

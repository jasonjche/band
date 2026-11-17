import Foundation

/// Rest score for today: today's own value, or last night's when that night is still fresh.
enum RestScoreCarry {
    static let freshnessDays = 2

    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func isStale(priorDayKey: String, todayKey: String) -> Bool {
        guard let prior = dayKeyParser.date(from: priorDayKey),
              let today = dayKeyParser.date(from: todayKey) else { return false }
        let days = Calendar.current.dateComponents([.day], from: prior, to: today).day ?? 0
        return days > freshnessDays
    }

    static func freshRestScore(todayValue: Double?, lastDay: String?, lastValue: Double?,
                               isTodaySelected: Bool, todayKey: String) -> Double? {
        if let v = todayValue { return v }
        guard isTodaySelected, let lastDay, let lastValue,
              !isStale(priorDayKey: lastDay, todayKey: todayKey) else { return nil }
        return lastValue
    }
}

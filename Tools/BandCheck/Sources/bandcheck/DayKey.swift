import Foundation

/// Local `yyyy-MM-dd` for a timestamp. Band's Native shell keys a sleep session off
/// `end − 4h` (the logical-day rollover). WHOOP cycles use `WhoopDayKeying.wakeDayKey`
/// in the cycle's own offset — that lives in StrandImport and is called at the join.
enum DayKey {
    static let defaultRolloverHour = 4

    static func calendar(tz: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }

    static func local(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func local(_ ts: Int, calendar: Calendar) -> String {
        local(Date(timeIntervalSince1970: TimeInterval(ts)), calendar: calendar)
    }

    /// Native `logicalToday`: local day of `date − rolloverHour`.
    static func logical(_ date: Date, calendar: Calendar, rolloverHour: Int = defaultRolloverHour) -> String {
        local(date.addingTimeInterval(-Double(rolloverHour) * 3600), calendar: calendar)
    }

    static func logical(_ ts: Int, calendar: Calendar, rolloverHour: Int = defaultRolloverHour) -> String {
        logical(Date(timeIntervalSince1970: TimeInterval(ts)), calendar: calendar, rolloverHour: rolloverHour)
    }

    static func clockMin(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func startOfLocalDay(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        c.hour = 0; c.minute = 0; c.second = 0
        return calendar.date(from: c)
    }

    static func dayBounds(_ key: String, calendar: Calendar, rolloverHour: Int = defaultRolloverHour) -> (Int, Int)? {
        guard let start = startOfLocalDay(key, calendar: calendar) else { return nil }
        let from = Int(start.addingTimeInterval(Double(rolloverHour) * 3600).timeIntervalSince1970)
        return (from, from + 86400 - 1)
    }

    /// Walks a sorted timestamp stream and only asks Calendar at a local-day boundary.
    /// Byte-identical to calling `logical(_:calendar:)` per sample.
    struct LogicalCursor {
        let calendar: Calendar
        let rolloverHour: Int
        private var key = ""
        private var lo = Int.min
        private var hi = Int.min

        init(calendar: Calendar, rolloverHour: Int = DayKey.defaultRolloverHour) {
            self.calendar = calendar
            self.rolloverHour = rolloverHour
        }

        mutating func logical(_ ts: Int) -> String {
            if ts >= lo && ts <= hi { return key }
            let shifted = TimeInterval(ts - rolloverHour * 3600)
            let date = Date(timeIntervalSince1970: shifted)
            let start = calendar.startOfDay(for: date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: start) else {
                return DayKey.logical(ts, calendar: calendar, rolloverHour: rolloverHour)
            }
            key = DayKey.local(start, calendar: calendar)
            lo = Int(start.timeIntervalSince1970) + rolloverHour * 3600
            hi = Int(next.timeIntervalSince1970) + rolloverHour * 3600 - 1
            return key
        }
    }
}

/// Punctuation-insensitive journal title fold. JournalCatalog.titleKey (app target) is the
/// same fold; aliases that live only in that catalog are not applied here.
func journalTitleKey(_ s: String) -> String {
    let folded = s.lowercased().unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
    }
    return String(folded)
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

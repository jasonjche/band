import Foundation
import WhoopStore

/// Follow-up shown under a Yes answer: quantity, a clock time, or both.
enum NativeJournalFollowUp: Equatable {
    case none
    case quantity(unit: String)
    case time
    case quantityAndTime(unit: String)

    var hasQuantity: Bool {
        switch self {
        case .quantity, .quantityAndTime: return true
        case .none, .time: return false
        }
    }

    var hasTime: Bool {
        switch self {
        case .time, .quantityAndTime: return true
        case .none, .quantity: return false
        }
    }

    var unitLabel: String? {
        switch self {
        case .quantity(let unit), .quantityAndTime(let unit): return unit
        case .none, .time: return nil
        }
    }

    var defaultQuantity: Double { 1 }

    /// WHOOP-style extras for caffeine, alcohol, late meal, and screen time, plus any numeric catalog item.
    static func forItem(_ item: JournalCatalogItem) -> NativeJournalFollowUp {
        forQuestion(item.canonical, kind: item.kind)
    }

    static func forQuestion(_ question: String, kind: JournalKind) -> NativeJournalFollowUp {
        let key = JournalCatalogStore.titleKey(JournalCatalogStore.canonicalId(for: question))
        let time = needsTime(key)
        let catalogUnit = kind.unitLabel.flatMap { $0.isEmpty ? nil : $0 }
        let mappedUnit = defaultUnit(key)
        let unit = catalogUnit ?? mappedUnit
        let quantity = kind.isNumeric || mappedUnit != nil
        switch (quantity, time) {
        case (true, true): return .quantityAndTime(unit: unit ?? "")
        case (true, false): return .quantity(unit: unit ?? "")
        case (false, true): return .time
        case (false, false): return .none
        }
    }

    private static func needsTime(_ key: String) -> Bool {
        if key.contains("caffeine") { return true }
        if key.contains("alcohol") { return true }
        if key.contains("screen") { return true }
        if key.contains("bedtime") || key.contains("close to bed") { return true }
        if key.contains("late meal") || key.contains("late food") { return true }
        if key.contains("eat close") || key.contains("ate food close") { return true }
        return false
    }

    private static func defaultUnit(_ key: String) -> String? {
        if key.contains("alcohol") { return "drinks" }
        if key.contains("caffeine") { return "servings" }
        return nil
    }
}

/// Time (and optional free-text) packed into `JournalEntry.notes` so quantity stays on `numericValue`
/// and the journal table needs no migration. Legacy plain-text notes still decode as notes.
enum NativeJournalNotes {
    static let payloadVersion = 1
    static let defaultHour = 21
    static let defaultMinute = 0

    struct Decoded: Equatable {
        var timeMinutes: Int?
        var note: String?
    }

    private struct Payload: Codable {
        var v: Int
        var t: String?
        var n: String?
    }

    static func encode(timeMinutes: Int?, note: String?) -> String? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteValue = (trimmed?.isEmpty == false) ? trimmed : nil
        let time = timeMinutes.map(clampMinutes)
        if time == nil && noteValue == nil { return nil }
        let payload = Payload(v: payloadVersion, t: time.map(hhmm), n: noteValue)
        return (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ notes: String?) -> Decoded {
        guard let notes, !notes.isEmpty else { return Decoded(timeMinutes: nil, note: nil) }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{",
              let data = trimmed.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.v == payloadVersion
        else {
            return Decoded(timeMinutes: nil, note: notes)
        }
        let note = payload.n.flatMap { $0.isEmpty ? nil : $0 }
        return Decoded(timeMinutes: payload.t.flatMap(minutes(fromHHMM:)), note: note)
    }

    static func clampMinutes(_ minutes: Int) -> Int {
        max(0, min(23 * 60 + 59, minutes))
    }

    static func minutes(from date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return clampMinutes((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    static func date(minutes: Int, on day: Date, calendar: Calendar = .current) -> Date {
        let clamped = clampMinutes(minutes)
        return calendar.date(bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: day) ?? day
    }

    static func defaultTime(on day: Date, calendar: Calendar = .current) -> Date {
        date(minutes: defaultHour * 60 + defaultMinute, on: day, calendar: calendar)
    }

    static func formatTime(_ minutes: Int, locale: Locale = .current) -> String {
        timeLock.lock()
        defer { timeLock.unlock() }
        if timeLocale != locale {
            timeFormatter.locale = locale
            timeLocale = locale
        }
        let day = Date(timeIntervalSince1970: 0)
        return timeFormatter.string(from: date(minutes: minutes, on: day))
    }

    private static let timeLock = NSLock()
    private static var timeLocale: Locale?
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static func hhmm(_ minutes: Int) -> String {
        let clamped = clampMinutes(minutes)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    static func minutes(fromHHMM text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}

/// Read-side merge of imported WHOOP titles onto catalogue ids. Never rewrites stored rows.
enum NativeJournalIdentity {
    static func canonicalQuestion(_ question: String) -> String {
        JournalCatalogStore.canonicalId(for: question)
    }

    /// One winning row per (day, canonical id). A row already stored under the catalogue id
    /// beats an imported alias for the same day.
    static func winningEntries(_ entries: [JournalEntry]) -> [JournalEntry] {
        var best: [String: JournalEntry] = [:]
        for entry in entries.sorted(by: { ($0.day, $0.question) < ($1.day, $1.question) }) {
            let id = JournalCatalogStore.canonicalId(for: entry.question)
            let key = entry.day + "\u{1F}" + id
            if let existing = best[key] {
                let entryIsCanon = JournalCatalogStore.norm(entry.question) == JournalCatalogStore.norm(id)
                let existingIsCanon = JournalCatalogStore.norm(existing.question) == JournalCatalogStore.norm(id)
                if entryIsCanon && !existingIsCanon {
                    best[key] = entry
                }
            } else {
                best[key] = entry
            }
        }
        return best.values
            .map { entry in
                JournalEntry(
                    day: entry.day,
                    question: JournalCatalogStore.canonicalId(for: entry.question),
                    answeredYes: entry.answeredYes,
                    notes: entry.notes,
                    numericValue: entry.numericValue
                )
            }
            .sorted { ($0.day, $0.question) < ($1.day, $1.question) }
    }

    static func lookup<Value>(_ map: [String: Value], canonical: String) -> Value? {
        if let value = map[canonical] { return value }
        for id in JournalCatalogStore.answerIds(for: canonical) {
            if let value = map[id] { return value }
        }
        return nil
    }
}

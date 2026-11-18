import Foundation
import ZIPFoundation

/// Serializes Band history into WHOOP's four-CSV export shape so a zip re-imports through
/// `WhoopExportImporter` (and can be dropped into WHOOP if the user continues there).
///
/// Headers, column order, local `yyyy-MM-dd HH:mm:ss` timestamps, `UTC-05:00`-style timezone
/// cells, empty cells for missing values, and `true`/`false` booleans match WHOOP's English
/// export. Cycle bounds are sleep-onset → next sleep-onset; the open (current) cycle has an
/// empty end. Strain is WHOOP's 0–21 scale. CSV writing is pure: the app gatherer supplies
/// `WhoopCycleRow` / `WhoopSleepRow` / `WhoopWorkoutRow` / `WhoopJournalRow`.
public enum WhoopCsvExporter {

    public static let cyclesHeader =
        "Cycle start time,Cycle end time,Cycle timezone,Recovery score %,"
        + "Resting heart rate (bpm),Heart rate variability (ms),Skin temp (celsius),"
        + "Blood oxygen %,Day Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),"
        + "Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),"
        + "Asleep duration (min),In bed duration (min),Light sleep duration (min),"
        + "Deep (SWS) duration (min),REM duration (min),Awake duration (min),"
        + "Sleep need (min),Sleep debt (min),Sleep efficiency %,Sleep consistency %"

    public static let sleepsHeader =
        "Cycle start time,Cycle end time,Cycle timezone,Sleep onset,Wake onset,"
        + "Sleep performance %,Respiratory rate (rpm),Asleep duration (min),"
        + "In bed duration (min),Light sleep duration (min),Deep (SWS) duration (min),"
        + "REM duration (min),Awake duration (min),Sleep need (min),Sleep debt (min),"
        + "Sleep efficiency %,Sleep consistency %,Nap"

    public static let workoutsHeader =
        "Cycle start time,Cycle end time,Cycle timezone,Workout start time,Workout end time,"
        + "Duration (min),Activity name,Activity Strain,Energy burned (cal),Max HR (bpm),"
        + "Average HR (bpm),HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,HR Zone 5 %,"
        + "GPS enabled"

    public static let journalHeader =
        "Cycle start time,Cycle end time,Cycle timezone,Question text,Answered yes,Notes"

    // MARK: - Primitives

    /// RFC-4180 quoting: quote when the field carries a comma, quote, CR or LF; escape an
    /// embedded `"` by doubling it.
    static func field(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        guard raw.contains(",") || raw.contains("\"") || raw.contains("\n") || raw.contains("\r") else {
            return raw
        }
        return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Locale-proof numbers: integral Doubles print without a trailing ".0", and String(Double)
    /// always uses '.' regardless of the user's locale.
    static func num(_ v: Double?) -> String {
        guard let v else { return "" }
        return v == v.rounded() && abs(v) < 1e12 ? String(Int64(v)) : String(v)
    }

    static func num(_ v: Int?) -> String { v.map(String.init) ?? "" }

    static func bool(_ v: Bool?) -> String {
        guard let v else { return "" }
        return v ? "true" : "false"
    }

    /// `UTC-05:00` / `UTC+01:00` (WHOOP's Cycle timezone column).
    public static func timezoneLabel(offsetMinutes: Int) -> String {
        let sign = offsetMinutes >= 0 ? "+" : "-"
        let abs = Swift.abs(offsetMinutes)
        return String(format: "UTC%@%02d:%02d", sign, abs / 60, abs % 60)
    }

    /// `yyyy-MM-dd HH:mm:ss` in the given offset. Empty when `date` is nil.
    public static func timestamp(_ date: Date?, offsetMinutes: Int) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60) ?? TimeZone(secondsFromGMT: 0)!
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    /// Offset of `timeZone` at `date`, in minutes.
    public static func offsetMinutes(at date: Date, timeZone: TimeZone = .current) -> Int {
        timeZone.secondsFromGMT(for: date) / 60
    }

    /// Sleep-onset → next sleep-onset. The last (open / current) cycle has a nil end.
    public static func cycleWindows(mainOnsets: [Date]) -> [(start: Date, end: Date?)] {
        let sorted = mainOnsets.sorted()
        return sorted.enumerated().map { i, start in
            (start, i + 1 < sorted.count ? sorted[i + 1] : nil)
        }
    }

    /// Cycle whose `[start, end)` contains `date`. The open cycle (nil end) matches any `date >= start`.
    public static func cycleContaining(
        _ date: Date,
        windows: [(start: Date, end: Date?)]
    ) -> (start: Date, end: Date?)? {
        windows.last { window in
            date >= window.start && (window.end.map { date < $0 } ?? true)
        }
    }

    // MARK: - Stage / zone JSON (gatherer helpers)

    /// Stage minutes recovered from any persisted stagesJSON shape Band has written:
    ///   - {"light":min,…}            — WHOOP import
    ///   - [{"stage","min"}]          — Android import / demo seeds
    ///   - [{"start","end","stage"}]  — on-device SleepStager ("wake" == awake)
    /// Unusable / empty input → all-nil, so the column exports blank rather than a bogus zero.
    public struct StageMinutes {
        public var light: Double?, deep: Double?, rem: Double?, awake: Double?
        public var asleep: Double? {
            if light == nil && deep == nil && rem == nil { return nil }
            return (light ?? 0) + (deep ?? 0) + (rem ?? 0)
        }
    }

    public static func stageMinutes(_ stagesJSON: String?) -> StageMinutes {
        let none = StageMinutes(light: nil, deep: nil, rem: nil, awake: nil)
        guard let stagesJSON, let data = stagesJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return none }
        if let dict = obj as? [String: Any] {
            func g(_ k: String) -> Double? { (dict[k] as? NSNumber)?.doubleValue }
            return StageMinutes(light: g("light"), deep: g("deep"), rem: g("rem"),
                                awake: g("awake") ?? g("wake"))
        }
        guard let arr = obj as? [[String: Any]] else { return none }
        var l = 0.0, d = 0.0, r = 0.0, a = 0.0
        var any = false
        for seg in arr {
            let stage = (seg["stage"] as? String)?.lowercased() ?? ""
            let minutes: Double
            if let m = (seg["min"] as? NSNumber)?.doubleValue {
                minutes = m
            } else if let s = (seg["start"] as? NSNumber)?.doubleValue,
                      let e = (seg["end"] as? NSNumber)?.doubleValue {
                minutes = (e - s) / 60.0
            } else {
                continue
            }
            any = true
            switch stage {
            case "light":         l += minutes
            case "deep", "sws":   d += minutes
            case "rem":           r += minutes
            case "awake", "wake": a += minutes
            default:              break
            }
        }
        return any ? StageMinutes(light: l, deep: d, rem: r, awake: a) : none
    }

    /// Z1–Z5 percents from zonesJSON. "z1"…"z5" or "zone1"…"zone5". nil when unusable.
    public static func zonePercents(_ zonesJSON: String?) -> [Double]? {
        guard let zonesJSON, let data = zonesJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let p = (1...5).map { i -> Double in
            ((obj["z\(i)"] ?? obj["zone\(i)"]) as? NSNumber)?.doubleValue ?? 0
        }
        return p.contains(where: { $0 > 0 }) ? p : nil
    }

    // MARK: - The four CSVs

    public static func cyclesCSV(_ rows: [WhoopCycleRow]) -> String {
        var out = cyclesHeader + "\r\n"
        for r in rows {
            let tz = r.tzOffsetMin
            let cols: [String] = [
                timestamp(r.cycleStart, offsetMinutes: tz),
                timestamp(r.cycleEnd, offsetMinutes: tz),
                timezoneLabel(offsetMinutes: tz),
                num(r.recoveryScore), num(r.restingHeartRate), num(r.hrvMs),
                num(r.skinTempCelsius), num(r.bloodOxygenPct), num(r.dayStrain),
                num(r.energyKcal), num(r.maxHeartRate), num(r.avgHeartRate),
                timestamp(r.sleepOnset, offsetMinutes: tz),
                timestamp(r.wakeOnset, offsetMinutes: tz),
                num(r.sleepPerformancePct), num(r.respiratoryRate),
                num(r.asleepDurationMin), num(r.inBedDurationMin),
                num(r.lightSleepDurationMin), num(r.deepSleepDurationMin),
                num(r.remDurationMin), num(r.awakeDurationMin),
                num(r.sleepNeedMin), num(r.sleepDebtMin),
                num(r.sleepEfficiencyPct), num(r.sleepConsistencyPct),
            ]
            out += cols.joined(separator: ",") + "\r\n"
        }
        return out
    }

    public static func sleepsCSV(_ rows: [WhoopSleepRow]) -> String {
        var out = sleepsHeader + "\r\n"
        for r in rows {
            let tz = r.tzOffsetMin
            let cols: [String] = [
                timestamp(r.cycleStart, offsetMinutes: tz),
                timestamp(r.cycleEnd, offsetMinutes: tz),
                timezoneLabel(offsetMinutes: tz),
                timestamp(r.sleepOnset, offsetMinutes: tz),
                timestamp(r.wakeOnset, offsetMinutes: tz),
                num(r.sleepPerformancePct), num(r.respiratoryRate),
                num(r.asleepDurationMin), num(r.inBedDurationMin),
                num(r.lightSleepDurationMin), num(r.deepSleepDurationMin),
                num(r.remDurationMin), num(r.awakeDurationMin),
                num(r.sleepNeedMin), num(r.sleepDebtMin),
                num(r.sleepEfficiencyPct), num(r.sleepConsistencyPct),
                bool(r.isNap),
            ]
            out += cols.joined(separator: ",") + "\r\n"
        }
        return out
    }

    public static func workoutsCSV(_ rows: [WhoopWorkoutRow]) -> String {
        var out = workoutsHeader + "\r\n"
        for r in rows {
            let tz = r.tzOffsetMin
            let duration = r.durationMin ?? durationMinutes(start: r.workoutStart, end: r.workoutEnd)
            let cols: [String] = [
                timestamp(r.cycleStart, offsetMinutes: tz),
                timestamp(r.cycleEnd, offsetMinutes: tz),
                timezoneLabel(offsetMinutes: tz),
                timestamp(r.workoutStart, offsetMinutes: tz),
                timestamp(r.workoutEnd, offsetMinutes: tz),
                num(duration),
                field(r.activityName), num(r.activityStrain), num(r.energyKcal),
                num(r.maxHeartRate), num(r.avgHeartRate),
                num(r.hrZone1Pct), num(r.hrZone2Pct), num(r.hrZone3Pct),
                num(r.hrZone4Pct), num(r.hrZone5Pct),
                bool(r.gpsEnabled),
            ]
            out += cols.joined(separator: ",") + "\r\n"
        }
        return out
    }

    public static func journalCSV(_ rows: [WhoopJournalRow]) -> String {
        var out = journalHeader + "\r\n"
        for r in rows {
            let tz = r.tzOffsetMin
            let cols: [String] = [
                timestamp(r.cycleStart, offsetMinutes: tz),
                timestamp(r.cycleEnd, offsetMinutes: tz),
                timezoneLabel(offsetMinutes: tz),
                field(r.question),
                field(r.answer),
                field(r.notes),
            ]
            out += cols.joined(separator: ",") + "\r\n"
        }
        return out
    }

    private static func durationMinutes(start: Date?, end: Date?) -> Double? {
        guard let start, let end, end > start else { return nil }
        return end.timeIntervalSince(start) / 60.0
    }

    // MARK: - Archive

    /// Write the four WHOOP CSVs into a fresh zip at `url`.
    public static func writeArchive(
        cycles: [WhoopCycleRow],
        sleeps: [WhoopSleepRow],
        workouts: [WhoopWorkoutRow],
        journal: [WhoopJournalRow],
        to url: URL
    ) throws {
        let entries: [(name: String, data: Data)] = [
            ("physiological_cycles.csv", Data(cyclesCSV(cycles).utf8)),
            ("sleeps.csv", Data(sleepsCSV(sleeps).utf8)),
            ("workouts.csv", Data(workoutsCSV(workouts).utf8)),
            ("journal_entries.csv", Data(journalCSV(journal).utf8)),
        ]
        try writeArchive(entries: entries, to: url)
    }

    /// Write the entries into a fresh zip at `url`.
    public static func writeArchive(entries: [(name: String, data: Data)], to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for e in entries {
            try archive.addEntry(with: e.name, type: .file,
                                 uncompressedSize: Int64(e.data.count),
                                 provider: { position, size in
                                     e.data.subdata(in: Int(position)..<(Int(position) + size))
                                 })
        }
    }
}

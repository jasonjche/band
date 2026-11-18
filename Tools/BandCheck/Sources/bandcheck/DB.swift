import Foundation
import SQLite3
import WhoopProtocol

/// Minimal read-only SQLite reader. Deliberately not GRDB: this tool must open a COPY of a
/// device database taken at any schema version without running migrations. Opened `immutable=1`
/// so it can never write.
final class ReadOnlyDB {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let uri = "file:\(path)?immutable=1"
        let rc = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK else {
            throw Err("cannot open \(path): \(String(cString: sqlite3_errstr(rc)))")
        }
    }
    deinit { if let handle { sqlite3_close(handle) } }

    struct Err: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    func query(_ sql: String, _ each: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Err("prepare failed: \(String(cString: sqlite3_errmsg(handle))) [\(sql)]")
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { each(stmt!) }
    }

    static func int(_ s: OpaquePointer, _ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }
    static func dbl(_ s: OpaquePointer, _ i: Int32) -> Double { sqlite3_column_double(s, i) }
    static func isNull(_ s: OpaquePointer, _ i: Int32) -> Bool {
        sqlite3_column_type(s, i) == SQLITE_NULL
    }
    static func str(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }
}

struct DailyRow {
    let deviceId: String
    let day: String
    let totalSleepMin: Double?
    let efficiency: Double?
    let deepMin: Double?
    let remMin: Double?
    let lightMin: Double?
    let restingHr: Double?
    let avgHrv: Double?
    let recovery: Double?
    let strain: Double?
    let respRateBpm: Double?
    let steps: Int?
    let activeKcalEst: Double?
    let skinTempC: Double?
    let spo2Pct: Double?
}

struct SleepRow {
    let deviceId: String
    let startTs: Int
    let endTs: Int
    let stagesJSON: String?
    let efficiency: Double?
    var durationS: Int { max(0, endTs - startTs) }
}

struct WorkoutDBRow {
    let deviceId: String
    let startTs: Int
    let endTs: Int
    let sport: String
    let source: String
    let durationS: Double?
    let strain: Double?
    let avgHr: Int?
    var durationSec: Int {
        if let durationS, durationS > 0 { return Int(durationS.rounded()) }
        return max(0, endTs - startTs)
    }
    var isDetected: Bool { source.lowercased().hasSuffix("-noop") }
    var isApple: Bool {
        let s = source.lowercased()
        return s == "apple-health" || s == "apple_health"
    }
    var isManual: Bool { source.lowercased() == "manual" }
}

struct AppleDailyRow {
    let day: String
    let steps: Int?
    let vo2max: Double?
}

struct JournalDBRow {
    let deviceId: String
    let day: String
    let question: String
}

struct MetricPointRow {
    let deviceId: String
    let day: String
    let key: String
    let value: Double
}

extension ReadOnlyDB {
    func dailyMetrics() throws -> [DailyRow] {
        var out: [DailyRow] = []
        try query("""
            SELECT deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin,
                   restingHr, avgHrv, recovery, strain, respRateBpm, steps, activeKcalEst,
                   skinTempC, spo2Pct
            FROM dailyMetric ORDER BY day
            """) { s in
            out.append(DailyRow(
                deviceId: ReadOnlyDB.str(s, 0) ?? "",
                day: ReadOnlyDB.str(s, 1) ?? "",
                totalSleepMin: ReadOnlyDB.isNull(s, 2) ? nil : ReadOnlyDB.dbl(s, 2),
                efficiency: ReadOnlyDB.isNull(s, 3) ? nil : ReadOnlyDB.dbl(s, 3),
                deepMin: ReadOnlyDB.isNull(s, 4) ? nil : ReadOnlyDB.dbl(s, 4),
                remMin: ReadOnlyDB.isNull(s, 5) ? nil : ReadOnlyDB.dbl(s, 5),
                lightMin: ReadOnlyDB.isNull(s, 6) ? nil : ReadOnlyDB.dbl(s, 6),
                restingHr: ReadOnlyDB.isNull(s, 7) ? nil : ReadOnlyDB.dbl(s, 7),
                avgHrv: ReadOnlyDB.isNull(s, 8) ? nil : ReadOnlyDB.dbl(s, 8),
                recovery: ReadOnlyDB.isNull(s, 9) ? nil : ReadOnlyDB.dbl(s, 9),
                strain: ReadOnlyDB.isNull(s, 10) ? nil : ReadOnlyDB.dbl(s, 10),
                respRateBpm: ReadOnlyDB.isNull(s, 11) ? nil : ReadOnlyDB.dbl(s, 11),
                steps: ReadOnlyDB.isNull(s, 12) ? nil : ReadOnlyDB.int(s, 12),
                activeKcalEst: ReadOnlyDB.isNull(s, 13) ? nil : ReadOnlyDB.dbl(s, 13),
                skinTempC: ReadOnlyDB.isNull(s, 14) ? nil : ReadOnlyDB.dbl(s, 14),
                spo2Pct: ReadOnlyDB.isNull(s, 15) ? nil : ReadOnlyDB.dbl(s, 15)))
        }
        return out
    }

    func sleepSessions() throws -> [SleepRow] {
        var out: [SleepRow] = []
        try query("SELECT deviceId, startTs, endTs, stagesJSON, efficiency FROM sleepSession ORDER BY startTs") { s in
            out.append(SleepRow(
                deviceId: ReadOnlyDB.str(s, 0) ?? "",
                startTs: ReadOnlyDB.int(s, 1),
                endTs: ReadOnlyDB.int(s, 2),
                stagesJSON: ReadOnlyDB.str(s, 3),
                efficiency: ReadOnlyDB.isNull(s, 4) ? nil : ReadOnlyDB.dbl(s, 4)))
        }
        return out
    }

    func workouts() throws -> [WorkoutDBRow] {
        var out: [WorkoutDBRow] = []
        try query("""
            SELECT deviceId, startTs, endTs, sport, source, durationS, strain, avgHr
            FROM workout ORDER BY startTs
            """) { s in
            out.append(WorkoutDBRow(
                deviceId: ReadOnlyDB.str(s, 0) ?? "",
                startTs: ReadOnlyDB.int(s, 1),
                endTs: ReadOnlyDB.int(s, 2),
                sport: ReadOnlyDB.str(s, 3) ?? "",
                source: ReadOnlyDB.str(s, 4) ?? "",
                durationS: ReadOnlyDB.isNull(s, 5) ? nil : ReadOnlyDB.dbl(s, 5),
                strain: ReadOnlyDB.isNull(s, 6) ? nil : ReadOnlyDB.dbl(s, 6),
                avgHr: ReadOnlyDB.isNull(s, 7) ? nil : ReadOnlyDB.int(s, 7)))
        }
        return out
    }

    func appleDaily() throws -> [AppleDailyRow] {
        var out: [AppleDailyRow] = []
        try query("SELECT day, steps, vo2max FROM appleDaily ORDER BY day") { s in
            out.append(AppleDailyRow(
                day: ReadOnlyDB.str(s, 0) ?? "",
                steps: ReadOnlyDB.isNull(s, 1) ? nil : ReadOnlyDB.int(s, 1),
                vo2max: ReadOnlyDB.isNull(s, 2) ? nil : ReadOnlyDB.dbl(s, 2)))
        }
        return out
    }

    func journal() throws -> [JournalDBRow] {
        var out: [JournalDBRow] = []
        try query("SELECT deviceId, day, question FROM journal") { s in
            out.append(JournalDBRow(
                deviceId: ReadOnlyDB.str(s, 0) ?? "",
                day: ReadOnlyDB.str(s, 1) ?? "",
                question: ReadOnlyDB.str(s, 2) ?? ""))
        }
        return out
    }

    func metricSeries(keys: [String]) throws -> [MetricPointRow] {
        guard !keys.isEmpty else { return [] }
        let listed = keys.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
        var out: [MetricPointRow] = []
        try query("SELECT deviceId, day, key, value FROM metricSeries WHERE key IN (\(listed))") { s in
            out.append(MetricPointRow(
                deviceId: ReadOnlyDB.str(s, 0) ?? "",
                day: ReadOnlyDB.str(s, 1) ?? "",
                key: ReadOnlyDB.str(s, 2) ?? "",
                value: ReadOnlyDB.dbl(s, 3)))
        }
        return out
    }

    func hrSpan() throws -> (from: Int, to: Int)? {
        var from: Int?, to: Int?
        try query("SELECT MIN(ts), MAX(ts) FROM hrSample") { s in
            if !ReadOnlyDB.isNull(s, 0) { from = ReadOnlyDB.int(s, 0) }
            if !ReadOnlyDB.isNull(s, 1) { to = ReadOnlyDB.int(s, 1) }
        }
        try query("SELECT MIN(ts), MAX(ts) FROM ppgHrSample") { s in
            if !ReadOnlyDB.isNull(s, 0) {
                from = min(from ?? ReadOnlyDB.int(s, 0), ReadOnlyDB.int(s, 0))
            }
            if !ReadOnlyDB.isNull(s, 1) {
                to = max(to ?? ReadOnlyDB.int(s, 1), ReadOnlyDB.int(s, 1))
            }
        }
        guard let from, let to else { return nil }
        return (from, to)
    }

    /// Measured HR wins; PPG fills seconds with no measured row. Same coalescing `Reads.hrBuckets` uses.
    func coalescedHR(device: String, from: Int, to: Int) throws -> [HRSample] {
        var out: [HRSample] = []
        let d = device.replacingOccurrences(of: "'", with: "''")
        try query("""
            SELECT ts, bpm FROM (
                SELECT ts, bpm FROM hrSample
                WHERE deviceId = '\(d)' AND ts >= \(from) AND ts <= \(to)
                UNION ALL
                SELECT p.ts, CAST(ROUND(p.bpm) AS INTEGER) FROM ppgHrSample p
                WHERE p.deviceId = '\(d)' AND p.ts >= \(from) AND p.ts <= \(to)
                  AND NOT EXISTS (
                    SELECT 1 FROM hrSample h
                    WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
            ) ORDER BY ts
            """) { s in
            out.append(HRSample(ts: ReadOnlyDB.int(s, 0), bpm: ReadOnlyDB.int(s, 1)))
        }
        return out
    }

    func steps(device: String, from: Int, to: Int) throws -> [StepSample] {
        var out: [StepSample] = []
        let d = device.replacingOccurrences(of: "'", with: "''")
        try query("""
            SELECT ts, counter, activityClass FROM stepSample
            WHERE deviceId = '\(d)' AND ts >= \(from) AND ts <= \(to)
            ORDER BY ts
            """) { s in
            out.append(StepSample(
                ts: ReadOnlyDB.int(s, 0),
                counter: ReadOnlyDB.int(s, 1),
                activityClass: ReadOnlyDB.isNull(s, 2) ? nil : ReadOnlyDB.int(s, 2)))
        }
        return out
    }

    func gravity(device: String, from: Int, to: Int) throws -> [GravitySample] {
        var out: [GravitySample] = []
        let d = device.replacingOccurrences(of: "'", with: "''")
        try query("""
            SELECT ts, x, y, z, dynAccel FROM gravitySample
            WHERE deviceId = '\(d)' AND ts >= \(from) AND ts <= \(to)
            ORDER BY ts
            """) { s in
            out.append(GravitySample(
                ts: ReadOnlyDB.int(s, 0),
                x: ReadOnlyDB.dbl(s, 1), y: ReadOnlyDB.dbl(s, 2), z: ReadOnlyDB.dbl(s, 3),
                unit: "g",
                dynAccel: ReadOnlyDB.isNull(s, 4) ? nil : ReadOnlyDB.dbl(s, 4)))
        }
        return out
    }

    func rrIntervals(device: String, from: Int, to: Int) throws -> [RRInterval] {
        var out: [RRInterval] = []
        let d = device.replacingOccurrences(of: "'", with: "''")
        try query("""
            SELECT ts, rrMs FROM rrInterval
            WHERE deviceId = '\(d)' AND ts >= \(from) AND ts <= \(to)
            ORDER BY ts
            """) { s in
            out.append(RRInterval(ts: ReadOnlyDB.int(s, 0), rrMs: ReadOnlyDB.int(s, 1)))
        }
        return out
    }

    func skinTemp(device: String, from: Int, to: Int) throws -> [SkinTempSample] {
        var out: [SkinTempSample] = []
        let d = device.replacingOccurrences(of: "'", with: "''")
        try query("""
            SELECT ts, raw FROM skinTempSample
            WHERE deviceId = '\(d)' AND ts >= \(from) AND ts <= \(to)
            ORDER BY ts
            """) { s in
            out.append(SkinTempSample(ts: ReadOnlyDB.int(s, 0), raw: ReadOnlyDB.int(s, 1), unit: "raw_adc"))
        }
        return out
    }

    func workoutHasHR(start: Int, end: Int) throws -> Bool {
        var n = 0
        try query("""
            SELECT 1 FROM hrSample WHERE ts >= \(start) AND ts <= \(end) LIMIT 1
            """) { _ in n = 1 }
        if n == 1 { return true }
        try query("""
            SELECT 1 FROM ppgHrSample WHERE ts >= \(start) AND ts <= \(end) LIMIT 1
            """) { _ in n = 1 }
        return n == 1
    }

    func duplicateDailyMetricCounts() throws -> Int {
        var n = 0
        try query("""
            SELECT COUNT(*) FROM (
                SELECT deviceId, day FROM dailyMetric GROUP BY deviceId, day HAVING COUNT(*) > 1
            )
            """) { s in n = ReadOnlyDB.int(s, 0) }
        return n
    }
}

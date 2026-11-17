import Foundation
import GRDB
import WhoopProtocol
import XCTest
@testable import WhoopStore

/// Hot-path read benchmark. Skipped unless `BAND_PERF=1`.
///
/// Seeds `/tmp/perfA/whoop-synth.sqlite` (180 days of 1 Hz HR/RR/steps/gravity) via `WhoopStore.insert`
/// on first run, then times each chart/analysis read over day / week / 6-month windows.
/// Prints median and p90 of 7 timed runs after a warm-up, plus `EXPLAIN QUERY PLAN` and insert
/// throughput. Does not assert timings — this is a measurement harness, not a gate.
final class ReadPerfBenchTests: XCTestCase {

    private static let realPath = "/tmp/perfA/whoop.sqlite"
    private static let synthPath = "/tmp/perfA/whoop-synth.sqlite"
    private static let deviceId = "my-whoop"
    /// 2023-11-14 22:13:20 UTC. 180 * 86400 = 15_552_000 seconds of 1 Hz data.
    private static let synthStart = 1_700_000_000
    private static let synthDays: Int = {
        if let raw = ProcessInfo.processInfo.environment["BAND_PERF_DAYS"], let n = Int(raw), n > 0 {
            return n
        }
        return 180
    }()
    private static let secondsPerDay = 86_400
    private static let timedRuns = 7

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BAND_PERF"] == "1",
                          "set BAND_PERF=1 to run WhoopStore read benchmarks")
    }

    func testReadPerfRealAndSynthetic() async throws {
        try await Self.ensureSyntheticDatabase()
        let real = try await WhoopStore(path: Self.realPath)
        let synth = try await WhoopStore(path: Self.synthPath)

        let realRange = try await Self.hrRange(store: real, deviceId: Self.deviceId)
        let synthEnd = Self.synthStart + Self.synthDays * Self.secondsPerDay - 1
        print("PERF real hr range=\(realRange.map { "\($0.lo)-\($0.hi) n=\($0.n)" } ?? "empty")")
        print("PERF synth window=\(Self.synthStart)-\(synthEnd)")
        if let bytes = await real.databaseFileSizeBytes() {
            print("PERF real db bytes=\(bytes)")
        }
        if let bytes = await synth.databaseFileSizeBytes() {
            print("PERF synth db bytes=\(bytes)")
        }
        let minuteN = try await synth.hrMinuteCountForTest(deviceId: Self.deviceId)
        print("PERF synth hrMinute rows=\(minuteN)")

        print("PERF EXPLAIN real")
        try await Self.dumpExplains(store: real, deviceId: Self.deviceId,
                                    from: realRange?.lo ?? 0, to: realRange?.hi ?? 1)
        print("PERF EXPLAIN synth day")
        try await Self.dumpExplains(store: synth, deviceId: Self.deviceId,
                                    from: synthEnd - Self.secondsPerDay + 1, to: synthEnd)

        let insertMs = try await Self.measureInsertThroughput(store: synth)
        print("PERF insert 10000-hr-rr-grav-step median_ms=\(String(format: "%.2f", insertMs.median)) p90_ms=\(String(format: "%.2f", insertMs.p90))")

        if let realRange {
            try await Self.benchStore(label: "real", store: real, deviceId: Self.deviceId,
                                      dayFrom: realRange.lo, dayTo: realRange.hi,
                                      weekFrom: realRange.lo, weekTo: realRange.hi,
                                      longFrom: realRange.lo, longTo: realRange.hi)
        }
        try await Self.benchStore(label: "synth", store: synth, deviceId: Self.deviceId,
                                  dayFrom: synthEnd - Self.secondsPerDay + 1, dayTo: synthEnd,
                                  weekFrom: synthEnd - 7 * Self.secondsPerDay + 1, weekTo: synthEnd,
                                  longFrom: Self.synthStart, longTo: synthEnd)
    }

    // MARK: - Seed

    private static func ensureSyntheticDatabase() async throws {
        if FileManager.default.fileExists(atPath: synthPath) {
            let t0 = Date()
            let store = try await WhoopStore(path: synthPath)
            let openS = Date().timeIntervalSince(t0)
            print("PERF synth open+migrate s=\(String(format: "%.3f", openS))")
            let n = try await store.hrFingerprint(deviceId: deviceId, from: 0, to: Int.max).count
            let want = synthDays * secondsPerDay
            if n >= want {
                print("PERF synth already seeded hr=\(n)")
                return
            }
            print("PERF synth resume hr=\(n) want=\(want)")
            try await seedSynthetic(store: store, already: n)
            return
        }
        print("PERF synth seeding \(synthDays) days into \(synthPath)")
        let store = try await WhoopStore(path: synthPath)
        try await seedSynthetic(store: store, already: 0)
    }

    private static func seedSynthetic(store: WhoopStore, already: Int) async throws {
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP 5.0 / MG")
        try await store.upsertWhoop5RegistryForTest(id: deviceId)

        let startDay = already / secondsPerDay
        let t0 = Date()
        for day in startDay..<synthDays {
            let dayStart = synthStart + day * secondsPerDay
            var hr: [HRSample] = []
            var rr: [RRInterval] = []
            var gravity: [GravitySample] = []
            var steps: [StepSample] = []
            hr.reserveCapacity(secondsPerDay)
            rr.reserveCapacity(secondsPerDay)
            gravity.reserveCapacity(secondsPerDay)
            steps.reserveCapacity(secondsPerDay)
            for i in 0..<secondsPerDay {
                let ts = dayStart + i
                let bpm = 55 + (i % 40)
                hr.append(HRSample(ts: ts, bpm: bpm))
                rr.append(RRInterval(ts: ts, rrMs: 60000 / max(bpm, 1),
                                     srcChannel: .whoop5Historical, ord: 0))
                let g = Double(i % 17) * 0.01
                gravity.append(GravitySample(ts: ts, x: g, y: 0.02, z: 0.98))
                steps.append(StepSample(ts: ts, counter: i, activityClass: i % 3))
            }
            _ = try await store.insert(Streams(hr: hr, rr: rr, gravity: gravity, steps: steps),
                                       deviceId: deviceId)

            let dayKey = String(format: "2023-%02d-%02d", (day / 30) % 12 + 1, (day % 28) + 1)
            _ = try await store.upsertSleepSessions([
                CachedSleepSession(startTs: dayStart + 22_000, endTs: dayStart + 50_000,
                                   efficiency: 0.9, restingHr: 52, avgHrv: 60,
                                   stagesJSON: "[{\"start\":0,\"end\":1800,\"stage\":\"light\"}]")
            ], deviceId: deviceId)
            _ = try await store.upsertDailyMetrics([
                DailyMetric(day: dayKey, totalSleepMin: 420, efficiency: 0.9, deepMin: 80,
                            remMin: 90, lightMin: 250, disturbances: 1, restingHr: 52, avgHrv: 60,
                            recovery: 67, strain: 9, exerciseCount: 1, steps: 8000)
            ], deviceId: deviceId)
            _ = try await store.upsertWorkouts([
                WorkoutRow(startTs: dayStart + 60_000, endTs: dayStart + 63_600,
                           sport: "running", source: "whoop", durationS: 3600,
                           energyKcal: 400, avgHr: 140, maxHr: 170, strain: 8,
                           distanceM: 8000, zonesJSON: nil, notes: nil, steps: 9000)
            ], deviceId: deviceId)
            _ = try await store.upsertDerivedSeries(DerivedSeriesRow(
                kind: "stressMinute", day: dayKey, version: 1, computedAt: dayStart,
                payload: Data(repeating: 1, count: 288)))

            if day % 10 == 9 || day == synthDays - 1 {
                let elapsed = Date().timeIntervalSince(t0)
                print("PERF synth seeded day \(day + 1)/\(synthDays) elapsed_s=\(String(format: "%.0f", elapsed))")
            }
        }
        try await store.checkpointWAL()
        let n = try await store.hrFingerprint(deviceId: deviceId, from: 0, to: Int.max).count
        print("PERF synth seed done hr=\(n)")
    }

    // MARK: - Bench

    private static func benchStore(label: String, store: WhoopStore, deviceId: String,
                                   dayFrom: Int, dayTo: Int,
                                   weekFrom: Int, weekTo: Int,
                                   longFrom: Int, longTo: Int) async throws {
        let windows: [(String, Int, Int)] = [
            ("day", dayFrom, dayTo),
            ("week", weekFrom, weekTo),
            ("6mo", longFrom, longTo),
        ]
        for (name, from, to) in windows {
            try await time(label: "\(label).hrSamples.\(name)", runs: timedRuns) {
                _ = try await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: 200_000)
            }
            try await time(label: "\(label).hrBuckets300.\(name)", runs: timedRuns) {
                _ = try await store.hrBuckets(deviceId: deviceId, from: from, to: to, bucketSeconds: 300)
            }
            try await time(label: "\(label).rrIntervals.\(name)", runs: timedRuns) {
                _ = try await store.rrIntervals(deviceId: deviceId, from: from, to: to, limit: 200_000)
            }
            try await time(label: "\(label).gravitySamples.\(name)", runs: timedRuns) {
                _ = try await store.gravitySamples(deviceId: deviceId, from: from, to: to, limit: 200_000)
            }
            try await time(label: "\(label).stepSamples.\(name)", runs: timedRuns) {
                _ = try await store.stepSamples(deviceId: deviceId, from: from, to: to, limit: 200_000)
            }
        }
        try await time(label: "\(label).dailyMetrics", runs: timedRuns) {
            _ = try await store.dailyMetrics(deviceId: deviceId, from: "0000-01-01", to: "9999-12-31")
        }
        try await time(label: "\(label).sleepSessions", runs: timedRuns) {
            _ = try await store.sleepSessions(deviceId: deviceId, from: 0, to: 4_102_444_800, limit: 100)
        }
        try await time(label: "\(label).sleepSessionBounds", runs: timedRuns) {
            _ = try await store.sleepSessionBounds(deviceId: deviceId, from: 0, to: 4_102_444_800)
        }
        try await time(label: "\(label).workouts", runs: timedRuns) {
            _ = try await store.workouts(deviceId: deviceId, from: 0, to: 4_102_444_800, limit: 5000)
        }
        try await time(label: "\(label).derivedSeries", runs: timedRuns) {
            _ = try await store.derivedSeries(kind: "stressMinute", day: "2023-01-01")
        }
    }

    @discardableResult
    private static func time(label: String, runs: Int, body: () async throws -> Void) async throws -> (median: Double, p90: Double) {
        try await body() // warm-up
        var ms: [Double] = []
        ms.reserveCapacity(runs)
        for _ in 0..<runs {
            let t0 = DispatchTime.now().uptimeNanoseconds
            try await body()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
            ms.append(elapsed)
        }
        ms.sort()
        let median = ms[ms.count / 2]
        let p90 = ms[Int((0.9 * Double(ms.count - 1)).rounded(.down))]
        let spread = "min=\(String(format: "%.2f", ms.first!)) max=\(String(format: "%.2f", ms.last!))"
        print("PERF \(label) median_ms=\(String(format: "%.2f", median)) p90_ms=\(String(format: "%.2f", p90)) \(spread) n=\(runs)")
        return (median, p90)
    }

    private static func measureInsertThroughput(store: WhoopStore) async throws -> (median: Double, p90: Double) {
        let base = 3_200_000_000
        return try await time(label: "insert.10k", runs: 3) {
            let offset = Int(DispatchTime.now().uptimeNanoseconds % 1_000_000)
            let start = base + offset * 20_000
            let hr = (0..<10_000).map { HRSample(ts: start + $0, bpm: 60) }
            let rr = (0..<10_000).map {
                RRInterval(ts: start + $0, rrMs: 900, srcChannel: .whoop5Historical, ord: 0)
            }
            let gravity = (0..<10_000).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1) }
            let steps = (0..<10_000).map { StepSample(ts: start + $0, counter: $0, activityClass: 1) }
            _ = try await store.insert(Streams(hr: hr, rr: rr, gravity: gravity, steps: steps),
                                       deviceId: "perf-insert")
        }
    }

    private static func hrRange(store: WhoopStore, deviceId: String) async throws -> (lo: Int, hi: Int, n: Int)? {
        let fp = try await store.hrFingerprint(deviceId: deviceId, from: 0, to: Int.max)
        guard fp.count > 0, fp.maxTs > 0 else { return nil }
        let lo = try await store.minHrTsForTest(deviceId: deviceId)
        return (lo, fp.maxTs, fp.count)
    }

    private static func dumpExplains(store: WhoopStore, deviceId: String, from: Int, to: Int) async throws {
        let complete = WhoopStore.completeHrMinutes(from: from, to: to)
        let firstFull = complete?.first ?? from
        let lastFull = complete?.last ?? to
        let cases: [(String, String, StatementArguments)] = [
            ("hrSamples", """
                SELECT ts, bpm FROM (
                    SELECT ts, bpm FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                    UNION ALL
                    SELECT p.ts, CAST(ROUND(p.bpm) AS INTEGER) AS bpm FROM ppgHrSample p
                    WHERE p.deviceId = ? AND p.ts >= ? AND p.ts <= ?
                      AND NOT EXISTS (
                        SELECT 1 FROM hrSample h
                        WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                )
                ORDER BY ts ASC LIMIT ?
                """, [deviceId, from, to, deviceId, from, to, 200_000]),
            ("hrSamplesFast", """
                SELECT ts, bpm FROM hrSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, [deviceId, from, to, 200_000]),
            ("hrBuckets", """
                SELECT (ts / ?) * ? AS bucket, AVG(bpm) AS avgBpm, MIN(conf) AS minConf,
                       MIN(bpm) AS minBpm, MAX(bpm) AS maxBpm FROM (
                    SELECT ts, bpm, 1.0 AS conf FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                    UNION ALL
                    SELECT p.ts, p.bpm, p.conf FROM ppgHrSample p
                    WHERE p.deviceId = ? AND p.ts >= ? AND p.ts <= ?
                      AND NOT EXISTS (
                        SELECT 1 FROM hrSample h
                        WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                )
                GROUP BY ts / ?
                ORDER BY bucket ASC
                """, [300, 300, deviceId, from, to, deviceId, from, to, 300]),
            ("hrBucketsFast", """
                SELECT (ts / ?) * ? AS bucket, AVG(bpm) AS avgBpm, 1.0 AS minConf,
                       MIN(bpm) AS minBpm, MAX(bpm) AS maxBpm
                FROM hrSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                GROUP BY ts / ?
                ORDER BY 1 ASC
                """, [300, 300, deviceId, from, to, 300]),
            ("hrBucketsMinute", """
                SELECT (src / ?) * ? AS bucket,
                       CAST(SUM(sumBpm) AS REAL) / SUM(n) AS avgBpm,
                       1.0 AS minConf,
                       MIN(minBpm) AS minBpm, MAX(maxBpm) AS maxBpm FROM (
                    SELECT minuteTs AS src, sumBpm, n, minBpm, maxBpm
                    FROM hrMinute
                    WHERE deviceId = ? AND minuteTs >= ? AND minuteTs <= ?
                    UNION ALL
                    SELECT ts, bpm, 1, bpm, bpm
                    FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts < ?
                    UNION ALL
                    SELECT ts, bpm, 1, bpm, bpm
                    FROM hrSample
                    WHERE deviceId = ? AND ts > ? AND ts <= ?
                )
                GROUP BY src / ?
                ORDER BY 1 ASC
                """, [300, 300, deviceId, firstFull, lastFull,
                      deviceId, from, firstFull,
                      deviceId, lastFull + 59, to, 300]),
            ("rrIntervals", """
                SELECT ts, rrMs, srcChannel, ord, seq FROM rrInterval
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                AND (srcChannel IS NULL OR srcChannel <> 2)
                AND (tsSuspect IS NULL OR tsSuspect <> 1)
                ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC LIMIT ?
                """, [deviceId, from, to, 200_000]),
            ("gravitySamples", """
                SELECT ts, x, y, z, dynAccel FROM gravitySample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, [deviceId, from, to, 200_000]),
            ("stepSamples", """
                SELECT ts, counter, activityClass FROM stepSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, [deviceId, from, to, 200_000]),
            ("sleepSessions", """
                SELECT startTs FROM sleepSession
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs ASC LIMIT ?
                """, [deviceId, 0, 4_102_444_800, 100]),
            ("dailyMetrics", """
                SELECT day FROM dailyMetric
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day ASC
                """, [deviceId, "0000-01-01", "9999-12-31"]),
            ("workouts", """
                SELECT startTs FROM workout
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs ASC LIMIT ?
                """, [deviceId, 0, 4_102_444_800, 5000]),
            ("derivedSeries", """
                SELECT kind, day, version, computedAt, payload FROM derivedSeries
                WHERE kind = ? AND day = ?
                """, ["stressMinute", "2023-01-01"]),
        ]
        for (name, sql, args) in cases {
            let plan = try await store.explainQueryPlanForTest(sql, arguments: args)
            print("PERF EXPLAIN \(name)\n\(plan)")
        }
    }
}

extension WhoopStore {
    func explainQueryPlanForTest(_ sql: String, arguments: StatementArguments) throws -> String {
        try syncRead { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
                .map { row in
                    if let detail: String = row["detail"] { return detail }
                    let cols = row.count
                    return (0..<cols).map { String(describing: row[$0] as DatabaseValue) }
                        .joined(separator: " | ")
                }
                .joined(separator: "\n")
        }
    }

    func minHrTsForTest(deviceId: String) throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(MIN(ts), 0) FROM hrSample WHERE deviceId = ?",
                             arguments: [deviceId]) ?? 0
        }
    }

    func hrMinuteCountForTest(deviceId: String) throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrMinute WHERE deviceId = ?",
                             arguments: [deviceId]) ?? 0
        }
    }
}

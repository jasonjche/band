import Foundation
import GRDB
import WhoopProtocol
import XCTest
@testable import WhoopStore

/// Frozen pre-optimization SQL vs the public read APIs. Results must be identical
/// (same rows, same order, bucket values within 1e-9).
final class ReadCorrectnessTests: XCTestCase {

    private let deviceId = "perf-correctness"

    func testPublicReadsMatchFrozenSQLOnMixedSynthetic() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP 5.0 / MG")
        try await store.upsertWhoop5RegistryForTest(id: deviceId)

        let start = 1_700_000_000
        let seconds = 7_200 // 2 hours of 1 Hz, small enough for every CI run
        var hr: [HRSample] = []
        var ppg: [PpgHrSample] = []
        var rr: [RRInterval] = []
        var gravity: [GravitySample] = []
        var steps: [StepSample] = []
        hr.reserveCapacity(seconds)
        for i in 0..<seconds {
            let ts = start + i
            if i % 17 == 0 {
                // PPG-only second: exercises the anti-join arm of the union.
                ppg.append(PpgHrSample(ts: ts, bpm: 70 + (i % 5), conf: 0.42))
            } else {
                hr.append(HRSample(ts: ts, bpm: 55 + (i % 40)))
            }
            rr.append(RRInterval(ts: ts, rrMs: 800 + (i % 30),
                                 srcChannel: .whoop5Historical, ord: 0))
            if i % 50 == 0 {
                rr.append(RRInterval(ts: ts, rrMs: 500, srcChannel: .spo2Ibi, ord: 1))
            }
            gravity.append(GravitySample(ts: ts, x: 0.01, y: 0.02, z: 0.98, dynAccel: 0.003))
            steps.append(StepSample(ts: ts, counter: i, activityClass: i % 3))
        }
        _ = try await store.insert(Streams(hr: hr, rr: rr, gravity: gravity, steps: steps, ppgHr: ppg),
                                   deviceId: deviceId)

        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: start + 100, endTs: start + 4000,
                               efficiency: 0.91, restingHr: 51, avgHrv: 62,
                               stagesJSON: "[]", userEdited: false)
        ], deviceId: deviceId)
        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: "2023-11-14", totalSleepMin: 400, efficiency: 0.91, deepMin: 70,
                        remMin: 80, lightMin: 250, disturbances: 2, restingHr: 51, avgHrv: 62,
                        recovery: 70, strain: 8.5, exerciseCount: 1, steps: 1234)
        ], deviceId: deviceId)
        _ = try await store.upsertWorkouts([
            WorkoutRow(startTs: start + 5000, endTs: start + 6000, sport: "running",
                       source: "whoop", durationS: 1000, energyKcal: 200, avgHr: 140, maxHr: 170,
                       strain: 7, distanceM: 3000, zonesJSON: nil, notes: nil, steps: 4000)
        ], deviceId: deviceId)
        _ = try await store.upsertDerivedSeries(DerivedSeriesRow(
            kind: "stressMinute", day: "2023-11-14", version: 3, computedAt: start,
            payload: Data([0, 1, 2, 3, 4])))

        let from = start
        let to = start + seconds - 1

        let newHR = try await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: 200_000)
        let oldHR = try await store.legacyHrSamplesForTest(deviceId: deviceId, from: from, to: to, limit: 200_000)
        XCTAssertEqual(newHR, oldHR)

        let newBuckets = try await store.hrBuckets(deviceId: deviceId, from: from, to: to, bucketSeconds: 60)
        let oldBuckets = try await store.legacyHrBucketsForTest(deviceId: deviceId, from: from, to: to, bucket: 60)
        XCTAssertEqual(newBuckets.count, oldBuckets.count)
        for (a, b) in zip(newBuckets, oldBuckets) {
            XCTAssertEqual(a.ts, b.ts)
            XCTAssertEqual(a.bpm, b.bpm, accuracy: 1e-9)
            XCTAssertEqual(a.minBpm, b.minBpm, accuracy: 1e-9)
            XCTAssertEqual(a.maxBpm, b.maxBpm, accuracy: 1e-9)
            XCTAssertEqual(a.conf, b.conf, accuracy: 1e-9)
        }

        let newRR = try await store.rrIntervals(deviceId: deviceId, from: from, to: to, limit: 200_000)
        let oldRR = try await store.legacyRrIntervalsForTest(deviceId: deviceId, from: from, to: to, limit: 200_000)
        XCTAssertEqual(newRR, oldRR)
        XCTAssertFalse(newRR.contains { $0.srcChannel == .spo2Ibi })

        let newG = try await store.gravitySamples(deviceId: deviceId, from: from, to: to, limit: 200_000)
        let oldG = try await store.legacyGravityForTest(deviceId: deviceId, from: from, to: to, limit: 200_000)
        XCTAssertEqual(newG, oldG)

        let newS = try await store.stepSamples(deviceId: deviceId, from: from, to: to, limit: 200_000)
        let oldS = try await store.legacyStepsForTest(deviceId: deviceId, from: from, to: to, limit: 200_000)
        XCTAssertEqual(newS, oldS)

        let newSleep = try await store.sleepSessions(deviceId: deviceId, from: from, to: to, limit: 100)
        XCTAssertEqual(newSleep.count, 1)
        XCTAssertEqual(newSleep[0].startTs, start + 100)
        XCTAssertEqual(newSleep[0].endTs, start + 4000)

        let newDaily = try await store.dailyMetrics(deviceId: deviceId, from: "2023-11-14", to: "2023-11-14")
        XCTAssertEqual(newDaily.count, 1)
        XCTAssertEqual(newDaily[0].steps, 1234)

        let newWO = try await store.workouts(deviceId: deviceId, from: from, to: to, limit: 50)
        XCTAssertEqual(newWO.count, 1)
        XCTAssertEqual(newWO[0].sport, "running")

        let series = try await store.derivedSeries(kind: "stressMinute", day: "2023-11-14", version: 3)
        XCTAssertEqual(series?.payload, Data([0, 1, 2, 3, 4]))
    }
}

extension WhoopStore {
    func upsertWhoop5RegistryForTest(id: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO pairedDevice (id, brand, model, nickname, sourceKind, capabilities, status, addedAt, lastSeenAt)
                VALUES (?, 'WHOOP', 'WHOOP 5.0 / MG', NULL, 'liveBLE', 'hr,hrv,skinTemp,sleep,strainLoad', 'active', ?, ?)
                ON CONFLICT(id) DO UPDATE SET model = excluded.model, brand = excluded.brand, status = 'active'
                """, arguments: [id, now, now])
        }
    }

    /// Frozen SQL from Reads.hrSamples before the v51 read-path rewrite.
    func legacyHrSamplesForTest(deviceId: String, from: Int, to: Int, limit: Int) throws -> [HRSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
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
                """, arguments: [deviceId, from, to, deviceId, from, to, limit])
            .map { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
        }
    }

    func legacyHrBucketsForTest(deviceId: String, from: Int, to: Int, bucket: Int) throws -> [HRBucket] {
        let b = max(1, bucket)
        return try syncRead { db in
            try Row.fetchAll(db, sql: """
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
                """, arguments: [b, b, deviceId, from, to, deviceId, from, to, b])
            .map { HRBucket(ts: $0["bucket"], bpm: $0["avgBpm"],
                            minBpm: $0["minBpm"], maxBpm: $0["maxBpm"],
                            conf: $0["minConf"] ?? 1.0) }
        }
    }

    /// Frozen WHOOP 5 branch of `rrIntervals` (scorable channels 5 and 7, spo2Ibi excluded).
    func legacyRrIntervalsForTest(deviceId: String, from: Int, to: Int, limit: Int) throws -> [RRInterval] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, rrMs, srcChannel, ord, seq FROM rrInterval
                WHERE deviceId = :d AND ts >= :f AND ts <= :t
                AND (srcChannel IS NULL OR srcChannel <> :rrx)
                AND srcChannel = (SELECT MIN(srcChannel) FROM rrInterval
                    WHERE deviceId = :d AND ts >= :f AND ts <= :t AND srcChannel IN (5, 7)
                    AND (tsSuspect IS NULL OR tsSuspect <> 1))
                AND (tsSuspect IS NULL OR tsSuspect <> 1)
                ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC LIMIT :lim
                """, arguments: ["d": deviceId, "f": from, "t": to,
                                 "rrx": RRSourceChannel.spo2Ibi.rawValue, "lim": limit])
            .map { row in
                RRInterval(ts: row["ts"], rrMs: row["rrMs"],
                           srcChannel: (row["srcChannel"] as Int?).flatMap(RRSourceChannel.init(rawValue:)),
                           ord: row["ord"] as Int?, seq: row["seq"])
            }
        }
    }

    func legacyGravityForTest(deviceId: String, from: Int, to: Int, limit: Int) throws -> [GravitySample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, x, y, z, dynAccel FROM gravitySample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
            .map { GravitySample(ts: $0["ts"], x: $0["x"], y: $0["y"], z: $0["z"],
                                 dynAccel: $0["dynAccel"]) }
        }
    }

    func legacyStepsForTest(deviceId: String, from: Int, to: Int, limit: Int) throws -> [StepSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, counter, activityClass FROM stepSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
            .map { StepSample(ts: $0["ts"], counter: $0["counter"], activityClass: $0["activityClass"]) }
        }
    }
}

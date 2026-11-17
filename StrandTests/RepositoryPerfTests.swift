import XCTest
import Foundation
import WhoopStore
import WhoopProtocol
@testable import Strand

/// Band-library perf: no-op `refreshSeq`, bucketed HR, parsed stage/zone cache.
@MainActor
final class RepositoryPerfTests: XCTestCase {

    private let dev = "my-whoop"

    private func seededRepo() async throws -> (Repository, Int) {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        let now = Int(Date().timeIntervalSince1970)
        let day = Repository.localDayKey(Date())
        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 80,
                        remMin: 90, lightMin: 250, disturbances: 1, restingHr: 52, avgHrv: 60,
                        recovery: 67, strain: 9, exerciseCount: 1)
        ], deviceId: dev)
        let stages = "[{\"start\":0,\"end\":1800,\"stage\":\"light\"},{\"start\":1800,\"end\":3600,\"stage\":\"deep\"}]"
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: now - 8 * 3600, endTs: now, efficiency: 0.9,
                               restingHr: 52, avgHrv: 60, stagesJSON: stages)
        ], deviceId: dev)
        _ = try await store.upsertWorkouts([
            WorkoutRow(startTs: now - 3600, endTs: now, sport: "running", source: "whoop",
                       durationS: 3600, energyKcal: 400, avgHr: 140, maxHr: 170, strain: 8,
                       distanceM: 8000,
                       zonesJSON: "{\"z1\":10,\"z2\":20,\"z3\":40,\"z4\":20,\"z5\":10}",
                       notes: nil, steps: 9000)
        ], deviceId: dev)
        let hr = (0..<3_600).map { HRSample(ts: now + $0, bpm: 60 + $0 % 20) }
        _ = try await store.insert(Streams(hr: hr), deviceId: dev)
        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)
        return (repo, now)
    }

    func testRefreshSeqDoesNotBumpWhenCachesAreUnchanged() async throws {
        let (repo, _) = try await seededRepo()
        await repo.refresh(days: 10)
        XCTAssertTrue(repo.loaded)
        let seq = repo.refreshSeq
        XCTAssertGreaterThan(seq, 0)
        await repo.refresh(days: 10)
        XCTAssertEqual(repo.refreshSeq, seq, "a no-op refresh must not bump refreshSeq")
        await repo.refresh(days: 10)
        XCTAssertEqual(repo.refreshSeq, seq)
    }

    func testHrSamplesBucketSecondsReturnsSqlBucketsNotRawRows() async throws {
        let (repo, now) = try await seededRepo()
        let raw = await repo.hrSamples(from: now, to: now + 3_599, limit: 100_000)
        XCTAssertEqual(raw.count, 3_600)
        let buckets = await repo.hrSamples(from: now, to: now + 3_599, bucketSeconds: 300)
        let expectedBuckets = ((now + 3_599) / 300) - (now / 300) + 1
        XCTAssertEqual(buckets.count, expectedBuckets)
        XCTAssertEqual(buckets.first?.ts, (now / 300) * 300)
        XCTAssertGreaterThan(buckets.first?.bpm ?? 0, 0)
        XCTAssertGreaterThan(buckets.first?.maxBpm ?? 0, 0)
    }

    func testParsedStagesAndZonesHitPerRowCache() async throws {
        let (repo, _) = try await seededRepo()
        await repo.refresh(days: 10)
        let session = try XCTUnwrap(repo.sleeps.first)
        let stages = repo.parsedStages(for: session)
        XCTAssertEqual(stages.count, 2)
        XCTAssertEqual(stages[0].stage, "light")
        XCTAssertEqual(stages[1].stage, "deep")
        XCTAssertEqual(repo.parsedStages(for: session), stages)

        let workouts = await repo.workoutRows(days: 2)
        let row = try XCTUnwrap(workouts.first)
        let zones = try XCTUnwrap(repo.parsedZones(for: row))
        XCTAssertEqual(zones.count, 5)
        XCTAssertEqual(zones[2], 40, accuracy: 0.01)
        XCTAssertEqual(repo.parsedZones(for: row), zones)
    }
}

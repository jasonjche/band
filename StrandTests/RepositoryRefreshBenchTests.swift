import XCTest
import Foundation
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Incremental `Repository.refresh()` vs the kept full-reload path, plus offload-chunk coalesce.
@MainActor
final class RepositoryRefreshBenchTests: XCTestCase {

    private let dev = "my-whoop"

    func testIncrementalRefreshMatchesFullReloadAfterOneDayChange() async throws {
        let (repo, store, today) = try await seededRepo()
        await repo.refreshFull(days: 400)
        XCTAssertTrue(repo.loaded)
        XCTAssertGreaterThan(repo.days.count, 300)
        XCTAssertGreaterThan(repo.sleeps.count, 300)

        let changed = DailyMetric(day: today, totalSleepMin: 390, efficiency: 0.88, deepMin: 70,
                                  remMin: 85, lightMin: 235, disturbances: 2, restingHr: 54, avgHrv: 58,
                                  recovery: 61, strain: 11, exerciseCount: 1)
        _ = try await store.upsertDailyMetrics([changed], deviceId: dev)

        let loadsBefore = repo.refreshStoreLoadCount
        await repo.refresh(days: 400)
        XCTAssertTrue(repo.lastRefreshUsedIncremental)
        XCTAssertEqual(repo.refreshStoreLoadCount, loadsBefore + 1)
        let incremental = Snapshot(repo)

        await repo.refreshFull(days: 400)
        let full = Snapshot(repo)
        XCTAssertEqual(incremental.days, full.days)
        XCTAssertEqual(incremental.sleeps, full.sleeps)
        XCTAssertEqual(incremental.importedSleep, full.importedSleep)
        XCTAssertEqual(incremental.vitalRows, full.vitalRows)
        XCTAssertEqual(incremental.freshness, full.freshness)
        XCTAssertEqual(incremental.chargeBaselines, full.chargeBaselines)
    }

    func testUnchangedRevisionSkipsStoreReload() async throws {
        let (repo, _, _) = try await seededRepo()
        await repo.refresh(days: 400)
        let loads = repo.refreshStoreLoadCount
        let seq = repo.refreshSeq
        let performs = repo.refreshPerformCount
        await repo.refresh(days: 400)
        XCTAssertEqual(repo.refreshStoreLoadCount, loads)
        XCTAssertEqual(repo.refreshSeq, seq)
        XCTAssertEqual(repo.refreshPerformCount, performs + 1)
        XCTAssertFalse(repo.lastRefreshUsedIncremental)
    }

    func testOffloadChunkBurstCoalescesToOneOrTwoStoreLoads() async throws {
        let (repo, store, today) = try await seededRepo()
        await repo.refresh(days: 400)
        let loadsBefore = repo.refreshStoreLoadCount
        let skipsBefore = repo.refreshCoalesceSkipCount

        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: today, totalSleepMin: 410, efficiency: 0.91, deepMin: 82,
                        remMin: 88, lightMin: 240, disturbances: 1, restingHr: 51, avgHrv: 62,
                        recovery: 70, strain: 10, exerciseCount: 1)
        ], deviceId: dev)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { @MainActor in
                    await repo.refresh(days: 400)
                }
            }
        }

        let loads = repo.refreshStoreLoadCount - loadsBefore
        XCTAssertGreaterThanOrEqual(loads, 1)
        XCTAssertLessThanOrEqual(loads, 2, "12 overlapping refresh() calls must coalesce; got \(loads) store loads")
        XCTAssertGreaterThanOrEqual(repo.refreshCoalesceSkipCount - skipsBefore, 8)
        XCTAssertEqual(repo.days.last?.recovery, 70)
    }

    func testRefreshFullStaysCallableForABTiming() async throws {
        let (repo, store, today) = try await seededRepo()
        await repo.refreshFull(days: 400)

        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: today, totalSleepMin: 401, efficiency: 0.9, deepMin: 80,
                        remMin: 90, lightMin: 231, disturbances: 1, restingHr: 52, avgHrv: 60,
                        recovery: 65, strain: 9, exerciseCount: 1)
        ], deviceId: dev)
        let incStart = ContinuousClock.now
        await repo.refresh(days: 400)
        let incElapsed = ContinuousClock.now - incStart
        XCTAssertTrue(repo.lastRefreshUsedIncremental)

        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: today, totalSleepMin: 402, efficiency: 0.9, deepMin: 80,
                        remMin: 90, lightMin: 232, disturbances: 1, restingHr: 52, avgHrv: 60,
                        recovery: 64, strain: 9, exerciseCount: 1)
        ], deviceId: dev)
        let fullStart = ContinuousClock.now
        await repo.refreshFull(days: 400)
        let fullElapsed = ContinuousClock.now - fullStart

        print("RepositoryRefreshBench incremental=\(incElapsed) full=\(fullElapsed)")
        XCTAssertTrue(repo.loaded)
        XCTAssertGreaterThan(incElapsed, Duration.zero)
        XCTAssertGreaterThan(fullElapsed, Duration.zero)
    }

    // MARK: - Seed

    private struct Snapshot: Equatable {
        let days: [DailyMetric]
        let sleeps: [CachedSleepSession]
        let importedSleep: [String: ImportedSleepFigures]
        let vitalRows: [SourcedDailyMetric]
        let freshness: RepositoryFreshness
        let chargeBaselines: ChargeBaselines.Resolved?
        init(_ repo: Repository) {
            days = repo.days
            sleeps = repo.sleeps
            importedSleep = repo.importedSleep
            vitalRows = repo.vitalRows
            freshness = repo.freshness
            chargeBaselines = repo.chargeBaselines
        }
    }

    private func seededRepo() async throws -> (Repository, WhoopStore, String) {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        let cal = Calendar(identifier: .gregorian)
        let todayDate = Date()
        let today = Repository.localDayKey(todayDate)
        var dailies: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        var workouts: [WorkoutRow] = []
        var journal: [JournalEntry] = []
        dailies.reserveCapacity(365)
        sleeps.reserveCapacity(400)
        workouts.reserveCapacity(300)
        journal.reserveCapacity(365)
        let stages = Self.stagesJSON
        for back in 0..<365 {
            guard let day = cal.date(byAdding: .day, value: -back, to: todayDate) else { continue }
            let key = Repository.localDayKey(day)
            dailies.append(DailyMetric(
                day: key, totalSleepMin: 400 + Double(back % 40), efficiency: 0.9,
                deepMin: 80, remMin: 90, lightMin: 230, disturbances: back % 3,
                restingHr: 50 + back % 8, avgHrv: 55 + Double(back % 20),
                recovery: 60 + Double(back % 25), strain: 8 + Double(back % 7),
                exerciseCount: back % 2))
            let end = Int(day.timeIntervalSince1970) + 7 * 3600
            let start = end - 8 * 3600
            sleeps.append(CachedSleepSession(
                startTs: start, endTs: end, efficiency: 0.9, restingHr: 52,
                avgHrv: 60, stagesJSON: stages))
            if back < 35 {
                sleeps.append(CachedSleepSession(
                    startTs: start - 4 * 3600, endTs: start - 2 * 3600, efficiency: 0.7,
                    restingHr: 55, avgHrv: 50, stagesJSON: stages))
            }
            if back < 300 {
                workouts.append(WorkoutRow(
                    startTs: start - 3600, endTs: start, sport: "running", source: "whoop",
                    durationS: 3600, energyKcal: 400, avgHr: 140, maxHr: 170, strain: 8,
                    distanceM: 8000, zonesJSON: "{\"z1\":10,\"z2\":20,\"z3\":40,\"z4\":20,\"z5\":10}",
                    notes: nil, steps: 9000))
            }
            journal.append(JournalEntry(day: key, question: "Alcohol?", answeredYes: back % 4 == 0,
                                        notes: nil, numericValue: nil))
        }
        _ = try await store.upsertDailyMetrics(dailies, deviceId: dev)
        _ = try await store.upsertSleepSessions(sleeps, deviceId: dev)
        _ = try await store.upsertWorkouts(workouts, deviceId: dev)
        _ = try await store.upsertJournal(journal, deviceId: dev)
        _ = try await store.upsertMetricSeries(
            dailies.prefix(100).map { MetricPoint(day: $0.day, key: "sleep_performance", value: 80) },
            deviceId: dev)
        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)
        return (repo, store, today)
    }

    private static let stagesJSON: String = {
        let parts = (0..<16).map { i -> String in
            let stage = ["light", "deep", "rem", "awake"][i % 4]
            return "{\"start\":\(i * 1800),\"end\":\((i + 1) * 1800),\"stage\":\"\(stage)\"}"
        }
        return "[\(parts.joined(separator: ","))]"
    }()
}

@MainActor
final class LaunchHistoryPassGateTests: XCTestCase {
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        let keys = [
            IntelligenceEngine.timestampHealFlagKey,
            IntelligenceEngine.timestampHealPendingKey,
            IntelligenceEngine.effortRescoreFlagKey,
            IntelligenceEngine.sleepWearRescoreFlagKey
        ]
        let d = UserDefaults.standard
        for key in keys { saved[key] = d.object(forKey: key) }
    }

    override func tearDown() {
        let d = UserDefaults.standard
        for (key, value) in saved {
            if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        }
        saved.removeAll()
        super.tearDown()
    }

    func testLaunchHistoryPassesArePendingWhenFlagsUnset() {
        let d = UserDefaults.standard
        d.removeObject(forKey: IntelligenceEngine.timestampHealFlagKey)
        d.removeObject(forKey: IntelligenceEngine.timestampHealPendingKey)
        d.removeObject(forKey: IntelligenceEngine.effortRescoreFlagKey)
        d.removeObject(forKey: IntelligenceEngine.sleepWearRescoreFlagKey)
        XCTAssertTrue(IntelligenceEngine.launchHistoryPassesArePending())
    }

    func testLaunchHistoryPassesSkipWhenFingerprintsAreSet() {
        let d = UserDefaults.standard
        d.set(true, forKey: IntelligenceEngine.timestampHealFlagKey)
        d.set(false, forKey: IntelligenceEngine.timestampHealPendingKey)
        d.set(true, forKey: IntelligenceEngine.effortRescoreFlagKey)
        d.set(true, forKey: IntelligenceEngine.sleepWearRescoreFlagKey)
        XCTAssertFalse(IntelligenceEngine.launchHistoryPassesArePending())
    }

    func testRehealPendingOverridesDoneFlag() {
        let d = UserDefaults.standard
        d.set(true, forKey: IntelligenceEngine.timestampHealFlagKey)
        d.set(true, forKey: IntelligenceEngine.timestampHealPendingKey)
        d.set(true, forKey: IntelligenceEngine.effortRescoreFlagKey)
        d.set(true, forKey: IntelligenceEngine.sleepWearRescoreFlagKey)
        XCTAssertTrue(IntelligenceEngine.launchHistoryPassesArePending())
    }
}

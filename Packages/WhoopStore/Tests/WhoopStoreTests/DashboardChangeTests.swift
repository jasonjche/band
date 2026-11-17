import XCTest
@testable import WhoopStore

final class DashboardChangeTests: XCTestCase {
    func testRevisionStaysZeroUntilADashboardWrite() async throws {
        let store = try await WhoopStore.inMemory()
        let rev = await store.dashboardRevision()
        XCTAssertEqual(rev, 0)
        let peek = await store.peekDashboardChanges()
        XCTAssertEqual(peek.revision, 0)
        XCTAssertTrue(peek.days.isEmpty)
        XCTAssertFalse(peek.forceFull)
    }

    func testDailyUpsertRecordsTouchedDaysAndTakeClearsDelta() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-11-16"
        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 80,
                        remMin: 90, lightMin: 250, disturbances: 1, restingHr: 52, avgHrv: 60,
                        recovery: 67, strain: 9, exerciseCount: 0)
        ], deviceId: "dev")
        let rev = await store.dashboardRevision()
        XCTAssertEqual(rev, 1)
        let peek = await store.peekDashboardChanges()
        XCTAssertEqual(peek.days, [day])
        XCTAssertTrue(peek.isIncremental)
        let taken = await store.takeDashboardChanges()
        XCTAssertEqual(taken.days, [day])
        let after = await store.peekDashboardChanges()
        XCTAssertEqual(after.days, [])
        let revAfter = await store.dashboardRevision()
        XCTAssertEqual(revAfter, 1)
    }

    func testHydrationMetricSeriesDoesNotBumpDashboardRevision() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: "2026-11-16", key: "hydration_ml", value: 500)
        ], deviceId: "dev")
        let rev0 = await store.dashboardRevision()
        XCTAssertEqual(rev0, 0)
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: "2026-11-16", key: "sleep_performance", value: 82)
        ], deviceId: "dev")
        let rev1 = await store.dashboardRevision()
        XCTAssertEqual(rev1, 1)
        let peek = await store.peekDashboardChanges()
        XCTAssertEqual(peek.days, ["2026-11-16"])
    }

    func testWideDeleteForcesFullReload() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: "2020-01-01", totalSleepMin: 400, efficiency: 0.9, deepMin: 80,
                        remMin: 90, lightMin: 230, disturbances: 0, restingHr: 50, avgHrv: 55,
                        recovery: 60, strain: 8, exerciseCount: 0),
            DailyMetric(day: "2026-11-16", totalSleepMin: 400, efficiency: 0.9, deepMin: 80,
                        remMin: 90, lightMin: 230, disturbances: 0, restingHr: 50, avgHrv: 55,
                        recovery: 60, strain: 8, exerciseCount: 0)
        ], deviceId: "dev")
        _ = try await store.deleteDailyMetrics(deviceId: "dev", from: "2020-01-01", to: "2026-11-16")
        let peek = await store.peekDashboardChanges()
        XCTAssertTrue(peek.forceFull)
        XCTAssertFalse(peek.isIncremental)
    }
}

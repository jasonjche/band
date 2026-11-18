import XCTest
import GRDB
@testable import WhoopStore

final class DerivedSeriesStoreTests: XCTestCase {

    func testV50CreatesDerivedSeriesTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("derivedSeries"))

        let pk = try await store.primaryKeyColumns("derivedSeries")
        XCTAssertEqual(pk, ["kind", "day"])

        let cols = try await store.columnNamesForTest(table: "derivedSeries")
        for c in ["kind", "day", "version", "computedAt", "payload"] {
            XCTAssertTrue(cols.contains(c), "derivedSeries missing column \(c)")
        }
    }

    func testV50IsAdditive() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "sleepSession", "dailyMetric",
                  "workout", "appleStepHour", "metricSeries"] {
            XCTAssertTrue(tables.contains(t), "v50 must not drop \(t)")
        }
    }

    func testUpsertReadAndVersionMiss() async throws {
        let store = try await WhoopStore.inMemory()
        let payload = Data([1, 2, 3, 4])
        let row = DerivedSeriesRow(
            kind: "stressMinute", day: "2026-11-14", version: 1,
            computedAt: 1_700_000_000, payload: payload
        )
        let changed = try await store.upsertDerivedSeries(row)
        XCTAssertEqual(changed, 1)

        let read = try await store.derivedSeries(kind: "stressMinute", day: "2026-11-14")
        XCTAssertEqual(read, row)
        let bytes = try await store.derivedSeriesPayloadBytes(kind: "stressMinute", day: "2026-11-14")
        XCTAssertEqual(bytes, 4)

        let current = try await store.derivedSeries(kind: "stressMinute", day: "2026-11-14", version: 1)
        XCTAssertEqual(current, row)
        let stale = try await store.derivedSeries(kind: "stressMinute", day: "2026-11-14", version: 2)
        XCTAssertNil(stale)
        let missing = try await store.derivedSeries(kind: "overnightHR", day: "2026-11-14")
        XCTAssertNil(missing)
    }

    func testUpsertReplacesPayloadInPlace() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDerivedSeries(DerivedSeriesRow(
            kind: "hourlySteps", day: "2026-11-14", version: 1,
            computedAt: 10, payload: Data([1])
        ))
        try await store.upsertDerivedSeries(DerivedSeriesRow(
            kind: "hourlySteps", day: "2026-11-14", version: 2,
            computedAt: 20, payload: Data([9, 8, 7])
        ))
        let read = try await store.derivedSeries(kind: "hourlySteps", day: "2026-11-14")
        XCTAssertEqual(read?.version, 2)
        XCTAssertEqual(read?.computedAt, 20)
        XCTAssertEqual(read?.payload, Data([9, 8, 7]))
    }

    func testKindsPartitionIndependently() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDerivedSeries(DerivedSeriesRow(
            kind: "stressMinute", day: "2026-11-14", version: 1,
            computedAt: 1, payload: Data([1])
        ))
        try await store.upsertDerivedSeries(DerivedSeriesRow(
            kind: "overnightHR", day: "2026-11-14", version: 1,
            computedAt: 1, payload: Data([2])
        ))
        let stress = try await store.derivedSeries(kind: "stressMinute", day: "2026-11-14")
        let overnight = try await store.derivedSeries(kind: "overnightHR", day: "2026-11-14")
        XCTAssertEqual(stress?.payload, Data([1]))
        XCTAssertEqual(overnight?.payload, Data([2]))
    }
}

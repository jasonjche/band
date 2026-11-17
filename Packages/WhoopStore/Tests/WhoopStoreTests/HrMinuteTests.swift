import Foundation
import GRDB
import WhoopProtocol
import XCTest
@testable import WhoopStore

/// v52 `hrMinute` rollup: exact `hrBuckets` equivalence vs the frozen 1 Hz GROUP BY,
/// incremental insert (RETURNING so re-ingest does not double-count), and PPG hybrid.
final class HrMinuteTests: XCTestCase {

    private func assertBucketsEqual(_ got: [HRBucket], _ want: [HRBucket], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, want.count, "bucket count", file: file, line: line)
        for (a, b) in zip(got, want) {
            XCTAssertEqual(a.ts, b.ts, "bucket ts", file: file, line: line)
            XCTAssertEqual(a.bpm, b.bpm, accuracy: 1e-9, "mean bpm at \(a.ts)", file: file, line: line)
            XCTAssertEqual(a.minBpm, b.minBpm, accuracy: 1e-9, "min bpm at \(a.ts)", file: file, line: line)
            XCTAssertEqual(a.maxBpm, b.maxBpm, accuracy: 1e-9, "max bpm at \(a.ts)", file: file, line: line)
            XCTAssertEqual(a.conf, b.conf, accuracy: 1e-9, "conf at \(a.ts)", file: file, line: line)
        }
    }

    func testIncrementalInsertMatchesRawBucketsAndDoesNotDoubleCount() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        // Unaligned start (ts 100) so edge minutes are partial for a 60s bucket.
        let first = (0..<130).map { HRSample(ts: 100 + $0, bpm: 55 + ($0 % 40)) }
        let n1 = try await store.insert(Streams(hr: first), deviceId: "dev")
        XCTAssertEqual(n1.hr, 130)

        let from = 100
        let to = 229
        for bucket in [60, 300, 3600] {
            let got = try await store.hrBuckets(deviceId: "dev", from: from, to: to, bucketSeconds: bucket)
            let want = try await store.legacyHrBucketsForTest(deviceId: "dev", from: from, to: to, bucket: bucket)
            assertBucketsEqual(got, want)
        }

        let dup = try await store.insert(Streams(hr: first), deviceId: "dev")
        XCTAssertEqual(dup.hr, 0, "ON CONFLICT DO NOTHING must insert nothing")
        let afterDup = try await store.hrBuckets(deviceId: "dev", from: from, to: to, bucketSeconds: 60)
        let wantDup = try await store.legacyHrBucketsForTest(deviceId: "dev", from: from, to: to, bucket: 60)
        assertBucketsEqual(afterDup, wantDup)

        let extra = (130..<200).map { HRSample(ts: 100 + $0, bpm: 90) }
        let n2 = try await store.insert(Streams(hr: extra), deviceId: "dev")
        XCTAssertEqual(n2.hr, 70)
        let afterExtra = try await store.hrBuckets(deviceId: "dev", from: from, to: 299, bucketSeconds: 60)
        let wantExtra = try await store.legacyHrBucketsForTest(deviceId: "dev", from: from, to: 299, bucket: 60)
        assertBucketsEqual(afterExtra, wantExtra)
    }

    func testNonMultipleOf60UsesRawAndStillMatches() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        let hr = (0..<400).map { HRSample(ts: $0, bpm: 60 + ($0 % 7)) }
        _ = try await store.insert(Streams(hr: hr), deviceId: "dev")
        let got = try await store.hrBuckets(deviceId: "dev", from: 0, to: 399, bucketSeconds: 100)
        let want = try await store.legacyHrBucketsForTest(deviceId: "dev", from: 0, to: 399, bucket: 100)
        assertBucketsEqual(got, want)
    }

    func testPpgHybridMatchesRawUnion() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        var hr: [HRSample] = []
        var ppg: [PpgHrSample] = []
        for i in 0..<600 {
            let ts = 1_700_000_000 + i
            if i % 17 == 0 {
                ppg.append(PpgHrSample(ts: ts, bpm: 70 + (i % 5), conf: 0.42))
            } else {
                hr.append(HRSample(ts: ts, bpm: 55 + (i % 40)))
            }
        }
        _ = try await store.insert(Streams(hr: hr, ppgHr: ppg), deviceId: "dev")
        let from = 1_700_000_000
        let to = from + 599
        for bucket in [60, 300] {
            let got = try await store.hrBuckets(deviceId: "dev", from: from, to: to, bucketSeconds: bucket)
            let want = try await store.legacyHrBucketsForTest(deviceId: "dev", from: from, to: to, bucket: bucket)
            assertBucketsEqual(got, want)
        }
    }

    func testUnalignedWindowPartialMinutes() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        // Dense 1 Hz across several minutes; window cuts both edges.
        let hr = (0..<500).map { HRSample(ts: 1_000 + $0, bpm: 50 + ($0 % 13)) }
        _ = try await store.insert(Streams(hr: hr), deviceId: "dev")
        let from = 1_010
        let to = 1_447
        XCTAssertNotNil(WhoopStore.completeHrMinutes(from: from, to: to))
        let got = try await store.hrBuckets(deviceId: "dev", from: from, to: to, bucketSeconds: 60)
        let want = try await store.legacyHrBucketsForTest(deviceId: "dev", from: from, to: to, bucket: 60)
        assertBucketsEqual(got, want)
        let got5 = try await store.hrBuckets(deviceId: "dev", from: from, to: to, bucketSeconds: 300)
        let want5 = try await store.legacyHrBucketsForTest(deviceId: "dev", from: from, to: to, bucket: 300)
        assertBucketsEqual(got5, want5)
    }

    func testShortWindowFallsBackToRaw() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        let hr = (0..<40).map { HRSample(ts: 10 + $0, bpm: 70) }
        _ = try await store.insert(Streams(hr: hr), deviceId: "dev")
        XCTAssertNil(WhoopStore.completeHrMinutes(from: 10, to: 49))
        let got = try await store.hrBuckets(deviceId: "dev", from: 10, to: 49, bucketSeconds: 60)
        let want = try await store.legacyHrBucketsForTest(deviceId: "dev", from: 10, to: 49, bucket: 60)
        assertBucketsEqual(got, want)
    }

    func testHealDropsImplausibleMinuteRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        let now = 1_750_000_000
        let farPast = 1_250_000_000
        _ = try await store.insert(Streams(hr: [
            HRSample(ts: now - 60, bpm: 55),
            HRSample(ts: farPast, bpm: 99),
        ]), deviceId: "dev")
        _ = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: "2025-06-15")
        let minutes = try await store.hrMinuteRowsForTest(deviceId: "dev")
        XCTAssertEqual(minutes.map(\.minuteTs), [((now - 60) / 60) * 60])
        let got = try await store.hrBuckets(deviceId: "dev", from: 0, to: Int.max, bucketSeconds: 60)
        let want = try await store.legacyHrBucketsForTest(deviceId: "dev", from: 0, to: Int.max, bucket: 60)
        assertBucketsEqual(got, want)
    }
}

extension WhoopStore {
    func hrMinuteRowsForTest(deviceId: String) throws -> [(minuteTs: Int, sumBpm: Int, n: Int)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT minuteTs, sumBpm, n FROM hrMinute WHERE deviceId = ? ORDER BY minuteTs
                """, arguments: [deviceId]).map { ($0["minuteTs"], $0["sumBpm"], $0["n"]) }
        }
    }
}

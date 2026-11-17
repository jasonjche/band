import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// Bulk multi-VALUES RR insert must persist the same rows as the previous per-row
/// INSERT + promote loop (seq/ord assignment, canonical-source promote, chunk 64).
final class RrBulkIdentityTests: XCTestCase {

    private typealias Dump = (ts: Int, rrMs: Int, seq: Int, ord: Int?, srcChannel: Int?)

    /// The round-1 per-row insert, kept as a test oracle so a bulk rewrite cannot drift.
    private func insertRrPerRowOracle(db: Database, deviceId: String, rows: [RRInterval]) throws {
        struct Key: Hashable { let ts: Int; let transport: Int }
        let stmt = try db.cachedStatement(sql: """
            INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord, srcChannel)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(deviceId, ts, rrMs, seq) DO NOTHING
            """)
        let promote = try db.cachedStatement(sql: """
            UPDATE rrInterval SET srcChannel = :source, ord = :ord
            WHERE deviceId = :device AND ts = :ts AND rrMs = :rr AND seq = :seq
            AND ((:source = 5 AND (srcChannel IS NULL OR srcChannel IN (6, 7)))
              OR (:source = 7 AND (srcChannel IS NULL OR srcChannel = 6)))
            """)
        let promoteWhoop4History = try db.cachedStatement(sql: """
            UPDATE rrInterval SET srcChannel = :source, ord = :ord
            WHERE deviceId = :device AND ts = :ts AND rrMs = :rr AND seq = :seq
            AND :source = 8 AND srcChannel IS NULL
            """)
        var seqByTsRr: [Key: [Int: Int]] = [:]
        var ordByTs: [Key: Int] = [:]
        for r in rows {
            let key = Key(ts: r.ts,
                          transport: r.srcChannel?.isWhoop5Transport == true ? r.srcChannel!.rawValue : 0)
            let seq = seqByTsRr[key]?[r.rrMs] ?? 0
            seqByTsRr[key, default: [:]][r.rrMs] = seq + 1
            let ord = ordByTs[key] ?? 0
            ordByTs[key] = ord + 1
            try stmt.execute(arguments: [deviceId, r.ts, r.rrMs, seq, ord, r.srcChannel?.rawValue])
            let inserted = db.changesCount
            if inserted == 0, let source = r.srcChannel,
               source == .whoop5Historical || source == .whoop5Standard {
                try promote.execute(arguments: ["source": source.rawValue, "ord": ord,
                    "device": deviceId, "ts": r.ts, "rr": r.rrMs, "seq": seq])
            }
            if inserted == 0, r.srcChannel == .whoop4Historical {
                try promoteWhoop4History.execute(arguments: [
                    "source": RRSourceChannel.whoop4Historical.rawValue, "ord": ord,
                    "device": deviceId, "ts": r.ts, "rr": r.rrMs, "seq": seq])
            }
        }
    }

    private func dump(_ store: WhoopStore, _ id: String) async throws -> [Dump] {
        try await store.rrTableDumpForTest(deviceId: id)
    }

    private func assertIdentical(_ batches: [[RRInterval]], file: StaticString = #filePath, line: UInt = #line) async throws {
        let bulk = try await WhoopStore.inMemory()
        let oracle = try await WhoopStore.inMemory()
        try await bulk.upsertDevice(id: "dev", mac: nil, name: nil)
        try await oracle.upsertDevice(id: "dev", mac: nil, name: nil)
        var bulkInserted = 0
        var oracleInserted = 0
        for batch in batches {
            let n = try await bulk.insert(Streams(rr: batch), deviceId: "dev")
            bulkInserted += n.rr
            let added = try await oracle.dbWriter.write { db -> Int in
                let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval") ?? 0
                try self.insertRrPerRowOracle(db: db, deviceId: "dev", rows: batch)
                let after = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval") ?? 0
                return after - before
            }
            oracleInserted += added
        }
        XCTAssertEqual(bulkInserted, oracleInserted, "insert counts drifted", file: file, line: line)
        let got = try await dump(bulk, "dev")
        let want = try await dump(oracle, "dev")
        XCTAssertEqual(got.count, want.count, file: file, line: line)
        for (a, b) in zip(got, want) {
            XCTAssertEqual(a.ts, b.ts, file: file, line: line)
            XCTAssertEqual(a.rrMs, b.rrMs, file: file, line: line)
            XCTAssertEqual(a.seq, b.seq, file: file, line: line)
            XCTAssertEqual(a.ord, b.ord, file: file, line: line)
            XCTAssertEqual(a.srcChannel, b.srcChannel, file: file, line: line)
        }
    }

    func testFreshHistoricalDayAcrossChunkBoundary() async throws {
        let rows = (0..<130).map {
            RRInterval(ts: 1_780_916_150 + $0, rrMs: 600 + ($0 % 200), srcChannel: .whoop5Historical)
        }
        try await assertIdentical([rows])
    }

    func testEqualBeatsGetDistinctSeqInOneSecond() async throws {
        let rows = [700, 900, 900, 800].map { RRInterval(ts: 100, rrMs: $0, srcChannel: .whoop5Historical) }
        try await assertIdentical([rows])
    }

    func testPromoteLegacyThenHistorical() async throws {
        let legacy = [700, 900, 900, 800].map { RRInterval(ts: 100, rrMs: $0) }
        let history = [900, 700, 900, 800].map { RRInterval(ts: 100, rrMs: $0, srcChannel: .whoop5Historical) }
        try await assertIdentical([legacy, history])
    }

    func testInterleavedTransportsSameBatch() async throws {
        let pairs: [(Int, RRSourceChannel)] = [
            (700, .whoop5Standard), (900, .whoop5Historical),
            (900, .whoop5Standard), (700, .whoop5Historical),
            (900, .whoop5Historical), (800, .whoop5Historical),
        ]
        try await assertIdentical([pairs.map { RRInterval(ts: 100, rrMs: $0.0, srcChannel: $0.1) }])
    }

    func testStandardThenHistoricalPromotion() async throws {
        let standard = [900, 700, 900, 800].map { RRInterval(ts: 100, rrMs: $0, srcChannel: .whoop5Standard) }
        let history = [800, 900, 700, 900].map { RRInterval(ts: 100, rrMs: $0, srcChannel: .whoop5Historical) }
        try await assertIdentical([standard, history, standard])
    }

    func testWhoop4HistoryPromotesNullSource() async throws {
        let unlabelled = [RRInterval(ts: 50, rrMs: 810)]
        let hist = [RRInterval(ts: 50, rrMs: 810, srcChannel: .whoop4Historical)]
        try await assertIdentical([unlabelled, hist])
    }

    func testOuraLabelIsNotPromoted() async throws {
        let oura = [RRInterval(ts: 100, rrMs: 800, srcChannel: .greenQuality)]
        let hist = [RRInterval(ts: 100, rrMs: 800, srcChannel: .whoop5Historical)]
        try await assertIdentical([oura, hist])
    }

    func testIdempotentReplayOfIdenticalHistorical() async throws {
        let rows = (0..<70).map {
            RRInterval(ts: 1_000 + $0, rrMs: 850, srcChannel: .whoop5Historical)
        }
        try await assertIdentical([rows, rows])
    }

    func testMixedNewAndDuplicateAcrossChunks() async throws {
        let first = (0..<65).map { RRInterval(ts: 2_000 + $0, rrMs: 700 + $0, srcChannel: .whoop5Standard) }
        let again = first + (65..<80).map { RRInterval(ts: 2_000 + $0, rrMs: 1, srcChannel: .whoop5Standard) }
        try await assertIdentical([first, again])
    }
}

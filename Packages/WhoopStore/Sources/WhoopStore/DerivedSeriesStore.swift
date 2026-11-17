import Foundation
import GRDB

// MARK: - v50 cache: finished per-day display series
// Home stress, the Stress page, Sleep overnight HR, and hourly steps previously
// rebuilt from raw 1 Hz HR on every open. This table stores the finished series
// once, after each analysis pass (and on a read-path miss). Kind strings and the
// packed payload layout live in StrandAnalytics.DerivedSeriesCodec; this file is
// the GRDB CRUD only.

/// One cached display series. Natural key `(kind, day)`.
public struct DerivedSeriesRow: Equatable, Sendable {
    public let kind: String
    public let day: String
    public let version: Int
    public let computedAt: Int
    public let payload: Data

    public init(kind: String, day: String, version: Int, computedAt: Int, payload: Data) {
        self.kind = kind
        self.day = day
        self.version = version
        self.computedAt = computedAt
        self.payload = payload
    }
}

extension WhoopStore {

    /// Upsert one finished series. Natural key `(kind, day)`; a later write replaces
    /// version, computedAt, and payload in place. Returns rows changed.
    @discardableResult
    public func upsertDerivedSeries(_ row: DerivedSeriesRow) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO derivedSeries (kind, day, version, computedAt, payload)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(kind, day) DO UPDATE SET
                    version = excluded.version,
                    computedAt = excluded.computedAt,
                    payload = excluded.payload
                """, arguments: [row.kind, row.day, row.version, row.computedAt, row.payload])
            return db.changesCount
        }
    }

    /// The row for `(kind, day)`, or nil when that series has never been written.
    public func derivedSeries(kind: String, day: String) async throws -> DerivedSeriesRow? {
        try syncRead { db in
            let stmt = try db.cachedStatement(sql: """
                SELECT kind, day, version, computedAt, payload FROM derivedSeries
                WHERE kind = ? AND day = ?
                """)
            try stmt.setArguments([kind, day])
            guard let row = try Row.fetchOne(stmt) else { return nil }
            let payload: Data = row[4]
            return DerivedSeriesRow(
                kind: row[0], day: row[1], version: row[2],
                computedAt: row[3], payload: payload
            )
        }
    }

    /// Current-version row, or nil when missing or stamped with another algorithm version.
    /// A code bump of the kind's version is a miss; the caller recomputes and writes back.
    public func derivedSeries(kind: String, day: String, version: Int) async throws -> DerivedSeriesRow? {
        guard let row = try await derivedSeries(kind: kind, day: day) else { return nil }
        return row.version == version ? row : nil
    }

    /// Payload byte length for `(kind, day)`, or nil when the row is absent.
    /// Measurement helper — does not materialise the blob.
    public func derivedSeriesPayloadBytes(kind: String, day: String) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT length(payload) FROM derivedSeries WHERE kind = ? AND day = ?
                """, arguments: [kind, day])
        }
    }
}

import GRDB

/// Shared GRDB fetch helpers for the hot WhoopStore read path.
/// Cached statements + a reused cursor + positional columns avoid per-row
/// dictionary lookups and the intermediate `[Row]` array `fetchAll` builds.
enum ReadFetch {
    static let cap = 262_144

    static func hasPpgHr(db: Database, deviceId: String, from: Int, to: Int) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM ppgHrSample WHERE deviceId = ? AND ts >= ? AND ts <= ?)
            """, arguments: [deviceId, from, to]) ?? false
    }

    static func mapAll<T>(db: Database, sql: String, arguments: StatementArguments,
                          reserve: Int, map: (Row) throws -> T) throws -> [T] {
        let stmt = try db.cachedStatement(sql: sql)
        try stmt.setArguments(arguments)
        var out: [T] = []
        if reserve > 0 { out.reserveCapacity(min(reserve, cap)) }
        let cursor = try Row.fetchCursor(stmt)
        while let row = try cursor.next() {
            out.append(try map(row))
        }
        return out
    }
}

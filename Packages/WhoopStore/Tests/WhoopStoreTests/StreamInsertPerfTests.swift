import XCTest
import WhoopProtocol
@testable import WhoopStore

/// Store WRITE throughput benches. Skipped unless `BAND_PERF=1`.
///
/// A day's worth of each 1 Hz stream (86400 rows) is inserted into a temp-file SQLite DB
/// (WAL pool, same configuration as production). Median + p90 of ≥7 runs after one warm-up.
/// Events are rarer on the wire; the bench still uses 1000 so JSON encoding is visible.
final class StreamInsertPerfTests: XCTestCase {

    private static let dayRows = 86_400
    private static let eventRows = 1_000
    private static let measuredRuns = 7
    private static let t0 = 1_780_916_150

    private func requirePerf() throws {
        guard ProcessInfo.processInfo.environment["BAND_PERF"] == "1" else {
            throw XCTSkip("set BAND_PERF=1 to run ingest pipeline benchmarks")
        }
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let i = min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))
        return sorted[i]
    }

    private func summarize(_ xs: [Double]) -> (median: Double, p90: Double, lo: Double, hi: Double) {
        let s = xs.sorted()
        return (percentile(s, 0.5), percentile(s, 0.9), s.first ?? 0, s.last ?? 0)
    }

    private func report(_ name: String, n: Int, seconds: [Double]) {
        let st = summarize(seconds)
        let medRps = Double(n) / st.median
        let p90Rps = Double(n) / st.p90
        print(String(
            format: "BAND_PERF %@ n=%d median=%.0f rows/s p90=%.0f rows/s  (s median=%.4f p90=%.4f spread=[%.4f..%.4f])",
            name, n, medRps, p90Rps, st.median, st.p90, st.lo, st.hi))
        fflush(stdout)
    }

    private func withTempStore<T>(_ body: (WhoopStore) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("band-ingest-perf-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        let store = try await WhoopStore(path: path)
        try await store.upsertDevice(id: "perf", mac: nil, name: nil)
        return try await body(store)
    }

    private func timeInsert(streams: Streams, n: Int, name: String) async throws {
        try requirePerf()
        // Warm-up on a throwaway DB so measured runs see a migrated WAL file of similar shape.
        _ = try await withTempStore { store in
            try await store.insert(streams, deviceId: "perf")
        }
        var times: [Double] = []
        times.reserveCapacity(Self.measuredRuns)
        var inserted = 0
        for _ in 0..<Self.measuredRuns {
            inserted = try await withTempStore { store in
                let t0 = DispatchTime.now().uptimeNanoseconds
                let r = try await store.insert(streams, deviceId: "perf")
                let t1 = DispatchTime.now().uptimeNanoseconds
                times.append(Double(t1 - t0) / 1e9)
                return r.hr + r.rr + r.events + r.gravity + n
            }
        }
        XCTAssertGreaterThan(inserted, 0)
        report(name, n: n, seconds: times)
    }

    func testPerfInsertDayHR() async throws {
        var hr = [HRSample](); hr.reserveCapacity(Self.dayRows)
        for i in 0..<Self.dayRows { hr.append(HRSample(ts: Self.t0 + i, bpm: 60 + (i % 40))) }
        try await timeInsert(streams: Streams(hr: hr), n: Self.dayRows, name: "insert_hr")
    }

    func testPerfInsertDayRR() async throws {
        var rr = [RRInterval](); rr.reserveCapacity(Self.dayRows)
        for i in 0..<Self.dayRows {
            rr.append(RRInterval(ts: Self.t0 + i, rrMs: 600 + (i % 200),
                                 srcChannel: .whoop5Historical))
        }
        try await timeInsert(streams: Streams(rr: rr), n: Self.dayRows, name: "insert_rr")
    }

    func testPerfInsertDaySteps() async throws {
        var steps = [StepSample](); steps.reserveCapacity(Self.dayRows)
        for i in 0..<Self.dayRows {
            steps.append(StepSample(ts: Self.t0 + i, counter: i, activityClass: i % 3))
        }
        try await timeInsert(streams: Streams(steps: steps), n: Self.dayRows, name: "insert_steps")
    }

    func testPerfInsertDayGravity() async throws {
        var g = [GravitySample](); g.reserveCapacity(Self.dayRows)
        for i in 0..<Self.dayRows {
            g.append(GravitySample(ts: Self.t0 + i, x: 0.01, y: 0.02, z: 0.98,
                                   dynAccel: 0.009))
        }
        try await timeInsert(streams: Streams(gravity: g), n: Self.dayRows, name: "insert_gravity")
    }

    func testPerfInsertEvents() async throws {
        var ev = [WhoopEvent](); ev.reserveCapacity(Self.eventRows)
        for i in 0..<Self.eventRows {
            ev.append(WhoopEvent(ts: Self.t0 + i, kind: "DOUBLE_TAP(14)",
                                 payload: ["event": .string("DOUBLE_TAP(14)"),
                                           "n": .int(i)]))
        }
        try await timeInsert(streams: Streams(events: ev), n: Self.eventRows, name: "insert_events")
    }

    func testPerfInsertDayMixedHistoricalStreams() async throws {
        try requirePerf()
        var hr = [HRSample](); hr.reserveCapacity(Self.dayRows)
        var rr = [RRInterval](); rr.reserveCapacity(Self.dayRows)
        var steps = [StepSample](); steps.reserveCapacity(Self.dayRows)
        var g = [GravitySample](); g.reserveCapacity(Self.dayRows)
        for i in 0..<Self.dayRows {
            let ts = Self.t0 + i
            hr.append(HRSample(ts: ts, bpm: 70))
            rr.append(RRInterval(ts: ts, rrMs: 850, srcChannel: .whoop5Historical))
            steps.append(StepSample(ts: ts, counter: i, activityClass: 0))
            g.append(GravitySample(ts: ts, x: 0, y: 0, z: 1, dynAccel: 0.01))
        }
        let streams = Streams(hr: hr, rr: rr, gravity: g, steps: steps)
        let n = Self.dayRows * 4
        _ = try await withTempStore { store in
            try await store.insert(streams, deviceId: "perf")
        }
        var times: [Double] = []
        for _ in 0..<Self.measuredRuns {
            _ = try await withTempStore { store in
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = try await store.insert(streams, deviceId: "perf")
                let t1 = DispatchTime.now().uptimeNanoseconds
                times.append(Double(t1 - t0) / 1e9)
            }
        }
        report("insert_mixed_hr_rr_steps_gravity", n: n, seconds: times)
    }
}

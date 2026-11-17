import XCTest
import WhoopProtocol
@testable import WhoopStore

/// Persisted rows after the multi-VALUES insert rewrite must match the previous per-row
/// ON CONFLICT DO NOTHING behaviour, including chunk boundaries (64) and mixed new/duplicate rows.
final class InsertBulkIdentityTests: XCTestCase {

    func testHrChunkBoundaryAndConflictsRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        let first = (0..<65).map { HRSample(ts: 1_000 + $0, bpm: 60 + $0) }
        let n1 = try await store.insert(Streams(hr: first), deviceId: "dev")
        XCTAssertEqual(n1.hr, 65)
        let again = first + (65..<75).map { HRSample(ts: 1_000 + $0, bpm: 1) }
        let n2 = try await store.insert(Streams(hr: again), deviceId: "dev")
        XCTAssertEqual(n2.hr, 10)
        let got = try await store.hrSamples(deviceId: "dev", from: 1_000, to: 2_000, limit: 200)
        XCTAssertEqual(got.map(\.ts), Array(1_000..<1_075))
        XCTAssertEqual(got.map(\.bpm), (0..<65).map { 60 + $0 } + Array(repeating: 1, count: 10))
    }

    func testGravityAndStepsChunkBoundaryRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        let gravity = (0..<70).map {
            GravitySample(ts: 2_000 + $0, x: Double($0), y: 0.5, z: 0.8,
                          dynAccel: $0 % 2 == 0 ? 0.01 : nil)
        }
        let steps = (0..<70).map {
            StepSample(ts: 2_000 + $0, counter: $0 * 3, activityClass: $0 % 3)
        }
        let n = try await store.insert(Streams(gravity: gravity, steps: steps), deviceId: "dev")
        XCTAssertEqual(n.gravity, 70)
        let gotG = try await store.gravitySamples(deviceId: "dev", from: 2_000, to: 3_000, limit: 200)
        XCTAssertEqual(gotG, gravity)
        let gotS = try await store.stepSamples(deviceId: "dev", from: 2_000, to: 3_000, limit: 200)
        XCTAssertEqual(gotS, steps)
        let dup = try await store.insert(Streams(gravity: gravity, steps: steps), deviceId: "dev")
        XCTAssertEqual(dup.gravity, 0)
        let stepCount = try await store.stepCountForTest()
        XCTAssertEqual(stepCount, 70)
    }

    func testEventPayloadJSONStableAndDeduped() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        let events = (0..<70).map { i in
            WhoopEvent(ts: 3_000 + i, kind: "DOUBLE_TAP(14)",
                       payload: ["z": .int(i), "a": .string("x"), "n": .int(i)])
        }
        let n1 = try await store.insert(Streams(events: events), deviceId: "dev")
        XCTAssertEqual(n1.events, 70)
        let n2 = try await store.insert(Streams(events: events), deviceId: "dev")
        XCTAssertEqual(n2.events, 0)
        let stats = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(stats.events, 70)
        // Sorted-keys JSON: "a" before "n" before "z".
        let json = try WhoopStore.encodePayload(events[0].payload)
        XCTAssertEqual(json, "{\"a\":\"x\",\"n\":0,\"z\":0}")
    }

    func testPackPpgSamplesLittleEndianUnchanged() {
        let samples = [0, 1, -1, 32767, -32768, 256]
        let data = WhoopStore.packPpgSamples(samples)
        XCTAssertEqual([UInt8](data), [
            0x00, 0x00,
            0x01, 0x00,
            0xFF, 0xFF,
            0xFF, 0x7F,
            0x00, 0x80,
            0x00, 0x01,
        ])
        XCTAssertEqual(WhoopStore.unpackPpgSamples(data), samples)
    }

    func testStepRevisionRecordsOnlyInsertedTimestampsAcrossChunks() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        let day = 1_780_876_800
        let first = (0..<70).map { StepSample(ts: day + $0, counter: $0) }
        _ = try await store.insert(Streams(steps: first), deviceId: "dev")
        let sig1 = await store.stepDataRevisionSignature(deviceId: "dev", from: day, to: day + 1_000)
        _ = try await store.insert(Streams(steps: first), deviceId: "dev")
        let sig2 = await store.stepDataRevisionSignature(deviceId: "dev", from: day, to: day + 1_000)
        XCTAssertEqual(sig1, sig2, "duplicate steps must not bump the revision")
        _ = try await store.insert(Streams(steps: [StepSample(ts: day + 80, counter: 80)]), deviceId: "dev")
        let sig3 = await store.stepDataRevisionSignature(deviceId: "dev", from: day, to: day + 1_000)
        XCTAssertNotEqual(sig1, sig3, "a new step must bump the revision")
    }
}

import XCTest
@testable import StrandAnalytics

final class DerivedSeriesCodecTests: XCTestCase {

    func testAlgorithmVersionsArePinned() {
        XCTAssertEqual(DerivedSeriesCodec.algorithmVersion(kind: DerivedSeriesCodec.stressMinuteKind), 2)  // v2: line runs through activities, 15-min smoothing
        XCTAssertEqual(DerivedSeriesCodec.algorithmVersion(kind: DerivedSeriesCodec.overnightHRKind), 1)
        XCTAssertEqual(DerivedSeriesCodec.algorithmVersion(kind: DerivedSeriesCodec.hourlyStepsKind), 1)
        XCTAssertEqual(DerivedSeriesCodec.algorithmVersion(kind: "unknown"), 0)
    }

    func testStressRoundTripPreservesPointsAndExclusions() {
        let payload = DerivedSeriesCodec.StressPayload(
            fingerprint: "s=1|e=2|wr=58.0",
            points: [
                DerivedSeriesCodec.Point(ts: 1_700_000_000, value: 0.4),
                DerivedSeriesCodec.Point(ts: 1_700_000_060, value: 2.25),
            ],
            exclusions: [
                BandStress.ExclusionSpan(startTs: 1_700_000_120, endTs: 1_700_000_400, kind: .workout),
                BandStress.ExclusionSpan(startTs: 1_700_001_000, endTs: 1_700_001_180, kind: .activity),
            ]
        )
        let decoded = DerivedSeriesCodec.decodeStress(DerivedSeriesCodec.encodeStress(payload))
        XCTAssertEqual(decoded, payload)
    }

    func testOvernightRoundTripPreservesNilAverage() {
        let withAvg = DerivedSeriesCodec.OvernightPayload(
            fingerprint: "10|20",
            points: [DerivedSeriesCodec.Point(ts: 10, value: 54)],
            average: 54.5,
            rawCount: 28800
        )
        XCTAssertEqual(DerivedSeriesCodec.decodeOvernight(DerivedSeriesCodec.encodeOvernight(withAvg)), withAvg)

        let noAvg = DerivedSeriesCodec.OvernightPayload(
            fingerprint: "10|20",
            points: [],
            average: nil,
            rawCount: 0
        )
        XCTAssertEqual(DerivedSeriesCodec.decodeOvernight(DerivedSeriesCodec.encodeOvernight(noAvg)), noAvg)
    }

    func testHourlyStepsRoundTripPadsToTwentyFour() {
        let payload = DerivedSeriesCodec.HourlyStepsPayload(
            fingerprint: "a=1|s=4000|m=4000",
            dayStartTs: 1_700_000_000,
            hours: [10, 20, 30]
        )
        let decoded = DerivedSeriesCodec.decodeHourlySteps(DerivedSeriesCodec.encodeHourlySteps(payload))
        XCTAssertEqual(decoded?.fingerprint, payload.fingerprint)
        XCTAssertEqual(decoded?.dayStartTs, payload.dayStartTs)
        XCTAssertEqual(decoded?.hours.count, 24)
        XCTAssertEqual(decoded?.hours.prefix(3).map { $0 }, [10, 20, 30])
        XCTAssertEqual(decoded?.hours.dropFirst(3).allSatisfy { $0 == 0 }, true)
    }

    func testCorruptPayloadDecodesNil() {
        XCTAssertNil(DerivedSeriesCodec.decodeStress(Data([0, 1, 2])))
        XCTAssertNil(DerivedSeriesCodec.decodeOvernight(Data()))
        XCTAssertNil(DerivedSeriesCodec.decodeHourlySteps(Data([1])))
    }

    func testPackedStressDayIsCompact() {
        let points = (0..<1_440).map {
            DerivedSeriesCodec.Point(ts: 1_700_000_000 + $0 * 60, value: Double($0 % 3) + 0.25)
        }
        let payload = DerivedSeriesCodec.StressPayload(
            fingerprint: "s=1|e=2",
            points: points,
            exclusions: [
                BandStress.ExclusionSpan(startTs: 1_700_000_000, endTs: 1_700_001_800, kind: .workout)
            ]
        )
        let bytes = DerivedSeriesCodec.encodeStress(payload).count
        XCTAssertLessThan(bytes, 30_000, "1440 packed minutes should stay well under 30 KB")
        XCTAssertGreaterThan(bytes, 1_440 * 16, "each point is ts+value (16 bytes) plus header")
    }
}

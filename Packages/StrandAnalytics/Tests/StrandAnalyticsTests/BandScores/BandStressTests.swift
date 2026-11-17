import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class BandStressTests: XCTestCase {

    private let rhr55 = BandStress.Baselines(wakeRestingHR: 55, sleepRestingHR: 55, rmssd: 50)
    private let rhr75 = BandStress.Baselines(wakeRestingHR: 75, sleepRestingHR: 75, rmssd: 50)

    func testRestReadsLow() {
        let v = BandStress.score(bpm: 55, isAsleep: false, baselines: rhr55)
        XCTAssertEqual(v, 0, accuracy: 1e-9)
        XCTAssertLessThan(v, 1)
    }

    func testSameRelativeElevationMatchesAcrossRestingHR() {
        let a = BandStress.score(bpm: 55 + 12, isAsleep: false, baselines: rhr55)
        let b = BandStress.score(bpm: 75 + 12, isAsleep: false, baselines: rhr75)
        XCTAssertEqual(a, 1.0, accuracy: 1e-9)
        XCTAssertEqual(a, b, accuracy: 1e-9)
        let highA = BandStress.score(bpm: 55 + 24, isAsleep: false, baselines: rhr55)
        let highB = BandStress.score(bpm: 75 + 24, isAsleep: false, baselines: rhr75)
        XCTAssertEqual(highA, 2.0, accuracy: 1e-9)
        XCTAssertEqual(highA, highB, accuracy: 1e-9)
    }

    func testOrdinaryElevationIsMediumAndSustainedIsHigh() {
        let medium = BandStress.score(bpm: 55 + 14, isAsleep: false, baselines: rhr55)
        XCTAssertGreaterThanOrEqual(medium, 1)
        XCTAssertLessThan(medium, 2)
        let high = BandStress.score(bpm: 55 + 30, isAsleep: false, baselines: rhr55)
        XCTAssertGreaterThanOrEqual(high, 2)
    }

    func testWorkoutBucketIsExcluded() {
        let out = BandStress.evaluate(
            bpm: 160, isWorkout: true, isAsleep: false, baselines: rhr55
        )
        XCTAssertEqual(out, .excluded)
    }

    func testMissingBaselineFallsBackToSixty() {
        let resolved = BandStress.Baselines.resolve(
            dayRestingHR: nil, recentRestingHRs: [],
            dayRMSSD: nil, recentRMSSDs: []
        )
        XCTAssertEqual(resolved.wakeRestingHR, BandStress.defaultRestingHR)
        XCTAssertEqual(resolved.sleepRestingHR, BandStress.defaultRestingHR)
        XCTAssertNil(resolved.rmssd)
        XCTAssertEqual(BandStress.defaultRestingHR, 60, accuracy: 0)
        let v = BandStress.score(bpm: 72, isAsleep: false, baselines: .fallback)
        XCTAssertEqual(v, 1.0, accuracy: 1e-9)
    }

    func testRecentMedianUsedWhenDayRHRMissing() {
        let resolved = BandStress.Baselines.resolve(
            dayRestingHR: nil, recentRestingHRs: [50, 60, 70],
            dayRMSSD: nil, recentRMSSDs: [40, 50, 60]
        )
        XCTAssertEqual(resolved.wakeRestingHR, 60, accuracy: 1e-9)
        XCTAssertEqual(resolved.rmssd ?? -1, 50, accuracy: 1e-9)
    }

    func testGapsStayGaps() {
        let out = BandStress.evaluate(
            bpm: nil, isWorkout: false, isAsleep: false, baselines: .fallback
        )
        XCTAssertEqual(out, .gap)
    }

    func testSleepUsesSleepBaseline() {
        let split = BandStress.Baselines(wakeRestingHR: 70, sleepRestingHR: 55, rmssd: nil)
        let sleepAtRHR = BandStress.score(bpm: 55, isAsleep: true, baselines: split)
        let wakeAtSleepRHR = BandStress.score(bpm: 55, isAsleep: false, baselines: split)
        XCTAssertEqual(sleepAtRHR, 0, accuracy: 1e-9)
        XCTAssertEqual(wakeAtSleepRHR, 0, accuracy: 1e-9)
        let elevatedSleep = BandStress.score(bpm: 79, isAsleep: true, baselines: split)
        let sameHRWake = BandStress.score(bpm: 79, isAsleep: false, baselines: split)
        XCTAssertEqual(elevatedSleep, 2.0, accuracy: 1e-9)
        XCTAssertEqual(sameHRWake, (79 - 70) / 12, accuracy: 1e-9)
        XCTAssertGreaterThan(elevatedSleep, sameHRWake)
    }

    func testHRVSuppressionRaisesScoreHROnlyStillWorks() {
        let hrOnly = BandStress.score(bpm: 67, rmssd: nil, isAsleep: false, baselines: rhr55)
        let withHRV = BandStress.score(bpm: 67, rmssd: 10, isAsleep: false, baselines: rhr55)
        XCTAssertEqual(hrOnly, 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(withHRV, hrOnly)
        XCTAssertLessThan(withHRV, 2)
    }

    func testSparseRROmitsRMSSDBucket() {
        let thin = (0..<10).map { (ts: 1_000 + $0, ms: 800.0) }
        XCTAssertTrue(BandStress.rmssdByBucket(rr: thin).isEmpty)
        let start = 1_200
        let dense = (0..<40).map { i -> (ts: Int, ms: Double) in
            (ts: start + i, ms: 800 + Double(i % 3) * 10)
        }
        let got = BandStress.rmssdByBucket(rr: dense)
        XCTAssertEqual(got.count, 1)
        XCTAssertNotNil(got[start] ?? got.values.first)
    }

    func testOvernightHighShareUsesSleepBaseline() {
        let start = 1_700_000_000
        var samples: [HRSample] = []
        for i in 0..<4 {
            samples.append(HRSample(ts: start + i * 300, bpm: 55))
        }
        for i in 4..<8 {
            samples.append(HRSample(ts: start + i * 300, bpm: 79))
        }
        let share = BandStress.overnightHighShare(
            hr: samples, startTs: start, endTs: start + 8 * 300, baselines: rhr55
        )
        XCTAssertEqual(share ?? -1, 50, accuracy: 1e-9)
        XCTAssertNil(BandStress.overnightHighShare(
            hr: [], startTs: start, endTs: start + 300, baselines: rhr55
        ))
    }

    func testWorkoutOverlapAndClamps() {
        XCTAssertTrue(BandStress.overlaps(bucketTs: 1_080, start: 1_100, end: 1_400))
        XCTAssertFalse(BandStress.overlaps(bucketTs: 1_000, start: 1_100, end: 1_400))
        XCTAssertEqual(BandStress.score(bpm: 200, isAsleep: false, baselines: rhr55), 3, accuracy: 1e-9)
        XCTAssertEqual(BandStress.score(bpm: 40, isAsleep: false, baselines: rhr55), 0, accuracy: 1e-9)
    }

    func testActivityAndRecoveryAreExcluded() {
        XCTAssertEqual(
            BandStress.evaluate(bpm: 110, isWorkout: false, isAsleep: false, baselines: rhr55,
                                isActivity: true),
            .excluded)
        XCTAssertEqual(
            BandStress.evaluate(bpm: 110, isWorkout: false, isAsleep: false, baselines: rhr55,
                                isRecovery: true),
            .excluded)
        XCTAssertEqual(
            BandStress.exclusionKind(isWorkout: true, isRecovery: true, isActivity: true),
            .workout)
        XCTAssertEqual(
            BandStress.exclusionKind(isWorkout: false, isRecovery: true, isActivity: true),
            .recovery)
    }

    func testRecoveryWindowEndsWhenHRReturns() {
        let start = 1_000
        let end = 1_000 + 20 * 60
        var samples: [(ts: Int, bpm: Double)] = []
        for t in stride(from: start - 600, to: start, by: 60) { samples.append((t, 60)) }
        for t in stride(from: start, to: end, by: 60) { samples.append((t, 150)) }
        for t in stride(from: end, to: end + 3_600, by: 60) {
            let bpm = t < end + 10 * 60 ? 120.0 : 70.0
            samples.append((t, bpm))
        }
        let window = BandStress.recoveryWindow(workoutStart: start, workoutEnd: end, samples: samples)
        XCTAssertEqual(window?.start, end)
        XCTAssertEqual(window?.end, end + 10 * 60)
    }

    func testRecoveryWindowCapsAtSixtyMinutes() {
        let start = 2_000
        let end = 2_000 + 30 * 60
        var samples: [(ts: Int, bpm: Double)] = []
        for t in stride(from: start - 600, to: start, by: 60) { samples.append((t, 60)) }
        for t in stride(from: start, to: end + 4_000, by: 60) { samples.append((t, 140)) }
        let window = BandStress.recoveryWindow(workoutStart: start, workoutEnd: end, samples: samples)
        XCTAssertEqual(window?.end, end + BandStress.recoveryMaxSeconds)
    }

    func testWalkBucketsAreActivityNotStill() {
        let t0 = 3_000
        var steps: [(ts: Int, activityClass: Int)] = []
        for i in 0..<20 { steps.append((t0 + i, 1)) }
        var still: [(ts: Int, activityClass: Int)] = []
        for i in 0..<20 { still.append((t0 + 600 + i, 0)) }
        let walk = BandStress.activityBuckets(bucketStarts: [t0], steps: steps)
        let sit = BandStress.activityBuckets(bucketStarts: [t0 + 600], steps: still)
        XCTAssertTrue(walk.contains(t0))
        XCTAssertTrue(sit.isEmpty)
    }

    func testGravityWalkFloorMarksActivity() {
        let t0 = 9_000
        let moving = (0..<20).map { (ts: t0 + $0, intensity: 0.25) }
        let desk = (0..<20).map { (ts: t0 + 600 + $0, intensity: 0.04) }
        XCTAssertTrue(BandStress.activityBuckets(bucketStarts: [t0], motion: moving).contains(t0))
        XCTAssertTrue(BandStress.activityBuckets(bucketStarts: [t0 + 600], motion: desk).isEmpty)
    }

    func testActivitySpansMergeAdjacentBuckets() {
        let spans = BandStress.spans(fromBuckets: [0, 300, 900], bucketSeconds: 300)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].startTs, 0)
        XCTAssertEqual(spans[0].endTs, 600)
        XCTAssertEqual(spans[1].startTs, 900)
        XCTAssertEqual(spans[1].kind, .activity)
    }

    func testBucketSecondsIsOneMinute() {
        XCTAssertEqual(BandStress.bucketSeconds, 60)
        XCTAssertEqual(BandStress.smoothWindowSeconds, 300)
        XCTAssertEqual(BandStress.smoothRadiusBuckets, 2)
        XCTAssertEqual(
            (2 * BandStress.smoothRadiusBuckets + 1) * BandStress.bucketSeconds,
            BandStress.smoothWindowSeconds
        )
        XCTAssertEqual(BandStress.chartGapSeconds, 90)
        XCTAssertEqual(BandStress.overnightWindowSeconds, 300)
    }

    func testCenteredSmoothDampsAOneMinuteSpike() {
        let t0 = 10_000
        var points: [(ts: Int, value: Double)] = []
        for i in 0..<11 {
            let ts = t0 + i * BandStress.bucketSeconds
            points.append((ts, i == 5 ? 3.0 : 0.0))
        }
        let smoothed = BandStress.smoothCentered(points: points)
        XCTAssertEqual(smoothed.count, 11)
        let peak = smoothed[5].value
        XCTAssertEqual(peak, 0.6, accuracy: 1e-9)
        XCTAssertLessThan(peak, 1)
        XCTAssertEqual(smoothed[0].value, 0, accuracy: 1e-9)
        XCTAssertEqual(smoothed[10].value, 0, accuracy: 1e-9)
    }

    func testCenteredSmoothDoesNotFillAHole() {
        let t0 = 20_000
        let left = (0..<3).map { (ts: t0 + $0 * 60, value: 1.0) }
        let right = (0..<3).map { (ts: t0 + 5 * 60 + $0 * 60, value: 2.0) }
        let smoothed = BandStress.smoothCentered(points: left + right)
        XCTAssertEqual(smoothed.count, 6)
        XCTAssertEqual(smoothed[2].ts, t0 + 120)
        XCTAssertEqual(smoothed[3].ts, t0 + 300)
        XCTAssertEqual(smoothed[2].value, 1.0, accuracy: 1e-9)
        XCTAssertEqual(smoothed[3].value, 2.0, accuracy: 1e-9)
        XCTAssertFalse(smoothed.contains { $0.ts == t0 + 180 || $0.ts == t0 + 240 })
    }

    func testMergeSpansJoinsShortWalksWithinTenMinutes() {
        let walks = [
            BandStress.ExclusionSpan(startTs: 0, endTs: 60, kind: .activity),
            BandStress.ExclusionSpan(startTs: 180, endTs: 240, kind: .activity),
            BandStress.ExclusionSpan(startTs: 12 * 60, endTs: 13 * 60, kind: .activity),
        ]
        let merged = BandStress.mergeSpans(walks)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].startTs, 0)
        XCTAssertEqual(merged[0].endTs, 13 * 60)
        let far = BandStress.mergeSpans([
            BandStress.ExclusionSpan(startTs: 0, endTs: 60, kind: .activity),
            BandStress.ExclusionSpan(startTs: 20 * 60, endTs: 21 * 60, kind: .activity),
        ])
        XCTAssertEqual(far.count, 2)
        let mixed = BandStress.mergeSpans([
            BandStress.ExclusionSpan(startTs: 0, endTs: 600, kind: .workout),
            BandStress.ExclusionSpan(startTs: 120, endTs: 180, kind: .activity),
        ], gapSeconds: 10 * 60)
        XCTAssertEqual(mixed.count, 2)
        XCTAssertEqual(mixed.map(\.kind), [.workout, .activity])
    }

    func testFullDayMinuteGridIs1440() {
        let start = 1_700_000_000
        let points = (0..<1_440).map { i in
            (ts: start + i * BandStress.bucketSeconds, value: Double(i % 3))
        }
        let smoothed = BandStress.smoothCentered(points: points)
        XCTAssertEqual(points.count, 1_440)
        XCTAssertEqual(smoothed.count, 1_440)
        XCTAssertEqual(smoothed.first?.ts, start)
        XCTAssertEqual(smoothed.last?.ts, start + 1_439 * 60)
    }
}

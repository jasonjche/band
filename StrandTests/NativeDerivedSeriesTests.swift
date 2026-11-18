import XCTest
import WhoopStore
import StrandAnalytics
import WhoopProtocol
@testable import Strand

/// Cached display series and the live builder are one funnel: encode/decode of the
/// live output is identity, so Home / Stress / Sleep cannot disagree with the cache.
final class NativeDerivedSeriesTests: XCTestCase {

    func testStressCacheRoundTripMatchesLiveBuilder() {
        let t0 = 1_700_000_000
        var buckets: [HRBucket] = []
        for i in 0..<11 {
            let bpm = i == 5 ? 96.0 : 60.0
            buckets.append(HRBucket(ts: t0 + i * 60, bpm: bpm, minBpm: bpm, maxBpm: bpm))
        }
        let sleepStart = Date(timeIntervalSince1970: TimeInterval(t0))
        let sleepEnd = Date(timeIntervalSince1970: TimeInterval(t0 + 8 * 60))
        let workouts = [(
            start: Date(timeIntervalSince1970: TimeInterval(t0 + 9 * 60)),
            end: Date(timeIntervalSince1970: TimeInterval(t0 + 11 * 60))
        )]
        let samples = buckets.map { (ts: $0.ts, bpm: $0.bpm) }
        let unixBouts = workouts.map {
            (start: Int($0.start.timeIntervalSince1970), end: Int($0.end.timeIntervalSince1970))
        }
        let recovery = BandStress.recoveryWindows(workouts: unixBouts, samples: samples)
        let live = NativeHomeCharts.stressTimeline(
            buckets: buckets,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            workouts: workouts,
            recovery: recovery
        )
        let built = NativeDerivedSeries.computeStress(
            buckets: buckets,
            baselines: .fallback,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            workouts: workouts,
            rr: [],
            steps: [],
            gravity: []
        )
        XCTAssertEqual(built.hours, live.hours)
        XCTAssertEqual(built.exclusions, live.exclusions)

        let fingerprint = DerivedSeriesCodec.stressFingerprint(
            sleepStartTs: t0, sleepEndTs: t0 + 8 * 60,
            workouts: [(t0 + 9 * 60, t0 + 11 * 60)],
            wakeRestingHR: BandStress.defaultRestingHR,
            sleepRestingHR: BandStress.defaultRestingHR,
            rmssd: nil
        ) + "|\(NativeDerivedSeries.stressCalibrationTag)"
        let payload = DerivedSeriesCodec.encodeStress(DerivedSeriesCodec.StressPayload(
            fingerprint: fingerprint,
            points: built.hours.map {
                DerivedSeriesCodec.Point(ts: Int($0.time.timeIntervalSince1970), value: $0.value)
            },
            exclusions: built.exclusions
        ))
        let decoded = DerivedSeriesCodec.decodeStress(payload)
        XCTAssertEqual(decoded?.fingerprint, fingerprint)
        XCTAssertEqual(decoded?.points.map(\.value), built.hours.map(\.value))
        XCTAssertEqual(decoded?.points.map(\.ts), built.hours.map { Int($0.time.timeIntervalSince1970) })
        XCTAssertEqual(decoded?.exclusions, built.exclusions)

        let other = DerivedSeriesCodec.decodeStress(payload)
        XCTAssertNotEqual(other?.fingerprint, "s=0|e=0")
        XCTAssertEqual(
            NativeDerivedSeries.stressLiveHRFingerprint(bucketCount: 12, lastTs: 9_999),
            "hr:12:9999"
        )
        XCTAssertTrue(fingerprint.contains(NativeDerivedSeries.stressCalibrationTag))
    }

    func testComputeStressHoldsUnloggedWalking() {
        let t0 = 1_699_999_980 // minute-aligned so step ticks share BandStress bucket keys
        var buckets: [HRBucket] = []
        var steps: [AutoWorkoutDetector.StepTick] = []
        for i in 0..<30 {
            let ts = t0 + i * 60
            let walking = (10..<20).contains(i)
            let bpm = walking ? 108.0 : 72.0
            buckets.append(HRBucket(ts: ts, bpm: bpm, minBpm: bpm, maxBpm: bpm))
            if walking {
                for s in 0..<20 {
                    steps.append(AutoWorkoutDetector.StepTick(ts: ts + s, activityClass: 1))
                }
            }
        }
        let overnight = BandStress.Baselines(wakeRestingHR: 57, sleepRestingHR: 57, rmssd: nil)
        let built = NativeDerivedSeries.computeStress(
            buckets: buckets,
            baselines: overnight,
            sleepStart: nil,
            sleepEnd: nil,
            workouts: [],
            rr: [],
            steps: steps,
            gravity: []
        )
        let sit = NativeHomeCharts.stressValue(bpm: 72, baselines: overnight)
        XCTAssertEqual(built.hours.map(\.value).max() ?? 9, sit, accuracy: 0.12)
        XCTAssertFalse(built.exclusions.filter { $0.kind == .activity }.isEmpty)
    }

    func testOvernightCacheRoundTripMatchesLiveMake() {
        let start = 1_700_000_000
        let samples = (0..<1_200).map { HRSample(ts: start + $0 * 2, bpm: 50 + ($0 % 9)) }
        let live = NativeOvernightHeart.make(samples: samples)
        let fingerprint = DerivedSeriesCodec.overnightFingerprint(startTs: start, endTs: start + 2_400)
        let payload = DerivedSeriesCodec.encodeOvernight(DerivedSeriesCodec.OvernightPayload(
            fingerprint: fingerprint,
            points: live.points.map {
                DerivedSeriesCodec.Point(ts: Int($0.time.timeIntervalSince1970), value: $0.value)
            },
            average: live.average,
            rawCount: live.rawCount
        ))
        let decoded = DerivedSeriesCodec.decodeOvernight(payload)
        XCTAssertEqual(decoded?.fingerprint, fingerprint)
        XCTAssertEqual(decoded?.rawCount, live.rawCount)
        XCTAssertEqual(decoded?.average ?? -1, live.average ?? -2, accuracy: 1e-12)
        XCTAssertEqual(decoded?.points.map(\.value), live.points.map(\.value))
        XCTAssertEqual(decoded?.points.count, live.plotCount)
    }

    func testHourlyStepsCacheRoundTripMatchesLivePoints() {
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let calendar = Calendar(identifier: .gregorian)
        var cal = calendar
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let appleHours = [
            (ts: Int(start.timeIntervalSince1970) + 3_600, steps: 400),
            (ts: Int(start.timeIntervalSince1970) + 7_200, steps: 900),
        ]
        let live = NativeResolvedSteps.hourPoints(
            appleHours: appleHours, dayStart: start, calendar: cal, preferApple: true
        )
        XCTAssertEqual(live.count, 24)
        let fingerprint = DerivedSeriesCodec.hourlyStepsFingerprint(
            preferApple: true, appleSum: 1_300, mergedDaily: 1_300
        )
        let payload = DerivedSeriesCodec.encodeHourlySteps(DerivedSeriesCodec.HourlyStepsPayload(
            fingerprint: fingerprint,
            dayStartTs: Int(cal.startOfDay(for: start).timeIntervalSince1970),
            hours: live.map(\.value)
        ))
        let decoded = DerivedSeriesCodec.decodeHourlySteps(payload)
        XCTAssertEqual(decoded?.fingerprint, fingerprint)
        XCTAssertEqual(decoded?.hours, live.map(\.value))
    }

    func testStaleFingerprintIsAMiss() {
        let payload = DerivedSeriesCodec.encodeOvernight(DerivedSeriesCodec.OvernightPayload(
            fingerprint: "10|20",
            points: [DerivedSeriesCodec.Point(ts: 10, value: 54)],
            average: 54,
            rawCount: 1
        ))
        let decoded = DerivedSeriesCodec.decodeOvernight(payload)
        XCTAssertEqual(decoded?.fingerprint, "10|20")
        XCTAssertNotEqual(decoded?.fingerprint, DerivedSeriesCodec.overnightFingerprint(startTs: 1, endTs: 2))
    }
}

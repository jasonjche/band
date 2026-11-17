import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// App-target derived-series timings. Parent runs these; skipped unless `BAND_PERF=1`.
final class DerivedSeriesMeasureTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BAND_PERF"] == "1",
            "set BAND_PERF=1 to run derived-series measure cases"
        )
    }

    func testMeasure_stressTimeline() {
        let t0 = 1_700_000_000
        var buckets: [HRBucket] = []
        buckets.reserveCapacity(1_440)
        for i in 0..<1_440 {
            let bpm = 58.0 + Double(i % 37) * 0.4
            buckets.append(HRBucket(ts: t0 + i * 60, bpm: bpm, minBpm: bpm, maxBpm: bpm))
        }
        let workouts = (0..<6).map { i -> (start: Date, end: Date) in
            let s = t0 + (7 + i * 2) * 3600
            return (
                Date(timeIntervalSince1970: TimeInterval(s)),
                Date(timeIntervalSince1970: TimeInterval(s + 1800))
            )
        }
        let sleepStart = Date(timeIntervalSince1970: TimeInterval(t0))
        let sleepEnd = Date(timeIntervalSince1970: TimeInterval(t0 + 8 * 3600))
        let unix = workouts.map { (Int($0.start.timeIntervalSince1970), Int($0.end.timeIntervalSince1970)) }
        let samples = buckets.map { (ts: $0.ts, bpm: $0.bpm) }
        let recovery = BandStress.recoveryWindows(workouts: unix, samples: samples)
        measure {
            _ = NativeHomeCharts.stressTimeline(
                buckets: buckets, sleepStart: sleepStart, sleepEnd: sleepEnd,
                workouts: workouts, recovery: recovery
            )
        }
    }

    func testMeasure_hrSmoothing1Hz() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0..<86_400).map { i in
            NativeHourPoint(time: start.addingTimeInterval(TimeInterval(i)), value: 60 + Double(i % 41) * 0.5)
        }
        measure {
            _ = NativeHRSmoothing.smooth(points)
        }
    }

    func testMeasure_hrDownsample() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0..<86_400).map { i in
            NativeHourPoint(time: start.addingTimeInterval(TimeInterval(i)), value: 60 + Double(i % 41) * 0.5)
        }
        measure {
            _ = NativeHeartRateMath.downsample(points, maxPoints: 300)
        }
    }

    func testMeasure_scopeSeriesMake() {
        let cal = Calendar(identifier: .gregorian)
        let end = cal.date(from: DateComponents(year: 2026, month: 11, day: 14))!
        let points = (0..<365).compactMap { i -> NativeDayPoint? in
            guard let day = cal.date(byAdding: .day, value: i - 364, to: end) else { return nil }
            let key = NativeScopeSeries.key(from: day, calendar: cal)
            return NativeDayPoint(key: key, value: 50 + Double(i % 20))
        }
        measure {
            _ = NativeScopeSeries.make(
                points: points, scope: .sixMonths, kind: .rate,
                calendar: cal, now: end, ending: end
            )
        }
    }
}

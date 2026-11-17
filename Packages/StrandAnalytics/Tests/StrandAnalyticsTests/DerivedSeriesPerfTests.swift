import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Derived-series benchmarks. Skipped unless `BAND_PERF=1`.
/// Prints `BAND_PERF <name>: median=…ms p90=…ms` — timings only, never sample values.
final class DerivedSeriesPerfTests: XCTestCase {

    private static let runs = 9
    private static let dayStart = 1_700_000_000
    private static let fixtures = Fixtures()

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BAND_PERF"] == "1",
            "set BAND_PERF=1 to run derived-series benchmarks"
        )
    }

    func testPerf_rmssdByBucket() {
        let rr = Self.fixtures.rr200k
        report("BandStress.rmssdByBucket") {
            _ = BandStress.rmssdByBucket(rr: rr)
        }
    }

    func testPerf_recoveryWindows() {
        let samples = Self.fixtures.hrMinute
        let workouts = Self.fixtures.workouts
        report("BandStress.recoveryWindows") {
            _ = BandStress.recoveryWindows(workouts: workouts, samples: samples)
        }
    }

    func testPerf_smoothCentered() {
        let points = Self.fixtures.stressPoints
        report("BandStress.smoothCentered") {
            _ = BandStress.smoothCentered(points: points, radius: 7)
        }
    }

    func testPerf_activityBuckets() {
        let buckets = Self.fixtures.bucketStarts
        let steps = Self.fixtures.steps
        let motion = Self.fixtures.motion
        report("BandStress.activityBuckets") {
            _ = BandStress.activityBuckets(bucketStarts: buckets, steps: steps, motion: motion)
        }
    }

    func testPerf_timeline() {
        let buckets = Self.fixtures.hrMinute
        let baselines = BandStress.Baselines.fallback
        let workouts = Self.fixtures.workouts
        let recovery = BandStress.recoveryWindows(workouts: workouts, samples: buckets)
        let activity = Set(Self.fixtures.bucketStarts.suffix(40))
        let rmssd = Dictionary(uniqueKeysWithValues: buckets.prefix(200).map { ($0.ts, 45.0) })
        report("BandStress.timeline") {
            _ = BandStress.timeline(
                buckets: buckets,
                baselines: baselines,
                sleepStart: Self.dayStart,
                sleepEnd: Self.dayStart + 8 * 3600,
                workouts: workouts,
                rmssdByBucket: rmssd,
                activityBuckets: activity,
                recovery: recovery,
                smoothRadius: 7
            )
        }
    }

    func testPerf_hrvAnalyzeNight() {
        let rr = Self.fixtures.rrNight
        report("HRVAnalyzer.analyze.night") {
            _ = HRVAnalyzer.analyze(rawRR: rr)
        }
    }

    func testPerf_hrvCleanRR() {
        let rr = Self.fixtures.rrNight
        report("HRVAnalyzer.cleanRRGapAware") {
            _ = HRVAnalyzer.cleanRRGapAware(rr)
        }
    }

    func testPerf_hrvRollingRmssd() {
        let rr = Self.fixtures.rrIntervalsNight
        report("HRVAnalyzer.rollingRmssd") {
            _ = HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 120, stepSec: 10, minBeatsPerWindow: 8)
        }
    }

    func testPerf_hrvTrend() {
        let nights = Self.fixtures.hrvNights
        report("HRVTrend.evaluate") {
            _ = HRVTrend.evaluate(nights: nights)
        }
    }

    func testPerf_healthspanCompute() {
        let days = Self.fixtures.healthspanDays
        let profile = HealthspanEngine.Profile(chronoAge: 32, sex: "male")
        report("HealthspanEngine.compute") {
            _ = HealthspanEngine.compute(days: days, profile: profile, asOfDay: days.last!.day)
        }
    }

    func testPerf_healthspanTrendPoints() {
        let days = HealthspanEngine.fillingConsistency(Self.fixtures.healthspanDays)
        let profile = HealthspanEngine.Profile(chronoAge: 32, sex: "male")
        report("HealthspanEngine.trendPoints") {
            _ = HealthspanEngine.trendPoints(days: days, profile: profile, asOfDay: days.last!.day)
        }
    }

    func testPerf_displaySmooth() {
        let points = Self.fixtures.hr1Hz
        report("DisplaySeries.smooth.1Hz") {
            _ = DisplaySeries.smooth(points, window: 45)
        }
    }

    func testPerf_displayDownsample() {
        let points = Self.fixtures.hr1Hz
        report("DisplaySeries.downsample") {
            _ = DisplaySeries.downsample(points, maxPoints: 300)
        }
    }

    func testPerf_performanceAssessmentHistory() {
        let series = Self.fixtures.assessmentSeries
        report("PerformanceAssessment.history12") {
            let windows = PerformanceAssessment.historyWindows(
                kind: .weekly, asOfDay: "2026-11-14", limit: 12
            )
            for window in windows {
                _ = PerformanceAssessment.build(window: window, series: series)
            }
        }
    }

    func testPerf_scopeSeriesMake() {
        let points = Self.fixtures.scopePoints
        report("ScopeSeries.daily") {
            _ = ScopeSeries.daily(
                points: points, fromEpoch: points.first!.epochDay,
                toEpoch: points.last!.epochDay
            )
        }
        report("ScopeSeries.weekly") {
            _ = ScopeSeries.grouped(
                points: points, fromEpoch: points.first!.epochDay,
                toEpoch: points.last!.epochDay, unitDays: 7
            )
        }
    }

    // MARK: - Timing

    private func report(_ name: String, body: () -> Void) {
        var samples: [Double] = []
        samples.reserveCapacity(Self.runs)
        body()
        for _ in 0..<Self.runs {
            let t0 = CFAbsoluteTimeGetCurrent()
            body()
            samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1_000)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let p90Idx = min(samples.count - 1, Int((Double(samples.count) * 0.9).rounded(.down)))
        let p90 = samples[p90Idx]
        let spread = samples.last! - samples.first!
        fputs(
            String(
                format: "BAND_PERF %@: median=%.3fms p90=%.3fms n=%d spread=%.3fms\n",
                name, median, p90, Self.runs, spread
            ),
            stderr
        )
        XCTAssertGreaterThan(median, 0)
    }

    // MARK: - Fixtures (synthetic; no phone-DB values)

    fileprivate struct Fixtures {
        let rr200k: [(ts: Int, ms: Double)]
        let rrNight: [Double]
        let rrIntervalsNight: [RRInterval]
        let hrMinute: [(ts: Int, bpm: Double)]
        let hr1Hz: [(ts: Int, value: Double)]
        let workouts: [(start: Int, end: Int)]
        let bucketStarts: [Int]
        let steps: [(ts: Int, activityClass: Int)]
        let motion: [(ts: Int, intensity: Double)]
        let stressPoints: [(ts: Int, value: Double)]
        let hrvNights: [HRVTrend.Night]
        let healthspanDays: [HealthspanEngine.Day]
        let assessmentSeries: PerformanceAssessment.Series
        let scopePoints: [ScopeSeries.Point]

        init() {
            let dayStart = DerivedSeriesPerfTests.dayStart
            var rr: [(ts: Int, ms: Double)] = []
            rr.reserveCapacity(200_000)
            for i in 0..<200_000 {
                let ts = dayStart + (i * 86_400) / 200_000
                let ms = 720.0 + Double(i % 29) * 4.0
                rr.append((ts, ms))
            }
            rr200k = rr

            var night: [Double] = []
            night.reserveCapacity(30_000)
            var nightRR: [RRInterval] = []
            nightRR.reserveCapacity(30_000)
            for i in 0..<30_000 {
                let ms = 780.0 + Double(i % 11) * 5.0
                night.append(ms)
                nightRR.append(RRInterval(ts: dayStart + i, rrMs: Int(ms)))
            }
            rrNight = night
            rrIntervalsNight = nightRR

            var minute: [(ts: Int, bpm: Double)] = []
            minute.reserveCapacity(1_440)
            var starts: [Int] = []
            starts.reserveCapacity(1_440)
            var stress: [(ts: Int, value: Double)] = []
            stress.reserveCapacity(1_440)
            for i in 0..<1_440 {
                let ts = dayStart + i * 60
                let bpm = 58.0 + Double(i % 37) * 0.4
                minute.append((ts, bpm))
                starts.append(ts)
                stress.append((ts, Double(i % 3)))
            }
            hrMinute = minute
            bucketStarts = starts
            stressPoints = stress

            var hz: [(ts: Int, value: Double)] = []
            hz.reserveCapacity(86_400)
            for i in 0..<86_400 {
                hz.append((ts: dayStart + i, value: 60.0 + Double(i % 41) * 0.5))
            }
            hr1Hz = hz

            workouts = [
                (dayStart + 7 * 3600, dayStart + 7 * 3600 + 2400),
                (dayStart + 12 * 3600, dayStart + 12 * 3600 + 3600),
                (dayStart + 15 * 3600, dayStart + 15 * 3600 + 1800),
                (dayStart + 17 * 3600, dayStart + 17 * 3600 + 2700),
                (dayStart + 19 * 3600, dayStart + 19 * 3600 + 1500),
                (dayStart + 21 * 3600, dayStart + 21 * 3600 + 1200),
            ]

            var stepRows: [(ts: Int, activityClass: Int)] = []
            stepRows.reserveCapacity(8_640)
            var motionRows: [(ts: Int, intensity: Double)] = []
            motionRows.reserveCapacity(8_640)
            for i in 0..<8_640 {
                let ts = dayStart + i * 10
                stepRows.append((ts, i % 20 == 0 ? 1 : 0))
                motionRows.append((ts, i % 17 == 0 ? 0.25 : 0.04))
            }
            steps = stepRows
            motion = motionRows

            let end = HealthspanEngine.isoEpochDay("2026-11-14")!
            var nights: [HRVTrend.Night] = []
            nights.reserveCapacity(365)
            var days: [HealthspanEngine.Day] = []
            days.reserveCapacity(365)
            var recovery: [String: Double] = [:]
            var strain: [String: Double] = [:]
            var sleepPerf: [String: Double] = [:]
            var sleepHours: [String: Double] = [:]
            var hrv: [String: Double] = [:]
            var rhr: [String: Double] = [:]
            var stepsMap: [String: Double] = [:]
            var scope: [ScopeSeries.Point] = []
            scope.reserveCapacity(365)
            for i in 0..<365 {
                let epoch = end - (364 - i)
                let key = HealthspanEngine.isoString(epoch)!
                let rmssd = 40.0 + Double(i % 13)
                nights.append(HRVTrend.Night(day: key, rmssdMs: rmssd))
                days.append(.init(
                    day: key, sleepHours: 7.2 + Double(i % 5) * 0.1,
                    sleepOnsetMin: 23 * 60, sleepWakeMin: 7 * 60,
                    steps: 7_000 + Double(i % 40) * 50,
                    restingHR: 52 + Double(i % 7),
                    vo2max: 46,
                    zone13Min: 18, zone45Min: 3,
                    strengthMin: i % 7 == 0 ? 40 : 0
                ))
                recovery[key] = 55 + Double(i % 30)
                strain[key] = 8 + Double(i % 9) * 0.4
                sleepPerf[key] = 70 + Double(i % 20)
                sleepHours[key] = 7.0 + Double(i % 6) * 0.15
                hrv[key] = rmssd
                rhr[key] = 52 + Double(i % 7)
                stepsMap[key] = 7_000 + Double(i % 40) * 50
                scope.append(ScopeSeries.Point(
                    epochDay: epoch, value: 50 + Double(i % 20), low: nil, high: nil
                ))
            }
            hrvNights = nights
            healthspanDays = days
            scopePoints = scope
            assessmentSeries = PerformanceAssessment.Series(
                recovery: recovery, strain21: strain, sleepPerformance: sleepPerf,
                sleepHours: sleepHours, hrv: hrv, rhr: rhr, steps: stepsMap
            )
        }
    }
}

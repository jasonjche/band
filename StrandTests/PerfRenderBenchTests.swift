import XCTest
import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics
@testable import Strand

/// Before/after benches for work that used to run in SwiftUI `body` (or on the main actor
/// during Home/Score rebuild). Parent runs these with the app test target; they are not a
/// Swift package. Baseline copies of the old paths live in this file so both run in one go.
final class PerfRenderBenchTests: XCTestCase {

    // MARK: - Fixtures (365 days, 400 sleeps with stagesJSON, 300 workouts)

    private struct Fixture {
        var days: [DailyMetric]
        var sleeps: [CachedSleepSession]
        var workouts: [WorkoutRow]
        var imported: [String: ImportedSleepFigures]
        var todayKey: String
        var today: Date
    }

    private static let stagesJSON: String = {
        var parts: [String] = []
        var t = 0
        let cycle: [(Int, String)] = [
            (18 * 60, "light"), (12 * 60, "deep"), (8 * 60, "rem"), (4 * 60, "wake"),
        ]
        for _ in 0..<12 {
            for (dur, stage) in cycle {
                parts.append("{\"start\":\(t),\"end\":\(t + dur),\"stage\":\"\(stage)\"}")
                t += dur
            }
        }
        return "[" + parts.joined(separator: ",") + "]"
    }()

    private static func fixture(
        days nDays: Int = 365,
        sleeps nSleeps: Int = 400,
        workouts nWorkouts: Int = 300
    ) -> Fixture {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 16))!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        var days: [DailyMetric] = []
        days.reserveCapacity(nDays)
        for back in (0..<nDays).reversed() {
            let date = cal.date(byAdding: .day, value: -back, to: today)!
            let key = fmt.string(from: date)
            days.append(DailyMetric(
                day: key, totalSleepMin: 420, efficiency: 0.9, deepMin: 80,
                remMin: 90, lightMin: 250, disturbances: 1, restingHr: 52,
                avgHrv: 60, recovery: 67, strain: 9, exerciseCount: 1
            ))
        }
        var sleeps: [CachedSleepSession] = []
        sleeps.reserveCapacity(nSleeps)
        for back in 0..<nSleeps {
            let date = cal.date(byAdding: .day, value: -back, to: today)!
            let end = Int(date.timeIntervalSince1970) + 8 * 3600
            sleeps.append(CachedSleepSession(
                startTs: end - 8 * 3600, endTs: end,
                efficiency: 0.9, restingHr: 52, avgHrv: 60, stagesJSON: stagesJSON
            ))
        }
        var workouts: [WorkoutRow] = []
        workouts.reserveCapacity(nWorkouts)
        for back in 0..<nWorkouts {
            let date = cal.date(byAdding: .day, value: -(back % nDays), to: today)!
            let start = Int(date.timeIntervalSince1970) + 12 * 3600
            workouts.append(WorkoutRow(
                startTs: start, endTs: start + 3600, sport: "running", source: "whoop",
                durationS: 3600, energyKcal: 400, avgHr: 140, maxHr: 170, strain: 8,
                distanceM: 8000, zonesJSON: "{\"z1\":10,\"z2\":20,\"z3\":40,\"z4\":20,\"z5\":10}",
                notes: nil, steps: 9000
            ))
        }
        return Fixture(
            days: days, sleeps: sleeps, workouts: workouts, imported: [:],
            todayKey: fmt.string(from: today), today: today
        )
    }

    private func medianMs(runs: Int = 7, warmup: Bool = true, _ work: () -> Void) -> Double {
        if warmup { work() }
        var samples: [Double] = []
        samples.reserveCapacity(runs)
        for _ in 0..<runs {
            let t = DispatchTime.now().uptimeNanoseconds
            work()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1_000_000)
        }
        samples.sort()
        return samples[runs / 2]
    }

    // MARK: - Baseline copies of old body paths

    /// Pre-change Sleep HR chart: every 2nd sample, cap 8_000 → thousands of Chart marks.
    private static func baselineOvernightPoints(from samples: [HRSample]) -> [NativeHourPoint] {
        NativeOvernightHeart.points(from: samples, every: 2, cap: 8_000)
    }

    /// Pre-change Sleep page: JSON-decode stagesJSON on every call (AnalyticsEngine.decodeStages).
    private static func baselineDecodeStages(_ json: String?) -> [StageSegment] {
        AnalyticsEngine.decodeStages(json)
    }

    /// Pre-change Home `body`: NativeDay.make + week series + calendar recovery, each calling resolve.
    private static func baselineHomeBodyPass(_ f: Fixture) -> (
        NativeDay.Model, [NativeDayPoint], [NativeDayPoint], [String: Double]
    ) {
        let model = NativeDay.make(
            days: f.days, sleeps: f.sleeps, workouts: f.workouts,
            todayKey: f.todayKey, connected: false, effortScale: .whoop,
            now: f.today, importedSleep: f.imported
        )
        let weekRecovery = NativeWeek.points(
            kind: .recovery, days: f.days, todayKey: f.todayKey,
            sleeps: f.sleeps, workouts: f.workouts, importedSleep: f.imported
        )
        let weekStrain = NativeWeek.points(
            kind: .strain, days: f.days, todayKey: f.todayKey,
            sleeps: f.sleeps, workouts: f.workouts, importedSleep: f.imported
        )
        let calendar = HomeCalendarRecovery.values(
            days: f.days, sleeps: f.sleeps, workouts: f.workouts, importedSleep: f.imported
        )
        return (model, weekRecovery, weekStrain, calendar)
    }

    // MARK: - Equivalence

    func testOvernightDisplayPointsMatchMeanOfRaw() {
        let start = 1_700_000_000
        let samples = (0..<(8 * 3600)).map { HRSample(ts: start + $0, bpm: 54 + ($0 % 7)) }
        let baseline = Self.baselineOvernightPoints(from: samples)
        let after = NativeOvernightHeart.make(samples: samples)
        XCTAssertGreaterThan(baseline.count, NativeOvernightHeart.displayMax)
        XCTAssertLessThanOrEqual(after.plotCount, NativeOvernightHeart.displayMax)
        XCTAssertEqual(
            after.average ?? -1,
            NativeScoreMath.mean(samples.map { Double($0.bpm) }) ?? -2,
            accuracy: 1e-9
        )
    }

    func testParsedStagesMatchAnalyticsEngineDecode() {
        let json = Self.stagesJSON
        let baseline = Self.baselineDecodeStages(json)
        let parsed = Repository.parseStagesJSON(json)
        XCTAssertEqual(baseline.count, parsed.count)
        XCTAssertEqual(baseline.map(\.start), parsed.map(\.start))
        XCTAssertEqual(baseline.map(\.end), parsed.map(\.end))
        XCTAssertEqual(baseline.map(\.stage), parsed.map(\.stage))
    }

    func testSleepPageDetailParsedStagesMatchJSONDecode() {
        let f = Self.fixture(days: 40, sleeps: 14, workouts: 8)
        let session = f.sleeps[0]
        let fromJSON = NativeSleepPageDetail.make(
            dayKey: NativeDayLogic.sleepSessionDayKey(
                Date(timeIntervalSince1970: TimeInterval(session.endTs))
            ),
            days: f.days, sleeps: f.sleeps, workouts: f.workouts, importedSleep: f.imported
        )
        let parsed = Repository.parseStagesJSON(session.stagesJSON)
        let fromCache = NativeSleepPageDetail.make(
            dayKey: NativeDayLogic.sleepSessionDayKey(
                Date(timeIntervalSince1970: TimeInterval(session.endTs))
            ),
            days: f.days, sleeps: f.sleeps, workouts: f.workouts, importedSleep: f.imported,
            parsedStages: parsed
        )
        XCTAssertEqual(fromJSON.hypnogram, fromCache.hypnogram)
        XCTAssertEqual(fromJSON.efficiency, fromCache.efficiency)
        XCTAssertEqual(fromJSON.hypnogramEstimated, fromCache.hypnogramEstimated)
    }

    func testNeedBreakdownMatchesResolverWithoutSecondEvaluate() {
        let f = Self.fixture(days: 40, sleeps: 40, workouts: 10)
        let scores = NativeBandScores.resolve(
            days: f.days, sleeps: f.sleeps, workouts: f.workouts, importedSleep: f.imported
        )
        let resolved = NativeSleepNeed.resolve(
            dayKey: f.todayKey, days: f.days, sleeps: f.sleeps,
            workouts: f.workouts, importedSleep: f.imported
        )
        let scored = scores.byDay[f.todayKey]
        XCTAssertEqual(resolved?.needMin, scored?.sleepNeed)
        XCTAssertEqual(resolved?.baselineMin ?? -1, scored?.needBaselineMin ?? -2, accuracy: 1e-9)
        XCTAssertEqual(resolved?.strainMin ?? -1, scored?.needStrainMin ?? -2, accuracy: 1e-9)
        XCTAssertEqual(resolved?.debtMin ?? -1, scored?.needDebtMin ?? -2, accuracy: 1e-9)
        if let resolved, resolved.hasBreakdown {
            XCTAssertEqual(
                (resolved.baselineMin ?? 0) + (resolved.strainMin ?? 0) + (resolved.debtMin ?? 0),
                resolved.needMin,
                accuracy: 1e-6
            )
        }
    }

    func testHomeRebuildMatchesPerBodyPass() {
        let f = Self.fixture(days: 40, sleeps: 40, workouts: 12)
        let (model, weekR, weekS, calendar) = Self.baselineHomeBodyPass(f)
        let snapshot = NativeHomeRebuild.run(NativeHomeRebuild.Input(
            days: f.days, sleeps: f.sleeps, importedSleep: f.imported,
            workouts: f.workouts, journalEntries: [], vo2max: nil,
            sampleHours: [], liveTodayStrain: nil,
            selectedKey: f.todayKey, selectedDay: f.today,
            effortScale: .whoop, smartAlarmEnabled: false, smartAlarmMinutes: 7 * 60,
            dashboardJSON: "", temperature: .celsius, stressExtraExclusions: [],
            now: f.today
        ))
        XCTAssertEqual(snapshot.dayModel.sleep.value, model.sleep.value)
        XCTAssertEqual(snapshot.dayModel.recovery.value, model.recovery.value)
        XCTAssertEqual(snapshot.dayModel.strain.value, model.strain.value)
        XCTAssertEqual(snapshot.weekRecovery.map(\.key), weekR.map(\.key))
        XCTAssertEqual(snapshot.weekStrain.map(\.key), weekS.map(\.key))
        XCTAssertEqual(snapshot.calendarRecovery, calendar)
        XCTAssertEqual(snapshot.activityItems.count, HomeActivityItem.make(from: model).count)
    }

    func testActivityMakeIsStableAcrossRepeats() {
        let f = Self.fixture(days: 10, sleeps: 2, workouts: 20)
        let row = f.workouts[0]
        let first = NativeActivityPageLogic.make(row, prior: f.workouts, scale: .whoop, zoneSet: nil, percents: [10, 20, 30, 20, 20])
        let second = NativeActivityPageLogic.make(row, prior: f.workouts, scale: .whoop, zoneSet: nil, percents: [10, 20, 30, 20, 20])
        XCTAssertEqual(first, second)
    }

    func testHRDisplayBudgetCapsDenseSeries() {
        let points = (0..<4_000).map {
            NativeHourPoint(time: Date(timeIntervalSince1970: Double($0)), value: 60)
        }
        let plotted = NativeHRDisplay.line(points)
        XCTAssertLessThanOrEqual(plotted.count, NativeHRDisplay.plotBudget)
        XCTAssertGreaterThan(plotted.count, 2)
        let short = Array(points.prefix(24))
        XCTAssertEqual(NativeHRDisplay.line(short).count, short.count)
    }

    // MARK: - Clock benches (parent must run; not a Swift package)

    func testBenchOvernightPointsBaseline() {
        let start = 1_700_000_000
        let samples = (0..<(8 * 3600)).map { HRSample(ts: start + $0, bpm: 54 + ($0 % 7)) }
        measure(metrics: [XCTClockMetric()]) {
            _ = Self.baselineOvernightPoints(from: samples)
        }
    }

    func testBenchOvernightDisplayPointsAfter() {
        let start = 1_700_000_000
        let samples = (0..<(8 * 3600)).map { HRSample(ts: start + $0, bpm: 54 + ($0 % 7)) }
        measure(metrics: [XCTClockMetric()]) {
            _ = NativeOvernightHeart.make(samples: samples)
        }
    }

    func testBenchStagesJSONDecodeBaseline() {
        let f = Self.fixture()
        measure(metrics: [XCTClockMetric()]) {
            var count = 0
            for session in f.sleeps {
                count += Self.baselineDecodeStages(session.stagesJSON).count
            }
            XCTAssertGreaterThan(count, 0)
        }
    }

    func testBenchStagesJSONParseAfter() {
        let f = Self.fixture()
        measure(metrics: [XCTClockMetric()]) {
            var count = 0
            var cache: [String: [ParsedSleepStage]] = [:]
            for session in f.sleeps {
                let key = Repository.sleepStageCacheKey(session)
                if let hit = cache[key] {
                    count += hit.count
                } else {
                    let parsed = Repository.parseStagesJSON(session.stagesJSON)
                    cache[key] = parsed
                    count += parsed.count
                }
            }
            XCTAssertGreaterThan(count, 0)
        }
    }

    func testBenchHomeBodyPassBaseline() {
        let f = Self.fixture()
        measure(metrics: [XCTClockMetric()]) {
            // Old: every SwiftUI invalidation re-ran resolve via make + week + calendar.
            for _ in 0..<3 {
                _ = Self.baselineHomeBodyPass(f)
            }
        }
    }

    func testBenchHomeRebuildAfter() {
        let f = Self.fixture()
        let input = NativeHomeRebuild.Input(
            days: f.days, sleeps: f.sleeps, importedSleep: f.imported,
            workouts: f.workouts, journalEntries: [], vo2max: nil,
            sampleHours: [], liveTodayStrain: nil,
            selectedKey: f.todayKey, selectedDay: f.today,
            effortScale: .whoop, smartAlarmEnabled: false, smartAlarmMinutes: 7 * 60,
            dashboardJSON: "", temperature: .celsius, stressExtraExclusions: [],
            now: f.today
        )
        measure(metrics: [XCTClockMetric()]) {
            _ = NativeHomeRebuild.run(input)
        }
    }

    func testBenchScoreRebuildAfter() {
        let f = Self.fixture()
        let parsed = f.sleeps.first.map { Repository.parseStagesJSON($0.stagesJSON) } ?? []
        measure(metrics: [XCTClockMetric()]) {
            _ = NativeScoreRebuild.run(
                kind: .sleep, dayKey: f.todayKey, days: f.days, sleeps: f.sleeps,
                workouts: f.workouts, importedSleep: f.imported, effortScale: .whoop,
                highSleepStress: nil, liveStrain: nil, sleepStress: nil,
                parsedStages: parsed, includingSleepDetail: true
            )
        }
    }

    func testBenchActivityMakeBaselinePerBody() {
        let f = Self.fixture(days: 30, sleeps: 4, workouts: 120)
        let row = f.workouts[0]
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<8 {
                _ = NativeActivityPageLogic.make(
                    row, prior: f.workouts, scale: .whoop, zoneSet: nil,
                    percents: [10, 20, 30, 20, 20]
                )
            }
        }
    }

    func testBenchActivityMakeAfterOnce() {
        let f = Self.fixture(days: 30, sleeps: 4, workouts: 120)
        let row = f.workouts[0]
        measure(metrics: [XCTClockMetric()]) {
            _ = NativeActivityPageLogic.make(
                row, prior: f.workouts, scale: .whoop, zoneSet: nil,
                percents: [10, 20, 30, 20, 20]
            )
        }
    }

    func testMedianTimingPrintsForParent() {
        let f = Self.fixture()
        let before = medianMs {
            for _ in 0..<3 { _ = Self.baselineHomeBodyPass(f) }
        }
        let after = medianMs {
            _ = NativeHomeRebuild.run(NativeHomeRebuild.Input(
                days: f.days, sleeps: f.sleeps, importedSleep: f.imported,
                workouts: f.workouts, journalEntries: [], vo2max: nil,
                sampleHours: [], liveTodayStrain: nil,
                selectedKey: f.todayKey, selectedDay: f.today,
                effortScale: .whoop, smartAlarmEnabled: false, smartAlarmMinutes: 7 * 60,
                dashboardJSON: "", temperature: .celsius, stressExtraExclusions: [],
                now: f.today
            ))
        }
        let stagesBefore = medianMs {
            for session in f.sleeps { _ = Self.baselineDecodeStages(session.stagesJSON) }
        }
        var cache: [String: [ParsedSleepStage]] = [:]
        let stagesAfter = medianMs {
            cache.removeAll(keepingCapacity: true)
            for session in f.sleeps {
                let key = Repository.sleepStageCacheKey(session)
                if cache[key] == nil {
                    cache[key] = Repository.parseStagesJSON(session.stagesJSON)
                }
            }
        }
        let start = 1_700_000_000
        let samples = (0..<(8 * 3600)).map { HRSample(ts: start + $0, bpm: 54 + ($0 % 7)) }
        let hrBefore = medianMs { _ = Self.baselineOvernightPoints(from: samples) }
        let hrAfter = medianMs { _ = NativeOvernightHeart.make(samples: samples) }
        XCTContext.runActivity(named: """
            medians ms homeBody=\(before) homeRebuild=\(after) \
            stagesJSON=\(stagesBefore) stagesCache=\(stagesAfter) \
            overnightPoints=\(hrBefore) overnightDisplay=\(hrAfter)
            """) { _ in }
        XCTAssertGreaterThan(before, 0)
        XCTAssertGreaterThan(after, 0)
    }
}

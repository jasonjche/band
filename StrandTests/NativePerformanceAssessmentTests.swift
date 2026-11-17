import XCTest
import StrandAnalytics
import WhoopStore
import StrandDesign
@testable import Strand

final class NativePerformanceAssessmentTests: XCTestCase {

    func testMoreListIncludesAssessments() {
        XCTAssertTrue(NativeMoreItem.titles.contains("Assessments"))
        XCTAssertEqual(NativeMoreItem.assessments.icon, "calendar")
    }

    func testSleepHoursMatchSleepPageAsleepMinutes() {
        let light = 250.0, deep = 70.0, rem = 90.0, total = 980.0
        let engine = PerformanceAssessment.asleepMinutes(
            light: light, deep: deep, rem: rem, totalSleepMin: total
        )
        let page = NativeDayLogic.asleepMinutes(
            light: light, deep: deep, rem: rem, totalSleepMin: total
        )
        XCTAssertEqual(engine, page)
        XCTAssertEqual(engine ?? -1, 410, accuracy: 1e-9)
    }

    func testAssessmentHoursUseMainSessionWhenDailyStagesAreStacked() {
        let start = 1_783_000_000
        let end = start + 643 * 60
        let session = CachedSleepSession(
            startTs: start, endTs: end, efficiency: 0.82, restingHr: nil, avgHrv: nil,
            stagesJSON: "{\"light\":291,\"rem\":124,\"deep\":113,\"awake\":115}"
        )
        XCTAssertEqual(NativePerformanceAssessmentModel.sessionAsleep(session) ?? -1, 528, accuracy: 1e-9)
        let byDay = NativePerformanceAssessmentModel.mainSession(byDay: [session])
        XCTAssertEqual(byDay.count, 1)
        let hours = PerformanceAssessment.asleepMinutes(
            light: 953, deep: 72, rem: 145, totalSleepMin: 1171,
            mainSessionAsleepMin: NativePerformanceAssessmentModel.sessionAsleep(session)
        )
        XCTAssertEqual(hours ?? -1, 528, accuracy: 1e-9)
        XCTAssertEqual(
            NativeDayLogic.asleepMinutes(light: 250, deep: 70, rem: 90, totalSleepMin: 431),
            PerformanceAssessment.asleepMinutes(light: 250, deep: 70, rem: 90, totalSleepMin: 431)
        )
    }

    func testMetricFormatting() {
        XCTAssertEqual(
            NativePerformanceAssessmentCopy.format(54.4, metric: .recovery),
            "54%"
        )
        XCTAssertEqual(
            NativePerformanceAssessmentCopy.format(8.41, metric: .strain),
            "8.4"
        )
        XCTAssertEqual(
            NativePerformanceAssessmentCopy.format(7.36, metric: .sleepHours),
            "7.4 hr"
        )
        XCTAssertEqual(
            NativePerformanceAssessmentCopy.format(47.2, metric: .hrv),
            "47 ms"
        )
        XCTAssertEqual(
            NativePerformanceAssessmentCopy.format(15.14, metric: .respRate),
            "15.1 breaths/min"
        )
    }

    func testRecoveryValueUsesBandTint() {
        let row = PerformanceAssessment.MetricDelta(
            metric: .recovery,
            current: ComparisonEngine.stat([71]),
            previous: ComparisonEngine.stat([60]),
            comparison: ComparisonEngine.compare(current: [71], previous: [60])
        )
        XCTAssertEqual(NativePerformanceAssessmentCopy.valueText(row), "71%")
        XCTAssertEqual(NativePerformanceAssessmentCopy.priorText(row), "60%")
        XCTAssertEqual(NativePerformanceAssessmentCopy.delta(row), NativeScore.Delta.up)
        XCTAssertEqual(NativePerformanceAssessmentCopy.valueTint(row), NativeTokens.recoveryHigh)
    }

    func testNotifyPolicyDefaultOff() {
        XCTAssertNil(
            PerformanceAssessment.NotifyPolicy.shouldNotify(
                enabled: false, asOfDay: "2026-06-15", lastNotifiedEnd: nil
            )
        )
        XCTAssertEqual(
            WeeklyReportNotifier.enabledKey,
            "behavior.weeklyReportNudge"
        )
    }

    func testHistoryCaptionIncludesBalanceAndRecovery() {
        var recovery: [String: Double] = [:]
        for d in 8...14 { recovery[String(format: "2026-06-%02d", d)] = 71 }
        for d in 1...7 { recovery[String(format: "2026-06-%02d", d)] = 60 }
        let report = PerformanceAssessment.build(
            kind: .weekly,
            series: .init(recovery: recovery),
            asOfDay: "2026-06-15"
        )!
        let caption = NativePerformanceAssessmentCopy.historyCaption(report)
        XCTAssertTrue(caption.contains("71% recovery"), caption)
    }

    func testDriverNightsCopy() {
        XCTAssertEqual(
            NativePerformanceAssessmentCopy.driverNights(1, kind: .weekly),
            "Logged on 1 night this week."
        )
        XCTAssertEqual(
            NativePerformanceAssessmentCopy.driverNights(3, kind: .monthly),
            "Logged on 3 nights this month."
        )
    }

    func testSportCopy() {
        let sport = PerformanceAssessment.SportDelta(
            sport: "Running", sessions: 2, minutes: 70,
            priorSessions: 1, priorMinutes: 20
        )
        XCTAssertEqual(NativePerformanceAssessmentCopy.sportValue(sport), "2 · 1:10")
        XCTAssertEqual(NativePerformanceAssessmentCopy.sportPrior(sport), "1 · 0:20")
        XCTAssertEqual(NativePerformanceAssessmentCopy.sportDelta(sport), NativeScore.Delta.up)
    }
}

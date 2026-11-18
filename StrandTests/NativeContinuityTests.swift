import XCTest
import SwiftUI
@testable import Strand

/// Pins Continuity IDs and Reduce Motion gating. Zoom modifiers are iOS 18 view
/// chrome; these tests cover the mapping the sources and destinations share.
final class NativeContinuityTests: XCTestCase {

    func testReduceMotionDisablesZoomGeometry() {
        XCTAssertTrue(NativeContinuity.allowsZoom(reduceMotion: false))
        XCTAssertFalse(NativeContinuity.allowsZoom(reduceMotion: true))
    }

    func testGatedAnimationNilsWhenReduced() {
        XCTAssertNotNil(NativeContinuity.gated(NativeContinuity.inScreen, reduced: false))
        XCTAssertNil(NativeContinuity.gated(NativeContinuity.inScreen, reduced: true))
        XCTAssertNil(NativeContinuity.gated(NativeContinuity.sheet, reduced: true))
    }

    func testInScreenSpringStaysInTheCalmBand() {
        XCTAssertEqual(NativeContinuity.inScreen, Animation.spring(response: 0.36, dampingFraction: 0.90))
        XCTAssertEqual(NativeContinuity.sheet, Animation.spring(response: 0.40, dampingFraction: 0.88))
    }

    func testHomeRingsMapOntoDistinctScoreIDs() {
        XCTAssertEqual(NativeContinuity.ring(for: .sleep), .homeRing(.sleep))
        XCTAssertEqual(NativeContinuity.ring(for: .metric(HeroRingMetric.charge)), .homeRing(.recovery))
        XCTAssertEqual(NativeContinuity.ring(for: .metric(HeroRingMetric.effort)), .homeRing(.strain))
        XCTAssertNotEqual(NativeContinuityID.homeRing(.sleep), NativeContinuityID.homeRing(.recovery))
        XCTAssertNotEqual(NativeContinuityID.homeRing(.recovery), NativeContinuityID.homeRing(.strain))
    }

    func testStressTileAndChartKeepSeparateSources() {
        XCTAssertNotEqual(NativeContinuityID.homeStressTile, NativeContinuityID.homeStressChart)
        XCTAssertNotEqual(NativeContinuityID.homeStressTile, NativeContinuityID.sleepStress)
        XCTAssertNotEqual(NativeContinuityID.homeHealthTile, NativeContinuityID.tab(.healthMonitor))
    }

    func testWeekCardIDsMatchThePushedDestinationKind() {
        XCTAssertEqual(NativeContinuity.weekCard(title: "Time in Bed"), .scoreTrend("Time in Bed"))
        XCTAssertEqual(NativeContinuity.weekCard(title: "Hours of Sleep"), .scoreTrend("Hours of Sleep"))
        XCTAssertEqual(NativeContinuity.weekCard(title: "Restorative Sleep"), .scoreTrend("Restorative Sleep"))
        XCTAssertEqual(NativeContinuity.weekCard(title: "Heart Rate Zones 1–3"), .scoreTrend("Heart Rate Zones 1–3"))
        XCTAssertEqual(NativeContinuity.weekCard(title: "Sleep Stress"), .sleepStress)
        XCTAssertEqual(NativeContinuity.weekCard(title: "Sleep Consistency"), .sleepConsistency)
        XCTAssertEqual(NativeContinuity.weekCard(title: "Sleep Debt"), .scoreMetric("sleep_debt_min"))
        XCTAssertEqual(NativeContinuity.weekCard(title: "Hours vs. Needed"), .scoreMetric("hours_vs_needed_pct"))
        XCTAssertEqual(NativeContinuity.weekCard(title: "Sleep Efficiency"), .scoreMetric("sleep_efficiency"))
        XCTAssertEqual(NativeContinuity.weekCard(title: "Heart Rate Variability"), .scoreMetric("hrv"))
    }

    func testSleepCardIDsMatchScorePagePushes() {
        XCTAssertEqual(NativeContinuity.sleepCard(title: "Last Night"), .sleepHypnogram)
        XCTAssertEqual(NativeContinuity.sleepCard(title: "Overnight Heart Rate"), .scoreMetric("avg_hr"))
        XCTAssertEqual(NativeContinuity.sleepCard(title: "Hours vs. Needed"), .scoreMetric("hours_vs_needed_pct"))
        XCTAssertEqual(NativeContinuity.sleepCard(title: "Sleep Consistency"), .sleepConsistency)
        XCTAssertEqual(NativeContinuity.sleepCard(title: "Sleep Efficiency"), .scoreMetric("sleep_efficiency"))
        XCTAssertEqual(NativeContinuity.sleepCard(title: "Sleep Stress"), .sleepStress)
    }

    func testContributorRowIDsPreferMetricKeys() {
        let hrv = NativeScore.Row(
            title: "Heart Rate Variability",
            value: "66",
            prior: "60",
            symbol: "heart.fill",
            delta: .none,
            route: .metric("hrv")
        )
        XCTAssertEqual(NativeContinuity.row(hrv), .scoreMetric("hrv"))

        let consistency = NativeScore.Row(
            title: "Sleep Consistency",
            value: "80%",
            prior: "78%",
            symbol: "calendar",
            delta: .none,
            route: .metric("sleep_consistency")
        )
        XCTAssertEqual(NativeContinuity.row(consistency), .sleepConsistency)

        let sleepPerf = NativeScore.Row(
            title: "Sleep Performance",
            value: "90%",
            prior: "88%",
            symbol: "moon.fill",
            delta: .none,
            route: .sleep
        )
        XCTAssertEqual(NativeContinuity.row(sleepPerf), .tab(.sleep))
    }

    func testSheetIDsAreStableAndDistinct() {
        XCTAssertEqual(NativeContinuityID.liftSession, NativeContinuityID.liftSession)
        XCTAssertNotEqual(NativeContinuityID.liftSession, NativeContinuityID.addActivity)
        XCTAssertNotEqual(NativeContinuityID.addActivity, NativeContinuityID.morningJournal)
        XCTAssertNotEqual(NativeContinuityID.homeJournal, NativeContinuityID.morningJournal)
    }

    func testHealthTabIDsCoverEachPushedRow() {
        XCTAssertEqual(NativeContinuityID.healthItem(.trends), .healthItem(.trends))
        XCTAssertEqual(NativeContinuityID.healthItem(.reports), .healthItem(.reports))
        XCTAssertNotEqual(NativeContinuityID.healthItem(.trends), NativeContinuityID.healthItem(.reports))
        XCTAssertNotEqual(
            NativeContinuityID.healthspanTrend(.bandAge),
            NativeContinuityID.healthspanTrend(.pace)
        )
    }

    func testDashboardIDsStayUniquePerCard() {
        let hrv = HomeMetricItem(
            title: "Heart Rate Variability",
            value: "66",
            unit: "ms",
            prior: nil,
            delta: .none,
            symbol: "heart.fill",
            tint: .red,
            points: [],
            bars: false,
            route: .metric("hrv")
        )
        let steps = HomeMetricItem(
            title: "Steps",
            value: "1,200",
            unit: nil,
            prior: nil,
            delta: .none,
            symbol: "figure.walk",
            tint: .green,
            points: [],
            bars: false,
            route: .metric("steps")
        )
        XCTAssertEqual(NativeContinuity.dashboard(hrv), .homeDashboard("Heart Rate Variability"))
        XCTAssertNotEqual(NativeContinuity.dashboard(hrv), NativeContinuity.dashboard(steps))
    }
}

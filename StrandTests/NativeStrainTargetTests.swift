import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

@MainActor
final class NativeStrainTargetTests: XCTestCase {

    func testPastDayIsNil() {
        let today = day("2026-11-17", recovery: 72, strain21: 8)
        let imported = importSleep(today.day)
        let got = NativeStrainTarget.resolve(
            viewingKey: "2026-11-16",
            todayKey: "2026-11-17",
            days: [today],
            importedSleep: imported
        )
        XCTAssertNil(got)
    }

    func testUnknownRecoveryIsNil() {
        let today = day("2026-11-17", recovery: nil, strain21: 8)
        XCTAssertNil(
            NativeStrainTarget.resolve(
                viewingKey: today.day,
                todayKey: today.day,
                days: [today]
            )
        )
    }

    func testImportedRecoveryMatchesHomeRing() {
        var days: [DailyMetric] = []
        var imported: [String: ImportedSleepFigures] = [:]
        for i in 1...20 {
            let key = String(format: "2026-10-%02d", i)
            days.append(day(key, recovery: 60, strain21: 8))
            imported[key] = ImportedSleepFigures(
                performancePct: 80, consistencyPct: 70, needMin: 480, debtMin: 0
            )
        }
        let today = day("2026-11-17", recovery: 71, strain21: 6)
        days.append(today)
        imported[today.day] = ImportedSleepFigures(
            performancePct: 82, consistencyPct: 70, needMin: 480, debtMin: 0
        )
        let scores = NativeBandScores.resolve(days: days, importedSleep: imported)
        XCTAssertEqual(scores.byDay[today.day]?.recovery, 71)
        let got = NativeStrainTarget.resolve(
            viewingKey: today.day,
            todayKey: today.day,
            days: days,
            importedSleep: imported
        )
        let expect = BandStrainTarget.recommend(
            recovery: 71,
            recentStrain21: NativeStrainTarget.history21(
                days: days, excluding: today.day, importedSleep: imported
            )
        )
        XCTAssertEqual(got, expect)
        XCTAssertEqual(got?.label, .push)
        XCTAssertEqual(got?.personalized, true)
    }

    func testHistoryExcludesTodayAndUsesWhoopScale() {
        let prior = day("2026-11-16", recovery: 50, strain21: 7.1)
        let today = day("2026-11-17", recovery: 50, strain21: 18)
        let imported = importSleep(prior.day).merging(importSleep(today.day)) { _, n in n }
        let hist = NativeStrainTarget.history21(
            days: [today, prior], excluding: today.day, importedSleep: imported
        )
        XCTAssertEqual(hist.count, 1)
        XCTAssertEqual(hist[0], 7.1, accuracy: 1e-9)
    }

    func testCaptionAndPosition() {
        let result = BandStrainTarget.Result(range: 10.2...13.8, label: .maintain, personalized: true)
        XCTAssertEqual(
            NativeStrainTarget.caption(result: result, strain21: 11.0),
            "Target 10.2-13.8 · Maintain · In range"
        )
        XCTAssertEqual(
            NativeStrainTarget.caption(result: result, strain21: 9.0),
            "Target 10.2-13.8 · Maintain · Below"
        )
        XCTAssertEqual(
            NativeStrainTarget.caption(result: result, strain21: 14.1),
            "Target 10.2-13.8 · Maintain · Above"
        )
        XCTAssertEqual(
            NativeStrainTarget.caption(result: result, strain21: nil),
            "Target 10.2-13.8 · Maintain"
        )
        XCTAssertEqual(NativeStrainTarget.position(strain21: 10.2, range: result.range), .inRange)
        XCTAssertEqual(NativeStrainTarget.position(strain21: 13.8, range: result.range), .inRange)
    }

    func testRingFractionIsOnTheUnitTrack() {
        let frac = NativeStrainTarget.ringFraction(10.5...14.7)
        XCTAssertEqual(frac.lowerBound, 10.5 / 21, accuracy: 1e-12)
        XCTAssertEqual(frac.upperBound, 14.7 / 21, accuracy: 1e-12)
    }

    private func day(_ key: String, recovery: Double?, strain21: Double?) -> DailyMetric {
        DailyMetric(
            day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
            lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: recovery,
            strain: strain21.map { StrainScorer.effortValue(fromWhoopStrain: $0) },
            exerciseCount: nil
        )
    }

    private func importSleep(_ key: String) -> [String: ImportedSleepFigures] {
        [key: ImportedSleepFigures(performancePct: 80, consistencyPct: 70, needMin: 480, debtMin: 0)]
    }
}

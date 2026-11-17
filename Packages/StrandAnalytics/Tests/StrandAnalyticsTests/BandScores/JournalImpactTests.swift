import XCTest
@testable import StrandAnalytics

final class JournalImpactTests: XCTestCase {

    private func ymd(_ y: Int, _ m: Int, _ d: Int) -> String {
        String(format: "%04d-%02d-%02d", y, m, d)
    }

    private func days(_ start: String, count: Int) -> [String] {
        (0..<count).compactMap { JournalImpact.shiftDay(start, by: $0) }
    }

    private func answers(id: String, yes: [String], no: [String]) -> [JournalImpact.Answer] {
        yes.map { JournalImpact.Answer(day: $0, behaviorId: id, yes: true) }
            + no.map { JournalImpact.Answer(day: $0, behaviorId: id, yes: false) }
    }

    private func row(_ rows: [JournalImpact.Insight], _ id: String) -> JournalImpact.Insight? {
        rows.first { $0.behaviorId == id }
    }

    // MARK: - Known effects

    func testKnownPositiveEffectIsHelps() {
        let yes = days("2026-01-01", count: 8)
        let no = days("2026-02-01", count: 8)
        var recovery: [String: Double] = [:]
        for (i, d) in yes.enumerated() { recovery[d] = 80 + Double(i % 3) }
        for (i, d) in no.enumerated() { recovery[d] = 70 + Double(i % 3) }
        let out = JournalImpact.rank(
            answers: answers(id: "Meditation", yes: yes, no: no),
            recoveryByDay: recovery,
            asOfDay: "2026-04-01",
            windowDays: 365
        )
        let r = row(out, "Meditation")
        XCTAssertEqual(r?.recovery?.verdict, .helps)
        XCTAssertGreaterThan(r?.recovery?.effect ?? 0, 5)
        XCTAssertGreaterThan(r?.recovery?.intervalLow ?? 0, 0)
        XCTAssertEqual(out.count, 1)
    }

    func testKnownNegativeEffectIsHurts() {
        let yes = days("2026-01-01", count: 8)
        let no = days("2026-02-01", count: 8)
        var recovery: [String: Double] = [:]
        for (i, d) in yes.enumerated() { recovery[d] = 50 + Double(i % 3) }
        for (i, d) in no.enumerated() { recovery[d] = 70 + Double(i % 3) }
        let out = JournalImpact.rank(
            answers: answers(id: "Alcohol", yes: yes, no: no),
            recoveryByDay: recovery,
            asOfDay: "2026-04-01",
            windowDays: 365
        )
        let rec = row(out, "Alcohol")?.recovery
        XCTAssertEqual(rec?.verdict, .hurts)
        XCTAssertLessThan(rec?.effect ?? 0, -10)
        XCTAssertLessThan(rec?.intervalHigh ?? 0, 0)
        XCTAssertEqual(rec?.nYes, 8)
        XCTAssertEqual(rec?.nNo, 8)
    }

    func testKnownNullStaysUnclear() {
        let yes = days("2026-01-01", count: 10)
        let no = days("2026-02-01", count: 10)
        var recovery: [String: Double] = [:]
        for (i, d) in yes.enumerated() { recovery[d] = 70 + Double(i % 3) }
        for (i, d) in no.enumerated() { recovery[d] = 70 + Double(i % 3) }
        let rec = row(
            JournalImpact.rank(
                answers: answers(id: "Caffeine", yes: yes, no: no),
                recoveryByDay: recovery,
                asOfDay: "2026-04-01",
                windowDays: 365
            ),
            "Caffeine"
        )?.recovery
        XCTAssertEqual(rec?.verdict, .unclear)
        XCTAssertLessThanOrEqual(rec?.intervalLow ?? 1, 0)
        XCTAssertGreaterThanOrEqual(rec?.intervalHigh ?? -1, 0)
    }

    func testBelowMinimumProducesNoEffect() {
        let yes = days("2026-01-01", count: 4)
        let no = days("2026-02-01", count: 10)
        var recovery: [String: Double] = [:]
        for d in yes { recovery[d] = 40 }
        for d in no { recovery[d] = 70 }
        let insight = row(
            JournalImpact.rank(
                answers: answers(id: "Sauna", yes: yes, no: no),
                recoveryByDay: recovery,
                asOfDay: "2026-04-01",
                windowDays: 365
            ),
            "Sauna"
        )
        XCTAssertNil(insight?.recovery)
        XCTAssertEqual(insight?.nYesAll, 4)
        XCTAssertEqual(insight?.nNoAll, 10)
        XCTAssertEqual(insight?.neededYes, 1)
        XCTAssertEqual(insight?.neededNo, 0)
    }

    func testUnloggedDaysAreNotNo() {
        let yes = days("2026-01-01", count: 6)
        let no = days("2026-02-01", count: 6)
        var recovery: [String: Double] = [:]
        for d in days("2026-01-01", count: 60) { recovery[d] = 90 }
        for d in yes { recovery[d] = 50 }
        for d in no { recovery[d] = 70 }
        let rec = row(
            JournalImpact.rank(
                answers: answers(id: "Alcohol", yes: yes, no: no),
                recoveryByDay: recovery,
                asOfDay: "2026-04-01",
                windowDays: 365
            ),
            "Alcohol"
        )?.recovery
        XCTAssertEqual(rec?.nYes, 6)
        XCTAssertEqual(rec?.nNo, 6)
        XCTAssertEqual(rec?.verdict, .hurts)
    }

    // MARK: - Alignment

    /// Answer on D pairs with recovery on D. A planted D+1 trap must not drive the sign.
    func testAnswerDayPairsWithRecoveryOnTheSameDay() {
        XCTAssertEqual(JournalImpact.alignmentLagDays, 0)
        let yes = (0..<6).map { ymd(2026, 6, 1 + 4 * $0) } // 1,5,9,13,17,21
        let no = (0..<6).map { ymd(2026, 6, 2 + 4 * $0) }  // 2,6,10,14,18,22
        var recovery: [String: Double] = [:]
        for d in 1...30 {
            recovery[ymd(2026, 6, d)] = 70
        }
        for d in yes {
            recovery[d] = 50
            if let next = JournalImpact.shiftDay(d, by: 1) {
                recovery[next] = 90
            }
        }
        for d in no { recovery[d] = 70 }
        let rec = row(
            JournalImpact.rank(
                answers: answers(id: "Alcohol", yes: yes, no: no),
                recoveryByDay: recovery,
                asOfDay: "2026-07-01",
                windowDays: 365
            ),
            "Alcohol"
        )?.recovery
        XCTAssertEqual(rec?.verdict, .hurts)
        XCTAssertLessThan(rec?.effect ?? 0, -10)
        XCTAssertEqual(rec?.nYes, 6)
        XCTAssertEqual(rec?.nNo, 6)
    }

    func testMissingSameDayRecoveryDoesNotPairWithTheNextMorning() {
        let yes = (0..<6).map { ymd(2026, 6, 1 + 4 * $0) }
        let no = (0..<6).map { ymd(2026, 6, 3 + 4 * $0) }
        var recovery: [String: Double] = [:]
        for d in yes {
            if let next = JournalImpact.shiftDay(d, by: 1) { recovery[next] = 40 }
        }
        for d in no {
            if let next = JournalImpact.shiftDay(d, by: 1) { recovery[next] = 80 }
        }
        let insight = row(
            JournalImpact.rank(
                answers: answers(id: "Alcohol", yes: yes, no: no),
                recoveryByDay: recovery,
                asOfDay: "2026-07-01",
                windowDays: 365
            ),
            "Alcohol"
        )
        XCTAssertNil(insight?.recovery)
        XCTAssertEqual(insight?.nYesAll, 0)
        XCTAssertEqual(insight?.nNoAll, 0)
    }

    // MARK: - Window

    func testWindowFallsBackToAllHistoryWhenThin() {
        let oldYes = days("2026-01-01", count: 8)
        let windowYes = days("2026-05-01", count: 3)
        let no = days("2026-05-10", count: 8)
        var recovery: [String: Double] = [:]
        for d in oldYes { recovery[d] = 40 }
        for d in windowYes { recovery[d] = 40 }
        for d in no { recovery[d] = 70 }
        let rec = row(
            JournalImpact.rank(
                answers: answers(id: "Alcohol", yes: oldYes + windowYes, no: no),
                recoveryByDay: recovery,
                asOfDay: "2026-06-01",
                windowDays: 90
            ),
            "Alcohol"
        )?.recovery
        XCTAssertEqual(rec?.usedFullHistory, true)
        XCTAssertEqual(rec?.nYes, 11)
        XCTAssertEqual(rec?.verdict, .hurts)
    }

    func testWindowIsPreferredWhenItClearsTheGate() {
        let oldYes = days("2026-01-01", count: 10)
        let oldNo = days("2026-01-15", count: 10)
        let winYes = days("2026-04-01", count: 6)
        let winNo = days("2026-04-15", count: 6)
        var recovery: [String: Double] = [:]
        for d in oldYes { recovery[d] = 68 }
        for d in oldNo { recovery[d] = 70 }
        for d in winYes { recovery[d] = 40 }
        for d in winNo { recovery[d] = 80 }
        let rec = row(
            JournalImpact.rank(
                answers: answers(id: "Alcohol", yes: oldYes + winYes, no: oldNo + winNo),
                recoveryByDay: recovery,
                asOfDay: "2026-06-01",
                windowDays: 90
            ),
            "Alcohol"
        )?.recovery
        XCTAssertEqual(rec?.usedFullHistory, false)
        XCTAssertEqual(rec?.nYes, 6)
        XCTAssertEqual(rec?.nNo, 6)
        XCTAssertEqual(rec?.verdict, .hurts)
        XCTAssertLessThan(rec?.effect ?? 0, -20)
    }

    // MARK: - Sleep secondary + ranking + determinism

    func testSleepIsComputedOnTheSameSplit() {
        let yes = days("2026-01-01", count: 8)
        let no = days("2026-02-01", count: 8)
        var recovery: [String: Double] = [:]
        var sleep: [String: Double] = [:]
        for (i, d) in yes.enumerated() {
            recovery[d] = 50 + Double(i % 3)
            sleep[d] = 60 + Double(i % 3)
        }
        for (i, d) in no.enumerated() {
            recovery[d] = 70 + Double(i % 3)
            sleep[d] = 80 + Double(i % 3)
        }
        let insight = row(
            JournalImpact.rank(
                answers: answers(id: "Alcohol", yes: yes, no: no),
                recoveryByDay: recovery,
                sleepByDay: sleep,
                asOfDay: "2026-04-01",
                windowDays: 365
            ),
            "Alcohol"
        )
        XCTAssertEqual(insight?.recovery?.verdict, .hurts)
        XCTAssertEqual(insight?.sleep?.verdict, .hurts)
        XCTAssertLessThan(insight?.sleep?.effect ?? 0, -10)
    }

    func testClearResultsSortByAbsoluteEffectThenId() {
        var recovery: [String: Double] = [:]
        let aYes = days("2026-01-01", count: 6)
        let aNo = days("2026-01-15", count: 6)
        let bYes = days("2026-02-01", count: 6)
        let bNo = days("2026-02-15", count: 6)
        let cYes = days("2026-03-01", count: 3)
        let cNo = days("2026-03-15", count: 6)
        for d in aYes { recovery[d] = 40 }
        for d in aNo { recovery[d] = 80 }
        for (i, d) in bYes.enumerated() { recovery[d] = 70 + Double(i % 3) }
        for (i, d) in bNo.enumerated() { recovery[d] = 70 + Double(i % 3) }
        for d in cYes { recovery[d] = 10 }
        for d in cNo { recovery[d] = 90 }
        let out = JournalImpact.rank(
            answers: answers(id: "Alcohol", yes: aYes, no: aNo)
                + answers(id: "Caffeine", yes: bYes, no: bNo)
                + answers(id: "Sauna", yes: cYes, no: cNo),
            recoveryByDay: recovery,
            asOfDay: "2026-04-01",
            windowDays: 365
        )
        XCTAssertEqual(out.map(\.behaviorId), ["Alcohol", "Caffeine", "Sauna"])
        XCTAssertEqual(out[0].recovery?.verdict, .hurts)
        XCTAssertEqual(out[1].recovery?.verdict, .unclear)
        XCTAssertNil(out[2].recovery)
    }

    func testRankIsDeterministic() {
        let yes = days("2026-01-01", count: 8)
        let no = days("2026-02-01", count: 8)
        var recovery: [String: Double] = [:]
        for (i, d) in yes.enumerated() { recovery[d] = 50 + Double(i % 3) }
        for (i, d) in no.enumerated() { recovery[d] = 70 + Double(i % 3) }
        let answers = self.answers(id: "Alcohol", yes: yes, no: no)
            + self.answers(id: "Caffeine", yes: no, no: yes)
        let a = JournalImpact.rank(answers: answers, recoveryByDay: recovery,
                                   asOfDay: "2026-04-01", windowDays: 365)
        let b = JournalImpact.rank(answers: answers, recoveryByDay: recovery,
                                   asOfDay: "2026-04-01", windowDays: 365)
        XCTAssertEqual(a, b)
    }

    func testTCrit90MatchesKnownQuantile() {
        XCTAssertEqual(JournalImpact.tCrit90(df: 10), 1.8125, accuracy: 0.01)
        XCTAssertEqual(JournalImpact.tCrit90(df: 1e12), 1.64485, accuracy: 0.0001)
    }
}

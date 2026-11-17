import XCTest
import StrandAnalytics
@testable import Strand

final class NativeJournalImpactTests: XCTestCase {

    func testShortTitlesForKnownQuestions() {
        XCTAssertEqual(NativeJournalImpactCopy.title(for: "Have any alcoholic drinks?"), "Alcohol")
        XCTAssertEqual(NativeJournalImpactCopy.title(for: "Did you drink any alcohol?"), "Alcohol")
        XCTAssertEqual(NativeJournalImpactCopy.title(for: "Consumed caffeine?"), "Caffeine")
        XCTAssertEqual(NativeJournalImpactCopy.title(for: "Did you have caffeine late in the day?"), "Caffeine")
        XCTAssertEqual(NativeJournalImpactCopy.title(for: "Did you view a screen in bed?"), "Screen in bed")
        XCTAssertEqual(NativeJournalImpactCopy.title(for: "Ate food close to bedtime?"), "Late meal")
        XCTAssertEqual(NativeJournalImpactCopy.title(for: "Custom stretch?"), "Custom stretch")
    }

    func testRecoverySentenceIsAnAssociation() {
        XCTAssertEqual(
            NativeJournalImpactCopy.recoverySentence(title: "Alcohol", effect: -8.2),
            "Recovery is 8 points lower after days with alcohol"
        )
        XCTAssertEqual(
            NativeJournalImpactCopy.recoverySentence(title: "Magnesium", effect: 6.4),
            "Recovery is 6 points higher after days with magnesium"
        )
        XCTAssertEqual(
            NativeJournalImpactCopy.effectText(-8.2),
            "-8 recovery"
        )
    }

    func testNeedCaptionAndUnclearCaption() {
        XCTAssertEqual(NativeJournalImpactCopy.needCaption(needYes: 2, needNo: 0), "2 more yes answers")
        XCTAssertEqual(NativeJournalImpactCopy.needCaption(needYes: 1, needNo: 3), "1 more yes answer · 3 more no answers")
        XCTAssertEqual(
            NativeJournalImpactCopy.sampleCaption(verdict: .unclear, nYes: 12, nNo: 40),
            "No clear effect yet · 12 yes · 40 no days"
        )
        XCTAssertEqual(
            NativeJournalImpactCopy.sampleCaption(verdict: .hurts, nYes: 12, nNo: 40),
            "Hurts · 12 yes · 40 no days"
        )
    }

    func testRowModelHidesSignedEffectWhenUnclearOrThin() {
        let unclear = JournalImpact.Insight(
            behaviorId: "Consumed caffeine?",
            recovery: JournalImpact.OutcomeEffect(
                nYes: 12, nNo: 10, meanYes: 70, meanNo: 69.5,
                effect: 0.5, intervalLow: -2, intervalHigh: 3,
                verdict: .unclear, usedFullHistory: false
            ),
            sleep: nil, nYesAll: 12, nNoAll: 10
        )
        let unclearRow = NativeJournalImpactRowModel.make(unclear)
        XCTAssertNil(unclearRow.effectText)
        XCTAssertTrue(unclearRow.caption.hasPrefix("No clear effect yet"))

        let thin = JournalImpact.Insight(
            behaviorId: "Did you use a sauna?",
            recovery: nil, sleep: nil, nYesAll: 3, nNoAll: 10
        )
        let thinRow = NativeJournalImpactRowModel.make(thin)
        XCTAssertEqual(thinRow.title, "Sauna")
        XCTAssertNil(thinRow.effectText)
        XCTAssertEqual(thinRow.caption, "2 more yes answers")
    }

    func testClearRowShowsSignedRecoveryAndSleep() {
        let insight = JournalImpact.Insight(
            behaviorId: "Have any alcoholic drinks?",
            recovery: JournalImpact.OutcomeEffect(
                nYes: 12, nNo: 40, meanYes: 45, meanNo: 53,
                effect: -8, intervalLow: -12, intervalHigh: -4,
                verdict: .hurts, usedFullHistory: false
            ),
            sleep: JournalImpact.OutcomeEffect(
                nYes: 12, nNo: 40, meanYes: 70, meanNo: 74,
                effect: -4, intervalLow: -6, intervalHigh: -1,
                verdict: .hurts, usedFullHistory: false
            ),
            nYesAll: 12, nNoAll: 40
        )
        let row = NativeJournalImpactRowModel.make(insight)
        XCTAssertEqual(row.title, "Alcohol")
        XCTAssertEqual(row.effectText, "-8 recovery")
        XCTAssertEqual(row.caption, "Hurts · 12 yes · 40 no days")
        XCTAssertEqual(row.sleepText, "Sleep -4")
        XCTAssertEqual(row.sentence, "Recovery is 8 points lower after days with alcohol")
        XCTAssertEqual(row.tintHelps, false)
    }

    func testModelSplitsClearUnclearAndInsufficient() {
        let hurts = JournalImpact.Insight(
            behaviorId: "Have any alcoholic drinks?",
            recovery: JournalImpact.OutcomeEffect(
                nYes: 12, nNo: 40, meanYes: 45, meanNo: 53,
                effect: -8, intervalLow: -12, intervalHigh: -4,
                verdict: .hurts, usedFullHistory: false
            ),
            sleep: nil, nYesAll: 12, nNoAll: 40
        )
        let unclear = JournalImpact.Insight(
            behaviorId: "Consumed caffeine?",
            recovery: JournalImpact.OutcomeEffect(
                nYes: 20, nNo: 10, meanYes: 70, meanNo: 71,
                effect: -1, intervalLow: -4, intervalHigh: 2,
                verdict: .unclear, usedFullHistory: false
            ),
            sleep: nil, nYesAll: 20, nNoAll: 10
        )
        let thin = JournalImpact.Insight(
            behaviorId: "Did you use a sauna?",
            recovery: nil, sleep: nil, nYesAll: 2, nNoAll: 4
        )
        let model = NativeJournalImpactModel.make([hurts, unclear, thin])
        XCTAssertEqual(model.clear.map(\.title), ["Alcohol"])
        XCTAssertEqual(model.unclear.map(\.title), ["Caffeine"])
        XCTAssertEqual(model.insufficient.map(\.title), ["Sauna"])
        XCTAssertNil(model.unclear.first?.effectText)
    }
}

import XCTest
@testable import StrandAnalytics

final class BandIllnessSignalTests: XCTestCase {

    private let start = "2024-01-01"

    func testSingleCorroboratedNightStaysQuiet() {
        var nights = baseline()
        nights.append(strained(day: "2024-01-29"))
        let last = BandIllnessSignal.evaluate(nights: nights).last
        XCTAssertEqual(last?.level, .quiet)
        XCTAssertGreaterThanOrEqual(last?.signalCount ?? 0, 2)
        XCTAssertFalse(last?.consecutive ?? true)
    }

    func testTwoConsecutiveCorroboratedNightsWatch() {
        var nights = baseline()
        nights.append(strained(day: "2024-01-29"))
        nights.append(strained(day: "2024-01-30"))
        let eval = BandIllnessSignal.evaluate(nights: nights)
        XCTAssertEqual(eval[eval.count - 2].level, .quiet)
        XCTAssertEqual(eval.last?.level, .watch)
        XCTAssertTrue(eval.last?.consecutive ?? false)
        XCTAssertGreaterThanOrEqual(eval.last?.signalCount ?? 0, 2)
        XCTAssertTrue(eval.last?.copy.contains("not a diagnosis") ?? false)
        XCTAssertEqual(BandIllnessSignal.episodeCount(eval), 1)
    }

    func testGapResetsConsecutiveCount() {
        var nights = baseline()
        nights.append(strained(day: "2024-01-29"))
        nights.append(usual(day: "2024-01-30"))
        nights.append(strained(day: "2024-01-31"))
        let eval = BandIllnessSignal.evaluate(nights: nights)
        XCTAssertTrue(eval.allSatisfy { $0.level != .watch })
        XCTAssertEqual(BandIllnessSignal.episodeCount(eval), 0)
    }

    func testOneSignalNeverWatchesEvenIfRepeated() {
        var nights = baseline()
        for i in 0..<5 {
            let day = BandDayKey.addDays("2024-01-29", i)!
            nights.append(BandIllnessSignal.Night(day: day, rhr: 90, hrvMs: 60, respRpm: 15, skinTemp: 33))
        }
        let eval = BandIllnessSignal.evaluate(nights: nights)
        XCTAssertTrue(eval.suffix(5).allSatisfy { $0.signalCount <= 1 })
        XCTAssertTrue(eval.allSatisfy { $0.level != .watch })
    }

    func testMissingNightsAreSkippedNotZeroFilled() {
        var nights = baseline()
        // A missing RHR must not become 0 bpm (which would be a huge *low* z,
        // never illness-ward). Two nights with only HRV+RR still corroborate.
        nights.append(BandIllnessSignal.Night(day: "2024-01-29", rhr: nil, hrvMs: 20, respRpm: 18, skinTemp: nil))
        nights.append(BandIllnessSignal.Night(day: "2024-01-30", rhr: nil, hrvMs: 20, respRpm: 18, skinTemp: nil))
        let last = BandIllnessSignal.evaluate(nights: nights).last
        XCTAssertEqual(last?.level, .watch)
        XCTAssertFalse(last?.fired.contains(.rhr) ?? true)
        XCTAssertTrue(last?.fired.contains(.hrv) ?? false)
        XCTAssertTrue(last?.fired.contains(.resp) ?? false)
    }

    func testThinHistoryIsBuilding() {
        let nights = (0..<10).map { usual(day: BandDayKey.addDays(start, $0)!) }
        let last = BandIllnessSignal.evaluate(nights: nights).last
        XCTAssertEqual(last?.level, .building)
        XCTAssertEqual(last?.copy, "Still learning your usual range.")
    }

    func testAlcoholIsTaggedAndDoesNotSuppress() {
        var nights = baseline()
        nights.append(strained(day: "2024-01-29", alcohol: true))
        nights.append(strained(day: "2024-01-30", alcohol: true))
        let last = BandIllnessSignal.evaluate(nights: nights).last
        XCTAssertEqual(last?.level, .watch)
        XCTAssertTrue(last?.alcoholTagged ?? false)
        XCTAssertTrue(last?.alcoholOnEpisode ?? false)
    }

    func testCopyNeverNamesACondition() {
        var nights = baseline()
        nights.append(strained(day: "2024-01-29"))
        nights.append(strained(day: "2024-01-30"))
        let banned = ["covid", "flu", "fever", "infection", "sick", "illness", "disease"]
        for r in BandIllnessSignal.evaluate(nights: nights) {
            let copy = r.copy.lowercased()
            for b in banned {
                XCTAssertFalse(copy.contains(b), "copy contained \(b): \(r.copy)")
            }
        }
    }

    func testHrvDropIsIllnessWardAndRiseIsNot() {
        let hist = [Double](repeating: 60, count: 20)
        let drop = BandIllnessSignal.illnessZ(30, history: hist, floor: 3, invert: true)
        let rise = BandIllnessSignal.illnessZ(90, history: hist, floor: 3, invert: true)
        XCTAssertGreaterThan(drop ?? 0, BandIllnessSignal.zThreshold)
        XCTAssertLessThan(rise ?? 0, 0)
    }

    func testThreeNightStreakIsOneEpisode() {
        var nights = baseline()
        nights.append(strained(day: "2024-01-29"))
        nights.append(strained(day: "2024-01-30"))
        nights.append(strained(day: "2024-01-31"))
        let eval = BandIllnessSignal.evaluate(nights: nights)
        XCTAssertEqual(eval.last?.level, .watch)
        XCTAssertEqual(eval[eval.count - 2].level, .watch)
        XCTAssertEqual(BandIllnessSignal.episodeCount(eval), 1)
    }

    func testQuietCopyIsWellness() {
        let nights = baseline() + [usual(day: "2024-01-29")]
        let last = BandIllnessSignal.evaluate(nights: nights).last
        XCTAssertEqual(last?.level, .quiet)
        XCTAssertEqual(last?.copy, "Overnight signals look like your usual range.")
    }

    private func baseline() -> [BandIllnessSignal.Night] {
        (0..<28).map { usual(day: BandDayKey.addDays(start, $0)!) }
    }

    private func usual(day: String, alcohol: Bool = false) -> BandIllnessSignal.Night {
        BandIllnessSignal.Night(day: day, rhr: 60, hrvMs: 60, respRpm: 15, skinTemp: 33, alcohol: alcohol)
    }

    private func strained(day: String, alcohol: Bool = false) -> BandIllnessSignal.Night {
        BandIllnessSignal.Night(day: day, rhr: 78, hrvMs: 30, respRpm: 18.5, skinTemp: 34.4, alcohol: alcohol)
    }
}

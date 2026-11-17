import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class BandStrainBandTests: XCTestCase {

    func testWhoopCutoffs() {
        XCTAssertEqual(BandStrainBand.band(strain21: 0), .light)
        XCTAssertEqual(BandStrainBand.band(strain21: 9.9), .light)
        XCTAssertEqual(BandStrainBand.band(strain21: 9.94), .light)
        XCTAssertEqual(BandStrainBand.band(strain21: 9.999), .moderate, "shown as 10.0")
        XCTAssertEqual(BandStrainBand.band(strain21: 17.999), .allOut, "shown as 18.0")
        XCTAssertEqual(BandStrainBand.band(strain21: 10), .moderate)
        XCTAssertEqual(BandStrainBand.band(strain21: 13.9), .moderate)
        XCTAssertEqual(BandStrainBand.band(strain21: 14), .strenuous)
        XCTAssertEqual(BandStrainBand.band(strain21: 17.9), .strenuous)
        XCTAssertEqual(BandStrainBand.band(strain21: 18), .allOut)
        XCTAssertEqual(BandStrainBand.band(strain21: 21), .allOut)
    }

    func testWords() {
        XCTAssertEqual(BandStrainBand.light.rawValue, "Light")
        XCTAssertEqual(BandStrainBand.moderate.rawValue, "Moderate")
        XCTAssertEqual(BandStrainBand.strenuous.rawValue, "Strenuous")
        XCTAssertEqual(BandStrainBand.allOut.rawValue, "All Out")
    }

    func testEffort100MatchesBandStrainOnTheSameWindow() throws {
        let samples = constHR(150, seconds: 20 * 60)
        let params = try XCTUnwrap(BandStrain.bundledParams())
        let s21 = try XCTUnwrap(BandStrain.strain(samples, maxHR: 190, restingHR: 60, params: params))
        let live21 = try XCTUnwrap(LiveActivityScoring.strain21(samples: samples, maxHR: 190, restingHR: 60))
        XCTAssertEqual(live21, s21, accuracy: 1e-12)
        let effort = try XCTUnwrap(LiveActivityScoring.effort100(samples: samples, maxHR: 190, restingHR: 60))
        XCTAssertEqual(effort, try XCTUnwrap(BandStrain.effort100(s21)), accuracy: 1e-12)
        XCTAssertEqual(LiveActivityScoring.band(strain21: live21), BandStrainBand.band(strain21: s21))
    }

    func testAvgMaxAndCaloriesFromTheSameWindow() {
        let samples = (0..<120).map { HRSample(ts: $0, bpm: 140 + ($0 % 3)) }
        XCTAssertEqual(LiveActivityScoring.averageHr(samples), 141)
        XCTAssertEqual(LiveActivityScoring.peakHr(samples), 142)
        XCTAssertNil(LiveActivityScoring.averageHr([]))
        XCTAssertNil(LiveActivityScoring.peakHr([]))
        XCTAssertNil(LiveActivityScoring.calories(
            samples: [HRSample(ts: 0, bpm: 140)],
            profile: UserProfile(), maxHR: 190, restingHR: 60
        ))
        let kcal = LiveActivityScoring.calories(
            samples: samples, profile: UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male"),
            maxHR: 190, restingHR: 60
        )
        XCTAssertNotNil(kcal)
        XCTAssertGreaterThan(kcal ?? 0, 0)
    }

    func testRecoveryHidesStrainAndDistancePaceIsRunWalkCycle() {
        XCTAssertFalse(LiveActivityScoring.showsActivityStrain("Sauna"))
        XCTAssertFalse(LiveActivityScoring.showsActivityStrain("Ice Bath"))
        XCTAssertTrue(LiveActivityScoring.showsActivityStrain("Running"))
        XCTAssertTrue(LiveActivityScoring.showsActivityStrain("Yoga"))
        XCTAssertTrue(LiveActivityScoring.showsDistancePace("Running"))
        XCTAssertTrue(LiveActivityScoring.showsDistancePace("Walking"))
        XCTAssertTrue(LiveActivityScoring.showsDistancePace("Cycling"))
        XCTAssertFalse(LiveActivityScoring.showsDistancePace("Indoor cycle"))
        XCTAssertFalse(LiveActivityScoring.showsDistancePace("Treadmill run"))
        XCTAssertFalse(LiveActivityScoring.showsDistancePace("Hiking"))
    }

    private func constHR(_ bpm: Int, seconds: Int) -> [HRSample] {
        (0..<seconds).map { HRSample(ts: $0, bpm: bpm) }
    }
}

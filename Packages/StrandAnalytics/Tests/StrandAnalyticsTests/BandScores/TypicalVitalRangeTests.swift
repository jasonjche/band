import XCTest
@testable import StrandAnalytics

final class TypicalVitalRangeTests: XCTestCase {

    private let k = TypicalVitalRange.sigmaK
    private let scale = TypicalVitalRange.madToSigma

    func testTooFewNightsIsBuilding() {
        let history = Array(repeating: Optional(55.0), count: 13)
        let result = TypicalVitalRange.evaluate(history: history, today: 70, metric: .rhr)
        XCTAssertEqual(result.status, .building)
        XCTAssertFalse(result.flagged)
        XCTAssertNil(result.range)
        XCTAssertEqual(result.nights, 13)
        XCTAssertNil(TypicalVitalRange.range(history: history, sigmaFloor: TypicalVitalRange.Metric.rhr.sigmaFloor))
    }

    func testFourteenNightsIsEnough() {
        let history = Array(repeating: Optional(55.0), count: 14)
        let result = TypicalVitalRange.evaluate(history: history, today: 55, metric: .rhr)
        XCTAssertEqual(result.status, .inRange)
        XCTAssertFalse(result.flagged)
        XCTAssertEqual(result.nights, 14)
        XCTAssertNotNil(result.range)
    }

    func testMissingNightsAreSkippedNotZeroFilled() {
        var history: [Double?] = Array(repeating: 50, count: 14)
        history += Array(repeating: nil, count: 10)
        let result = TypicalVitalRange.evaluate(history: history, today: 50, metric: .rhr)
        XCTAssertEqual(result.nights, 14)
        XCTAssertEqual(result.status, .inRange)
    }

    func testASingleOutlierNightDoesNotWidenTheRange() {
        let stable = Array(repeating: 50.0, count: 20)
        let withSick = stable + [80]
        let floor = TypicalVitalRange.Metric.rhr.sigmaFloor
        let clean = TypicalVitalRange.range(history: stable.map { Optional($0) }, sigmaFloor: floor)
        let dirty = TypicalVitalRange.range(history: withSick.map { Optional($0) }, sigmaFloor: floor)
        XCTAssertEqual(clean?.lowerBound ?? -1, dirty?.lowerBound ?? -1, accuracy: 1e-12)
        XCTAssertEqual(clean?.upperBound ?? -1, dirty?.upperBound ?? -1, accuracy: 1e-12)
        let meanClean = mean(stable)
        let meanDirty = mean(withSick)
        XCTAssertGreaterThan(meanDirty, meanClean)
    }

    func testRestingHeartRateFlagsHighNotLow() {
        let history = Array(repeating: Optional(50.0), count: 20)
        let high = TypicalVitalRange.evaluate(history: history, today: 70, metric: .rhr)
        XCTAssertEqual(high.status, .above)
        XCTAssertTrue(high.flagged)
        let low = TypicalVitalRange.evaluate(history: history, today: 35, metric: .rhr)
        XCTAssertEqual(low.status, .below)
        XCTAssertFalse(low.flagged)
    }

    func testHrvFlagsLowNotHigh() {
        let history = Array(repeating: Optional(60.0), count: 20)
        let low = TypicalVitalRange.evaluate(history: history, today: 20, metric: .hrv)
        XCTAssertEqual(low.status, .below)
        XCTAssertTrue(low.flagged)
        let high = TypicalVitalRange.evaluate(history: history, today: 120, metric: .hrv)
        XCTAssertEqual(high.status, .above)
        XCTAssertFalse(high.flagged)
    }

    func testRespiratoryRateFlagsHigh() {
        let history = Array(repeating: Optional(14.0), count: 20)
        let high = TypicalVitalRange.evaluate(history: history, today: 20, metric: .resp)
        XCTAssertEqual(high.status, .above)
        XCTAssertTrue(high.flagged)
        let low = TypicalVitalRange.evaluate(history: history, today: 8, metric: .resp)
        XCTAssertEqual(low.status, .below)
        XCTAssertFalse(low.flagged)
    }

    func testSkinTemperatureFlagsEitherWay() {
        let history = Array(repeating: Optional(34.5), count: 20)
        let high = TypicalVitalRange.evaluate(history: history, today: 36.5, metric: .skin)
        XCTAssertEqual(high.status, .above)
        XCTAssertTrue(high.flagged)
        let low = TypicalVitalRange.evaluate(history: history, today: 32.0, metric: .skin)
        XCTAssertEqual(low.status, .below)
        XCTAssertTrue(low.flagged)
    }

    func testSpo2FlagsLowAndHonoursAbsoluteGuardRail() {
        let history = Array(repeating: Optional(97.0), count: 20)
        let low = TypicalVitalRange.evaluate(history: history, today: 91, metric: .spo2)
        XCTAssertEqual(low.status, .below)
        XCTAssertTrue(low.flagged)
        let high = TypicalVitalRange.evaluate(history: history, today: 99.5, metric: .spo2)
        XCTAssertEqual(high.status, .above)
        XCTAssertFalse(high.flagged)

        // Personal band would accept 89, but 90 % is the physiological floor.
        let wide = (0..<20).map { Optional(88.0 + Double($0) * 0.2) }
        let rail = TypicalVitalRange.evaluate(history: wide, today: 89, metric: .spo2)
        XCTAssertEqual(rail.status, .below)
        XCTAssertTrue(rail.flagged)
        XCTAssertEqual(TypicalVitalRange.spo2AbsoluteFloor, 90, accuracy: 0)
    }

    func testSpo2AbsoluteRailFlagsWhileBuilding() {
        let history = Array(repeating: Optional(97.0), count: 5)
        let result = TypicalVitalRange.evaluate(history: history, today: 88, metric: .spo2)
        XCTAssertEqual(result.status, .below)
        XCTAssertTrue(result.flagged)
        XCTAssertNil(result.range)
    }

    func testRangeMatchesEvaluateAndUsesMedianMadSigma() {
        let history: [Double?] = [40, 41, 42, 40, 43, 41, 40, 42, 41, 40, 44, 41, 42, 40, 41]
        let floor = TypicalVitalRange.Metric.hrv.sigmaFloor
        let band = TypicalVitalRange.range(history: history, sigmaFloor: floor)
        let evaluated = TypicalVitalRange.evaluate(history: history, today: 41, metric: .hrv)
        XCTAssertEqual(band?.lowerBound ?? -1, evaluated.range?.lowerBound ?? -1, accuracy: 1e-12)
        XCTAssertEqual(band?.upperBound ?? -1, evaluated.range?.upperBound ?? -1, accuracy: 1e-12)
        let valid = history.compactMap { $0 }
        let center = BandScores.median(valid)
        let mad = BandScores.median(valid.map { abs($0 - center) })
        let sigma = max(scale * mad, floor)
        XCTAssertEqual(band?.lowerBound ?? -1, center - k * sigma, accuracy: 1e-12)
        XCTAssertEqual(band?.upperBound ?? -1, center + k * sigma, accuracy: 1e-12)
    }

    func testSigmaFloorMappingAgreesWithMetric() {
        XCTAssertEqual(TypicalVitalRange.sigmaFloor(matching: Baselines.hrvCfg), TypicalVitalRange.Metric.hrv.sigmaFloor)
        XCTAssertEqual(TypicalVitalRange.sigmaFloor(matching: Baselines.restingHRCfg), TypicalVitalRange.Metric.rhr.sigmaFloor)
        XCTAssertEqual(TypicalVitalRange.sigmaFloor(matching: Baselines.respCfg), TypicalVitalRange.Metric.resp.sigmaFloor)
        XCTAssertEqual(TypicalVitalRange.sigmaFloor(matching: Baselines.metricCfg["skin_temp"]), TypicalVitalRange.Metric.skin.sigmaFloor)
        XCTAssertEqual(TypicalVitalRange.sigmaFloor(matching: nil), 0)
    }

    private func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }
}

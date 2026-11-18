import XCTest
@testable import Strand

final class HomeBatteryTintTests: XCTestCase {

    func testLowAtTwentyAndBelow() {
        XCTAssertEqual(HomeBatteryTint.level(percent: 0, charging: false), .low)
        XCTAssertEqual(HomeBatteryTint.level(percent: 20, charging: false), .low)
    }

    func testMidFromTwentyOneToFortyNine() {
        XCTAssertEqual(HomeBatteryTint.level(percent: 21, charging: false), .mid)
        XCTAssertEqual(HomeBatteryTint.level(percent: 49, charging: false), .mid)
    }

    func testHighAtFiftyAndAbove() {
        XCTAssertEqual(HomeBatteryTint.level(percent: 50, charging: false), .high)
        XCTAssertEqual(HomeBatteryTint.level(percent: 100, charging: false), .high)
    }

    func testChargingWinsAtAnyPercent() {
        XCTAssertEqual(HomeBatteryTint.level(percent: 10, charging: true), .charging)
        XCTAssertEqual(HomeBatteryTint.level(percent: 80, charging: true), .charging)
    }
}

import XCTest
@testable import Strand

final class NativeRingTests: XCTestCase {

    func testClampedFractionIsZeroToOne() {
        XCTAssertEqual(NativeRingMotion.clamped(nil), 0, accuracy: 1e-9)
        XCTAssertEqual(NativeRingMotion.clamped(-0.2), 0, accuracy: 1e-9)
        XCTAssertEqual(NativeRingMotion.clamped(0), 0, accuracy: 1e-9)
        XCTAssertEqual(NativeRingMotion.clamped(0.42), 0.42, accuracy: 1e-9)
        XCTAssertEqual(NativeRingMotion.clamped(1), 1, accuracy: 1e-9)
        XCTAssertEqual(NativeRingMotion.clamped(1.4), 1, accuracy: 1e-9)
    }
}

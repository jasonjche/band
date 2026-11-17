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

    func testTargetTickSitsAtTheMidpoint() {
        XCTAssertEqual(NativeRingMotion.targetTick(from: 0.4...0.6), 0.5, accuracy: 1e-12)
        XCTAssertEqual(NativeRingMotion.targetTickSpan, 0.018, accuracy: 1e-12)
        XCTAssertEqual(NativeRingMotion.targetTick(from: 0.8...0.8), 0.8, accuracy: 1e-12)
    }
}

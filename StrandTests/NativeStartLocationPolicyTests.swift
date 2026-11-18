import XCTest
@testable import Strand

/// The start-activity map is a backdrop pin. Continuous GPS plus the app's `location` background
/// mode used to keep the radio on after the user left the screen or backgrounded the phone.
final class NativeStartLocationPolicyTests: XCTestCase {

    func testAVisibleAuthorizedMapMayRequestAFix() {
        XCTAssertTrue(NativeStartLocationPolicy.shouldRequestFix(wanted: true, authorized: true))
    }

    func testAFixIsNeverRequestedAfterTheMapStopsWantingOne() {
        XCTAssertFalse(NativeStartLocationPolicy.shouldRequestFix(wanted: false, authorized: true))
        XCTAssertFalse(NativeStartLocationPolicy.shouldRequestFix(wanted: true, authorized: false))
        XCTAssertFalse(NativeStartLocationPolicy.shouldRequestFix(wanted: false, authorized: false))
    }

    func testTheMapStopsAfterTheFirstFix() {
        XCTAssertTrue(NativeStartLocationPolicy.stopsAfterFirstFix)
    }
}

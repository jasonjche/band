import XCTest
@testable import Strand

/// The Max Heart Rate stepper once counted up from Auto (0), so one tap saved 1 bpm and a few taps
/// broke every zone and strain score. These pin the sanitize + step rules.
final class ProfileHRMaxOverrideTests: XCTestCase {
    func testImplausibleStoredOverrideResolvesToAuto() {
        XCTAssertEqual(ProfileStore.sanitizedHRMaxOverride(14), 0)
        XCTAssertEqual(ProfileStore.sanitizedHRMaxOverride(119), 0)
        XCTAssertEqual(ProfileStore.sanitizedHRMaxOverride(250), 0)
        XCTAssertEqual(ProfileStore.sanitizedHRMaxOverride(0), 0)
        XCTAssertEqual(ProfileStore.sanitizedHRMaxOverride(185), 185)
    }

    func testFirstStepFromAutoStartsAtTheAutomaticValue() {
        XCTAssertEqual(ProfileStore.steppedHRMaxOverride(0, automatic: 198, up: true), 199)
        XCTAssertEqual(ProfileStore.steppedHRMaxOverride(0, automatic: 198, up: false), 197)
    }

    func testSteppingClampsToThePlausibleRange() {
        XCTAssertEqual(ProfileStore.steppedHRMaxOverride(120, automatic: 198, up: false), 120)
        XCTAssertEqual(ProfileStore.steppedHRMaxOverride(230, automatic: 198, up: true), 230)
        XCTAssertEqual(ProfileStore.steppedHRMaxOverride(190, automatic: 198, up: true), 191)
    }
}

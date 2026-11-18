import XCTest
@testable import Strand

/// The Band power-policy flag is one UserDefaults key with one resolver.
final class BandPowerPolicyTests: XCTestCase {

    private let suite = "BandPowerPolicyTests"

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testUnsetKeyReadsOff() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertFalse(BandPowerPolicy.enabled(defaults: defaults))
    }

    func testExplicitTrueReadsOn() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: BandPowerPolicy.defaultsKey)
        XCTAssertTrue(BandPowerPolicy.enabled(defaults: defaults))
    }
}

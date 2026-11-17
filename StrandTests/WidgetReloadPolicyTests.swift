import XCTest
@testable import Strand

final class WidgetReloadPolicyTests: XCTestCase {

    func testPolicyOnReloadsOnlyWhenOffloadStoredData() {
        XCTAssertTrue(WidgetReloadPolicy.shouldReload(policyEnabled: true, storedNewData: true))
        XCTAssertFalse(WidgetReloadPolicy.shouldReload(policyEnabled: true, storedNewData: false))
    }

    func testFlagOffAlwaysReloads() {
        XCTAssertTrue(WidgetReloadPolicy.shouldReload(policyEnabled: false, storedNewData: false))
        XCTAssertTrue(WidgetReloadPolicy.shouldReload(policyEnabled: false, storedNewData: true))
    }
}

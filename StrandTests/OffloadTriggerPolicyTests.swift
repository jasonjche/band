import XCTest
@testable import Strand

/// Pins EVENT-packet offload suppression. The 90 s `.strap` floor stays in `BackfillPolicy`
/// for when the flag is off.
final class OffloadTriggerPolicyTests: XCTestCase {

    func testPolicyOnDropsStrapEvents() {
        XCTAssertFalse(OffloadTriggerPolicy.shouldRequest(trigger: .strap, policyEnabled: true))
    }

    func testPolicyOnKeepsConnectForegroundPeriodicManualAndAutoContinue() {
        XCTAssertTrue(OffloadTriggerPolicy.shouldRequest(trigger: .connect, policyEnabled: true))
        XCTAssertTrue(OffloadTriggerPolicy.shouldRequest(trigger: .foreground, policyEnabled: true))
        XCTAssertTrue(OffloadTriggerPolicy.shouldRequest(trigger: .periodic, policyEnabled: true))
        XCTAssertTrue(OffloadTriggerPolicy.shouldRequest(trigger: .manual, policyEnabled: true))
        XCTAssertTrue(OffloadTriggerPolicy.shouldRequest(trigger: .autoContinue, policyEnabled: true))
    }

    func testFlagOffHonoursStrapEvents() {
        XCTAssertTrue(OffloadTriggerPolicy.shouldRequest(trigger: .strap, policyEnabled: false))
    }

    func testFlagOffStillAllowsEveryTrigger() {
        for trigger: BackfillTrigger in [.periodic, .connect, .foreground, .manual, .strap, .autoContinue] {
            XCTAssertTrue(OffloadTriggerPolicy.shouldRequest(trigger: trigger, policyEnabled: false))
        }
    }
}

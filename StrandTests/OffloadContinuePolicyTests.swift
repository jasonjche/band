import XCTest
@testable import Strand

/// Auto-continue only after a slice-cap (idle-timeout) exit while the strap still has backlog.
final class OffloadContinuePolicyTests: XCTestCase {

    private let wallNow = 1_800_000_000

    private func behindArgs(endedOnSliceCap: Bool,
                            policyEnabled: Bool,
                            persisted: Bool = true) -> Bool {
        OffloadContinuePolicy.shouldAutoContinue(
            policyEnabled: policyEnabled,
            endedOnSliceCap: endedOnSliceCap,
            stillConnected: true,
            strapNewestTs: wallNow,
            ourFrontierTs: wallNow - 86_400,
            wallNowUnix: wallNow,
            persistedSensorRows: persisted,
            lastTrimAdvanced: true,
            consecutiveCount: 0)
    }

    func testPolicyOnContinuesOnlyAfterSliceCapWithBacklog() {
        XCTAssertTrue(behindArgs(endedOnSliceCap: true, policyEnabled: true))
    }

    func testPolicyOnDoesNotContinueAfterHistoryComplete() {
        XCTAssertFalse(behindArgs(endedOnSliceCap: false, policyEnabled: true))
    }

    func testFlagOffStillContinuesAfterHistoryComplete() {
        XCTAssertTrue(behindArgs(endedOnSliceCap: false, policyEnabled: false))
    }

    func testSliceCapWithoutPendingDoesNotContinue() {
        XCTAssertFalse(OffloadContinuePolicy.shouldAutoContinue(
            policyEnabled: true,
            endedOnSliceCap: true,
            stillConnected: true,
            strapNewestTs: wallNow,
            ourFrontierTs: wallNow - 120,
            wallNowUnix: wallNow,
            persistedSensorRows: true,
            lastTrimAdvanced: true,
            consecutiveCount: 0))
    }

    func testSliceCapWithEmptySessionDoesNotContinue() {
        XCTAssertFalse(behindArgs(endedOnSliceCap: true, policyEnabled: true, persisted: false))
    }
}

import XCTest
@testable import Strand

/// Spacing is checked before `exploreSeries` builds a watch snapshot, so the policy has to be
/// decidable from timestamps alone.
final class WatchPushPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testTheFirstPushOfAProcessAlwaysPasses() {
        XCTAssertTrue(WatchPushPolicy.spacingAllowsPush(lastPushedAt: nil, now: t0))
    }

    func testAPushInsideTheWindowIsBlocked() {
        XCTAssertFalse(WatchPushPolicy.spacingAllowsPush(
            lastPushedAt: t0, now: t0.addingTimeInterval(29 * 60)))
    }

    func testTheBoundaryBelongsToAllow() {
        XCTAssertTrue(WatchPushPolicy.spacingAllowsPush(
            lastPushedAt: t0,
            now: t0.addingTimeInterval(WatchPushPolicy.minInterval)))
    }
}

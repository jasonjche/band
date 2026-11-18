import XCTest
@testable import Strand

/// Pins `LiveHRDemand`: 0x2A37 notify is a refcounted want, not an always-on subscription.
final class LiveHRDemandTests: XCTestCase {

    func testRetainReleaseIsRefcounted() {
        var n = 0
        n = LiveHRDemand.retain(n)
        n = LiveHRDemand.retain(n)
        XCTAssertEqual(n, 2)
        n = LiveHRDemand.release(n)
        XCTAssertEqual(n, 1)
        XCTAssertTrue(LiveHRDemand.shouldSubscribe(demandCount: n, continuousHRV: false, policyEnabled: true))
        n = LiveHRDemand.release(n)
        XCTAssertEqual(n, 0)
        XCTAssertFalse(LiveHRDemand.shouldSubscribe(demandCount: n, continuousHRV: false, policyEnabled: true))
    }

    func testReleaseWillNotGoNegative() {
        XCTAssertEqual(LiveHRDemand.release(0), 0)
        XCTAssertEqual(LiveHRDemand.release(1), 0)
    }

    func testTwoSurfacesDoNotFight() {
        var n = 0
        n = LiveHRDemand.retain(n)   // Live
        n = LiveHRDemand.retain(n)   // workout
        n = LiveHRDemand.release(n)  // Live leaves
        XCTAssertTrue(LiveHRDemand.shouldSubscribe(demandCount: n, continuousHRV: false, policyEnabled: true))
        n = LiveHRDemand.release(n)  // workout leaves
        XCTAssertFalse(LiveHRDemand.shouldSubscribe(demandCount: n, continuousHRV: false, policyEnabled: true))
    }

    func testContinuousHRVSubscribesWithNoSurface() {
        XCTAssertTrue(LiveHRDemand.shouldSubscribe(demandCount: 0, continuousHRV: true, policyEnabled: true))
    }

    func testFlagOffAlwaysSubscribes() {
        XCTAssertTrue(LiveHRDemand.shouldSubscribe(demandCount: 0, continuousHRV: false, policyEnabled: false))
    }

    func testHandshakeHoldsSubscription() {
        XCTAssertTrue(LiveHRDemand.shouldSubscribe(demandCount: 0, continuousHRV: false,
                                                   policyEnabled: true, holdForHandshake: true))
    }

    func testIdleWithPolicyOnDoesNotSubscribe() {
        XCTAssertFalse(LiveHRDemand.shouldSubscribe(demandCount: 0, continuousHRV: false, policyEnabled: true))
    }
}

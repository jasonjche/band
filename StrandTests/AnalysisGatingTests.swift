import XCTest
@testable import Strand

/// Pins when `analyzeRecent` walks 21 days, today only, or skips.
final class AnalysisGatingTests: XCTestCase {

    func testIdleTickIsTodayOnlyWhenPolicyOn() {
        XCTAssertEqual(AnalysisGating.pass(policyEnabled: true, kind: .idleTick, storedNewRecords: false),
                       .todayOnly)
        XCTAssertEqual(AnalysisGating.pass(policyEnabled: true, kind: .idleTick, storedNewRecords: true),
                       .todayOnly)
    }

    func testIdleTickIsFullWindowWhenFlagOff() {
        XCTAssertEqual(AnalysisGating.pass(policyEnabled: false, kind: .idleTick, storedNewRecords: false),
                       .fullWindow)
    }

    func testOffloadWithNewRecordsIsFullWindow() {
        XCTAssertEqual(AnalysisGating.pass(policyEnabled: true, kind: .offload, storedNewRecords: true),
                       .fullWindow)
        XCTAssertEqual(AnalysisGating.pass(policyEnabled: false, kind: .offload, storedNewRecords: true),
                       .fullWindow)
    }

    func testEmptyOffloadSkips() {
        XCTAssertEqual(AnalysisGating.pass(policyEnabled: true, kind: .offload, storedNewRecords: false),
                       .skip)
        XCTAssertEqual(AnalysisGating.pass(policyEnabled: false, kind: .offload, storedNewRecords: false),
                       .skip)
    }

    func testManualWorkoutOrImportIsAlwaysFullWindow() {
        XCTAssertEqual(AnalysisGating.pass(policyEnabled: true, kind: .manual, storedNewRecords: false),
                       .fullWindow)
        XCTAssertEqual(AnalysisGating.pass(policyEnabled: false, kind: .manual, storedNewRecords: false),
                       .fullWindow)
    }

    func testFingerprintIsO1FromIndexedFrontiers() {
        let a = AnalysisGating.fingerprint(maxHrTs: 100, maxHrRowid: 5, maxRrRowid: 9)
        let b = AnalysisGating.fingerprint(maxHrTs: 100, maxHrRowid: 5, maxRrRowid: 9)
        let c = AnalysisGating.fingerprint(maxHrTs: 101, maxHrRowid: 5, maxRrRowid: 9)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertTrue(a.hasPrefix("o1|"))
    }
}

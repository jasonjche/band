import XCTest
import SwiftUI
@testable import StrandDesign

/// WHOOP sleep-stage hexes sampled from private Last Night / Restorative screenshots.
final class NativeSleepStageTokenTests: XCTestCase {

    func testWhoopStageTokensMatchScreenshotHex() {
        assertHex(NativeTokens.whoopSleepAwake, "#C8C8C8")
        assertHex(NativeTokens.whoopSleepLight, "#A4A3EB")
        assertHex(NativeTokens.whoopSleepDeep, "#EC9AF4")
        assertHex(NativeTokens.whoopSleepREM, "#A15EE5")
    }

    func testAppleDarkStageTokensMatchScreenshotHex() {
        assertHex(Color(hex: "#C8C8C8"), "#C8C8C8")
        assertHex(Color(hex: "#A4A3EB"), "#A4A3EB")
        assertHex(Color(hex: "#EC9AF4"), "#EC9AF4")
        assertHex(Color(hex: "#A15EE5"), "#A15EE5")
    }

    private func assertHex(_ color: Color, _ hex: String, file: StaticString = #filePath, line: UInt = #line) {
        let got = color.rgbaComponents
        let want = Color(hex: hex).rgbaComponents
        XCTAssertEqual(got.r, want.r, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(got.g, want.g, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(got.b, want.b, accuracy: 0.02, file: file, line: line)
    }
}

import XCTest
import SwiftUI
@testable import StrandDesign

final class TypographyScaleTests: XCTestCase {
    func testCustomSizeFacesAreConstructible() {
        _ = StrandFont.rounded(17)
        _ = StrandFont.rounded(34, weight: .semibold)
        _ = StrandFont.number(26)
        _ = NativeTokens.whoopNumber(34)
        _ = NativeTokens.whoopCaps(11)
        XCTAssertEqual(StrandFont.scalingTextStyle(for: 11), .caption2)
        XCTAssertEqual(StrandFont.scalingTextStyle(for: 17), .body)
        XCTAssertEqual(StrandFont.scalingTextStyle(for: 40), .largeTitle)
    }

    func testScaledSystemAndRoundedShareACacheKeyedBySizeWeightDesign() {
        StrandFont.resetFontCacheForTests()
        XCTAssertEqual(StrandFont.fontCacheCountForTests(), 0)
        _ = StrandFont.scaledSystem(size: 17, weight: .semibold, design: .rounded)
        XCTAssertEqual(StrandFont.fontCacheCountForTests(), 1)
        _ = StrandFont.scaledSystem(size: 17, weight: .semibold, design: .rounded)
        XCTAssertEqual(StrandFont.fontCacheCountForTests(), 1)
        _ = StrandFont.rounded(17, weight: .semibold)
        XCTAssertEqual(StrandFont.fontCacheCountForTests(), 2)
        _ = StrandFont.rounded(17, weight: .semibold)
        XCTAssertEqual(StrandFont.fontCacheCountForTests(), 2)
        _ = StrandFont.number(17, weight: .semibold)
        XCTAssertEqual(StrandFont.fontCacheCountForTests(), 2)
        _ = StrandFont.rounded(34)
        XCTAssertEqual(StrandFont.fontCacheCountForTests(), 3)
        _ = StrandFont.scaledSystem(size: 17, weight: .regular, design: .default)
        XCTAssertEqual(StrandFont.fontCacheCountForTests(), 4)
    }
}

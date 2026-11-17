import XCTest
@testable import WhoopProtocol

/// Round-2 ingest identity: streaming extract == array extract, and a corrupted frame
/// (any integrity-gate failure) never becomes rows.
final class IngestEquivalenceTests: XCTestCase {

    private static let whoop5HistoricalHex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    private static func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            out.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return out
    }

    private func corrupt(_ frame: [UInt8], at index: Int) -> [UInt8] {
        var f = frame
        f[index] ^= 0xFF
        return f
    }

    func testStreamingExtractMatchesArrayExtract() {
        let seed = Self.hex(Self.whoop5HistoricalHex)
        XCTAssertTrue(parseFrame(seed, family: .whoop5).ok)
        var frames = [[UInt8]](); frames.reserveCapacity(128)
        for _ in 0..<128 { frames.append(seed) }
        let unix = 1_780_916_150
        let parsed = frames.map { parseFrame($0, family: .whoop5) }
        let fromArray = extractHistoricalStreams(parsed, deviceClockRef: unix, wallClockRef: unix,
                                                 family: .whoop5, wallNow: unix + 10)
        let streamed = extractHistoricalStreams(frames: frames, deviceClockRef: unix, wallClockRef: unix,
                                                family: .whoop5, wallNow: unix + 10)
        XCTAssertEqual(streamed, fromArray)
        XCTAssertEqual(streamed.hr.count, 128)
        XCTAssertEqual(streamed.rr.count, 256)
    }

    func testCorruptedFramesAreRejectedAndYieldNoRows() {
        let intact = Self.hex(Self.whoop5HistoricalHex)
        let unix = 1_780_916_150
        // Header CRC-16 (bytes 6-7), payload CRC32 (last 4), length field (bytes 2-3), SOF.
        let cases: [(String, [UInt8])] = [
            ("header checksum", corrupt(intact, at: 6)),
            ("payload crc32", corrupt(intact, at: intact.count - 1)),
            ("length mismatch", {
                var f = intact; f[2] ^= 0x01; return f
            }()),
            ("no SOF", {
                var f = intact; f[0] = 0x00; return f
            }()),
            ("truncated", Array(intact.dropLast(8))),
        ]
        for (label, frame) in cases {
            let parsed = parseFrame(frame, family: .whoop5)
            XCTAssertFalse(parsed.ok, "\(label) must fail the full integrity verdict")
            XCTAssertNotEqual(parsed.rejectReason, FrameRejectReason.none, label)
            let streams = extractHistoricalStreams([parsed], deviceClockRef: unix, wallClockRef: unix,
                                                   family: .whoop5, wallNow: unix + 10)
            XCTAssertTrue(streams.hr.isEmpty, "\(label) leaked HR")
            XCTAssertTrue(streams.rr.isEmpty, "\(label) leaked RR")
            XCTAssertTrue(streams.gravity.isEmpty, "\(label) leaked gravity")
        }
        // Mix: one intact among corrupted still extracts exactly that one.
        let mixed = [corrupt(intact, at: 6), intact, corrupt(intact, at: intact.count - 1)]
        let parsed = mixed.map { parseFrame($0, family: .whoop5) }
        XCTAssertEqual(parsed.map(\.ok), [false, true, false])
        let streams = extractHistoricalStreams(parsed, deviceClockRef: unix, wallClockRef: unix,
                                               family: .whoop5, wallNow: unix + 10)
        let intactStreams = extractHistoricalStreams([parseFrame(intact, family: .whoop5)],
                                                     deviceClockRef: unix, wallClockRef: unix,
                                                     family: .whoop5, wallNow: unix + 10)
        XCTAssertEqual(streams.hr, intactStreams.hr)
        XCTAssertEqual(streams.rr, intactStreams.rr)
        XCTAssertEqual(streams.gravity, intactStreams.gravity)
    }

    func testFastPathParsedDictUnchangedOnHistoricalAndCorrupted() {
        let intact = Self.hex(Self.whoop5HistoricalHex)
        for frame in [intact, corrupt(intact, at: 6), corrupt(intact, at: intact.count - 2)] {
            let fast = parseFrame(frame, family: .whoop5)
            let full = parseFrame(frame, family: .whoop5, collectFields: true)
            XCTAssertEqual(fast.parsed, full.parsed)
            XCTAssertEqual(fast.ok, full.ok)
            XCTAssertEqual(fast.rejectReason, full.rejectReason)
            XCTAssertEqual(fast.rawHex, "")
            XCTAssertFalse(full.rawHex.isEmpty)
        }
    }
}

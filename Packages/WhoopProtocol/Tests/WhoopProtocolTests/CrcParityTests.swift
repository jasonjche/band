import XCTest
@testable import WhoopProtocol

/// CRC / integrity-gate parity: the zlib (or table-CRC16) production path must agree with the
/// previous software implementations on every fixture byte, on truncated slices, and on flipped
/// bits. The `verifyFrame` verdict (header checksum, payload CRC32, size) is the BLE safety
/// contract — a CRC rewrite that changed a reject reason would be a protocol bug.
final class CrcParityTests: XCTestCase {

    private static func hex(_ s: String) -> [UInt8] {
        FramingTests.hex(s)
    }

    private struct FrameHex: Decodable { let hex: String }

    private func loadJSONFrames(_ resource: String) throws -> [[UInt8]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: resource, withExtension: "json"))
        let entries = try JSONDecoder().decode([FrameHex].self, from: Data(contentsOf: url))
        return entries.map { Self.hex($0.hex) }
    }

    private static let whoop5Historical =
        hex("aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817")
    private static let whoop5Realtime =
        hex("aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc")
    private static let whoop4Realtime =
        hex("aa1800ff28020f3de10128663c0000000000000000000000da855212")

    func testCrc32EmptyIsZero() {
        XCTAssertEqual(crc32([]), 0)
        XCTAssertEqual(crc32Table([]), 0)
        XCTAssertEqual(crc32([1, 2, 3], 2, 2), 0)
        XCTAssertEqual(crc32Table([1, 2, 3], 2, 2), 0)
    }

    func testCrc32KnownVector() {
        // ITU/zlib check value: CRC-32 of "123456789" is 0xCBF43926.
        let bytes = Array("123456789".utf8)
        XCTAssertEqual(crc32(bytes), 0xCBF43926)
        XCTAssertEqual(crc32Table(bytes), 0xCBF43926)
    }

    func testCrc32MatchesTableOnFixturesAndMutations() throws {
        var corpus = try loadJSONFrames("frames")
        corpus.append(contentsOf: try loadJSONFrames("historical_frames"))
        corpus.append(Self.whoop5Historical)
        corpus.append(Self.whoop5Realtime)
        corpus.append(Self.whoop4Realtime)
        XCTAssertGreaterThan(corpus.count, 10)

        for (i, frame) in corpus.enumerated() {
            assertCrc32Match(frame, label: "fixture #\(i)")
            if frame.count >= 2 {
                var flipped = frame
                flipped[frame.count / 2] ^= 0xFF
                assertCrc32Match(flipped, label: "flipped #\(i)")
                assertCrc32Match(Array(frame.dropLast()), label: "truncated-1 #\(i)")
                if frame.count > 8 {
                    assertCrc32Match(frame, from: 8, to: frame.count - 4, label: "payload #\(i)")
                    var payloadFlip = frame
                    payloadFlip[8] ^= 0x01
                    assertCrc32Match(payloadFlip, from: 8, to: frame.count - 4, label: "payload-flip #\(i)")
                }
            }
        }
    }

    func testCrc16ModbusMatchesBitwise() throws {
        var corpus = [Self.whoop5Historical, Self.whoop5Realtime]
        corpus.append(contentsOf: try loadJSONFrames("frames"))
        for (i, frame) in corpus.enumerated() {
            let n = min(6, frame.count)
            XCTAssertEqual(crc16Modbus(frame, 0, n), crc16ModbusBitwise(frame, 0, n),
                           "crc16 drift at fixture #\(i)")
            if frame.count >= 2 {
                var flipped = frame
                flipped[1] ^= 0xFF
                XCTAssertEqual(crc16Modbus(flipped, 0, n), crc16ModbusBitwise(flipped, 0, n),
                               "crc16 flipped drift at #\(i)")
            }
        }
        XCTAssertEqual(crc16Modbus([]), crc16ModbusBitwise([]))
    }

    func testVerifyFrameVerdictMatchesTableCrcOnCorruptFrames() throws {
        let seeds: [(frame: [UInt8], family: DeviceFamily)] = [
            (Self.whoop4Realtime, .whoop4),
            (Self.whoop5Historical, .whoop5),
            (Self.whoop5Realtime, .whoop5),
            (Self.hex(FrameIntegrityTests.w4Valid), .whoop4),
            (Self.hex(FrameIntegrityTests.w5Valid), .whoop5),
        ]
        for (seed, family) in seeds {
            XCTAssertTrue(verifyFrame(seed, family: family).ok, "seed must be intact")
            // Flip every byte in turn — header, payload, trailer — plus a truncated copy.
            for i in seed.indices {
                var bad = seed
                bad[i] ^= 0xFF
                assertVerdictUsesMatchingCrc(bad, family: family, label: "flip[\(i)]")
            }
            assertVerdictUsesMatchingCrc(Array(seed.dropLast()), family: family, label: "trunc-1")
            assertVerdictUsesMatchingCrc(Array(seed.dropLast(4)), family: family, label: "trunc-4")
            assertVerdictUsesMatchingCrc(seed + [0x00], family: family, label: "trailing")
            assertVerdictUsesMatchingCrc([], family: family, label: "empty")
        }
    }

    func testPuffinCommandFrameRoundTripStillVerifies() {
        let frame = puffinCommandFrame(cmd: 0x12, seq: 1, payload: [0x00, 0x01, 0x02, 0x03])
        let check = verifyFrame(frame, family: .whoop5)
        XCTAssertTrue(check.ok)
        XCTAssertEqual(check.reason, .none)
        XCTAssertEqual(crc32(frame, 8, frame.count - 4), crc32Table(frame, 8, frame.count - 4))
        XCTAssertEqual(crc16Modbus(frame, 0, 6), crc16ModbusBitwise(frame, 0, 6))
    }

    private func assertCrc32Match(_ bytes: [UInt8], from: Int = 0, to: Int? = nil,
                                  label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(crc32(bytes, from, to), crc32Table(bytes, from, to),
                       "crc32 zlib vs table drift at \(label)", file: file, line: line)
    }

    /// The production verifier's CRC32/CRC16 inputs are the same slices the table functions hash.
    /// If those match, a changed verdict cannot come from the CRC rewrite.
    private func assertVerdictUsesMatchingCrc(_ frame: [UInt8], family: DeviceFamily, label: String,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let check = verifyFrame(frame, family: family)
        switch family {
        case .whoop4:
            if frame.count >= 4 {
                let length = Int(frame[1]) | (Int(frame[2]) << 8)
                let total = length + 4
                if total <= frame.count, length >= 4 {
                    let got = crc32(frame, 4, length)
                    let want = crc32Table(frame, 4, length)
                    XCTAssertEqual(got, want, "whoop4 payload crc drift \(label)", file: file, line: line)
                    let trailer = UInt32(frame[length]) | (UInt32(frame[length + 1]) << 8)
                        | (UInt32(frame[length + 2]) << 16) | (UInt32(frame[length + 3]) << 24)
                    if let reported = check.crc32OK {
                        XCTAssertEqual(reported, got == trailer,
                                       "whoop4 crc32OK disagrees with matched crc \(label)",
                                       file: file, line: line)
                    }
                }
            }
        case .whoop5, .unsupported:
            if frame.count >= 8 {
                XCTAssertEqual(crc16Modbus(frame, 0, 6), crc16ModbusBitwise(frame, 0, 6),
                               "whoop5 header crc16 drift \(label)", file: file, line: line)
                let declared = Int(frame[2]) | (Int(frame[3]) << 8)
                let total = declared + 8
                if total <= frame.count, declared >= 4 {
                    let payloadEnd = total - 4
                    let got = crc32(frame, 8, payloadEnd)
                    XCTAssertEqual(got, crc32Table(frame, 8, payloadEnd),
                                   "whoop5 payload crc drift \(label)", file: file, line: line)
                    let trailer = UInt32(frame[payloadEnd]) | (UInt32(frame[payloadEnd + 1]) << 8)
                        | (UInt32(frame[payloadEnd + 2]) << 16) | (UInt32(frame[payloadEnd + 3]) << 24)
                    if let reported = check.crc32OK {
                        XCTAssertEqual(reported, got == trailer,
                                       "whoop5 crc32OK disagrees with matched crc \(label)",
                                       file: file, line: line)
                    }
                }
            }
        }
        // Structural reasons must still win over a matching CRC.
        if frame.isEmpty || frame.first != 0xAA {
            XCTAssertFalse(check.ok, "\(label) must fail", file: file, line: line)
        }
    }
}

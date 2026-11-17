import XCTest
@testable import WhoopProtocol

/// Round-3 fused decoder gate: `HistoricalStreamDecoder.decode` must match
/// `extractHistoricalStreams(frames.map { parseFrame })` and the DecodeFacts the old
/// finishChunk path derived from `[ParsedFrame]` + `rejectedHistoricalRecords`.
final class FusedHistoryDecodeTests: XCTestCase {

    private static let whoop5V18Hex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"
    private static let whoop5V18OffWristHex =
        "aa01740001003fb12f12803a3d84018889266a3d0a00000000000000000000000000000000000000000064c33b52b47d3fe1ba1dbda470ecbd000064000000000000000000e500e200c708000c010c020c0000000000000000000000000000000000000000000000010000008080000000000000000000009ffafe6c"
    private static let whoop5V26Hex =
        "aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4c" +
        "febafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff40" +
        "5fb33c50080101006cb67c17"
    private static let whoop5RealtimeHex =
        "aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc"
    private static let whoop5MetadataHex = "aa010c000001e741380300abcd00000060153281"

    private struct FrameHex: Decodable { let hex: String }
    private struct OracleFile: Decodable {
        struct Frame: Decodable {
            let name: String
            let family: String
            let hex: String
        }
        let frames: [Frame]
    }

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

    private func loadJSONFrames(_ resource: String) -> [[UInt8]] {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([FrameHex].self, from: data) else {
            return []
        }
        return entries.map { Self.hex($0.hex) }
    }

    private func loadOracleFrames() -> [(name: String, family: DeviceFamily, frame: [UInt8])] {
        guard let url = Bundle.module.url(forResource: "decoder_oracle", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let oracle = try? JSONDecoder().decode(OracleFile.self, from: data) else {
            return []
        }
        return oracle.frames.map {
            ($0.name, $0.family == "whoop5" ? DeviceFamily.whoop5 : .whoop4, Self.hex($0.hex))
        }
    }

    private func familyOf(_ frame: [UInt8]) -> DeviceFamily {
        frame.count >= 2 && frame[1] == 0x01 ? .whoop5 : .whoop4
    }

    private func reseal(_ frame: inout [UInt8], family: DeviceFamily) {
        switch family {
        case .whoop5, .unsupported:
            guard frame.count >= FrameLimits.whoop5MinimumFrameBytes else { return }
            let h = crc16Modbus(frame, 0, 6)
            frame[6] = UInt8(h & 0xff); frame[7] = UInt8(h >> 8)
            let payloadEnd = frame.count - 4
            let c = crc32(frame, 8, payloadEnd)
            frame[payloadEnd] = UInt8(c & 0xff)
            frame[payloadEnd + 1] = UInt8((c >> 8) & 0xff)
            frame[payloadEnd + 2] = UInt8((c >> 16) & 0xff)
            frame[payloadEnd + 3] = UInt8((c >> 24) & 0xff)
        case .whoop4:
            guard frame.count >= FrameLimits.whoop4MinimumFrameBytes else { return }
            frame[3] = crc8(frame, 1, 3)
            let length = Int(frame[1]) | (Int(frame[2]) << 8)
            guard length + 4 == frame.count, length >= 4 else { return }
            let c = crc32(frame, 4, length)
            frame[length] = UInt8(c & 0xff)
            frame[length + 1] = UInt8((c >> 8) & 0xff)
            frame[length + 2] = UInt8((c >> 16) & 0xff)
            frame[length + 3] = UInt8((c >> 24) & 0xff)
        }
    }

    private func putU32(_ f: inout [UInt8], _ off: Int, _ v: UInt32) {
        f[off] = UInt8(v & 0xff); f[off + 1] = UInt8((v >> 8) & 0xff)
        f[off + 2] = UInt8((v >> 16) & 0xff); f[off + 3] = UInt8((v >> 24) & 0xff)
    }

    private func whoop5Frame(total: Int, version: UInt8, _ build: (inout [UInt8]) -> Void) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: total)
        f[0] = 0xAA; f[1] = 0x01
        let declared = total - 8
        f[2] = UInt8(declared & 0xff); f[3] = UInt8((declared >> 8) & 0xff)
        f[4] = 0x01; f[5] = 0x00
        f[8] = 47
        f[9] = version
        build(&f)
        reseal(&f, family: .whoop5)
        return f
    }

    private func r16Frame() -> [UInt8] {
        var inner = [UInt8](repeating: 0, count: Whoop5Ecg.r16InnerLength)
        inner[0] = Whoop5Ecg.storedRecordType
        inner[1] = Whoop5Ecg.r16Revision
        inner[2] = 0x5a
        putU32(&inner, 3, 0x0001_2345)
        putU32(&inner, 7, 1_760_000_000)
        inner[11] = 0x00; inner[12] = 0x40
        inner[13] = 3
        inner[14] = 0x08
        inner[17] = 100
        inner[19] = 64
        inner[24] = UInt8(Whoop5Ecg.r16MaxSamples & 0xff)
        inner[25] = UInt8((Whoop5Ecg.r16MaxSamples >> 8) & 0xff)
        return puffinCommandFrame(cmd: inner[2], seq: inner[1],
                                  payload: Array(inner.dropFirst(3)), type: inner[0])
    }

    private struct OldFacts {
        var streams: Streams
        var rejected: [[UInt8]]
        var firstHistVersion: Int?
        var anyHeartRate: Bool
        var anyGravity: Bool
        var anyPpg: Bool
        var signalByVersion: [Int: Bool]
        var typeNames: [String]
    }

    private func oldPath(_ frames: [[UInt8]], family: DeviceFamily,
                         device: Int, wall: Int, oldest: Int? = nil, newest: Int? = nil,
                         wallNow: Int) -> OldFacts {
        let parsed = frames.map { parseFrame($0, family: family) }
        let streams = extractHistoricalStreams(parsed, deviceClockRef: device, wallClockRef: wall,
                                               family: family, sessionOldestUnix: oldest,
                                               sessionNewestUnix: newest, wallNow: wallNow)
        let rejected = rejectedHistoricalRecords(frames, family: family)
        var signal: [Int: Bool] = [:]
        for p in parsed {
            guard let v = p.parsed["hist_version"]?.intValue else { continue }
            let carries = p.parsed["heart_rate"] != nil
                || p.parsed["gravity_x"] != nil
                || p.parsed["ppg_waveform"] != nil
            signal[v] = (signal[v] ?? false) || carries
        }
        return OldFacts(
            streams: streams,
            rejected: rejected,
            firstHistVersion: parsed.lazy.compactMap { $0.parsed["hist_version"]?.intValue }.first,
            anyHeartRate: parsed.contains { $0.parsed["heart_rate"] != nil },
            anyGravity: parsed.contains { $0.parsed["gravity_x"] != nil },
            anyPpg: parsed.contains { $0.parsed["ppg_waveform"] != nil },
            signalByVersion: signal,
            typeNames: parsed.map(\.typeName))
    }

    /// `Double.nan != .nan` under Equatable, so two identical NaN gravity vectors from a
    /// mutated short v18 payload compare unequal even though every bit matches.
    private func doubleEq(_ a: Double, _ b: Double) -> Bool {
        (a.isNaN && b.isNaN) || a == b
    }

    private func streamsMatch(_ a: Streams, _ b: Streams) -> Bool {
        guard a.hr == b.hr, a.rr == b.rr, a.spo2 == b.spo2, a.skinTemp == b.skinTemp,
              a.resp == b.resp, a.steps == b.steps, a.sleepState == b.sleepState,
              a.ppgHr == b.ppgHr, a.ppgWaveform == b.ppgWaveform, a.ecgWaveform == b.ecgWaveform,
              a.v18Aux == b.v18Aux, a.events == b.events, a.battery == b.battery,
              a.droppedImplausible == b.droppedImplausible,
              a.droppedImplausibleOldestTs == b.droppedImplausibleOldestTs,
              a.droppedImplausibleNewestTs == b.droppedImplausibleNewestTs,
              a.droppedRtcEvents == b.droppedRtcEvents,
              a.unhandledPacketTypes == b.unhandledPacketTypes,
              a.dynAccel == b.dynAccel else { return false }
        guard a.gravity.count == b.gravity.count else { return false }
        for (x, y) in zip(a.gravity, b.gravity) {
            guard x.ts == y.ts, x.unit == y.unit,
                  doubleEq(x.x, y.x), doubleEq(x.y, y.y), doubleEq(x.z, y.z) else { return false }
            switch (x.dynAccel, y.dynAccel) {
            case (nil, nil): break
            case let (a?, b?) where doubleEq(a, b): break
            default: return false
            }
        }
        return true
    }

    private func assertFusedMatchesOld(_ frames: [[UInt8]], family: DeviceFamily,
                                       wallNow: Int, label: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let device = 1_780_916_150
        let (fused, facts) = HistoricalStreamDecoder.decode(
            frames: frames, family: family,
            deviceClockRef: device, wallClockRef: device,
            wallNow: wallNow)
        let old = oldPath(frames, family: family, device: device, wall: device, wallNow: wallNow)
        XCTAssertTrue(streamsMatch(fused, old.streams), "\(label) streams", file: file, line: line)
        XCTAssertEqual(facts.rejected, old.rejected, "\(label) rejected", file: file, line: line)
        XCTAssertEqual(facts.firstHistVersion, old.firstHistVersion, "\(label) firstHistVersion",
                       file: file, line: line)
        XCTAssertEqual(facts.anyHeartRate, old.anyHeartRate, "\(label) anyHeartRate",
                       file: file, line: line)
        XCTAssertEqual(facts.anyGravity, old.anyGravity, "\(label) anyGravity",
                       file: file, line: line)
        XCTAssertEqual(facts.anyPpgWaveform, old.anyPpg, "\(label) anyPpg",
                       file: file, line: line)
        XCTAssertEqual(facts.signalByVersion, old.signalByVersion, "\(label) signalByVersion",
                       file: file, line: line)
        XCTAssertEqual(facts.typeNames, old.typeNames, "\(label) typeNames",
                       file: file, line: line)
    }

    private func seedCorpus() -> [(family: DeviceFamily, frame: [UInt8])] {
        var out: [(DeviceFamily, [UInt8])] = [
            (.whoop5, Self.hex(Self.whoop5V18Hex)),
            (.whoop5, Self.hex(Self.whoop5V18OffWristHex)),
            (.whoop5, Self.hex(Self.whoop5V26Hex)),
            (.whoop5, Self.hex(Self.whoop5RealtimeHex)),
            (.whoop5, Self.hex(Self.whoop5MetadataHex)),
            (.whoop5, r16Frame()),
            (.whoop5, whoop5Frame(total: 1244, version: 21) { f in
                self.putU32(&f, 11, 42)
                self.putU32(&f, 15, 1_780_916_150)
            }),
            (.whoop5, whoop5Frame(total: 2140, version: 20) { f in
                self.putU32(&f, 11, 7)
                self.putU32(&f, 15, 1_780_916_150)
            }),
            (.whoop5, whoop5Frame(total: 124, version: 19) { f in
                self.putU32(&f, 15, 1_780_916_150)
            }),
        ]
        for item in loadOracleFrames() {
            out.append((item.family, item.frame))
        }
        for f in loadJSONFrames("historical_frames") {
            out.append((.whoop4, f))
        }
        for f in loadJSONFrames("frames") {
            out.append((familyOf(f), f))
        }
        return out
    }

    func testV18OffsetsMatchParseFrame() {
        let frame = Self.hex(Self.whoop5V18Hex)
        let p = parseFrame(frame, family: .whoop5).parsed
        XCTAssertEqual(p["hist_version"]?.intValue, Int(frame[Whoop5HistOff.version]))
        let unix = Int(frame[15]) | (Int(frame[16]) << 8) | (Int(frame[17]) << 16) | (Int(frame[18]) << 24)
        XCTAssertEqual(p["unix"]?.intValue, unix)
        XCTAssertEqual(p["heart_rate"]?.intValue, Int(frame[Whoop5HistOff.heartRate]))
        XCTAssertEqual(p["rr_count"]?.intValue, Int(frame[Whoop5HistOff.rrCount]))
    }

    func testOracleAndFixtureFramesFusedEqualsOld() {
        let wallNow = 1_780_916_160
        var versions = Set<Int>()
        for item in loadOracleFrames() {
            assertFusedMatchesOld([item.frame], family: item.family, wallNow: wallNow,
                                  label: "oracle \(item.name)")
            if let v = parseFrame(item.frame, family: item.family).parsed["hist_version"]?.intValue {
                versions.insert(v)
            }
        }
        XCTAssertTrue(versions.contains(18), "oracle must cover v18")
        XCTAssertTrue(versions.contains(16), "oracle must cover v16")
        XCTAssertTrue(versions.contains(24) || versions.contains(25), "oracle must cover WHOOP 4 layouts")

        for (i, frame) in loadJSONFrames("historical_frames").enumerated() {
            assertFusedMatchesOld([frame], family: .whoop4, wallNow: wallNow,
                                  label: "historical_frames[\(i)]")
        }
        assertFusedMatchesOld([Self.hex(Self.whoop5V18Hex)], family: .whoop5, wallNow: wallNow,
                              label: "v18 worn")
        assertFusedMatchesOld([Self.hex(Self.whoop5V18OffWristHex)], family: .whoop5, wallNow: wallNow,
                              label: "v18 offwrist")
        assertFusedMatchesOld([Self.hex(Self.whoop5V26Hex)], family: .whoop5, wallNow: wallNow,
                              label: "v26")
        assertFusedMatchesOld([r16Frame()], family: .whoop5, wallNow: wallNow, label: "v16 r16")
        let v21 = whoop5Frame(total: 1244, version: 21) { f in
            self.putU32(&f, 15, 1_780_916_150)
        }
        assertFusedMatchesOld([v21], family: .whoop5, wallNow: wallNow, label: "v21")
        let v20 = whoop5Frame(total: 2140, version: 20) { f in
            self.putU32(&f, 15, 1_780_916_150)
        }
        assertFusedMatchesOld([v20], family: .whoop5, wallNow: wallNow, label: "v20")
        let mixed: [[UInt8]] = [
            Self.hex(Self.whoop5V18Hex),
            Self.hex(Self.whoop5MetadataHex),
            Self.hex(Self.whoop5V26Hex),
            r16Frame(),
            Self.hex(Self.whoop5RealtimeHex),
        ]
        assertFusedMatchesOld(mixed, family: .whoop5, wallNow: wallNow, label: "mixed chunk")
    }

    func testCorruptedFramesMatchOldPath() {
        let intact = Self.hex(Self.whoop5V18Hex)
        let wallNow = 1_780_916_160
        func corrupt(_ frame: [UInt8], at i: Int) -> [UInt8] {
            var f = frame; f[i] ^= 0xFF; return f
        }
        let cases: [(String, [UInt8])] = [
            ("header checksum", corrupt(intact, at: 6)),
            ("payload crc32", corrupt(intact, at: intact.count - 1)),
            ("length mismatch", { var f = intact; f[2] ^= 0x01; return f }()),
            ("no SOF", { var f = intact; f[0] = 0x00; return f }()),
            ("truncated", Array(intact.dropLast(8))),
            ("trailing byte", intact + [0x00]),
        ]
        for (label, frame) in cases {
            assertFusedMatchesOld([frame], family: .whoop5, wallNow: wallNow, label: label)
        }
        let mixed = [corrupt(intact, at: 6), intact, corrupt(intact, at: intact.count - 1)]
        assertFusedMatchesOld(mixed, family: .whoop5, wallNow: wallNow, label: "mixed corrupt")
    }

    func testFuzz1MFramesFusedEqualsOld() {
        let seeds = seedCorpus()
        XCTAssertFalse(seeds.isEmpty)
        var rng: UInt64 = 0xC0FFEE_F00D_1234
        func next() -> UInt64 {
            rng &+= 0x9E3779B97F4A7C15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        func nextInt(_ bound: Int) -> Int {
            guard bound > 0 else { return 0 }
            return Int(next() % UInt64(bound))
        }
        let wallNow = 1_780_916_160
        let n = 1_000_000
        var streamMismatch = 0
        var factMismatch = 0
        var coveredVersions = Set<Int>()
        for i in 0..<n {
            let seed = seeds[i % seeds.count]
            let family = seed.family
            var frame = seed.frame
            let kind = nextInt(10)
            switch kind {
            case 0 where frame.count > 20:
                frame[nextInt(frame.count - 8) + 8] ^= UInt8(truncatingIfNeeded: next())
                reseal(&frame, family: family)
            case 1 where frame.count > 16:
                frame[15] = UInt8(truncatingIfNeeded: next())
                frame[16] = UInt8(truncatingIfNeeded: next())
                frame[17] = UInt8(truncatingIfNeeded: next())
                frame[18] = UInt8(truncatingIfNeeded: next())
                reseal(&frame, family: family)
            case 2 where family == .whoop5 && frame.count > 9:
                frame[9] = UInt8(nextInt(32))
                reseal(&frame, family: family)
            case 3 where frame.count > 6:
                frame[6] ^= 0xFF
            case 4 where frame.count > 4:
                frame[frame.count - 1] ^= 0xFF
            case 5 where frame.count > 3:
                frame[2] ^= 0x01
            case 6:
                frame[0] = 0x00
            case 7 where frame.count > 12:
                frame = Array(frame.dropLast(nextInt(8) + 1))
            case 8:
                frame.append(UInt8(truncatingIfNeeded: next()))
            default:
                if frame.count > 22 {
                    frame[22] = UInt8(truncatingIfNeeded: next())
                    reseal(&frame, family: family)
                }
            }
            if family == .whoop5, frame.count > 9 {
                coveredVersions.insert(Int(frame[9]))
            }
            let device = 1_780_916_150
            let (fused, facts) = HistoricalStreamDecoder.decode(
                frames: [frame], family: family,
                deviceClockRef: device, wallClockRef: device, wallNow: wallNow)
            let old = oldPath([frame], family: family, device: device, wall: device, wallNow: wallNow)
            if !streamsMatch(fused, old.streams) { streamMismatch += 1 }
            if facts.rejected != old.rejected
                || facts.firstHistVersion != old.firstHistVersion
                || facts.anyHeartRate != old.anyHeartRate
                || facts.anyGravity != old.anyGravity
                || facts.typeNames != old.typeNames {
                factMismatch += 1
            }
        }
        print("FUSED_FUZZ n=\(n) streamMismatch=\(streamMismatch) factMismatch=\(factMismatch) versions=\(coveredVersions.sorted())")
        fflush(stdout)
        XCTAssertEqual(streamMismatch, 0, "fused Streams diverged on fuzz corpus")
        XCTAssertEqual(factMismatch, 0, "DecodeFacts diverged on fuzz corpus")
    }

    func testDataSequenceOverloadMatchesArray() {
        let frames = [Self.hex(Self.whoop5V18Hex), Self.hex(Self.whoop5V26Hex)]
        let unix = 1_780_916_150
        let a = HistoricalStreamDecoder.decode(frames: frames, family: .whoop5,
                                               deviceClockRef: unix, wallClockRef: unix,
                                               wallNow: unix + 10)
        let b = HistoricalStreamDecoder.decode(frames: frames.map { Data($0) }, family: .whoop5,
                                               deviceClockRef: unix, wallClockRef: unix,
                                               wallNow: unix + 10)
        XCTAssertEqual(a.0, b.0)
        XCTAssertEqual(a.1, b.1)
    }
}

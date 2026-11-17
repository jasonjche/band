import XCTest
import Darwin
@testable import WhoopProtocol

/// Ingest-pipeline throughput benches. Skipped unless `BAND_PERF=1`.
///
/// Measures the history-sync CPU path after bytes have already arrived: CRC, `verifyFrame`,
/// `parseFrame` + `extractHistoricalStreams`. A day's worth of WHOOP 5.0 v18 historical frames
/// (1 Hz × 86400) is tiled from a real captured fixture so the input is realistic in size and
/// layout. Median + p90 of ≥7 runs after one warm-up.
final class IngestPerfTests: XCTestCase {

    private static let dayFrames = 86_400
    private static let measuredRuns = 7

    /// Real type-47 HISTORICAL_DATA v18 (worn WHOOP 5, captured 2026-06-08). Same vector as
    /// `Whoop5HistoricalTests`.
    private static let whoop5HistoricalHex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    /// type-40 REALTIME_DATA fixture (also a real capture).
    private static let whoop5RealtimeHex =
        "aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc"

    private struct Stats {
        var median: Double
        var p90: Double
        var samples: [Double]
    }

    private func requirePerf() throws {
        guard ProcessInfo.processInfo.environment["BAND_PERF"] == "1" else {
            throw XCTSkip("set BAND_PERF=1 to run ingest pipeline benchmarks")
        }
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

    private static func loadJSONFrames(_ resource: String) -> [[UInt8]] {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([FrameHex].self, from: data) else {
            return []
        }
        return entries.map { hex($0.hex) }
    }

    private struct FrameHex: Decodable { let hex: String }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let i = min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))
        return sorted[i]
    }

    private func summarize(_ xs: [Double]) -> Stats {
        let s = xs.sorted()
        return Stats(median: percentile(s, 0.5), p90: percentile(s, 0.9), samples: s)
    }

    private func mallocInUse() -> Int {
        var st = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &st)
        return Int(st.size_in_use)
    }

    /// Resident set size via `mach_task_basic_info`, for peak-memory benches.
    private func physFootprint() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size)
    }

    /// Tile `seed` to `count` frames. Identical copies are valid CRC-checked frames; decode
    /// throughput does not need unique timestamps (insert benches live in WhoopStore).
    private func tile(_ seed: [UInt8], count: Int) -> [[UInt8]] {
        var out = [[UInt8]](); out.reserveCapacity(count)
        for _ in 0..<count { out.append(seed) }
        return out
    }

    private func report(_ name: String, n: Int, bytes: Int, seconds: Stats, allocs: Stats?) {
        let medFps = Double(n) / seconds.median
        let p90Fps = Double(n) / seconds.p90
        let medMBps = (Double(bytes) / 1_000_000.0) / seconds.median
        let p90MBps = (Double(bytes) / 1_000_000.0) / seconds.p90
        var line = String(
            format: "BAND_PERF %@ n=%d median=%.0f frames/s p90=%.0f frames/s median=%.2f MB/s p90=%.2f MB/s  (s median=%.4f p90=%.4f spread=[%.4f..%.4f])",
            name, n, medFps, p90Fps, medMBps, p90MBps,
            seconds.median, seconds.p90, seconds.samples.first ?? 0, seconds.samples.last ?? 0)
        if let allocs {
            line += String(format: " alloc_delta_median=%.0f B p90=%.0f B", allocs.median, allocs.p90)
        }
        print(line)
        fflush(stdout)
    }

    // MARK: - CRC

    func testPerfCrc32DayOfHistoricalPayloads() throws {
        try requirePerf()
        let seed = Self.hex(Self.whoop5HistoricalHex)
        XCTAssertTrue(verifyFrame(seed, family: .whoop5).ok)
        let frames = tile(seed, count: Self.dayFrames)
        let bytes = frames.reduce(0) { $0 + $1.count }

        var times: [Double] = []
        var allocs: [Double] = []
        times.reserveCapacity(Self.measuredRuns)
        var sink: UInt32 = 0

        // warm-up
        for f in frames { sink ^= crc32(f, 8, f.count - 4) }

        for _ in 0..<Self.measuredRuns {
            let a0 = mallocInUse()
            let t0 = DispatchTime.now().uptimeNanoseconds
            for f in frames { sink ^= crc32(f, 8, f.count - 4) }
            let t1 = DispatchTime.now().uptimeNanoseconds
            let a1 = mallocInUse()
            times.append(Double(t1 - t0) / 1e9)
            allocs.append(Double(max(0, a1 - a0)))
        }
        XCTAssertNotEqual(Int(sink), Int(UInt32.max))
        report("crc32_whoop5_hist_payload", n: Self.dayFrames, bytes: bytes,
               seconds: summarize(times), allocs: summarize(allocs))
    }

    func testPerfVerifyFrameDayOfHistorical() throws {
        try requirePerf()
        let seed = Self.hex(Self.whoop5HistoricalHex)
        let frames = tile(seed, count: Self.dayFrames)
        let bytes = frames.reduce(0) { $0 + $1.count }

        var times: [Double] = []
        var allocs: [Double] = []
        var sink = 0
        for f in frames { if verifyFrame(f, family: .whoop5).ok { sink += 1 } } // warm-up

        for _ in 0..<Self.measuredRuns {
            let a0 = mallocInUse()
            let t0 = DispatchTime.now().uptimeNanoseconds
            var ok = 0
            for f in frames { if verifyFrame(f, family: .whoop5).ok { ok += 1 } }
            let t1 = DispatchTime.now().uptimeNanoseconds
            let a1 = mallocInUse()
            sink &+= ok
            times.append(Double(t1 - t0) / 1e9)
            allocs.append(Double(max(0, a1 - a0)))
        }
        XCTAssertGreaterThan(sink, 0)
        report("verifyFrame_whoop5_hist", n: Self.dayFrames, bytes: bytes,
               seconds: summarize(times), allocs: summarize(allocs))
    }

    // MARK: - Decode

    func testPerfParseAndExtractDayOfHistorical() throws {
        try requirePerf()
        let seed = Self.hex(Self.whoop5HistoricalHex)
        let frames = tile(seed, count: Self.dayFrames)
        let bytes = frames.reduce(0) { $0 + $1.count }
        // Identity clock so extract keeps the record's own unix (plausible: 1780916150).
        let unix = 1_780_916_150

        var times: [Double] = []
        var allocs: [Double] = []
        var sink = 0

        func runOnce() -> Int {
            // Stream parse→extract so a day's ParsedFrame dictionaries are not retained.
            let streams = extractHistoricalStreams(frames: frames, deviceClockRef: unix, wallClockRef: unix,
                                                   family: .whoop5, wallNow: unix + 10)
            return frames.count + streams.hr.count + streams.rr.count + streams.gravity.count
        }
        sink &+= runOnce() // warm-up

        for _ in 0..<Self.measuredRuns {
            let a0 = mallocInUse()
            let t0 = DispatchTime.now().uptimeNanoseconds
            sink &+= runOnce()
            let t1 = DispatchTime.now().uptimeNanoseconds
            let a1 = mallocInUse()
            times.append(Double(t1 - t0) / 1e9)
            allocs.append(Double(max(0, a1 - a0)))
        }
        XCTAssertGreaterThan(sink, 0)
        report("parse+extract_whoop5_hist", n: Self.dayFrames, bytes: bytes,
               seconds: summarize(times), allocs: summarize(allocs))
    }

    func testPerfParseFrameOnlyDayOfHistorical() throws {
        try requirePerf()
        let seed = Self.hex(Self.whoop5HistoricalHex)
        let frames = tile(seed, count: Self.dayFrames)
        let bytes = frames.reduce(0) { $0 + $1.count }

        var times: [Double] = []
        var allocs: [Double] = []
        var sink = 0
        for f in frames { sink &+= parseFrame(f, family: .whoop5).parsed["heart_rate"]?.intValue ?? 0 }

        for _ in 0..<Self.measuredRuns {
            let a0 = mallocInUse()
            let t0 = DispatchTime.now().uptimeNanoseconds
            for f in frames {
                sink &+= parseFrame(f, family: .whoop5).parsed["heart_rate"]?.intValue ?? 0
            }
            let t1 = DispatchTime.now().uptimeNanoseconds
            let a1 = mallocInUse()
            times.append(Double(t1 - t0) / 1e9)
            allocs.append(Double(max(0, a1 - a0)))
        }
        XCTAssertGreaterThan(sink, 0)
        report("parseFrame_whoop5_hist", n: Self.dayFrames, bytes: bytes,
               seconds: summarize(times), allocs: summarize(allocs))
    }

    func testPerfParseMixedCorpusTiled() throws {
        try requirePerf()
        // Mix real 4.0 + 5.0 fixtures so CRC/decode covers both envelopes, then tile to a day.
        var seeds = Self.loadJSONFrames("frames")
        seeds.append(Self.hex(Self.whoop5HistoricalHex))
        seeds.append(Self.hex(Self.whoop5RealtimeHex))
        XCTAssertFalse(seeds.isEmpty)
        var frames = [[UInt8]](); frames.reserveCapacity(Self.dayFrames)
        var i = 0
        while frames.count < Self.dayFrames {
            frames.append(seeds[i % seeds.count])
            i += 1
        }
        let bytes = frames.reduce(0) { $0 + $1.count }
        var times: [Double] = []
        var sink = 0
        for f in frames.prefix(1024) {
            let family: DeviceFamily = f.count >= 2 && f[1] == 0x01 ? .whoop5 : .whoop4
            sink &+= parseFrame(f, family: family).ok ? 1 : 0
        }
        for _ in 0..<Self.measuredRuns {
            let t0 = DispatchTime.now().uptimeNanoseconds
            for f in frames {
                let family: DeviceFamily = f.count >= 2 && f[1] == 0x01 ? .whoop5 : .whoop4
                sink &+= parseFrame(f, family: family).ok ? 1 : 0
            }
            let t1 = DispatchTime.now().uptimeNanoseconds
            times.append(Double(t1 - t0) / 1e9)
        }
        XCTAssertGreaterThan(sink, 0)
        report("parseFrame_mixed_tiled", n: Self.dayFrames, bytes: bytes,
               seconds: summarize(times), allocs: nil)
    }

    // MARK: - memcpy ceiling + peak memory

    func testPerfMemcpyDayOfHistorical() throws {
        try requirePerf()
        let seed = Self.hex(Self.whoop5HistoricalHex)
        let frames = tile(seed, count: Self.dayFrames)
        let bytes = frames.reduce(0) { $0 + $1.count }
        var dest = [UInt8](repeating: 0, count: seed.count)
        var times: [Double] = []
        var sink = 0
        for f in frames { dest.withUnsafeMutableBytes { d in
            f.withUnsafeBytes { s in _ = memcpy(d.baseAddress, s.baseAddress, s.count) }
        }; sink &+= Int(dest[0]) }
        for _ in 0..<Self.measuredRuns {
            let t0 = DispatchTime.now().uptimeNanoseconds
            for f in frames {
                dest.withUnsafeMutableBytes { d in
                    f.withUnsafeBytes { s in _ = memcpy(d.baseAddress, s.baseAddress, s.count) }
                }
                sink &+= Int(dest[4])
            }
            let t1 = DispatchTime.now().uptimeNanoseconds
            times.append(Double(t1 - t0) / 1e9)
        }
        XCTAssertGreaterThan(sink, 0)
        report("memcpy_whoop5_hist", n: Self.dayFrames, bytes: bytes,
               seconds: summarize(times), allocs: nil)
    }

    func testPerfPeakMemoryParseExtractDayStreamingVsAccumulating() throws {
        try requirePerf()
        let seed = Self.hex(Self.whoop5HistoricalHex)
        let frames = tile(seed, count: Self.dayFrames)
        let unix = 1_780_916_150
        _ = extractHistoricalStreams(frames: frames, deviceClockRef: unix, wallClockRef: unix,
                                     family: .whoop5, wallNow: unix + 10)

        let fp0 = physFootprint()
        let a0 = mallocInUse()
        var parsed = [ParsedFrame](); parsed.reserveCapacity(frames.count)
        for f in frames { parsed.append(parseFrame(f, family: .whoop5)) }
        let acc = extractHistoricalStreams(parsed, deviceClockRef: unix, wallClockRef: unix,
                                           family: .whoop5, wallNow: unix + 10)
        let fpAcc = physFootprint()
        let aAcc = mallocInUse()
        parsed.removeAll(keepingCapacity: false)

        let fp1 = physFootprint()
        let a1 = mallocInUse()
        let streamed = extractHistoricalStreams(frames: frames, deviceClockRef: unix, wallClockRef: unix,
                                                family: .whoop5, wallNow: unix + 10)
        let fpStream = physFootprint()
        let aStream = mallocInUse()

        XCTAssertEqual(streamed.hr.count, acc.hr.count)
        XCTAssertEqual(streamed.rr.count, acc.rr.count)
        print(String(
            format: "BAND_PERF peak_memory_parse+extract n=%d accum_footprint_delta=%.1f MB stream_footprint_delta=%.1f MB accum_malloc_delta=%.1f MB stream_malloc_delta=%.1f MB (baseline_fp=%.1f MB)",
            Self.dayFrames,
            Double(max(0, fpAcc - fp0)) / 1_000_000,
            Double(max(0, fpStream - fp1)) / 1_000_000,
            Double(max(0, aAcc - a0)) / 1_000_000,
            Double(max(0, aStream - a1)) / 1_000_000,
            Double(fp0) / 1_000_000))
        fflush(stdout)
    }
}

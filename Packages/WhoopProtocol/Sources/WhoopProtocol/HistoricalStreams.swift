import Foundation

/// #891: packet types an offload legitimately carries that `extractHistoricalStreams` has no rows for, so
/// reaching `default:` is expected rather than a finding. Both decode to zero rows BY DESIGN — CONSOLE_LOGS
/// is strap-side debug text, METADATA is envelope bookkeeping — and counting them on every sync would bury
/// the one signal `Streams.unhandledPacketTypes` exists to surface. Nothing else is excluded, including
/// named-but-unhandled types like `HISTORICAL_IMU_DATA_STREAM(52)`: those are exactly the interesting ones.
/// Keep in lockstep with the Android `EXPECTED_UNHANDLED_HISTORICAL_TYPES`.
let expectedUnhandledHistoricalTypes: Set<String> = ["METADATA", "CONSOLE_LOGS"]

/// How stale the strap RTC must be before the `(wall - device)` offset is applied to a historical
/// record's own unix second. BELOW this the offset is discarded and the raw stamp is kept verbatim, so
/// an everyday drift of seconds-to-minutes never reaches stored timestamps. Shared with `ChunkClockDiag`
/// so the strap log's `corr=on|off` cannot disagree with what the decoder actually did.
public let histStaleClockThresholdSec = 86_400   // 1 day

/// Shared plausibility bounds for a type-47 record's own unix timestamp (#547). A WHOOP strap with a
/// bad clock/flash (repeated trim=0xFFFFFFFF no-cursor) emits records whose decoded unix is scattered
/// garbage — far-past (2024/2029), a bogus 2027=1827642881, and even FUTURE dates. NOOP used to trust
/// these verbatim, so one polluted ~12h block got re-attributed to every day-window and a future-dated
/// record surfaced as the "last night" carry-over. We now reject any record whose ts isn't near "now".
///
/// MIN_PLAUSIBLE_UNIX = 2023-11 — the same 1.7B floor `BLEManager.strapDataBounds` already uses.
/// FUTURE_MARGIN = 1 day — a historical record can never post-date its own capture, so anything more
/// than a day ahead of wall time is a bad-clock artefact. Keep these in lockstep with the Android
/// `HistoricalStreams.kt` MIN_PLAUSIBLE_UNIX / FUTURE_MARGIN.
public let MIN_PLAUSIBLE_UNIX = 1_700_000_000   // 2023-11
public let FUTURE_MARGIN = 86_400               // 1 day

/// SESSION-RELATIVE slack (#547): how far OUTSIDE the strap's own GET_DATA_RANGE oldest/newest markers a
/// record may still be stamped before it's treated as bad-clock pollution. The strap reports its banked
/// history span [oldest, newest] for THIS sync; a real record cannot predate the oldest banked marker nor
/// post-date the newest by more than benign skew, so a record dated MONTHS off the strap's OWN window is a
/// wandering-clock artefact even when it clears the absolute 2023-11 floor (e.g. a 2024-12-25 record against
/// a 2026 strap window). 7 days absorbs marker jitter / a still-banking newest edge / DST while still
/// catching the months-off garbage. Kept in lockstep with Android `HistoricalStreams.kt` SESSION_RANGE_MARGIN.
public let SESSION_RANGE_MARGIN = 7 * 86_400    // 7 days

/// #520: the stillness cut for the `dynamic_acceleration` diagnostic. Borrowed from
/// `SleepStager.gravityStillThresholdG` (0.01 g) as a REFERENCE point, not because the two measure the
/// same thing — the stager thresholds a per-sample DELTA between consecutive gravity vectors, while this
/// field is an ABSOLUTE gravity-removed magnitude at one instant. Both approach 0 when the wrist is still,
/// so the same cut is a sensible starting point, but a matching still-fraction would not prove the two are
/// equivalent. Duplicated as a literal rather than imported — WhoopProtocol is the wire layer and must not
/// depend on StrandAnalytics. If the stager's constant moves, move this one with it.
public let dynAccelStillThresholdG = 0.01

/// True when `ts` is a plausible capture time for a historical record given `wallNow` (#547): on or
/// after the 2023-11 floor and no more than a day ahead of now. The single predicate the ingest gate
/// and the one-time DB heal both use, so both platforms reject the exact same set.
public func isPlausibleHistoricalUnix(_ ts: Int, wallNow: Int) -> Bool {
    ts >= MIN_PLAUSIBLE_UNIX && ts <= wallNow + FUTURE_MARGIN
}

/// SESSION-RELATIVE plausibility (#547): the absolute gate (`isPlausibleHistoricalUnix`) PLUS a check
/// that `ts` sits within the strap's OWN GET_DATA_RANGE markers for THIS sync, padded by
/// `SESSION_RANGE_MARGIN`. `sessionOldestUnix`/`sessionNewestUnix` are the markers the BLE client scanned
/// from the strap's range reply (nil when unknown — the replay/import/no-range paths). When BOTH markers
/// are present AND well-formed (both clear the absolute floor and oldest <= newest), a record dated far
/// before the oldest banked marker or far after the newest is rejected as wandering-clock pollution even
/// though it cleared the absolute floor. When the markers are absent or malformed this is byte-identical
/// to the absolute-only gate, so every legacy / range-less caller is unchanged. A legitimately-OLD record
/// that falls WITHIN [oldest, newest] (real history the strap actually banked) is always kept.
public func isPlausibleHistoricalUnix(_ ts: Int, wallNow: Int,
                                      sessionOldestUnix: Int?, sessionNewestUnix: Int?) -> Bool {
    guard isPlausibleHistoricalUnix(ts, wallNow: wallNow) else { return false }
    // Only apply the session-relative window when both markers are trustworthy: present, themselves above
    // the absolute floor, and correctly ordered. A wrong-epoch / partial marker must never reject real data.
    guard let oldest = sessionOldestUnix, let newest = sessionNewestUnix,
          oldest >= MIN_PLAUSIBLE_UNIX, newest >= oldest else { return true }
    return ts >= oldest - SESSION_RANGE_MARGIN && ts <= newest + SESSION_RANGE_MARGIN
}

/// The HISTORICAL_DATA record frames in `rawFrames` that NOOP cannot turn into rows — a genuine CRC
/// failure, an unmapped firmware layout (5/MG: any `hist_version` outside
/// `mappedWhoop5HistoricalVersions`), or a mapped layout whose envelope parsed but yielded no usable
/// biometrics. These are the records the strap is about to free once we ack the trim, so without an
/// archive they are lost forever while the UI reports a clean sync (#77 / #91).
///
/// Console (type-50, `frame[typeIndex] == 0x32`) frames are strap-side debug-log text that decode to
/// zero rows BY DESIGN and are never returned. 5/MG v16 (flash-banked ECG, #2847) is skipped on the same
/// terms as v26 below and for the same reason: its waveform has its own durable stream
/// (`Streams.ecgWaveform` / `ecgWaveformSample`), and the archive is the wrong home for a 1.5 KB record
/// at one per strap-second. 5/MG v26 (raw PPG block, hist_version 26) is skipped
/// only while it is INTACT: a v26 record's payload is the optical waveform, which
/// `extractHistoricalStreams` persists durably in its OWN stream (`Streams.ppgWaveform` / WhoopStore's
/// `ppgWaveformSample` table, issue #156 follow-up) — but only for a record it accepts. Since the
/// integrity gate, a v26 record with a broken envelope is dropped by that extraction too, so skipping
/// it here on the version byte alone would leave it stored nowhere while its section is acked anyway.
/// Only genuine type-47 record frames whose payload would otherwise be silently dropped are returned.
///
/// Used by the Backfiller/BLEManager to archive undecodable history BEFORE acking the trim. Mirrors
/// the Android rejectedHistoricalRecords so one mapping toolchain re-ingests both archives.
///
/// EVIDENCE-PRESERVING READER (D8) — its verdict runs the OTHER WAY ROUND, and the difference is
/// load-bearing. Everywhere else a negative integrity verdict means "do not act on this frame". Here it
/// means "this frame must be archived", because the strap is about to free it and this archive is the
/// only durable copy that will exist. Turning this into "act only on a positive verdict", the way the
/// state-driving gates were turned, would delete exactly the frames it exists to keep.
///
/// So the stricter verdict makes the archived set LARGER, never smaller: every frame archived before is
/// archived still, plus the classes the envelope check now rejects (a wrong header checksum, a declared
/// length below the family minimum, a truncated frame, trailing bytes). The one way a frame can be lost
/// relative to before is upstream of here: the reassembler drops a byte run whose declared total is
/// below the family minimum, so it never reaches any parser. That drop is counted
/// (`Reassembler.belowMinimumLengthDrops`, folded into `FrameRejectTally`) precisely so it stays visible.
///
/// Accepted side effect: on a noisy link the raw archives grow. The existing eviction rule bounds that.
public func rejectedHistoricalRecords(_ rawFrames: [[UInt8]], family: DeviceFamily) -> [[UInt8]] {
    // The type byte sits at the inner-record start: frame[4] on WHOOP 4.0, frame[8] on WHOOP 5/MG
    // (the puffin envelope is 4 bytes longer). hist_version sits one byte past the type+seq+cmd
    // header — frame[5] (4.0) / frame[9] (5/MG) — same shift.
    let typeIndex = family == .whoop5 ? 8 : 4
    let versionIndex = family == .whoop5 ? 9 : 5
    return rawFrames.filter { f in
        // Only genuine HISTORICAL_DATA records (47). Console (50) and METADATA frames have a
        // different type byte, so they never pass this gate — they are excluded by construction.
        guard f.count > typeIndex, Int(f[typeIndex]) == 47 else { return false }
        // v26 PPG: skipped BECAUSE `extractHistoricalStreams` stores it durably in its own waveform
        // stream (ppgWaveform) — so the skip holds only while that premise does. A REJECTED v26 record
        // is dropped by the extraction like any other, which leaves it stored nowhere while the section
        // is acked anyway. Bind the skip to the verdict, not to the version byte alone.
        if family == .whoop5, f.count > versionIndex, Int(f[versionIndex]) == 26 {
            let p = parseFrame(f, family: family)
            return !(p.ok && p.crcOK != false)
        }
        // v16 ECG (#2847): the same clause for the same reason. An intact R16 record's 500 three-byte
        // slots are banked in `ecgWaveformSample` by `extractHistoricalStreams`, so archiving it here as
        // well would hold a second copy of a ~1.5 KB record in a 5 MiB ring whose per-version floor
        // protects 64 lines — @DX23876 measured an ECG reading evicted to that floor within a couple of
        // hours of ordinary MG traffic, which is the eviction this issue exists to stop competing with.
        // A record that fails the verdict banks no row, so it is archived like any other broken frame.
        //
        // THE HOLE THIS SHARES WITH v26, stated rather than inherited: the skip asks whether the record
        // is intact, not whether a row was actually written, and those differ for an intact record whose
        // own @15 fails the #547 plausibility gate — the extraction drops it and this skips it, so it is
        // stored nowhere. Closing it needs this filter to know the wall clock it currently has no
        // parameter for, and it would widen the archive for v26's far larger population at the same time,
        // so it belongs in a change that covers both rather than in a one-version carve-out here.
        if family == .whoop5, f.count > versionIndex, Int(f[versionIndex]) == 16 {
            // SHAPE FIRST, and this clause is tighter than v26's above for a reason found by testing it:
            // `parseR16` accepts a record of exactly `r16InnerLength` and nothing else, so a type-47
            // revision-16 frame of any other length banks no row no matter how intact it is. Keying the
            // skip on the verdict alone sent such a frame nowhere at all: a 1,484-byte one with both CRCs
            // valid was skipped here and dropped by the extraction. The archive is its only copy.
            guard Whoop5Ecg.isR16Record(f) else { return true }
            let p = parseFrame(f, family: family)
            return !(p.ok && p.crcOK != false)
        }
        // UNMAPPED LAYOUT (5/MG) — archive UNCONDITIONALLY, whatever it decoded.
        //
        // The decode-outcome test below is the wrong question for a layout NOOP has no field map for.
        // `decodeWhoop5Historical`'s unmapped branch reads no offsets, so anything that DOES appear in
        // `parsed` for such a record came from the envelope, not from a mapped biometric — and a record
        // that happened to yield a plausible `unix` plus a `gravity_x`/`heart_rate` used to pass the
        // screen and be kept NOWHERE, its bytes freed by the very next trim ack. That is exactly the
        // shape a novel record type (a new firmware's rollup, an on-demand capture) can take.
        //
        // This cannot flood the archive with records we already understand: v18/v20/v21/v26 are in
        // `mappedWhoop5HistoricalVersions` and never reach here. Retention for the records that DO
        // (`RawHistoryArchive.evictLines`) evicts entirely-zero-payload frames first, so a firmware that
        // banks empty placeholder records at 1 Hz cannot push out the one informative frame either.
        if family == .whoop5, isUnmappedWhoop5HistoricalRecord(f) { return true }
        let p = parseFrame(f, family: family)
        // NOT INTACT → ARCHIVE. Reading the verdict this way round is the whole point of this reader
        // (D8): the frame cannot be turned into rows, so its bytes are the only thing left to keep.
        // With the verdict widened to cover the header checksum and the structural length, this branch
        // catches strictly MORE frames than it did before — which is the intended direction. The
        // `crcOK` half stays for exactly that reason: every condition here can only add to the archive.
        if !p.ok || p.crcOK == false { return true }
        // Unmapped layout: the envelope parsed but no usable biometrics decoded. A record is genuinely
        // undecodable only if it has no timestamp, or NEITHER heart rate NOR motion. v25 (issue #30)
        // carries gravity but no per-second HR (PPG-derived), so a gravity-bearing record is real data
        // the sleep stager uses — keep it. Only HR-less AND gravity-less type-47 records are rejected.
        return p.parsed["unix"]?.intValue == nil
            || (p.parsed["heart_rate"]?.intValue == nil && p.parsed["gravity_x"]?.doubleValue == nil)
    }
}

/// A rejected history frame whose entire record PAYLOAD is zero — a valid header + trailing CRC wrapping
/// nothing. Such a frame carries no field layout to reverse-engineer, so the Backfiller skips its (large)
/// hex dump (#1007: a strap emitting these produced ~4 MB of all-`00` in the strap log, ~8 dumps/chunk).
/// Only the payload between the ~21-byte header and the 4-byte trailing CRC is examined; the size guard
/// keeps a runt frame from ever reading as "empty". Mirrors the Android `isEmptyRecordFrame`.
public func isEmptyRecordFrame(_ frame: [UInt8]) -> Bool {
    guard frame.count > 25 else { return false }
    return frame[21..<(frame.count - 4)].allSatisfy { $0 == 0 }
}

/// Turn historical (offload) parsed frames into datastore rows. Port of
/// interpreter.extract_historical_streams.
///
/// HR/R-R come from REALTIME_RAW_DATA (type 43) headers — the canonical stream
/// during a historical backfill, where type-40 frames are absent.
/// EVENT and COMMAND_RESPONSE handling is identical to extractStreams.
/// CRC-failed and non-ok frames are skipped.
///
/// Parse each frame and fold it into `Streams` without retaining the `[ParsedFrame]` array.
/// Byte-identical to `frames.map { parseFrame($0, family:) }` then `extractHistoricalStreams`.
public func extractHistoricalStreams(frames: [[UInt8]],
                                     deviceClockRef: Int, wallClockRef: Int,
                                     family: DeviceFamily,
                                     sessionOldestUnix: Int? = nil,
                                     sessionNewestUnix: Int? = nil,
                                     subLagInterp: Bool = false,
                                     wallNow: Int? = nil) -> Streams {
    extractHistoricalStreams(
        frames.lazy.map { parseFrame($0, family: family) },
        deviceClockRef: deviceClockRef, wallClockRef: wallClockRef,
        family: family,
        sessionOldestUnix: sessionOldestUnix,
        sessionNewestUnix: sessionNewestUnix,
        subLagInterp: subLagInterp,
        wallNow: wallNow)
}

/// Twin of Kotlin `extractHistoricalStreams`. Named here because adding `family` re-identified this
/// function for the parity inventory, which keys on arity: the pair is unchanged, only its key moved.
///
/// Generic over `Sequence` so a caller can stream `lazy.map(parseFrame)` without retaining every
/// `ParsedFrame` (a day's offload is 86,400 dictionaries). `[ParsedFrame]` still matches.
public func extractHistoricalStreams<S: Sequence>(_ parsed: S,
                                     deviceClockRef: Int, wallClockRef: Int,
                                     family: DeviceFamily? = nil,
                                     // SESSION-RELATIVE bounds (#547): the strap's own GET_DATA_RANGE
                                     // oldest/newest markers for THIS sync. nil on the replay/import/no-range
                                     // paths — the gate then falls back to the absolute-only floor (unchanged).
                                     sessionOldestUnix: Int? = nil,
                                     sessionNewestUnix: Int? = nil,
                                     // Opt-in "HR-from-PPG sub-lag interpolation" (Test Centre → Experimental
                                     // algorithms, default false): threaded into the v26 PPG-HR estimator below.
                                     // The pure package can't read prefs, so the app-layer caller (Backfiller /
                                     // archive replay) reads PuffinExperiment.ppgHrSubLagInterpEnabled and passes
                                     // it. Default false = byte-identical to today. Mirrors the Android arg.
                                     subLagInterp: Bool = false,
                                     // TEST SEAM (#547 gate's "now"): overrides the live-clock upper bound
                                     // resolved just below. nil everywhere in production — every caller keeps
                                     // the live clock and today's behaviour is byte-identical. It exists so a
                                     // fixture can pin a record whose own timestamp is in the future relative
                                     // to the machine running the test, which is the only way to cover the
                                     // post-2038 (bit-31-set) unix domain at all. Android's
                                     // `extractHistoricalStreams` already had this parameter; this is Swift
                                     // catching up, so the two oracle harnesses can drive the gate identically.
                                     wallNow wallNowOverride: Int? = nil) -> Streams where S.Element == ParsedFrame {
    // Shared ingest engine with `HistoricalStreamDecoder` — one Streams writer for the ParsedFrame
    // path and the fused raw-bytes path, so they cannot drift.
    var ingest = HistoricalIngest(
        deviceClockRef: deviceClockRef,
        wallClockRef: wallClockRef,
        family: family,
        sessionOldestUnix: sessionOldestUnix,
        sessionNewestUnix: sessionNewestUnix,
        subLagInterp: subLagInterp,
        wallNowOverride: wallNowOverride,
        frameHint: parsed.underestimatedCount)
    for r in parsed {
        ingest.ingestParsed(r)
    }
    return ingest.finish()
}

/// Reconstruct a WHOOP 5/MG v26 optical window from its stored parts. #2019.
///
/// The strap sends a 25-sample window as one absolute ADC code plus 24 deltas, so this is the only way to
/// get back the signal the strap measured: `sample[0] = baseCode`, `sample[i+1] = sample[i] + delta[i]`.
/// NOOP stores the two as they arrive rather than folding them together, because the delta blob is
/// little-endian i16 and a real code (about 378,000 on the captured fixture) does not fit in one.
///
/// nil when `baseCode` is nil, which is the honest answer for a row written before the base was read: a
/// delta series cannot be inverted without its starting point, and returning the deltas, or a window
/// built from a fabricated zero, would present a signal nobody measured.
///
/// CAVEAT: the deltas are SATURATED, clamped at the i16 bounds by the encoder, so a window containing a
/// clamped delta reconstructs only approximately. Nothing here can detect that after the fact; a delta at
/// exactly ±32,768 is the signal to distrust, and the captured fixture's largest magnitude is 1,833.
///
/// Mirror EXACTLY in Kotlin (`ppgWaveformAbsolute`).
public func ppgWaveformAbsolute(baseCode: Int?, deltas: [Int]) -> [Int]? {
    guard let baseCode else { return nil }
    var out: [Int] = [baseCode]
    out.reserveCapacity(deltas.count + 1)
    var acc = baseCode
    for d in deltas {
        acc += d
        out.append(acc)
    }
    return out
}

/// A delta at either i16 rail: the encoder clamped it, so the window reconstructs only approximately.
public func isSaturatedPpgDelta(_ delta: Int) -> Bool {
    delta == Int(Int16.min) || delta == Int(Int16.max)
}

/// The per-session v26 optical census, or nil when the session carried no v26 windows (a 4.0, or a 5/MG
/// that banked none) so a log with nothing to say stays quiet. #2019.
///
/// Three things a strap log could not previously answer, all of which decide whether the banked windows
/// are usable for the channel-mapping work this stream exists for:
///
/// - how many windows arrived at all;
/// - how many carried the absolute base. A window without one cannot be reconstructed, ever. On a
///   well-formed record the base is always readable, so `withBase` below the window count means
///   TRUNCATED records or a firmware that does not carry it at frame-abs 23, and either is worth knowing
///   rather than silently banking un-reconstructable windows;
/// - how many windows hold a SATURATED delta. Those reconstruct only approximately, and the caveat is
///   worthless without a way to see whether it ever fires.
///
/// The base range is carried because it is the DC level over the session, which is the quantity the whole
/// stream is banked for and the one that used to be discarded entirely.
///
/// Mirror EXACTLY in Kotlin (`ppgWaveformCensusLine`).
public func ppgWaveformCensusLine(windows: Int, withBase: Int, saturatedWindows: Int,
                                  baseMin: Int?, baseMax: Int?) -> String? {
    guard windows > 0 else { return nil }
    let range: String = {
        guard let baseMin, let baseMax else { return " base n/a" }
        return " base \(baseMin)..\(baseMax)"
    }()
    let note = saturatedWindows > 0 ? " (a saturated window reconstructs only approximately)" : ""
    return "Backfill: v26 optical census: \(windows) window(s), \(withBase) with a base, "
        + "\(saturatedWindows) saturated,\(range)\(note)"
}

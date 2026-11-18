import Foundation

// MARK: - DecodeFacts (Backfiller finishChunk, without [ParsedFrame])

/// Compact per-frame facts `Backfiller.finishChunk` currently reads off `ParsedFrame.parsed`.
/// One small struct per frame instead of a `[String: ParsedValue]` dictionary.
public struct HistoryFrameFact: Equatable, Sendable {
    public var typeName: String
    public var histVersion: Int?
    public var unix: Int?
    public var hasHeartRate: Bool
    public var hasGravity: Bool
    public var hasPpgWaveform: Bool
    public var spo2Red: Int?
    public var spo2Ir: Int?
    public var skinTempRaw: Int?

    public init(typeName: String, histVersion: Int? = nil, unix: Int? = nil,
                hasHeartRate: Bool = false, hasGravity: Bool = false, hasPpgWaveform: Bool = false,
                spo2Red: Int? = nil, spo2Ir: Int? = nil, skinTempRaw: Int? = nil) {
        self.typeName = typeName
        self.histVersion = histVersion
        self.unix = unix
        self.hasHeartRate = hasHeartRate
        self.hasGravity = hasGravity
        self.hasPpgWaveform = hasPpgWaveform
        self.spo2Red = spo2Red
        self.spo2Ir = spo2Ir
        self.skinTempRaw = skinTempRaw
    }
}

/// What `Backfiller.finishChunk` needs from the parsed frames today, produced in the same
/// pass as `Streams` so the chunk does not keep `[ParsedFrame]` or run `rejectedHistoricalRecords`
/// (a second parse) afterwards.
public struct DecodeFacts: Equatable, Sendable {
    public var frames: [HistoryFrameFact]
    public var rejected: [[UInt8]]

    public init(frames: [HistoryFrameFact] = [], rejected: [[UInt8]] = []) {
        self.frames = frames
        self.rejected = rejected
    }

    /// `hist_version` of the first frame that carries it — same as
    /// `parsed.lazy.compactMap { $0.parsed["hist_version"]?.intValue }.first`.
    public var firstHistVersion: Int? { frames.lazy.compactMap(\.histVersion).first }

    public var anyHeartRate: Bool { frames.contains(where: \.hasHeartRate) }
    public var anyGravity: Bool { frames.contains(where: \.hasGravity) }
    public var anyPpgWaveform: Bool { frames.contains(where: \.hasPpgWaveform) }

    /// Per-version "carries a named signal" used by the #1992 strap-log line.
    public var signalByVersion: [Int: Bool] {
        var out: [Int: Bool] = [:]
        for f in frames {
            guard let v = f.histVersion else { continue }
            let carries = f.hasHeartRate || f.hasGravity || f.hasPpgWaveform
            out[v] = (out[v] ?? false) || carries
        }
        return out
    }

    public var typeNames: [String] { frames.map(\.typeName) }
}

// MARK: - Fused historical decoder

/// Raw-bytes → `Streams` for the history-sync path, skipping the general `ParsedFrame`
/// dictionary. Integrity is the same full `verifyFrame` verdict; mapped WHOOP 5/MG historical
/// versions read fields at the offsets `decodeWhoop5Historical` uses (v18 is not in
/// `whoop_protocol.json` — those version tables are WHOOP 4.0). Any other frame falls back to
/// `parseFrame` + the shared ingest engine so output stays byte-identical.
public enum HistoricalStreamDecoder {

    /// WHOOP 5/MG type-47 versions the fused field reader covers. Every other version (and
    /// every non-type-47 frame) uses the old parse path for that frame.
    public static var fusedWhoop5Versions: Set<Int> { mappedWhoop5HistoricalVersions }

    public static func decode<S: Sequence>(
        frames: S,
        family: DeviceFamily,
        deviceClockRef: Int,
        wallClockRef: Int,
        sessionOldestUnix: Int? = nil,
        sessionNewestUnix: Int? = nil,
        subLagInterp: Bool = false,
        wallNow: Int? = nil
    ) -> (Streams, DecodeFacts) where S.Element == Data {
        decode(frames: frames.lazy.map { [UInt8]($0) },
               family: family,
               deviceClockRef: deviceClockRef,
               wallClockRef: wallClockRef,
               sessionOldestUnix: sessionOldestUnix,
               sessionNewestUnix: sessionNewestUnix,
               subLagInterp: subLagInterp,
               wallNow: wallNow)
    }

    public static func decode<S: Sequence>(
        frames: S,
        family: DeviceFamily,
        deviceClockRef: Int,
        wallClockRef: Int,
        sessionOldestUnix: Int? = nil,
        sessionNewestUnix: Int? = nil,
        subLagInterp: Bool = false,
        wallNow: Int? = nil
    ) -> (Streams, DecodeFacts) where S.Element == [UInt8] {
        var ingest = HistoricalIngest(
            deviceClockRef: deviceClockRef,
            wallClockRef: wallClockRef,
            family: family,
            sessionOldestUnix: sessionOldestUnix,
            sessionNewestUnix: sessionNewestUnix,
            subLagInterp: subLagInterp,
            wallNowOverride: wallNow,
            frameHint: frames.underestimatedCount)
        var facts = DecodeFacts()
        facts.frames.reserveCapacity(max(0, frames.underestimatedCount))
        var rejected: [[UInt8]] = []

        for frame in frames {
            let check = verifyFrame(frame, family: family)
            let typeName = frameTypeName(frame, family: family) ?? "INVALID/FRAGMENT"
            let typeIndex = family == .whoop5 ? 8 : 4
            // Same INVALID guard as parseFrame: below the family minimum, or a missing SOF, there
            // is no inner record — the type byte would sit in the checksum trailer.
            let envelopeOK = frame.first == 0xAA
                && frame.count >= FrameLimits.minimumFrameBytes(for: family)
            let isType47 = envelopeOK && frame.count > typeIndex && Int(frame[typeIndex]) == 47

            var rec: FusedHistoricalRecord?
            var parsed: ParsedFrame?

            if family == .whoop5, isType47 {
                // Version is a named inner field, bounded by the CRC trailer — same as
                // decodeWhoop5Historical. A raw peek at frame[9] on a runt envelope would
                // dispatch a layout parseFrame never does (it stores hist_version = -1).
                let payloadEnd = check.length.map { ($0 + 8) - 4 }
                let limit = fusedPayloadLimit(frame, trailerStart: payloadEnd)
                let v = fusedU8(frame, Whoop5HistOff.version, limit) ?? -1
                if fusedWhoop5Versions.contains(v) {
                    rec = fusedWhoop5Historical(frame, version: v, check: check)
                    if check.ok, check.crc32OK != false, let rec {
                        ingest.ingestHistorical(rec)
                    }
                } else {
                    // Unmapped 5/MG layout: the interpreter publishes hist_version only.
                    var unmapped = FusedHistoricalRecord()
                    unmapped.histVersion = v
                    rec = unmapped
                }
            } else if typeName == "METADATA" || typeName == "CONSOLE_LOGS" {
                // Expected unhandled — extract drops them with no census. Skip parseFrame.
            } else {
                // Fallback: EVENT / COMMAND_RESPONSE / REALTIME_* / WHOOP 4 historical / other.
                // Always parse so DecodeFacts match a ParsedFrame (type-40 REALTIME_DATA carries
                // heart_rate even though extractHistoricalStreams has no rows for it).
                let p = parseFrame(frame, family: family)
                parsed = p
                if p.ok, p.crcOK != false {
                    ingest.ingestParsed(p)
                }
                if p.typeName == "HISTORICAL_DATA" {
                    rec = FusedHistoricalRecord(parsed: p.parsed)
                }
            }

            var fact = HistoryFrameFact(typeName: parsed?.typeName ?? typeName)
            if let rec {
                fact.histVersion = rec.histVersion
                fact.unix = rec.unix
                fact.hasHeartRate = rec.heartRate != nil
                fact.hasGravity = rec.gravityX != nil
                fact.hasPpgWaveform = rec.ppgWaveform != nil
                fact.spo2Red = rec.spo2Red
                fact.spo2Ir = rec.spo2Ir
                fact.skinTempRaw = rec.skinTempRaw
            } else if let p = parsed {
                fact.histVersion = p.parsed["hist_version"]?.intValue
                fact.unix = p.parsed["unix"]?.intValue
                fact.hasHeartRate = p.parsed["heart_rate"] != nil
                fact.hasGravity = p.parsed["gravity_x"] != nil
                fact.hasPpgWaveform = p.parsed["ppg_waveform"] != nil
                fact.spo2Red = p.parsed["spo2_red"]?.intValue
                fact.spo2Ir = p.parsed["spo2_ir"]?.intValue
                fact.skinTempRaw = p.parsed["skin_temp_raw"]?.intValue
            }
            facts.frames.append(fact)

            if considerRejected(frame, family: family, check: check, rec: rec, parsed: parsed) {
                rejected.append(frame)
            }
        }

        facts.rejected = rejected
        return (ingest.finish(), facts)
    }
}

// MARK: - Shared ingest engine (extractHistoricalStreams + fused decoder)

/// Typed historical fields. The fused reader fills this from bytes; the ParsedFrame path
/// fills it from the dictionary. `HistoricalIngest.ingestHistorical` is the one Streams writer.
struct FusedHistoricalRecord {
    var histVersion: Int? = nil
    var unix: Int? = nil
    var heartRate: Int? = nil
    var rrIntervals: [Int]? = nil
    var rrSourceChannel: RRSourceChannel? = nil
    var spo2Red: Int? = nil
    var spo2Ir: Int? = nil
    var skinTempRaw: Int? = nil
    var tempAux1: Int? = nil
    var tempAux2: Int? = nil
    var stepMotionCounter: Int? = nil
    var activityClass: Int? = nil
    var sleepState: Int? = nil
    var sleepStateByte: Int? = nil
    var respRateRaw: Int? = nil
    var gravityX: Double? = nil
    var gravityY: Double? = nil
    var gravityZ: Double? = nil
    var dynAccel: Double? = nil
    var ppgWaveform: [Int]? = nil
    var burstIndex: Int? = nil
    var ppgBaseCode: Int? = nil
    var ecgRecord: [Int]? = nil
    var ecgSequence: Int? = nil
    var recordIndex: Int? = nil
    var rrCount: Int? = nil
    var cardiacFlags: Int? = nil
    var hrQualityFlags: Int? = nil
    var heartRateAlt: Int? = nil
    var rrPacked: Int? = nil
    var cardiacStatus: Int? = nil
    var stepCadence: Int? = nil
    var statusWord: Int? = nil
    var statusWord1: Int? = nil
    var statusWord2: Int? = nil
    var auxByte82: Int? = nil
    var opticalBaselineA: Int? = nil
    var opticalBaselineB: Int? = nil
    var opticalAmpA: Int? = nil
    var opticalAmpB: Int? = nil
    var unknownF32At113: Double? = nil
}

extension FusedHistoricalRecord {
    init(parsed p: [String: ParsedValue]) {
        histVersion = p["hist_version"]?.intValue
        unix = p["unix"]?.intValue
        heartRate = p["heart_rate"]?.intValue
        rrIntervals = p["rr_intervals"]?.intArrayValue
        rrSourceChannel = p["rr_source_channel"]?.intValue.flatMap(RRSourceChannel.init(rawValue:))
        spo2Red = p["spo2_red"]?.intValue
        spo2Ir = p["spo2_ir"]?.intValue
        skinTempRaw = p["skin_temp_raw"]?.intValue
        tempAux1 = p["temp_aux_1_raw"]?.intValue
        tempAux2 = p["temp_aux_2_raw"]?.intValue
        stepMotionCounter = p["step_motion_counter"]?.intValue
        activityClass = p["activity_class"]?.intValue
        sleepState = p["sleep_state"]?.intValue
        sleepStateByte = p["sleep_state_byte"]?.intValue
        respRateRaw = p["resp_rate_raw"]?.intValue
        gravityX = p["gravity_x"]?.doubleValue
        gravityY = p["gravity_y"]?.doubleValue
        gravityZ = p["gravity_z"]?.doubleValue
        dynAccel = p["dynamic_acceleration"]?.doubleValue
        ppgWaveform = p["ppg_waveform"]?.intArrayValue
        burstIndex = p["burst_index"]?.intValue
        ppgBaseCode = p["ppg_base_code"]?.intValue
        ecgRecord = p["ecg_record"]?.intArrayValue
        ecgSequence = p["ecg_sequence"]?.intValue
        recordIndex = p[V18AuxSlot.recordIndex.decoderKey]?.intValue
        rrCount = p[V18AuxSlot.rrCount.decoderKey]?.intValue
        cardiacFlags = p[V18AuxSlot.cardiacFlags.decoderKey]?.intValue
        hrQualityFlags = p[V18AuxSlot.hrQualityFlags.decoderKey]?.intValue
        heartRateAlt = p[V18AuxSlot.heartRateAlt.decoderKey]?.intValue
        rrPacked = p[V18AuxSlot.rrPacked.decoderKey]?.intValue
        cardiacStatus = p[V18AuxSlot.cardiacStatus.decoderKey]?.intValue
        stepCadence = p[V18AuxSlot.stepCadence.decoderKey]?.intValue
        statusWord = p[V18AuxSlot.statusWord.decoderKey]?.intValue
        statusWord1 = p[V18AuxSlot.statusWord1.decoderKey]?.intValue
        statusWord2 = p[V18AuxSlot.statusWord2.decoderKey]?.intValue
        auxByte82 = p[V18AuxSlot.auxByte82.decoderKey]?.intValue
        opticalBaselineA = p[V18AuxSlot.opticalBaselineA.decoderKey]?.intValue
        opticalBaselineB = p[V18AuxSlot.opticalBaselineB.decoderKey]?.intValue
        opticalAmpA = p[V18AuxSlot.opticalAmpA.decoderKey]?.intValue
        opticalAmpB = p[V18AuxSlot.opticalAmpB.decoderKey]?.intValue
        unknownF32At113 = p[V18AuxSlot.unknownF32At113.decoderKey]?.doubleValue
    }
}

struct HistoricalIngest {
    let deviceClockRef: Int
    let wallClockRef: Int
    let family: DeviceFamily?
    let sessionOldestUnix: Int?
    let sessionNewestUnix: Int?
    let subLagInterp: Bool
    let wallNow: Int
    let clockOffset: Int
    let staleThreshold: Int
    let snapGranularity: Int

    var droppedImplausible = 0
    var droppedOldest: Int?
    var droppedNewest: Int?
    var out = Streams()
    var ppgRecords: [(ts: Int, samples: [Int])] = []
    var unhandledTypes: [String: Int] = [:]

    init(deviceClockRef: Int, wallClockRef: Int, family: DeviceFamily?,
         sessionOldestUnix: Int?, sessionNewestUnix: Int?,
         subLagInterp: Bool, wallNowOverride: Int?, frameHint: Int) {
        self.deviceClockRef = deviceClockRef
        self.wallClockRef = wallClockRef
        self.family = family
        self.sessionOldestUnix = sessionOldestUnix
        self.sessionNewestUnix = sessionNewestUnix
        self.subLagInterp = subLagInterp
        self.staleThreshold = histStaleClockThresholdSec
        self.snapGranularity = 300
        self.clockOffset = wallClockRef - deviceClockRef
        self.wallNow = wallNowOverride ?? max(wallClockRef, Int(Date().timeIntervalSince1970))
        if frameHint > 0 {
            out.hr.reserveCapacity(frameHint)
            out.rr.reserveCapacity(frameHint &* 2)
            out.gravity.reserveCapacity(frameHint)
            out.steps.reserveCapacity(frameHint)
            out.skinTemp.reserveCapacity(frameHint)
            out.sleepState.reserveCapacity(frameHint)
            out.spo2.reserveCapacity(frameHint)
            out.resp.reserveCapacity(frameHint)
            out.v18Aux.reserveCapacity(frameHint)
            out.events.reserveCapacity(min(frameHint, 64))
        }
    }

    func wall(_ deviceTs: Int?) -> Int? {
        guard let d = deviceTs else { return nil }
        return wallClockRef + (d - deviceClockRef)
    }

    mutating func correctedWall(_ rawTs: Int) -> Int? {
        let candidate: Int
        if abs(clockOffset) <= staleThreshold {
            candidate = rawTs
        } else {
            let snapped = (clockOffset >= 0
                ? (clockOffset + snapGranularity / 2)
                : (clockOffset - snapGranularity / 2)) / snapGranularity * snapGranularity
            let corrected = rawTs + snapped
            candidate = corrected <= wallClockRef + snapGranularity ? corrected : rawTs
        }
        guard isPlausibleHistoricalUnix(candidate, wallNow: wallNow,
                                        sessionOldestUnix: sessionOldestUnix,
                                        sessionNewestUnix: sessionNewestUnix) else {
            droppedImplausible += 1
            droppedOldest = min(droppedOldest ?? candidate, candidate)
            droppedNewest = max(droppedNewest ?? candidate, candidate)
            return nil
        }
        return candidate
    }

    mutating func ingestParsed(_ r: ParsedFrame) {
        if !r.ok || r.crcOK == false { return }
        switch r.typeName {
        case "HISTORICAL_DATA":
            ingestHistorical(FusedHistoricalRecord(parsed: r.parsed))
        case "REALTIME_RAW_DATA":
            let p = r.parsed
            var rtTs: Int?
            if let w = wall(p["timestamp"]?.intValue) {
                if isPlausibleHistoricalUnix(w, wallNow: wallNow,
                                             sessionOldestUnix: sessionOldestUnix,
                                             sessionNewestUnix: sessionNewestUnix) { rtTs = w }
                else { droppedImplausible += 1 }
            }
            if let ts = rtTs, let bpm = p["heart_rate"]?.intValue {
                out.hr.append(HRSample(ts: ts, bpm: bpm))
            }
            if let ts = rtTs, let rrs = p["rr_intervals"]?.intArrayValue {
                for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr)) }
            }
        case "EVENT":
            let p = r.parsed
            guard let rawTs = p["event_timestamp"]?.intValue else { return }
            let kind = p["event"]?.stringValue ?? ""
            guard let ts = correctedWall(rawTs) else {
                if DroppedRtcEvent.isRtcStateKind(kind) {
                    out.droppedRtcEvents.append(DroppedRtcEvent(kind: kind, rawTs: rawTs))
                }
                return
            }
            if kind.hasPrefix("BATTERY_LEVEL") { appendBattery(&out, ts: ts, p: p) }
            var payload = p
            payload.removeValue(forKey: "event")
            payload.removeValue(forKey: "event_timestamp")
            out.events.append(WhoopEvent(ts: ts, kind: kind, payload: payload))
        case "COMMAND_RESPONSE":
            appendBattery(&out, ts: wallClockRef, p: r.parsed)
        default:
            noteUnhandled(r.typeName)
        }
    }

    mutating func noteUnhandled(_ typeName: String) {
        if !expectedUnhandledHistoricalTypes.contains(typeName) {
            unhandledTypes[typeName, default: 0] += 1
        }
    }

    mutating func ingestHistorical(_ rec: FusedHistoricalRecord) {
        guard let rawTs = rec.unix, let ts = correctedWall(rawTs) else { return }
        if let samples = rec.ppgWaveform, !samples.isEmpty {
            ppgRecords.append((ts: ts, samples: samples))
            out.ppgWaveform.append(PpgWaveformSample(ts: ts, samples: samples,
                                                     burstIndex: rec.burstIndex,
                                                     baseCode: rec.ppgBaseCode))
        }
        if let bytes = rec.ecgRecord, let seq = rec.ecgSequence,
           bytes.count == Whoop5Ecg.r16InnerLength {
            let record = bytes.compactMap { UInt8(exactly: $0) }
            if record.count == bytes.count {
                out.ecgWaveform.append(EcgWaveformSample(ts: ts, sequence: seq, record: record))
            }
        }
        if let bpm = rec.heartRate, bpm != 0 {
            out.hr.append(HRSample(ts: ts, bpm: bpm))
        }
        if let rrs = rec.rrIntervals {
            let source = rec.rrSourceChannel
                ?? (family == .whoop4 ? .whoop4Historical : nil)
            for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr, srcChannel: source)) }
        }
        if let red = rec.spo2Red {
            out.spo2.append(SpO2Sample(ts: ts, red: red, ir: rec.spo2Ir ?? 0))
        }
        if let raw = rec.skinTempRaw {
            out.skinTemp.append(SkinTempSample(ts: ts, raw: raw,
                                               aux1Raw: rec.tempAux1,
                                               aux2Raw: rec.tempAux2))
        }
        if let c = rec.stepMotionCounter {
            out.steps.append(StepSample(ts: ts, counter: c, activityClass: rec.activityClass))
        }
        if let st = rec.sleepState {
            out.sleepState.append(SleepStateSample(ts: ts, state: st,
                                                   rawByte: rec.sleepStateByte))
        }
        if let raw = rec.respRateRaw {
            out.resp.append(RespSample(ts: ts, raw: raw))
        }
        if let gx = rec.gravityX {
            out.gravity.append(GravitySample(ts: ts, x: gx,
                y: rec.gravityY ?? 0, z: rec.gravityZ ?? 0,
                dynAccel: rec.dynAccel))
        }
        if let dyn = rec.dynAccel {
            out.dynAccel.add(dyn, threshold: dynAccelStillThresholdG)
        }
        if rec.histVersion == 18 {
            let aux = V18AuxSample(
                ts: ts,
                recordIndex: rec.recordIndex,
                rrCount: rec.rrCount,
                cardiacFlags: rec.cardiacFlags,
                hrQualityFlags: rec.hrQualityFlags,
                heartRateAlt: rec.heartRateAlt,
                rrPacked: rec.rrPacked,
                cardiacStatus: rec.cardiacStatus,
                stepCadence: rec.stepCadence,
                statusWord: rec.statusWord,
                statusWord1: rec.statusWord1,
                statusWord2: rec.statusWord2,
                auxByte82: rec.auxByte82,
                opticalBaselineA: rec.opticalBaselineA,
                opticalBaselineB: rec.opticalBaselineB,
                opticalAmpA: rec.opticalAmpA,
                opticalAmpB: rec.opticalAmpB,
                unknownF32Bits: rec.unknownF32At113.map { Int(Float($0).bitPattern) })
            if !aux.isEmpty { out.v18Aux.append(aux) }
        }
    }

    mutating func finish() -> Streams {
        out.ppgHr = PpgHr.derivePpgHr(records: ppgRecords, subLagInterp: subLagInterp)
        out.unhandledPacketTypes = unhandledTypes
        out.droppedImplausible = droppedImplausible
        out.droppedImplausibleOldestTs = droppedOldest
        out.droppedImplausibleNewestTs = droppedNewest
        return out
    }
}

// MARK: - Fused WHOOP 5/MG field reader

/// Frame-absolute offsets from `decodeWhoop5Historical` / v16 / v26 in Interpreter.swift.
/// `whoop_protocol.json` HISTORICAL_DATA versions are the WHOOP 4.0 layouts (v24/v12/v5);
/// 5/MG v18 is not in that table. These names are the decoder's own offsets so a fused
/// read cannot invent a second map.
enum Whoop5HistOff {
    static let version = 9
    static let recordIndex = 11
    static let unix = 15
    static let heartRate = 22
    static let rrCount = 23
    static let rrFirst = 24
    static let cardiacFlags = 33
    static let hrQualityFlags = 36
    static let heartRateAlt = 37
    static let rrPacked = 38
    static let cardiacStatus = 40
    static let dynAccel = 41
    static let gravityX = 45
    static let gravityY = 49
    static let gravityZ = 53
    static let stepMotion = 57
    static let stepCadence = 59
    static let activityClass = 63
    static let tempAux1 = 69
    static let tempAux2 = 71
    static let skinTemp = 73
    static let statusWord = 75
    static let statusWord1 = 77
    static let statusWord2 = 79
    static let sleepStateByte = 81
    static let auxByte82 = 82
    static let opticalBaselineA = 106
    static let opticalBaselineB = 107
    static let opticalAmpA = 108
    static let opticalAmpB = 109
    static let unknownF32 = 113
    static let v26BurstIndex = 21
    static let v26BaseCode = 23
    static let v26Waveform = 27
    static let v26WaveformEnd = 75
}

private func fusedWhoop5Historical(_ frame: [UInt8], version: Int, check: FrameCheck) -> FusedHistoricalRecord {
    let declaredLength = check.length
    let payloadEnd = declaredLength.map { ($0 + 8) - 4 }
    let limit = fusedPayloadLimit(frame, trailerStart: payloadEnd)
    var rec = FusedHistoricalRecord()
    rec.histVersion = fusedU8(frame, Whoop5HistOff.version, limit) ?? -1
    switch version {
    case 18:
        fusedWhoop5V18(frame, limit: limit, into: &rec)
    case 26:
        fusedWhoop5V26(frame, limit: limit, into: &rec)
    case 16:
        fusedWhoop5V16(frame, limit: limit, into: &rec)
    case 20, 21:
        rec.recordIndex = fusedU32(frame, Whoop5HistOff.recordIndex, limit)
        rec.unix = fusedU32(frame, Whoop5HistOff.unix, limit)
    default:
        break
    }
    return rec
}

private func fusedWhoop5V18(_ frame: [UInt8], limit: Int, into rec: inout FusedHistoricalRecord) {
    rec.recordIndex = fusedU32(frame, Whoop5HistOff.recordIndex, limit)
    rec.unix = fusedU32(frame, Whoop5HistOff.unix, limit)
    rec.heartRate = fusedU8(frame, Whoop5HistOff.heartRate, limit)
    rec.rrCount = fusedU8(frame, Whoop5HistOff.rrCount, limit)
    let rrn = rec.rrCount ?? 0
    var rrs: [Int] = []
    for i in 0..<min(rrn, 4) {
        let off = Whoop5HistOff.rrFirst + i * 2
        if let v = fusedU16(frame, off, limit), v > 0 {
            rrs.append(Whoop5RR.milliseconds(ticks: UInt16(v)))
        }
    }
    rec.rrIntervals = rrs
    rec.rrSourceChannel = .whoop5Historical
    rec.cardiacFlags = fusedU8(frame, Whoop5HistOff.cardiacFlags, limit)
    rec.hrQualityFlags = fusedU8(frame, Whoop5HistOff.hrQualityFlags, limit)
    rec.heartRateAlt = fusedU8(frame, Whoop5HistOff.heartRateAlt, limit)
    rec.rrPacked = fusedU16(frame, Whoop5HistOff.rrPacked, limit)
    rec.cardiacStatus = fusedU8(frame, Whoop5HistOff.cardiacStatus, limit)
    rec.gravityX = fusedF32(frame, Whoop5HistOff.gravityX, limit)
    rec.gravityY = fusedF32(frame, Whoop5HistOff.gravityY, limit)
    rec.gravityZ = fusedF32(frame, Whoop5HistOff.gravityZ, limit)
    if let d = fusedF32(frame, Whoop5HistOff.dynAccel, limit), d.isFinite, (0...8).contains(d) {
        rec.dynAccel = d
    }
    rec.stepMotionCounter = fusedU16(frame, Whoop5HistOff.stepMotion, limit)
    rec.stepCadence = fusedU8(frame, Whoop5HistOff.stepCadence, limit)
    if let cls = fusedU8(frame, Whoop5HistOff.activityClass, limit), cls == 0 || cls == 1 || cls == 2 {
        rec.activityClass = cls
    }
    if let v = fusedI16(frame, Whoop5HistOff.tempAux1, limit), (0...60).contains(Double(v) / 10.0) {
        rec.tempAux1 = v
    }
    if let v = fusedI16(frame, Whoop5HistOff.tempAux2, limit), (0...60).contains(Double(v) / 10.0) {
        rec.tempAux2 = v
    }
    if let raw = fusedU16(frame, Whoop5HistOff.skinTemp, limit) {
        let celsius = Double(raw) / 100.0
        if (5...45).contains(celsius) {
            rec.skinTempRaw = raw
        }
    }
    rec.statusWord = fusedU16(frame, Whoop5HistOff.statusWord, limit)
    rec.statusWord1 = fusedU16(frame, Whoop5HistOff.statusWord1, limit)
    rec.statusWord2 = fusedU16(frame, Whoop5HistOff.statusWord2, limit)
    if let sb = fusedU8(frame, Whoop5HistOff.sleepStateByte, limit) {
        rec.sleepState = (sb >> 4) & 3
        rec.sleepStateByte = sb
    }
    rec.auxByte82 = fusedU8(frame, Whoop5HistOff.auxByte82, limit)
    rec.opticalBaselineA = fusedU8(frame, Whoop5HistOff.opticalBaselineA, limit)
    rec.opticalBaselineB = fusedU8(frame, Whoop5HistOff.opticalBaselineB, limit)
    rec.opticalAmpA = fusedU8(frame, Whoop5HistOff.opticalAmpA, limit)
    rec.opticalAmpB = fusedU8(frame, Whoop5HistOff.opticalAmpB, limit)
    if let d = fusedF32(frame, Whoop5HistOff.unknownF32, limit), d.isFinite {
        rec.unknownF32At113 = d
    }
}

private func fusedWhoop5V26(_ frame: [UInt8], limit: Int, into rec: inout FusedHistoricalRecord) {
    if let bi = fusedU16(frame, Whoop5HistOff.v26BurstIndex, limit), bi > 0 {
        rec.burstIndex = bi
    }
    rec.recordIndex = fusedU32(frame, Whoop5HistOff.recordIndex, limit)
    rec.unix = fusedU32(frame, Whoop5HistOff.unix, limit)
    rec.ppgBaseCode = fusedU32(frame, Whoop5HistOff.v26BaseCode, limit)
    var samples: [Int] = []
    var off = Whoop5HistOff.v26Waveform
    while off < Whoop5HistOff.v26WaveformEnd {
        guard let v = fusedI16(frame, off, limit) else { break }
        samples.append(v)
        off += 2
    }
    if !samples.isEmpty {
        rec.ppgWaveform = samples
    }
}

private func fusedWhoop5V16(_ frame: [UInt8], limit: Int, into rec: inout FusedHistoricalRecord) {
    rec.unix = fusedU32(frame, Whoop5HistOff.unix, limit)
    let base = Whoop5Ecg.rawTypeOffset
    guard Whoop5Ecg.isR16Record(frame), base + Whoop5Ecg.r16InnerLength <= frame.count else { return }
    if let p = Whoop5Ecg.r16FromFrame(frame) {
        rec.ecgRecord = frame[base..<(base + Whoop5Ecg.r16InnerLength)].map { Int($0) }
        rec.ecgSequence = Int(p.sequence)
    }
}

// MARK: - Reject classifier (same rules as rejectedHistoricalRecords, no second parse)

private func considerRejected(_ frame: [UInt8], family: DeviceFamily, check: FrameCheck,
                              rec: FusedHistoricalRecord?, parsed: ParsedFrame?) -> Bool {
    let typeIndex = family == .whoop5 ? 8 : 4
    let versionIndex = family == .whoop5 ? 9 : 5
    guard frame.count > typeIndex, Int(frame[typeIndex]) == 47 else { return false }
    let ok = parsed?.ok ?? check.ok
    let crcOK = parsed?.crcOK ?? check.crc32OK
    if family == .whoop5, frame.count > versionIndex, Int(frame[versionIndex]) == 26 {
        return !(ok && crcOK != false)
    }
    if family == .whoop5, frame.count > versionIndex, Int(frame[versionIndex]) == 16 {
        guard Whoop5Ecg.isR16Record(frame) else { return true }
        return !(ok && crcOK != false)
    }
    if family == .whoop5, isUnmappedWhoop5HistoricalRecord(frame) { return true }
    if !ok || crcOK == false { return true }
    let unix = rec?.unix ?? parsed?.parsed["unix"]?.intValue
    let hr = rec?.heartRate ?? parsed?.parsed["heart_rate"]?.intValue
    let gx = rec?.gravityX ?? parsed?.parsed["gravity_x"]?.doubleValue
    return unix == nil || (hr == nil && gx == nil)
}

// MARK: - LE readers (same bounds as Interpreter.read*)

@inline(__always)
private func fusedPayloadLimit(_ frame: [UInt8], trailerStart: Int?) -> Int {
    guard let trailerStart else { return frame.count }
    return min(max(0, trailerStart), frame.count)
}

@inline(__always)
private func fusedU8(_ f: [UInt8], _ off: Int, _ limit: Int) -> Int? {
    off >= 0 && off + 1 <= limit ? Int(f[off]) : nil
}

@inline(__always)
private func fusedU16(_ f: [UInt8], _ off: Int, _ limit: Int) -> Int? {
    off >= 0 && off + 2 <= limit ? Int(f[off]) | (Int(f[off + 1]) << 8) : nil
}

@inline(__always)
private func fusedU32(_ f: [UInt8], _ off: Int, _ limit: Int) -> Int? {
    guard off >= 0, off + 4 <= limit else { return nil }
    return Int(f[off]) | (Int(f[off + 1]) << 8) | (Int(f[off + 2]) << 16) | (Int(f[off + 3]) << 24)
}

@inline(__always)
private func fusedI16(_ f: [UInt8], _ off: Int, _ limit: Int) -> Int? {
    guard off >= 0, off + 2 <= limit else { return nil }
    let raw = UInt16(f[off]) | (UInt16(f[off + 1]) << 8)
    return Int(Int16(bitPattern: raw))
}

@inline(__always)
private func fusedF32(_ f: [UInt8], _ off: Int, _ limit: Int) -> Double? {
    guard off >= 0, off + 4 <= limit else { return nil }
    let bits = UInt32(f[off]) | (UInt32(f[off + 1]) << 8) | (UInt32(f[off + 2]) << 16) | (UInt32(f[off + 3]) << 24)
    return Double(Float(bitPattern: bits))
}

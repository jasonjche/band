import Foundation

/// Packed payloads for `derivedSeries` (WhoopStore v50).
///
/// Algorithm versions sit here, one constant per kind. Bump the kind's version when
/// its display series changes shape or math; the read path treats any other stamp
/// as a miss and recomputes. The codec version is the binary layout, independent
/// of the algorithm version stored beside the blob.
public enum DerivedSeriesCodec {

    public static let codecVersion: UInt8 = 1

    public static let stressMinuteKind = "stressMinute"
    public static let overnightHRKind = "overnightHR"
    public static let hourlyStepsKind = "hourlySteps"

    public static let stressMinuteVersion = 2
    public static let overnightHRVersion = 1
    public static let hourlyStepsVersion = 1

    public static func algorithmVersion(kind: String) -> Int {
        switch kind {
        case stressMinuteKind: return stressMinuteVersion
        case overnightHRKind: return overnightHRVersion
        case hourlyStepsKind: return hourlyStepsVersion
        default: return 0
        }
    }

    public struct Point: Equatable, Sendable {
        public var ts: Int
        public var value: Double
        public init(ts: Int, value: Double) {
            self.ts = ts
            self.value = value
        }
    }

    public struct StressPayload: Equatable, Sendable {
        public var fingerprint: String
        public var points: [Point]
        public var exclusions: [BandStress.ExclusionSpan]
        public init(fingerprint: String, points: [Point], exclusions: [BandStress.ExclusionSpan]) {
            self.fingerprint = fingerprint
            self.points = points
            self.exclusions = exclusions
        }
    }

    public struct OvernightPayload: Equatable, Sendable {
        public var fingerprint: String
        public var points: [Point]
        public var average: Double?
        public var rawCount: Int
        public init(fingerprint: String, points: [Point], average: Double?, rawCount: Int) {
            self.fingerprint = fingerprint
            self.points = points
            self.average = average
            self.rawCount = rawCount
        }
    }

    public struct HourlyStepsPayload: Equatable, Sendable {
        public var fingerprint: String
        public var dayStartTs: Int
        public var hours: [Double]
        public init(fingerprint: String, dayStartTs: Int, hours: [Double]) {
            self.fingerprint = fingerprint
            self.dayStartTs = dayStartTs
            self.hours = hours
        }
    }

    // MARK: - Encode

    public static func encodeStress(_ payload: StressPayload) -> Data {
        var data = header(fingerprint: payload.fingerprint)
        appendUInt32(&data, UInt32(payload.points.count))
        for point in payload.points {
            appendInt64(&data, Int64(point.ts))
            appendDouble(&data, point.value)
        }
        appendUInt32(&data, UInt32(payload.exclusions.count))
        for span in payload.exclusions {
            appendInt64(&data, Int64(span.startTs))
            appendInt64(&data, Int64(span.endTs))
            data.append(exclusionCode(span.kind))
        }
        return data
    }

    public static func encodeOvernight(_ payload: OvernightPayload) -> Data {
        var data = header(fingerprint: payload.fingerprint)
        appendUInt32(&data, UInt32(payload.points.count))
        for point in payload.points {
            appendInt64(&data, Int64(point.ts))
            appendDouble(&data, point.value)
        }
        appendDouble(&data, payload.average ?? .nan)
        appendUInt32(&data, UInt32(payload.rawCount))
        return data
    }

    public static func encodeHourlySteps(_ payload: HourlyStepsPayload) -> Data {
        var data = header(fingerprint: payload.fingerprint)
        appendInt64(&data, Int64(payload.dayStartTs))
        let hours = payload.hours
        for i in 0..<24 {
            appendDouble(&data, i < hours.count ? hours[i] : 0)
        }
        return data
    }

    // MARK: - Decode

    public static func decodeStress(_ data: Data) -> StressPayload? {
        var cursor = 0
        guard let fingerprint = readHeader(data, cursor: &cursor) else { return nil }
        guard let pointCount = readUInt32(data, cursor: &cursor) else { return nil }
        var points: [Point] = []
        points.reserveCapacity(Int(pointCount))
        for _ in 0..<pointCount {
            guard let ts = readInt64(data, cursor: &cursor),
                  let value = readDouble(data, cursor: &cursor) else { return nil }
            points.append(Point(ts: Int(ts), value: value))
        }
        guard let exclusionCount = readUInt32(data, cursor: &cursor) else { return nil }
        var exclusions: [BandStress.ExclusionSpan] = []
        exclusions.reserveCapacity(Int(exclusionCount))
        for _ in 0..<exclusionCount {
            guard let start = readInt64(data, cursor: &cursor),
                  let end = readInt64(data, cursor: &cursor),
                  cursor < data.count else { return nil }
            let kind = exclusionKind(data[cursor])
            cursor += 1
            guard let kind else { return nil }
            exclusions.append(BandStress.ExclusionSpan(startTs: Int(start), endTs: Int(end), kind: kind))
        }
        return StressPayload(fingerprint: fingerprint, points: points, exclusions: exclusions)
    }

    public static func decodeOvernight(_ data: Data) -> OvernightPayload? {
        var cursor = 0
        guard let fingerprint = readHeader(data, cursor: &cursor) else { return nil }
        guard let pointCount = readUInt32(data, cursor: &cursor) else { return nil }
        var points: [Point] = []
        points.reserveCapacity(Int(pointCount))
        for _ in 0..<pointCount {
            guard let ts = readInt64(data, cursor: &cursor),
                  let value = readDouble(data, cursor: &cursor) else { return nil }
            points.append(Point(ts: Int(ts), value: value))
        }
        guard let average = readDouble(data, cursor: &cursor),
              let rawCount = readUInt32(data, cursor: &cursor) else { return nil }
        return OvernightPayload(
            fingerprint: fingerprint,
            points: points,
            average: average.isNaN ? nil : average,
            rawCount: Int(rawCount)
        )
    }

    public static func decodeHourlySteps(_ data: Data) -> HourlyStepsPayload? {
        var cursor = 0
        guard let fingerprint = readHeader(data, cursor: &cursor) else { return nil }
        guard let dayStart = readInt64(data, cursor: &cursor) else { return nil }
        var hours: [Double] = []
        hours.reserveCapacity(24)
        for _ in 0..<24 {
            guard let value = readDouble(data, cursor: &cursor) else { return nil }
            hours.append(value)
        }
        return HourlyStepsPayload(fingerprint: fingerprint, dayStartTs: Int(dayStart), hours: hours)
    }

    // MARK: - Fingerprints
    // The cached series is a memo of these inputs. A read whose live inputs disagree
    // is a miss, so Home / Stress / Sleep cannot show a series built from other bounds.

    public static func stressFingerprint(
        sleepStartTs: Int?,
        sleepEndTs: Int?,
        workouts: [(start: Int, end: Int)],
        wakeRestingHR: Double,
        sleepRestingHR: Double,
        rmssd: Double?
    ) -> String {
        var parts: [String] = [
            "s=\(sleepStartTs ?? 0)",
            "e=\(sleepEndTs ?? 0)",
            "wr=\(wakeRestingHR)",
            "sr=\(sleepRestingHR)",
            "h=\(rmssd.map { String($0) } ?? "nil")",
        ]
        parts.append(contentsOf: workouts.map { "w=\($0.start)-\($0.end)" })
        return parts.joined(separator: "|")
    }

    public static func overnightFingerprint(startTs: Int, endTs: Int) -> String {
        "\(startTs)|\(endTs)"
    }

    public static func hourlyStepsFingerprint(preferApple: Bool, appleSum: Int, mergedDaily: Int?) -> String {
        "a=\(preferApple ? 1 : 0)|s=\(appleSum)|m=\(mergedDaily ?? -1)"
    }

    // MARK: - Binary

    private static func header(fingerprint: String) -> Data {
        let bytes = Array(fingerprint.utf8)
        let count = min(bytes.count, Int(UInt8.max))
        var data = Data(capacity: 2 + count)
        data.append(codecVersion)
        data.append(UInt8(count))
        data.append(contentsOf: bytes.prefix(count))
        return data
    }

    private static func readHeader(_ data: Data, cursor: inout Int) -> String? {
        guard cursor + 2 <= data.count, data[cursor] == codecVersion else { return nil }
        let count = Int(data[cursor + 1])
        cursor += 2
        guard cursor + count <= data.count else { return nil }
        let slice = data[cursor..<(cursor + count)]
        cursor += count
        return String(bytes: slice, encoding: .utf8)
    }

    private static func exclusionCode(_ kind: BandStress.ExclusionKind) -> UInt8 {
        switch kind {
        case .workout: return 0
        case .recovery: return 1
        case .activity: return 2
        }
    }

    private static func exclusionKind(_ code: UInt8) -> BandStress.ExclusionKind? {
        switch code {
        case 0: return .workout
        case 1: return .recovery
        case 2: return .activity
        default: return nil
        }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendInt64(_ data: inout Data, _ value: Int64) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendDouble(_ data: inout Data, _ value: Double) {
        var v = value.bitPattern.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, cursor: inout Int) -> UInt32? {
        guard cursor + 4 <= data.count else { return nil }
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest, from: cursor..<(cursor + 4))
        }
        cursor += 4
        return UInt32(littleEndian: value)
    }

    private static func readInt64(_ data: Data, cursor: inout Int) -> Int64? {
        guard cursor + 8 <= data.count else { return nil }
        var value: Int64 = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest, from: cursor..<(cursor + 8))
        }
        cursor += 8
        return Int64(littleEndian: value)
    }

    private static func readDouble(_ data: Data, cursor: inout Int) -> Double? {
        guard cursor + 8 <= data.count else { return nil }
        var bits: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &bits) { dest in
            data.copyBytes(to: dest, from: cursor..<(cursor + 8))
        }
        cursor += 8
        return Double(bitPattern: UInt64(littleEndian: bits))
    }
}

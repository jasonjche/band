import Foundation

/// Gregorian civil-day arithmetic in UTC, matching `Calendar(identifier: .gregorian)`
/// with `TimeZone(secondsFromGMT: 0)`. Howard Hinnant days-from-civil; no Date/Calendar
/// in the hot path that walks a night or a 450-day illness baseline.
enum CivilDay {

    static func addDays(_ ymd: String, _ delta: Int) -> String? {
        guard let (y, m, d) = parse(ymd) else { return nil }
        let (yy, mm, dd) = civil(from: days(y: y, m: m, d: d) + delta)
        return format(y: yy, m: mm, d: dd)
    }

    static func parse(_ ymd: String) -> (Int, Int, Int)? {
        let parts = ymd.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              m >= 1, m <= 12, d >= 1, d <= 31 else { return nil }
        return (y, m, d)
    }

    static func format(y: Int, m: Int, d: Int) -> String {
        String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Serial day number; 1970-01-01 is 719468 + 0 under this epoch shift? Hinnant uses
    /// days since civil 0000-03-01. We only need differences to be exact.
    static func days(y: Int, m: Int, d: Int) -> Int {
        var y = y
        y -= m <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(from z: Int) -> (Int, Int, Int) {
        let z = z + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        y += (m <= 2 ? 1 : 0)
        return (y, m, d)
    }
}

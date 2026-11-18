import Foundation
import StrandAnalytics

/// BandIllnessSignal episode rate on stored daily rows and on WHOOP-export nights.
/// Aggregates only. Informational: not a threshold gate.
struct IllnessRateReport {
    var source: String
    var nights: Int
    var spanDays: Int
    var episodes: Int
    var watchNights: Int
    var per60: Double
}

func illnessRateReports(daily: [DailyRow], whoopDays: [WhoopDay],
                        importedDevice: String, computedDevice: String) -> [IllnessRateReport] {
    var out: [IllnessRateReport] = []
    let merged = nightsFromDaily(daily, prefer: computedDevice, fallback: importedDevice)
    out.append(rateReport("sqlite_daily", merged))
    out.append(rateReport("whoop_export", nightsFromWhoop(whoopDays)))
    return out
}

func nightsFromDaily(_ daily: [DailyRow], prefer: String, fallback: String) -> [BandIllnessSignal.Night] {
    var byDay: [String: BandIllnessSignal.Night] = [:]
    for r in daily where r.deviceId == fallback || r.deviceId == prefer {
        let existing = byDay[r.day]
        let take = r.deviceId == prefer || existing == nil
        guard take else { continue }
        byDay[r.day] = BandIllnessSignal.Night(
            day: r.day,
            rhr: r.restingHr,
            hrvMs: r.avgHrv,
            respRpm: r.respRateBpm,
            skinTemp: r.skinTempC)
    }
    return byDay.values.sorted { $0.day < $1.day }
}

func nightsFromWhoop(_ days: [WhoopDay]) -> [BandIllnessSignal.Night] {
    days.map {
        BandIllnessSignal.Night(day: $0.day, rhr: $0.rhr, hrvMs: $0.hrv,
                                respRpm: $0.resp, skinTemp: $0.skinTempC)
    }.sorted { $0.day < $1.day }
}

func rateReport(_ source: String, _ nights: [BandIllnessSignal.Night]) -> IllnessRateReport {
    let eval = BandIllnessSignal.evaluate(nights: nights)
    let episodes = BandIllnessSignal.episodeCount(eval)
    let watch = eval.filter { $0.level == .watch }.count
    let span: Int
    if let first = nights.first?.day, let last = nights.last?.day,
       let a = parseYMD(first), let b = parseYMD(last) {
        span = max(1, Int(b.timeIntervalSince(a) / 86_400) + 1)
    } else {
        span = max(1, nights.count)
    }
    return IllnessRateReport(source: source, nights: nights.count, spanDays: span,
                             episodes: episodes, watchNights: watch,
                             per60: Double(episodes) / Double(span) * 60.0)
}

private func parseYMD(_ ymd: String) -> Date? {
    let parts = ymd.split(separator: "-")
    guard parts.count == 3,
          let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal.date(from: DateComponents(year: y, month: m, day: d))
}

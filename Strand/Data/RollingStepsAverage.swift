import Foundation

/// Calendar-day window, never 30 observed rows. Missing observations are not zero.
struct RollingStepsAverage: Equatable {
    let mean: Double?
    let observedDays: Int

    static func startDay(ending day: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let end = formatter.date(from: day),
              let start = calendar.date(byAdding: .day, value: -29, to: end) else { return nil }
        return formatter.string(from: start)
    }

    static func calculate(readings: [(day: String, value: Double)], ending day: String) -> Self {
        guard let start = startDay(ending: day) else { return .init(mean: nil, observedDays: 0) }
        var byDay: [String: Double] = [:]
        for reading in readings where reading.day >= start && reading.day <= day
            && reading.value.isFinite && reading.value >= 0 {
            byDay[reading.day] = reading.value
        }
        return .init(mean: byDay.isEmpty ? nil : byDay.values.reduce(0, +) / Double(byDay.count),
                     observedDays: byDay.count)
    }
}

extension Repository {
    /// Shared by the detail and rolling tile: measured strap, phone import, then strap estimate.
    func resolvedSteps(from: String, to: String) async -> MetricSeriesResolution {
        async let strap = resolvedSeries(key: "steps", source: Self.whoopSource, from: from, to: to)
        async let phone = resolvedSeries(key: "steps", source: "apple-health", from: from, to: to)
        async let estimate = resolvedSeries(key: "steps_est", source: Self.whoopSource, from: from, to: to)
        let resolutions = await [strap, phone, estimate]
        var byDay: [String: ResolvedMetricPoint] = [:]
        for resolution in resolutions {
            for point in resolution.points where byDay[point.day] == nil { byDay[point.day] = point }
        }
        return MetricSeriesResolution(requestedSource: Self.whoopSource,
                                      candidates: resolutions.flatMap(\.candidates),
                                      points: byDay.values.sorted { $0.day < $1.day })
    }
}

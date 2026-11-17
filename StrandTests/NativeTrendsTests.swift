import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

final class NativeTrendsTests: XCTestCase {

    func testEveryCatalogMetricAppearsInExactlyOneGroup() {
        let sections = NativeTrendsCatalog.sections
        let groupedKeys = sections.flatMap { $0.metrics.map(\.key) }
        let catalogKeys = Set(MetricCatalog.all.map(\.key))

        XCTAssertEqual(Set(groupedKeys), catalogKeys,
                       "every unique catalog key must appear in the Trends menu")
        XCTAssertEqual(groupedKeys.count, catalogKeys.count,
                       "a catalog key must not appear in more than one group")

        for metric in MetricCatalog.all {
            let groups = sections.filter { section in
                section.metrics.contains { $0.key == metric.key }
            }
            XCTAssertEqual(groups.count, 1,
                           "\(metric.key) must live in exactly one Trends group")
        }

        for group in NativeTrendsGroup.allCases {
            XCTAssertEqual(sections.filter { $0.group == group }.count, 1)
            XCTAssertFalse(sections.first { $0.group == group }?.metrics.isEmpty ?? true,
                           "\(group.title) must list at least one metric")
        }
    }

    func testGroupOrderMatchesWhoopTrendView() {
        XCTAssertEqual(
            NativeTrendsCatalog.sections.map(\.group),
            [.strain, .recovery, .sleep, .health, .activity]
        )
        XCTAssertEqual(NativeTrendsGroup.allCases.map(\.title),
                       ["Strain", "Recovery", "Sleep", "Health", "Activity"])
        XCTAssertEqual(
            NativeTrendsCatalog.sections.first { $0.group == .strain }?.metrics.prefix(5).map(\.key) ?? [],
            ["strain", "hr_zones13_min", "hr_zones45_min", "energy_kcal", "avg_hr"]
        )
        XCTAssertEqual(
            NativeTrendsCatalog.sections.first { $0.group == .recovery }?.metrics.prefix(4).map(\.key) ?? [],
            ["recovery", "hrv", "rhr", "resp_rate"]
        )
        XCTAssertEqual(
            NativeTrendsCatalog.sections.first { $0.group == .sleep }?.metrics.first?.key ?? "",
            "sleep_performance"
        )
        XCTAssertEqual(
            NativeTrendsCatalog.sections.first { $0.group == .activity }?.metrics.prefix(2).map(\.key) ?? [],
            ["steps", "strength_min"]
        )
        XCTAssertTrue(
            NativeTrendsCatalog.sections.first { $0.group == .health }?.metrics.contains { $0.key == "vo2max" } ?? false
        )
    }

    func testEveryTrendsRouteOpens() {
        for key in NativeTrendsCatalog.keys {
            XCTAssertEqual(NativeTrendsCatalog.route(for: key), TabRoute.metric(key))
            XCTAssertNotNil(MetricCatalog.all.first { $0.key == key },
                            "\(key) must resolve through MetricCatalog so TabRoute.metric opens a page")

            let presentation = NativeRouteResolver.presentation(for: .metric(key), nativeLayout: true)
            switch presentation {
            case .metricPage(let opened):
                XCTAssertEqual(opened, key, "\(key) must open NativeMetricPage")
            case .score(let kind):
                XCTAssertEqual(NativeRouteResolver.scoreKind(forMetricKey: key), kind,
                               "\(key) must open its score page")
            default:
                XCTFail("\(key) must open a metric or score page, got \(String(describing: presentation))")
            }
        }
    }

    func testRemembersLastPickedMetricInUserDefaults() {
        XCTAssertEqual(NativeTrendsCatalog.storageKey, "native.trends.metricKey")
        XCTAssertEqual(NativeTrendsCatalog.defaultKey, "hrv")
        XCTAssertEqual(NativeTrendsCatalog.resolvedKey(""), "hrv")
        XCTAssertEqual(NativeTrendsCatalog.resolvedKey("missing"), "hrv")
        XCTAssertEqual(NativeTrendsCatalog.resolvedKey("steps"), "steps")
        XCTAssertEqual(NativeTrendsCatalog.group(for: NativeTrendsCatalog.defaultKey), .recovery)

        let suite = "native.trends.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("steps", forKey: NativeTrendsCatalog.storageKey)
        XCTAssertEqual(defaults.string(forKey: NativeTrendsCatalog.storageKey), "steps")
        XCTAssertEqual(
            NativeTrendsCatalog.resolvedKey(defaults.string(forKey: NativeTrendsCatalog.storageKey) ?? ""),
            "steps"
        )
        defaults.set("bogus", forKey: NativeTrendsCatalog.storageKey)
        XCTAssertEqual(
            NativeTrendsCatalog.resolvedKey(defaults.string(forKey: NativeTrendsCatalog.storageKey) ?? ""),
            NativeTrendsCatalog.defaultKey
        )
        defaults.removePersistentDomain(forName: suite)

        XCTAssertTrue(NativeMetricScope.pickerCases(for: "hrv").map(\.label).contains("W"))
        XCTAssertTrue(NativeMetricScope.pickerCases(for: "hrv").map(\.label).contains("M"))
        XCTAssertTrue(NativeMetricScope.pickerCases(for: "hrv").map(\.label).contains("6M"))
    }

    func testMoreListLeadsWithTrends() {
        XCTAssertEqual(NativeMoreItem.allCases.first, .trends)
        XCTAssertEqual(NativeMoreItem.trends.title, "Trends")
        XCTAssertEqual(NativeMoreItem.trends.subtitle, "All metrics over weeks and months")
        XCTAssertEqual(NativeMoreItem.trends.icon, "chart.xyaxis.line")
        XCTAssertEqual(NativeMoreItem.allCases.filter { $0 == .trends }.count, 1)
    }

    func testHRVNightsWindowCapsAtTheSixtyDayBaseline() {
        let days = (0..<90).map { index in
            sampleDay(day: shift("2026-11-16", -89 + index), hrv: 40 + Double(index))
        }
        let nights = NativeHRVTrend.nights(from: days, ending: "2026-11-16")
        XCTAssertEqual(nights.count, 60)
        XCTAssertEqual(nights.first?.day, shift("2026-11-16", -59))
        XCTAssertEqual(nights.last?.day, "2026-11-16")
        let older = NativeHRVTrend.nights(from: days, ending: "2026-10-01")
        XCTAssertLessThanOrEqual(older.count, 60)
        XCTAssertEqual(older.last?.day, "2026-10-01")
        XCTAssertTrue(older.allSatisfy { $0.day <= "2026-10-01" })
        XCTAssertEqual(NativeHRVTrend.nights(from: days).count, 90)
    }

    func testHRVResultMatchesTheUnwindowedBaselineOnASixtyDaySeries() {
        let days = (0..<60).map { index in
            sampleDay(day: shift("2026-11-16", -59 + index), hrv: 60)
        }
        let result = NativeHRVTrend.result(days: days, dayKey: "2026-11-16")
        XCTAssertEqual(result?.state, .withinNormal)
        XCTAssertEqual(result?.trendMs ?? 0, 60, accuracy: 0.5)
        XCTAssertEqual(NativeHRVTrend.stateLabel(.trendingBelow), "Trending lower")
    }

    private func sampleDay(day: String, hrv: Double?) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 52, avgHrv: hrv, recovery: nil, strain: nil,
            exerciseCount: nil
        )
    }

    private func shift(_ key: String, _ days: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = formatter.date(from: key)!
        return formatter.string(from: calendar.date(byAdding: .day, value: days, to: date)!)
    }
}

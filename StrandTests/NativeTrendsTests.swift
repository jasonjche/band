import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

final class NativeTrendsTests: XCTestCase {

    func testEveryTrendsMetricAppearsInExactlyOneWhoopGroup() {
        let sections = NativeTrendsCatalog.sections
        let groupedKeys = sections.flatMap { $0.metrics.map(\.key) }
        XCTAssertEqual(groupedKeys.count, Set(groupedKeys).count,
                       "a Trends key must not appear in more than one group")
        for key in groupedKeys {
            XCTAssertNotNil(MetricCatalog.all.first { $0.key == key },
                            "\(key) must be a MetricCatalog entry")
            XCTAssertEqual(
                sections.filter { $0.metrics.contains { $0.key == key } }.count, 1,
                "\(key) must live in exactly one Trends group"
            )
        }
        XCTAssertEqual(Set(groupedKeys), Set(NativeTrendsCatalog.orderedKeys.flatMap(\.keys)))
        for group in NativeTrendsGroup.allCases {
            XCTAssertEqual(sections.filter { $0.group == group }.count, 1)
            XCTAssertFalse(sections.first { $0.group == group }?.metrics.isEmpty ?? true,
                           "\(group.title) must list at least one metric")
        }
    }

    func testGroupOrderMatchesWhoopTrendView() {
        XCTAssertEqual(
            NativeTrendsCatalog.sections.map(\.group),
            [.healthspan, .other, .sleep, .strain, .recovery]
        )
        XCTAssertEqual(NativeTrendsGroup.allCases.map(\.title),
                       ["Healthspan", "Other", "Sleep", "Strain", "Recovery"])
        XCTAssertEqual(
            NativeTrendsCatalog.sections.first { $0.group == .healthspan }?.metrics.map(\.key) ?? [],
            ["band_age", "pace_of_aging"]
        )
        XCTAssertEqual(
            NativeTrendsCatalog.sections.first { $0.group == .other }?.metrics.map(\.key) ?? [],
            ["lean_mass", "weight", "stress"]
        )
        XCTAssertEqual(
            NativeTrendsCatalog.sections.first { $0.group == .sleep }?.metrics.map(\.key) ?? [],
            [
                "sleep_performance", "in_bed_min", "hours_vs_needed_hours", "hours_vs_needed_pct",
                "sleep_consistency", "restorative_pct", "restorative_min", "sleep_efficiency",
                "sleep_debt_min",
            ]
        )
        XCTAssertEqual(
            NativeTrendsCatalog.sections.first { $0.group == .strain }?.metrics.map(\.key) ?? [],
            [
                "strain", "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min",
                "strength_min", "avg_hr", "energy_kcal", "vo2max",
            ]
        )
        XCTAssertEqual(
            NativeTrendsCatalog.sections.first { $0.group == .recovery }?.metrics.map(\.key) ?? [],
            ["recovery", "hrv", "rhr", "resp_rate"]
        )
        XCTAssertEqual(NativeTrendsCatalog.title(for: "band_age"), "Band Age")
        XCTAssertEqual(NativeTrendsCatalog.title(for: "stress"), "Total Day Stress")
        XCTAssertEqual(NativeTrendsCatalog.title(for: "hours_vs_needed_pct"), "Hours vs. Needed (%)")
        XCTAssertEqual(NativeTrendsCatalog.title(for: "hours_vs_needed_hours"), "Hours vs. Needed (Hours)")
        XCTAssertEqual(NativeTrendsCatalog.title(for: "restorative_min"), "Restorative Sleep (Hours)")
        XCTAssertEqual(NativeTrendsCatalog.title(for: "hrv"), "Heart Rate Variability")
        XCTAssertEqual(NativeTrendsCatalog.title(for: "hr_zones_all_min"), "Heart Rate Zones All")
        XCTAssertTrue(NativeTrendsCatalog.opensHealthspan("band_age"))
        XCTAssertTrue(NativeTrendsCatalog.opensHealthspan("pace_of_aging"))
        XCTAssertFalse(NativeTrendsCatalog.opensHealthspan("hrv"))
    }

    func testEveryTrendsRouteOpens() {
        for key in NativeTrendsCatalog.keys {
            XCTAssertEqual(NativeTrendsCatalog.route(for: key), TabRoute.metric(key))
            XCTAssertNotNil(MetricCatalog.all.first { $0.key == key },
                            "\(key) must resolve through MetricCatalog so TabRoute.metric opens a page")
            if NativeTrendsCatalog.opensHealthspan(key) { continue }

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

    func testCatalogCategoryIdsStayEffortChargeRest() {
        XCTAssertEqual(
            MetricCatalog.categories,
            ["Heart", "Charge", "Rest", "Effort", "Health", "Nutrition", "Mind"]
        )
        XCTAssertEqual(MetricCatalog.all.first { $0.key == "recovery" }?.category, "Charge")
        XCTAssertEqual(MetricCatalog.all.first { $0.key == "strain" }?.category, "Effort")
        XCTAssertEqual(MetricCatalog.all.first { $0.key == "sleep_performance" }?.category, "Rest")
        XCTAssertEqual(MetricCatalog.all.first { $0.key == "band_age" }?.category, "Health")
        XCTAssertEqual(MetricCatalog.all.first { $0.key == "hours_vs_needed_hours" }?.category, "Rest")
    }

    func testHealthTabIncludesTrends() {
        XCTAssertFalse(NativeMoreItem.titles.contains("Trends"))
        XCTAssertEqual(NativeHealthItem.trends.title, "Trends")
        XCTAssertEqual(NativeHealthItem.trends.subtitle, "All metrics over weeks and months")
        XCTAssertEqual(NativeHealthItem.trends.icon, "chart.xyaxis.line")
        XCTAssertEqual(NativeHealthItem.allCases.filter { $0 == .trends }.count, 1)
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

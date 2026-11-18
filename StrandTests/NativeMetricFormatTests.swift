import XCTest
@testable import Strand

final class NativeMetricFormatTests: XCTestCase {

    func testDurationMinutesKeys() {
        let keys = [
            "sleep_total_min", "asleep_min", "in_bed_min",
            "sleep_deep_min", "deep_min", "sleep_rem_min", "rem_min",
            "sleep_light_min", "core_min", "sleep_awake_min", "awake_min",
            "sleep_need_min", "sleep_debt_min", "restorative_min",
            "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min",
            "strength_min", "intensity_min",
        ]
        for key in keys {
            XCTAssertTrue(NativeMetricFormat.isDurationMinutes(key: key), key)
            XCTAssertTrue(NativeMetricFormat.usesClockHero(key: key), key)
            XCTAssertNil(unit(key), "\(key) must hide min so the hero can read 8:00 / 8 hr 0 min")
        }
        XCTAssertFalse(NativeMetricFormat.isDurationMinutes(key: "hours_vs_needed_hours"))
        XCTAssertFalse(NativeMetricFormat.usesClockHero(key: "hrv"))
    }

    func testAsleepTimeIsClockNotRawMinutes() {
        XCTAssertEqual(format("sleep_total_min", 480), "8:00")
        XCTAssertEqual(rendered("sleep_total_min", 480), "8:00")
        XCTAssertEqual(format("in_bed_min", 480), "8:00")
        XCTAssertEqual(format("sleep_need_min", 480), "8:00")
        XCTAssertEqual(format("sleep_debt_min", 90), "1:30")
        XCTAssertEqual(format("sleep_deep_min", 95), "1:35")
        XCTAssertEqual(format("hr_zones13_min", 45), "0:45")
        XCTAssertEqual(format("strength_min", 40), "0:40")
        XCTAssertEqual(format("intensity_min", 32), "0:32")
    }

    func testRestorativeStaysMinutesNotDecimalHours() {
        XCTAssertEqual(display("restorative_min", 198) ?? -1, 198, accuracy: 1e-9)
        XCTAssertEqual(format("restorative_min", 198), "3:18")
        XCTAssertEqual(rendered("restorative_min", 198), "3:18")
        XCTAssertFalse(rendered("restorative_min", 198).contains("hr"))
    }

    func testHoursVsNeededIsSignedClock() {
        XCTAssertEqual(format("hours_vs_needed_hours", -0.6), "−0:36")
        XCTAssertEqual(format("hours_vs_needed_hours", 0.7), "+0:42")
        XCTAssertEqual(format("hours_vs_needed_hours", 34.0 / 60.0), "+0:34")
        XCTAssertNil(unit("hours_vs_needed_hours"))
        XCTAssertEqual(rendered("hours_vs_needed_hours", -0.6), "−0:36")
        XCTAssertFalse(rendered("hours_vs_needed_hours", -0.6).contains("hr"))
    }

    func testStrainNeverPrintsPerHundredOnWhoopScale() {
        let stored = 12.4 / UnitFormatter.effortScaleFactor
        let shown = display("strain", stored, scale: .whoop) ?? -1
        XCTAssertEqual(shown, 12.4, accuracy: 1e-9)
        XCTAssertEqual(NativeMetricFormat.format(value: shown, key: "strain", scale: .whoop), "12.4")
        XCTAssertNil(unit("strain", scale: .whoop, metricUnit: "/100"))
        XCTAssertEqual(rendered("strain", stored, scale: .whoop, metricUnit: "/100"), "12.4")
        XCTAssertFalse(rendered("strain", stored, scale: .whoop, metricUnit: "/100").contains("/100"))

        let hundred = display("strain", 59, scale: .hundred) ?? -1
        XCTAssertEqual(hundred, 59, accuracy: 1e-9)
        XCTAssertEqual(NativeMetricFormat.format(value: hundred, key: "strain", scale: .hundred), "59")
        XCTAssertNil(unit("strain", scale: .hundred, metricUnit: "/100"))
    }

    func testWeightAndLeanMassFollowBodySystem() {
        XCTAssertEqual(display("weight", 76.4, system: .metric) ?? -1, 76.4, accuracy: 1e-9)
        XCTAssertEqual(rendered("weight", 76.4, system: .metric), "76.4 kg")
        let pounds = display("weight", 76.4, system: .imperial) ?? -1
        XCTAssertEqual(pounds, UnitFormatter.kgToPounds(76.4), accuracy: 1e-9)
        XCTAssertEqual(rendered("weight", 76.4, system: .imperial), "168.4 lb")
        XCTAssertEqual(rendered("lean_mass", 76.4, system: .imperial), "168.4 lb")
        XCTAssertFalse(rendered("weight", 76.4, system: .imperial).contains("kg"))
        XCTAssertEqual(unit("weight", system: .imperial), "lb")
        XCTAssertEqual(unit("lean_mass", system: .metric), "kg")
    }

    func testSkinTempKeepsOneDecimalAndConverts() {
        XCTAssertEqual(rendered("skin_temp", 33.4, temperature: .celsius), "33.4 °C")
        XCTAssertEqual(rendered("skin_temp", 33.4, temperature: .fahrenheit), "92.1 °F")
        XCTAssertFalse(rendered("skin_temp", 33.4, temperature: .celsius).contains("33 °C"))
        XCTAssertEqual(format("skin_temp", 33), "33.0")
    }

    func testOneDecimalAndPercentMetrics() {
        XCTAssertEqual(rendered("body_fat", 14.8), "14.8 %")
        XCTAssertEqual(rendered("body_fat", 0.148), "14.8 %")
        XCTAssertEqual(rendered("bmi", 22.4), "22.4")
        XCTAssertNil(unit("bmi"))
        XCTAssertEqual(rendered("band_age", 24.6), "24.6 yrs")
        XCTAssertEqual(rendered("fitness_age", 31), "31 yrs")
        XCTAssertEqual(rendered("body_age", 28), "28 yrs")
        XCTAssertEqual(rendered("pace_of_aging", 0.92), "0.92x")
        XCTAssertEqual(rendered("pace_of_aging", 1.1), "1.10x")
        XCTAssertNil(unit("pace_of_aging"))
        XCTAssertEqual(rendered("stress", 0.8), "0.8")
        XCTAssertNil(unit("stress"))
        XCTAssertEqual(unit("stress", source: "xiaomi-band"), "/100")
        XCTAssertEqual(rendered("mood", 4), "4 /5")
        XCTAssertEqual(rendered("mood", 3.5), "3.5 /5")
    }

    func testIntegerPercentHeartAndCounts() {
        XCTAssertEqual(rendered("recovery", 89), "89 %")
        XCTAssertEqual(rendered("sleep_performance", 0.91), "91 %")
        XCTAssertEqual(rendered("sleep_efficiency", 0.91), "91 %")
        XCTAssertEqual(rendered("sleep_consistency", 74), "74 %")
        XCTAssertEqual(rendered("hours_vs_needed_pct", 96), "96 %")
        XCTAssertEqual(rendered("restorative_pct", 41), "41 %")
        XCTAssertEqual(rendered("spo2", 97), "97 %")
        XCTAssertEqual(rendered("sleep_score", 85), "85 %")
        XCTAssertEqual(rendered("hrv", 62), "62 ms")
        XCTAssertEqual(rendered("rhr", 54), "54 BPM")
        XCTAssertEqual(rendered("resting_hr", 54), "54 BPM")
        XCTAssertEqual(rendered("avg_hr", 71), "71 BPM")
        XCTAssertEqual(rendered("max_hr", 182), "182 BPM")
        XCTAssertEqual(rendered("resp_rate", 14.2), "14.2 breaths/min")
        XCTAssertEqual(rendered("vo2max", 52.3), "52.3 ml/kg·min")
        XCTAssertEqual(rendered("vo2max_est", 48.1), "48.1 ml/kg·min")
        XCTAssertEqual(rendered("steps", 8_420), "8,420 steps")
        XCTAssertEqual(rendered("steps_est", 8_420), "8,420 steps")
        XCTAssertEqual(rendered("energy_kcal", 1_772), "1,772 cal")
        XCTAssertEqual(rendered("active_kcal", 1_772), "1,772 cal")
        XCTAssertEqual(rendered("calories_in", 2_100), "2,100 cal")
        XCTAssertEqual(rendered("protein_g", 120), "120 g")
        XCTAssertEqual(rendered("carbs_g", 210), "210 g")
        XCTAssertEqual(rendered("fat_g", 62), "62 g")
    }

    func testDurationAxisUsesHourMinuteTicks() {
        XCTAssertEqual(NativeMetricFormat.durationCeiling(maxMinutes: 480), 540, accuracy: 1e-9)
        XCTAssertEqual(NativeMetricFormat.durationAxisTicks(maxMinutes: 480), [0, 180, 360, 540])
        XCTAssertEqual(
            NativeMetricFormat.durationAxisTicks(maxMinutes: 480).map { NativeScoreMath.duration($0) },
            ["0:00", "3:00", "6:00", "9:00"]
        )
        XCTAssertEqual(NativeMetricFormat.durationAxisTicks(maxMinutes: 90), [0, 30, 60, 90])
        XCTAssertEqual(
            NativeMetricFormat.durationAxisTicks(maxMinutes: 90).map { NativeScoreMath.duration($0) },
            ["0:00", "0:30", "1:00", "1:30"]
        )
        XCTAssertEqual(NativeMetricFormat.durationAxisTicks(maxMinutes: 40), [0, 15, 30, 45])
        let sleepLabels = NativeMetricFormat.durationAxisTicks(maxMinutes: 480).map {
            NativeMetricFormat.format(value: $0, key: "sleep_total_min", scale: .whoop)
        }
        XCTAssertFalse(sleepLabels.contains("250"))
        XCTAssertFalse(sleepLabels.contains("500"))
        XCTAssertFalse(sleepLabels.contains(NativeCountFormat.compact(250)))
        XCTAssertFalse(sleepLabels.contains(NativeCountFormat.compact(500)))
        XCTAssertEqual(NativeCountFormat.compact(5_000), "5k")
        XCTAssertEqual(NativeCountFormat.compact(10_000), "10k")
    }

    func testEveryCatalogAndTrendsKeyAvoidsBrokenRenders() {
        var keys = Set(MetricCatalog.all.map(\.key))
        keys.formUnion(NativeTrendsCatalog.keys)
        XCTAssertTrue(keys.contains("sleep_total_min"))
        XCTAssertTrue(keys.contains("strain"))
        XCTAssertTrue(keys.contains("weight"))
        XCTAssertTrue(keys.contains("skin_temp"))

        for metric in MetricCatalog.all {
            let whoop = rendered(
                metric.key, 480, scale: .whoop, metricUnit: metric.unit, source: metric.source
            )
            XCTAssertFalse(whoop.contains("480 min"), "\(metric.id) rendered \(whoop)")
            XCTAssertFalse(whoop.contains("12.4 /100"), "\(metric.id) rendered \(whoop)")
            if NativeMetricFormat.isDurationMinutes(key: metric.key) {
                XCTAssertEqual(whoop, "8:00", metric.id)
                XCTAssertFalse(whoop.contains("min"), metric.id)
            }

            let imperial = rendered(
                metric.key, 76.4, scale: .whoop, system: .imperial,
                temperature: .fahrenheit, metricUnit: metric.unit, source: metric.source
            )
            if metric.key == "weight" || metric.key == "lean_mass" {
                XCTAssertTrue(imperial.hasSuffix(" lb"), "\(metric.id) rendered \(imperial)")
                XCTAssertFalse(imperial.contains("kg"), "\(metric.id) rendered \(imperial)")
            }

            let skin = rendered(
                metric.key, 33.4, temperature: .celsius,
                metricUnit: metric.unit, source: metric.source
            )
            XCTAssertFalse(skin.contains("33 °C"), "\(metric.id) rendered \(skin)")
        }

        for key in NativeTrendsCatalog.keys {
            let whoop = rendered(key, 480)
            XCTAssertFalse(whoop.contains("480 min"), "\(key) rendered \(whoop)")
            XCTAssertFalse(whoop.contains("/100"), "\(key) rendered \(whoop)")
        }
    }

    private func display(
        _ key: String, _ raw: Double,
        scale: EffortScale = .whoop,
        system: UnitSystem = .metric,
        temperature: TemperatureUnit = .celsius
    ) -> Double? {
        NativeMetricFormat.displayValue(
            raw: raw, key: key, scale: scale, unitSystem: system, temperatureUnit: temperature
        )
    }

    private func format(_ key: String, _ value: Double, scale: EffortScale = .whoop) -> String {
        NativeMetricFormat.format(value: value, key: key, scale: scale)
    }

    private func unit(
        _ key: String,
        scale: EffortScale = .whoop,
        system: UnitSystem = .metric,
        temperature: TemperatureUnit = .celsius,
        metricUnit: String? = nil,
        source: String? = nil
    ) -> String? {
        NativeMetricFormat.unit(
            for: key, scale: scale, unitSystem: system, temperatureUnit: temperature,
            metricUnit: metricUnit, source: source
        )
    }

    private func rendered(
        _ key: String, _ raw: Double,
        scale: EffortScale = .whoop,
        system: UnitSystem = .metric,
        temperature: TemperatureUnit = .celsius,
        metricUnit: String? = nil,
        source: String? = nil
    ) -> String {
        let shown = display(key, raw, scale: scale, system: system, temperature: temperature) ?? raw
        let text = NativeMetricFormat.format(value: shown, key: key, scale: scale)
        if let unit = unit(
            key, scale: scale, system: system, temperature: temperature,
            metricUnit: metricUnit, source: source
        ), !unit.isEmpty {
            return "\(text) \(unit)"
        }
        return text
    }
}

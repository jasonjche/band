import SwiftUI
import WhoopStore
import StrandDesign

/// Body weight from Apple Health weigh-ins. The profile follows the latest reading, so
/// calorie maths tracks a changing weight without a manual edit.
enum NativeWeight {
    struct Reading: Identifiable, Equatable {
        let day: String
        let kg: Double
        var id: String { day }
        var date: Date { NativeWeight.dayParser.date(from: day) ?? Date() }
    }

    static let lastAppliedDayKey = "native.weight.lastAppliedDay"

    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func readings(_ rows: [AppleDaily]) -> [Reading] {
        rows.compactMap { row in
            guard let kg = row.weightKg, kg >= 30, kg <= 250 else { return nil }
            return Reading(day: row.day, kg: kg)
        }
        .sorted { $0.day < $1.day }
    }

    /// The weight to write into the profile, or nil when the latest reading was already applied.
    /// A reading is applied once, so a manual edit made afterwards holds until a newer weigh-in.
    static func weightToApply(readings: [Reading], lastAppliedDay: String?) -> Reading? {
        guard let latest = readings.last else { return nil }
        if let last = lastAppliedDay, latest.day <= last { return nil }
        return latest
    }

    @MainActor
    static func sync(repo: Repository, profile: ProfileStore,
                     defaults: UserDefaults = .standard) async -> [Reading] {
        let all = readings(await repo.appleDailyRows())
        if let r = weightToApply(readings: all,
                                 lastAppliedDay: defaults.string(forKey: lastAppliedDayKey)) {
            profile.weightKg = r.kg
            defaults.set(r.day, forKey: lastAppliedDayKey)
        }
        return all
    }
}

struct NativeWeightPage: View {
    let readings: [NativeWeight.Reading]
    let unitSystem: UnitSystem
    @State private var scope: NativeMetricScope = .week

    private func value(_ kg: Double) -> Double {
        unitSystem == .imperial ? UnitFormatter.kgToPounds(kg) : kg
    }

    private var unit: String { unitSystem == .imperial ? "lb" : "kg" }

    private var points: [NativeDayPoint] {
        readings.map { NativeDayPoint(key: $0.day, value: value($0.kg)) }
    }

    private var series: NativeScopeSeries {
        let ending = readings.last?.date ?? Date()
        return NativeScopeSeries.make(
            points: points,
            scope: scope,
            kind: .rate,
            now: ending,
            ending: ending
        )
    }

    var body: some View {
        NativeMetricChartPage(
            title: "Weight",
            scope: scope,
            onScope: { new in
                if NativeMetricScope.pickerCases(for: "weight").contains(new) { scope = new }
            },
            series: series,
            bars: false,
            tint: NativeTokens.activity,
            format: { String(format: "%.1f", $0) },
            unit: unit,
            latest: points.last,
            sourceCaption: "From Apple Health",
            scopes: NativeMetricScope.pickerCases(for: "weight")
        )
    }
}

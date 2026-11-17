import SwiftUI
import Charts
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

    private func value(_ kg: Double) -> Double {
        unitSystem == .imperial ? UnitFormatter.kgToPounds(kg) : kg
    }

    private var unit: String { unitSystem == .imperial ? "lb" : "kg" }

    private func label(_ kg: Double) -> String {
        String(format: "%.1f %@", value(kg), unit)
    }

    var body: some View {
        List {
            if let latest = readings.last {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label(latest.kg))
                            .font(.largeTitle.weight(.semibold))
                            .monospacedDigit()
                        Text("Apple Health · \(latest.date.formatted(.dateTime.month().day().year()))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if readings.count > 1 {
                        Chart(readings) { r in
                            LineMark(x: .value("Date", r.date), y: .value("Weight", value(r.kg)))
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("Date", r.date), y: .value("Weight", value(r.kg)))
                                .symbolSize(24)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 180)
                        .padding(.vertical, 8)
                    }
                }
            }
            Section("History") {
                ForEach(readings.reversed()) { r in
                    LabeledContent(r.date.formatted(.dateTime.month().day().year()),
                                   value: label(r.kg))
                }
            }
        }
        .navigationTitle("Weight")
        .navigationBarTitleDisplayModeInlineIfAvailable()
    }
}

private extension View {
    @ViewBuilder func navigationBarTitleDisplayModeInlineIfAvailable() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

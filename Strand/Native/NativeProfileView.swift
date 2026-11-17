import SwiftUI

/// iPhone Profile: iOS Settings Form. Same ProfileStore fields the personal shell already edits.
struct NativeProfileView: View {
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var repo: Repository
    @State private var weightReadings: [NativeWeight.Reading] = []
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    var body: some View {
        Form {
            Section {
                DatePicker(
                    "Birthday",
                    selection: $profile.dateOfBirth,
                    in: ProfileStore.dateOfBirthRange,
                    displayedComponents: .date
                )
                LabeledContent("Age", value: "\(profile.age)")
                Picker("Sex", selection: $profile.sex) {
                    Text("Male").tag("male")
                    Text("Female").tag("female")
                    Text("Non-binary").tag("nonbinary")
                }
            }

            Section {
                heightRow
                weightRow
            } footer: {
                if let latest = weightReadings.last {
                    Text("Weight follows Apple Health. Last weigh-in \(latest.date.formatted(.dateTime.month().day())).")
                }
            }

            Section {
                Stepper(value: $profile.hrMaxOverride, in: 0...230, step: 1) {
                    LabeledContent("Max Heart Rate", value: hrMaxLabel)
                }
                Toggle("Custom HR Zones", isOn: Binding(
                    get: { profile.hasCustomHRZones },
                    set: { profile.setCustomHRZonesEnabled($0) }
                ))
                if profile.hasCustomHRZones {
                    ForEach(profile.hrZoneThresholds.indices, id: \.self) { index in
                        Stepper(
                            onIncrement: { profile.stepHRZoneThreshold(at: index, up: true) },
                            onDecrement: { profile.stepHRZoneThreshold(at: index, up: false) }
                        ) {
                            LabeledContent(
                                "Zone \(index + 1) Starts",
                                value: "\(zoneStart(index)) bpm"
                            )
                        }
                    }
                }
            } footer: {
                Text(hrMaxFooter)
            }
        }
        .appleSettingsChrome("Profile")
        .task {
            weightReadings = await NativeWeight.sync(repo: repo, profile: profile)
            await profile.syncObservedHRMax(from: repo)
        }
    }

    private var hrMaxLabel: String {
        profile.hrMaxOverride > 0 ? "\(profile.hrMaxOverride) bpm" : "Auto · \(profile.hrMax) bpm"
    }

    private var hrMaxFooter: String {
        var text = "Max heart rate drives HR zones."
        if profile.hrMaxOverride > 0 { return text }
        if profile.hrMaxSource == "observed" {
            text += " From your highest recorded workouts."
        } else {
            text += " Estimated from age."
        }
        return text
    }

    private func zoneStart(_ index: Int) -> Int {
        profile.hrZoneThresholds.indices.contains(index) ? profile.hrZoneThresholds[index] : 0
    }

    @ViewBuilder private var heightRow: some View {
        if unitSystem == .imperial {
            Stepper(value: heightInches, in: 47...91, step: 1) {
                LabeledContent("Height", value: imperialHeightLabel)
            }
        } else {
            Stepper(value: $profile.heightCm, in: 120...230, step: 1) {
                LabeledContent("Height", value: "\(Int(profile.heightCm.rounded())) cm")
            }
        }
    }

    @ViewBuilder private var weightRow: some View {
        if weightReadings.isEmpty {
            manualWeightRow
        } else {
            NavigationLink {
                NativeWeightPage(readings: weightReadings, unitSystem: unitSystem)
            } label: {
                LabeledContent("Weight", value: unitSystem == .imperial
                    ? "\(Int(weightPounds.wrappedValue.rounded())) lb"
                    : String(format: "%.1f kg", profile.weightKg))
            }
        }
    }

    @ViewBuilder private var manualWeightRow: some View {
        if unitSystem == .imperial {
            Stepper(value: weightPounds, in: 66...551, step: 1) {
                LabeledContent("Weight", value: "\(Int(weightPounds.wrappedValue.rounded())) lb")
            }
        } else {
            Stepper(value: $profile.weightKg, in: 30...250, step: 0.5) {
                LabeledContent("Weight", value: String(format: "%.1f kg", profile.weightKg))
            }
        }
    }

    private var heightInches: Binding<Double> {
        Binding(
            get: { UnitFormatter.cmToInches(profile.heightCm).rounded() },
            set: { profile.heightCm = $0 * UnitFormatter.centimetersPerInch }
        )
    }

    private var weightPounds: Binding<Double> {
        Binding(
            get: { UnitFormatter.kgToPounds(profile.weightKg) },
            set: { profile.weightKg = $0 / UnitFormatter.poundsPerKilogram }
        )
    }

    private var imperialHeightLabel: String {
        let parts = UnitFormatter.cmToFeetInches(profile.heightCm)
        return "\(parts.feet)′ \(parts.inches)″"
    }
}

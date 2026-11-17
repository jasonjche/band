import SwiftUI

/// iPhone Profile: iOS Settings Form. Same ProfileStore fields the personal shell already edits.
struct NativeProfileView: View {
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var repo: Repository
    @State private var weightReadings: [NativeWeight.Reading] = []
    @State private var showStepsCalibration = false
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
                waistRow
            } footer: {
                if let latest = weightReadings.last {
                    Text("Weight follows Apple Health. Last weigh-in \(latest.date.formatted(.dateTime.month().day())). Optional waist makes VO₂max more accurate.")
                } else {
                    Text("Optional waist makes VO₂max more accurate. Measure around your middle, at the navel.")
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

            Section {
                Stepper(
                    onIncrement: {
                        profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up: true)
                    },
                    onDecrement: {
                        profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up: false)
                    }
                ) {
                    LabeledContent("Step Calibration", value: String(format: "%.1f", profile.stepTicksPerStep))
                }
                Button("Steps Estimate") { showStepsCalibration = true }
            } header: {
                Text("Steps")
            } footer: {
                Text("Counter ticks per step, and the WHOOP 4.0 motion estimate. Leave calibration at 1.0 unless steps run high.")
            }
        }
        .appleSettingsChrome("Profile")
        .sheet(isPresented: $showStepsCalibration) {
            StepsCalibrationSheet(repo: repo, onClose: { showStepsCalibration = false })
                .environmentObject(profile)
        }
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

    @ViewBuilder private var waistRow: some View {
        if unitSystem == .imperial {
            Stepper(
                onIncrement: {
                    let inches = profile.waistCm > 0 ? UnitFormatter.cmToInches(profile.waistCm).rounded() : 30
                    profile.waistCm = min(160, (inches + 1) * UnitFormatter.centimetersPerInch)
                },
                onDecrement: {
                    let inches = UnitFormatter.cmToInches(profile.waistCm).rounded() - 1
                    profile.waistCm = inches < 24 ? 0 : inches * UnitFormatter.centimetersPerInch
                }
            ) {
                LabeledContent("Waist", value: waistImperialLabel)
            }
        } else {
            Stepper(
                onIncrement: {
                    profile.waistCm = min(160, (profile.waistCm > 0 ? profile.waistCm : 79) + 1)
                },
                onDecrement: {
                    let next = profile.waistCm - 1
                    profile.waistCm = next < 60 ? 0 : next
                }
            ) {
                LabeledContent("Waist", value: profile.waistCm > 0
                    ? "\(Int(profile.waistCm.rounded())) cm"
                    : "Not set")
            }
        }
    }

    private var waistImperialLabel: String {
        guard profile.waistCm > 0 else { return "Not set" }
        return "\(Int(UnitFormatter.cmToInches(profile.waistCm).rounded())) in"
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

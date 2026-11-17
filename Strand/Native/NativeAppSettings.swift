import SwiftUI
import StrandAnalytics

/// More → Settings. Everyday Band preferences that are not on Profile, Notifications, or Data & Backup.
struct NativeAppSettingsView: View {
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.skinTempDisplayKey) private var skinTempDisplayRaw = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @AppStorage(NativeStyle.storageKey) private var nativeStyleRaw = NativeStyle.apple.rawValue
    #if os(iOS)
    @AppStorage(ScreenIdle.strapSyncKeepAwakeKey) private var syncKeepScreenOn = false
    #endif

    /// UserDefaults keys this page binds. Same spellings and defaults as the legacy SettingsView rows.
    static let boundKeys = [
        UnitPrefs.systemKey,
        UnitPrefs.distanceSystemKey,
        UnitPrefs.temperatureKey,
        UnitPrefs.skinTempDisplayKey,
        UnitPrefs.effortScaleKey,
        NativeStyle.storageKey,
        ScreenIdle.strapSyncKeepAwakeKey,
    ]

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: unitSystem, override: distanceSystemRaw)
    }
    private var distanceSystemBinding: Binding<String> {
        Binding(get: { distanceUnitSystem.rawValue }, set: { distanceSystemRaw = $0 })
    }

    var body: some View {
        List {
            Section {
                Picker("Body Measurements", selection: $unitSystemRaw) {
                    Text("Metric").tag(UnitSystem.metric.rawValue)
                    Text("Imperial").tag(UnitSystem.imperial.rawValue)
                }
                Picker("Exercise Distance & Pace", selection: distanceSystemBinding) {
                    Text("Kilometres").tag(UnitSystem.metric.rawValue)
                    Text("Miles").tag(UnitSystem.imperial.rawValue)
                }
                Picker("Temperature", selection: $temperatureRaw) {
                    Text("Follow body").tag("")
                    Text("°C").tag(TemperatureUnit.celsius.rawValue)
                    Text("°F").tag(TemperatureUnit.fahrenheit.rawValue)
                }
                Picker("Skin Temperature", selection: $skinTempDisplayRaw) {
                    Text("Temperature").tag("")
                    Text("vs baseline").tag(SkinTempDisplay.Kind.deviation.rawValue)
                }
            } header: {
                Text("Units")
            } footer: {
                Text("Display only. Stored data stays in SI units.")
            }

            Section {
                Picker("Strain Scale", selection: $effortScaleRaw) {
                    Text("0–21").tag(EffortScale.whoop.rawValue)
                    Text("0–100").tag(EffortScale.hundred.rawValue)
                }
            } header: {
                Text("Strain")
            } footer: {
                Text("WHOOP Day Strain uses 0–21. Stored strain is unchanged.")
            }

            Section {
                Picker("Style", selection: $nativeStyleRaw) {
                    ForEach(NativeStyle.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Apple is Health chrome with WHOOP's rings, contributor bands, and charts. WHOOP is the dark faithful drawing — without branding.")
            }

            #if os(iOS)
            Section {
                Toggle("Keep Screen On While Syncing", isOn: $syncKeepScreenOn)
            } header: {
                Text("Sync")
            } footer: {
                Text("Holds the screen awake while a strap history sync runs.")
            }
            #endif

            Section {
                NavigationLink("Advanced") {
                    SettingsView()
                }
            } footer: {
                Text("Diagnostics and experimental controls.")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .appleSettingsChrome("Settings")
    }
}

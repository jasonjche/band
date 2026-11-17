import SwiftUI
import StrandDesign
#if os(iOS)
import UIKit
#endif

/// Settings → Apple Health and More → Apple Health. One Form so the two routes cannot disagree.
/// Charts live on the Native metric pages; this screen is status, sync, and data-type access.
struct AppleHealthSettingsView: View {
    #if os(iOS)
    @EnvironmentObject private var health: HealthKitBridge
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @State private var latest: [String: String] = [:]
    #endif

    var body: some View {
        #if os(iOS)
        Form {
            statusSection
            dataTypeSection
            if !latest.isEmpty {
                recentSection
            }
            permissionsSection
        }
        .appleSettingsChrome("Apple Health")
        .task { await loadLatest() }
        #else
        Form {
            Section {
                LabeledContent("Status", value: "iPhone only")
            } footer: {
                Text("Apple Health lives on iPhone. Import a Health export in Data Sources on this Mac.")
            }
        }
        .appleSettingsChrome("Apple Health")
        #endif
    }

    #if os(iOS)
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    private var statusSection: some View {
        Section {
            LabeledContent("Status", value: statusValue)
            if let last = health.lastSync {
                LabeledContent("Last Sync", value: relativeAgo(last.timeIntervalSince1970))
            }
            if health.syncing {
                ProgressView(health.auth == .authorized ? "Syncing…" : "Working…")
            }
            switch health.auth {
            case .unavailable, .entitlementMissing:
                EmptyView()
            case .unknown, .denied:
                Button("Enable Apple Health") { enableHealth() }
            case .authorized:
                Button("Sync Now") { syncNow() }
                    .disabled(health.syncing)
            }
            if let err = health.lastError {
                LabeledContent("Error", value: err)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text(statusFooter)
        }
    }

    private var dataTypeSection: some View {
        Section {
            LabeledContent("Heart Rate", value: "Read & Write")
            LabeledContent("Resting HR", value: "Read & Write")
            LabeledContent("HRV", value: "Read & Write")
            LabeledContent("Blood Oxygen", value: "Read & Write")
            LabeledContent("Respiratory Rate", value: "Read & Write")
            LabeledContent("Sleep", value: "Read & Write")
            LabeledContent("Workouts", value: "Read & Write")
            LabeledContent("Steps", value: "Read")
            LabeledContent("Active Energy", value: "Read")
            LabeledContent("VO₂ Max", value: "Read")
            LabeledContent("Weight", value: "Read")
            LabeledContent("Body Fat", value: "Read")
            LabeledContent("Water", value: "Read")
            LabeledContent("Caffeine", value: "Read")
        } header: {
            Text("Data Types")
        } footer: {
            Text("Strap and manual workouts are written back to Apple Health with heart rate, energy, distance, and route. Workouts written to Apple Health can sync to Strava: in Strava, connect Apple Health under Settings → Manage Apps and Devices.")
        }
    }

    private var recentSection: some View {
        Section {
            if let v = latest["steps"] { LabeledContent("Steps", value: v) }
            if let v = latest["resting_hr"] { LabeledContent("Resting HR", value: v) }
            if let v = latest["hrv"] { LabeledContent("HRV", value: v) }
            if let v = latest["spo2"] { LabeledContent("Blood Oxygen", value: v) }
            if let v = latest["resp_rate"] { LabeledContent("Respiratory Rate", value: v) }
            if let v = latest["asleep_min"] { LabeledContent("Sleep", value: v) }
            if let v = latest["active_kcal"] { LabeledContent("Active Energy", value: v) }
            if let v = latest["vo2max"] { LabeledContent("VO₂ Max", value: v) }
            if let v = latest["weight"] { LabeledContent("Weight", value: v) }
            if let v = latest["body_fat"] { LabeledContent("Body Fat", value: v) }
            if let v = latest["lean_mass"] { LabeledContent("Lean Mass", value: v) }
        } header: {
            Text("Recent")
        }
    }

    private var permissionsSection: some View {
        Section {
            Button("Open Apple Health") { openHealthApp() }
        } footer: {
            Text("Change Band's access in Settings → Health → Data Access & Devices.")
        }
    }

    private var statusValue: String {
        switch health.auth {
        case .authorized: return health.syncing ? "Syncing" : "Connected"
        case .denied: return "Not authorised"
        case .unavailable: return "Unavailable"
        case .entitlementMissing: return "Not available"
        case .unknown: return "Not authorised"
        }
    }

    private var statusFooter: String {
        switch health.auth {
        case .authorized:
            return "New strap data is written automatically when iOS allows it."
        case .denied:
            return "Enable Band under Settings → Health → Data Access & Devices."
        case .entitlementMissing:
            return "This install cannot connect to Apple Health. Import a Health export in Data Sources."
        case .unavailable:
            return "Apple Health is not available on this device."
        case .unknown:
            return "Read heart rate, HRV, sleep, and steps, and write strap data back."
        }
    }

    private func enableHealth() {
        Task {
            await health.requestAuthorization()
            await HealthSyncRefreshCoordinator.run(
                sync: { await health.sync() },
                refresh: {
                    await model.refreshAfterAppleHealthSync(authorized: health.auth == .authorized)
                }
            )
            await loadLatest()
        }
    }

    private func syncNow() {
        Task {
            await HealthSyncRefreshCoordinator.run(
                sync: { await health.sync() },
                refresh: {
                    await model.refreshAfterAppleHealthSync(authorized: health.auth == .authorized)
                }
            )
            await loadLatest()
        }
    }

    private func openHealthApp() {
        if let url = URL(string: "x-apple-health://") {
            UIApplication.shared.open(url)
        }
    }

    private func loadLatest() async {
        let keys = [
            "steps", "resting_hr", "hrv", "vo2max", "weight", "body_fat",
            "lean_mass", "asleep_min", "spo2", "resp_rate", "active_kcal"
        ]
        var out: [String: String] = [:]
        out.reserveCapacity(keys.count)
        for key in keys {
            let rows = await repo.series(key: key, source: "apple-health", days: 90)
            if let last = rows.last {
                out[key] = formatLatest(key, last.value)
            }
        }
        latest = out
    }

    private func formatLatest(_ key: String, _ value: Double) -> String {
        switch key {
        case "steps", "active_kcal":
            return "\(Int(value.rounded()))"
        case "resting_hr":
            return "\(Int(value.rounded())) bpm"
        case "hrv":
            return "\(Int(value.rounded())) ms"
        case "vo2max":
            return String(format: "%.1f ml/kg", value)
        case "weight", "lean_mass":
            return UnitFormatter.massFromKilograms(value, system: unitSystem)
        case "body_fat", "spo2":
            return String(format: "%.1f%%", value)
        case "resp_rate":
            return String(format: "%.1f rpm", value)
        case "asleep_min":
            let total = Int(value.rounded())
            let h = total / 60, m = total % 60
            return h > 0 ? "\(h)h \(m)m" : "\(m)m"
        default:
            return String(format: "%.1f", value)
        }
    }
    #endif
}

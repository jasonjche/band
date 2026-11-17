import SwiftUI

/// Environment flag: iOS Settings/More use system Form/List chrome instead of NativeChrome panels.
private struct AppleSettingsStyleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var appleSettingsStyle: Bool {
        get { self[AppleSettingsStyleKey.self] }
        set { self[AppleSettingsStyleKey.self] = newValue }
    }
}

/// iOS Settings-style coloured rounded-square SF Symbol.
struct AppleSettingsGlyph: View {
    let systemName: String
    let background: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(background, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension View {
    /// Inline Settings title + grouped Form environment. macOS keeps the title only.
    @ViewBuilder
    func appleSettingsChrome(_ title: LocalizedStringKey) -> some View {
        #if os(iOS)
        self
            .environment(\.appleSettingsStyle, true)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        #else
        self
            .environment(\.appleSettingsStyle, true)
            .navigationTitle(title)
        #endif
    }
}

/// Inset-grouped Form used by secondary Settings / More App+Data screens on iOS.
struct AppleSettingsForm<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: () -> Content

    var body: some View {
        Form {
            content()
        }
        .appleSettingsChrome(title)
    }
}

/// True when the iOS Native Settings chrome should replace ScreenScaffold cards.
enum AppleSettingsLayout {
    static var isEnabled: Bool {
        #if os(iOS)
        if UserDefaults.standard.object(forKey: "noop.nativeTodayEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "noop.nativeTodayEnabled")
        #else
        return false
        #endif
    }
}

/// About → Licenses. Attribution only; no update checks.
struct LicensesView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("WHOOP 5.0 protocol", value: "b-nnett/goose")
                if !AppBrand.isPersonalBuild {
                    LabeledContent("WHOOP 4.0 protocol", value: "johnmiddleton12/my-whoop")
                }
            }
        }
        .appleSettingsChrome("Licenses")
    }
}

/// More → About. Version and licenses only.
struct BandAboutView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: versionLabel)
                NavigationLink("Licenses") { LicensesView() }
            }
        }
        .appleSettingsChrome("About")
    }

    private var versionLabel: String {
        let version = UpdateWatch.installedVersion
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        return "\(version) (\(build))"
    }
}

/// More → Notifications. Wrist-alert master for the WHOOP 5.0 strap.
struct BandNotificationsView: View {
    @AppStorage("notif.masterEnabled") private var wristAlertsMaster = false

    var body: some View {
        Form {
            Section {
                Toggle("Wrist alerts", isOn: $wristAlertsMaster)
            } footer: {
                Text("Master switch for strap buzzes. Off keeps the strap quiet.")
            }
        }
        .appleSettingsChrome("Notifications")
    }
}

import SwiftUI
import StrandDesign

/// Personal-build More index. Order is the product contract the tests pin.
enum NativeMoreItem: String, CaseIterable, Identifiable, Hashable {
    case strap
    case dataBackup
    case profile
    case settings
    case notifications
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strap: return "Strap"
        case .dataBackup: return "Data & Backup"
        case .profile: return "Profile"
        case .settings: return "Settings"
        case .notifications: return "Notifications"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .strap: return "badge.plus.radiowaves.right"
        case .dataBackup: return "externaldrive.fill"
        case .profile: return "person.fill"
        case .settings: return "gearshape.fill"
        case .notifications: return "bell.fill"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .strap: return .blue
        case .dataBackup: return Color(white: 0.45)
        case .profile: return .blue
        case .settings: return Color(white: 0.45)
        case .notifications: return .red
        case .about: return .gray
        }
    }

    static var titles: [String] { allCases.map(\.title) }

    var subtitle: String? { nil }

    var usesAppleSettingsChrome: Bool {
        true
    }

    @ViewBuilder var destination: some View {
        switch self {
        case .strap: DevicesView()
        case .dataBackup: NativeDataBackupView()
        case .profile: NativeProfileView()
        case .settings: SettingsView()
        case .notifications: NativeNotificationsSettings()
        case .about: BandAboutView()
        }
    }
}

/// Settings-style sections on the More index. Flattened `items` match `NativeMoreItem.allCases`.
enum NativeMoreSection: String, CaseIterable, Identifiable {
    case strap = "Strap"
    case data = "Data"
    case app = "App"

    var id: String { rawValue }
    var title: String { rawValue }

    var items: [NativeMoreItem] {
        switch self {
        case .strap: return [.strap]
        case .data: return [.dataBackup]
        case .app: return [.profile, .settings, .notifications, .about]
        }
    }
}

/// Inset grouped More list for the Native iPhone shell.
struct NativeMoreList: View {
    @Binding var suppressTabReselect: Bool
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal

    init(suppressTabReselect: Binding<Bool> = .constant(false)) {
        _suppressTabReselect = suppressTabReselect
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(NativeMoreSection.allCases) { section in
                    Section {
                        ForEach(section.items) { item in
                            moreLink(item)
                        }
                    } header: {
                        Text(section.title)
                    }
                    .id(section == .strap ? "more-top" : section.id)
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("More")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .onChangeCompat(of: scrollToTopSignal) { _ in
                proxy.scrollTo("more-top", anchor: .top)
            }
        }
    }

    @ViewBuilder
    private func moreLink(_ item: NativeMoreItem) -> some View {
        let row = NavigationLink(value: item) {
            NativeSettingsRow(title: item.title, icon: item.icon, color: item.color, subtitle: item.subtitle)
        }
        .simultaneousGesture(TapGesture().onEnded { suppressTabReselect = true })
        if let hint = item.subtitle, !hint.isEmpty {
            row.accessibilityHint(hint)
        } else {
            row
        }
    }
}

/// Data & Backup hub: Apple Health, WHOOP import, and file backup as one grouped section.
struct NativeDataBackupView: View {
    var body: some View {
        List {
            Section {
                NavigationLink {
                    AppleHealthSettingsView()
                } label: {
                    NativeSettingsRow(title: "Apple Health", icon: "heart.fill", color: .red)
                }
                NavigationLink {
                    DataSourcesView()
                } label: {
                    NativeSettingsRow(
                        title: "Import WHOOP Export",
                        icon: "square.and.arrow.down.fill",
                        color: .blue
                    )
                }
                NavigationLink {
                    BandBackupView()
                } label: {
                    NativeSettingsRow(
                        title: "Backup",
                        icon: "externaldrive.fill",
                        color: Color(white: 0.45)
                    )
                }
            } footer: {
                Text("Import from Apple Health or a WHOOP export, or write a local backup.")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .appleSettingsChrome("Data & Backup")
    }
}

struct NativeSettingsRow: View {
    var title: String
    var icon: String
    var color: Color
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            AppleSettingsGlyph(systemName: icon, background: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
        }
        .frame(minHeight: 44)
    }
}

import SwiftUI

/// Personal-build More index. Order is the product contract the tests pin.
enum NativeMoreItem: String, CaseIterable, Identifiable, Hashable {
    case healthspan
    case strap
    case profile
    case sleepPlanner
    case assessments
    case dataBackup
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .healthspan: return "Healthspan"
        case .strap: return "Strap"
        case .profile: return "Profile"
        case .sleepPlanner: return "Sleep Planner"
        case .assessments: return "Assessments"
        case .dataBackup: return "Data & Backup"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .healthspan: return "sparkles"
        case .strap: return "badge.plus.radiowaves.right"
        case .profile: return "person.fill"
        case .sleepPlanner: return "bed.double.fill"
        case .assessments: return "calendar"
        case .dataBackup: return "externaldrive.fill"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .healthspan: return NativeChrome.recovery
        case .strap: return .blue
        case .profile: return .blue
        case .sleepPlanner: return NativeChrome.sleep
        case .assessments: return .blue
        case .dataBackup: return Color(white: 0.45)
        case .about: return .gray
        }
    }

    static var titles: [String] { allCases.map(\.title) }
}

/// Inset grouped More list for the Native iPhone shell.
struct NativeMoreList: View {
    var onSelect: (NativeMoreItem) -> Void

    var body: some View {
        List {
            ForEach(NativeMoreItem.allCases) { item in
                Button {
                    onSelect(item)
                } label: {
                    HStack(spacing: 12) {
                        AppleSettingsGlyph(systemName: item.icon, background: item.color)
                        Text(item.title)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("More")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
    }
}

/// Data & Backup hub: Apple Health, WHOOP import, and file backup as three grouped sections.
struct NativeDataBackupView: View {
    var body: some View {
        List {
            Section {
                NavigationLink {
                    AppleHealthSettingsView()
                } label: {
                    NativeSettingsRow(title: "Apple Health", icon: "heart.fill", color: .red)
                }
            } header: {
                Text("Apple Health")
            }

            Section {
                NavigationLink {
                    DataSourcesView()
                } label: {
                    NativeSettingsRow(
                        title: "Import WHOOP Export",
                        icon: "square.and.arrow.down.fill",
                        color: .blue
                    )
                }
            } header: {
                Text("Import WHOOP Export")
            }

            Section {
                NavigationLink {
                    BandBackupView()
                } label: {
                    NativeSettingsRow(
                        title: "Backup",
                        icon: "externaldrive.fill",
                        color: Color(white: 0.45)
                    )
                }
            } header: {
                Text("Backup")
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

    var body: some View {
        HStack(spacing: 12) {
            AppleSettingsGlyph(systemName: icon, background: color)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
        }
        .frame(minHeight: 44)
    }
}

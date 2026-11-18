#if os(macOS)
import SwiftUI
import StrandDesign

/// True while this process is a unit-test host (`xcodebuild test -scheme BandMac`).
enum NativeMacHost {
    static var isUnitTestProcess: Bool {
        NSClassFromString("XCTestCase") != nil
    }
}

enum NativeMacLayout {
    static let contentWidth: CGFloat = 860
    static let windowWidth: CGFloat = 1120
    static let windowHeight: CGFloat = 780
    static let minWidth: CGFloat = 820
    static let minHeight: CGFloat = 560
    static let sidebarMin: CGFloat = 200
    static let sidebarIdeal: CGFloat = 232
    static let sidebarMax: CGFloat = 300
}

/// Sidebar groups for the macOS Native shell. Order is the product contract the tests pin.
enum NativeMacSidebarSection: String, CaseIterable, Identifiable {
    case overview
    case health
    case band

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .health: return "Health"
        case .band: return "Band"
        }
    }

    var items: [NativeMacSidebarItem] {
        switch self {
        case .overview:
            return [.home, .sleep, .recovery, .strain, .stressMonitor, .healthMonitor, .journal]
        case .health:
            return [.healthspan, .trends, .reports]
        case .band:
            return [.strap, .dataBackup, .profile, .settings, .notifications, .about]
        }
    }

    static var titles: [String] { allCases.map(\.title) }
}

/// One sidebar destination. Flattened `allCases` walk Overview → Health → Band.
enum NativeMacSidebarItem: String, CaseIterable, Identifiable, Hashable {
    case home, sleep, recovery, strain, stressMonitor, healthMonitor, journal
    case healthspan, trends, reports
    case strap, dataBackup, profile, settings, notifications, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .sleep: return "Sleep"
        case .recovery: return "Recovery"
        case .strain: return "Strain"
        case .stressMonitor: return "Stress Monitor"
        case .healthMonitor: return "Health Monitor"
        case .journal: return "Journal"
        case .healthspan: return NativeHealthItem.healthspan.title
        case .trends: return NativeHealthItem.trends.title
        case .reports: return NativeHealthItem.reports.title
        case .strap: return NativeMoreItem.strap.title
        case .dataBackup: return NativeMoreItem.dataBackup.title
        case .profile: return NativeMoreItem.profile.title
        case .settings: return NativeMoreItem.settings.title
        case .notifications: return NativeMoreItem.notifications.title
        case .about: return NativeMoreItem.about.title
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .sleep: return "moon.stars.fill"
        case .recovery: return "heart.fill"
        case .strain: return "bolt.fill"
        case .stressMonitor: return "waveform.path.ecg"
        case .healthMonitor: return "heart.text.square"
        case .journal: return "square.and.pencil"
        case .healthspan: return NativeHealthItem.healthspan.icon
        case .trends: return NativeHealthItem.trends.icon
        case .reports: return NativeHealthItem.reports.icon
        case .strap: return NativeMoreItem.strap.icon
        case .dataBackup: return NativeMoreItem.dataBackup.icon
        case .profile: return NativeMoreItem.profile.icon
        case .settings: return NativeMoreItem.settings.icon
        case .notifications: return NativeMoreItem.notifications.icon
        case .about: return NativeMoreItem.about.icon
        }
    }

    var section: NativeMacSidebarSection {
        switch self {
        case .home, .sleep, .recovery, .strain, .stressMonitor, .healthMonitor, .journal:
            return .overview
        case .healthspan, .trends, .reports:
            return .health
        case .strap, .dataBackup, .profile, .settings, .notifications, .about:
            return .band
        }
    }

    var scoreKind: NativeScoreKind? {
        switch self {
        case .sleep: return .sleep
        case .recovery: return .recovery
        case .strain: return .strain
        default: return nil
        }
    }

    var healthItem: NativeHealthItem? {
        switch self {
        case .healthspan: return .healthspan
        case .trends: return .trends
        case .reports: return .reports
        default: return nil
        }
    }

    var moreItem: NativeMoreItem? {
        switch self {
        case .strap: return .strap
        case .dataBackup: return .dataBackup
        case .profile: return .profile
        case .settings: return .settings
        case .notifications: return .notifications
        case .about: return .about
        default: return nil
        }
    }

    /// Map a `NavRouter` request onto the sidebar row that should become visible.
    static func item(for destination: NavRouter.Destination) -> NativeMacSidebarItem {
        switch destination {
        case .devices: return .strap
        case .trends: return .trends
        case .journal: return .journal
        case .alarms: return .sleep
        case .insightsHub, .labBook, .fusedRecord, .rhythm, .coach, .activeWorkout, .liveSession:
            return .home
        }
    }

    static var titles: [String] { allCases.map(\.title) }

    @ViewBuilder var destination: some View {
        switch self {
        case .home: NativeHomeView()
        case .sleep: NativeScorePage(kind: .sleep)
        case .recovery: NativeScorePage(kind: .recovery)
        case .strain: NativeScorePage(kind: .strain)
        case .stressMonitor: NativeStressPage()
        case .healthMonitor: NativeHealthMonitorPage()
        case .journal: NativeJournalView()
        case .healthspan: NativeHealthspanPage()
        case .trends: NativeTrendsPage()
        case .reports: NativePerformanceAssessmentView()
        case .strap: DevicesView()
        case .dataBackup: NativeDataBackupView()
        case .profile: NativeProfileView()
        case .settings: NativeAppSettingsView()
        case .notifications: NativeNotificationsSettings()
        case .about: BandAboutView()
        }
    }
}

/// Numbered Go-menu shortcuts. ⌘2 opens the Health tab analogue (Healthspan).
enum NativeMacCommand {
    static let sidebarShortcuts: [(key: Character, title: String, item: NativeMacSidebarItem)] = [
        ("1", "Home", .home),
        ("2", "Health", .healthspan),
        ("3", "Trends", .trends),
        ("4", "Reports", .reports),
        ("5", "Journal", .journal),
    ]
}

/// Native macOS shell: sidebar sections plus a per-destination `NavigationStack`.
struct NativeMacRootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: NavRouter
    @State private var selection: NativeMacSidebarItem = .home
    @State private var paths: [NativeMacSidebarItem: NavigationPath] = {
        Dictionary(uniqueKeysWithValues: NativeMacSidebarItem.allCases.map { ($0, NavigationPath()) })
    }()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(NativeMacSidebarSection.allCases) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            Label(item.title, systemImage: item.icon)
                                .tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Band")
            .navigationSplitViewColumnWidth(
                min: NativeMacLayout.sidebarMin,
                ideal: NativeMacLayout.sidebarIdeal,
                max: NativeMacLayout.sidebarMax
            )
        } detail: {
            NativeMacDetailStack(item: selection, path: pathBinding(for: selection))
        }
        .onChangeCompat(of: router.requestedDestination) { dest in
            guard let dest else { return }
            selection = NativeMacSidebarItem.item(for: dest)
            router.requestedDestination = nil
        }
        .focusedSceneValue(\.nativeMacSelection, $selection)
        .focusedSceneObject(model)
    }

    private func pathBinding(for item: NativeMacSidebarItem) -> Binding<NavigationPath> {
        Binding(
            get: { paths[item] ?? NavigationPath() },
            set: { paths[item] = $0 }
        )
    }
}

private struct NativeMacSelectionKey: FocusedValueKey {
    typealias Value = Binding<NativeMacSidebarItem>
}

extension FocusedValues {
    var nativeMacSelection: Binding<NativeMacSidebarItem>? {
        get { self[NativeMacSelectionKey.self] }
        set { self[NativeMacSelectionKey.self] = newValue }
    }
}

/// Menu bar: ⌘R refresh, ⌘1–⌘5 Go, ⌘, Settings.
struct NativeMacCommands: Commands {
    @FocusedBinding(\.nativeMacSelection) private var selection
    @FocusedObject private var model: AppModel?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .toolbar) {
            Button("Refresh") {
                model?.ble.syncNow()
                Task { await model?.repo.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model == nil)
        }
        CommandGroup(after: .sidebar) {
            ForEach(NativeMacCommand.sidebarShortcuts, id: \.item) { shortcut in
                Button(shortcut.title) { selection = shortcut.item }
                    .keyboardShortcut(KeyEquivalent(shortcut.key), modifiers: .command)
                    .disabled(selection == nil)
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { selection = .settings }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(selection == nil)
        }
    }
}

/// One destination's stack. Destinations are registered here so Home cards, Health rows,
/// More pushes, Health Monitor HR, and Journal impact all resolve on macOS.
private struct NativeMacDetailStack: View {
    var item: NativeMacSidebarItem
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            item.destination
                .frame(maxWidth: NativeMacLayout.contentWidth, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .tabRouteDestinations()
                .navigationDestination(for: NativeHealthItem.self) { health in
                    health.destination
                        .nativeStyleBridge()
                        .frame(maxWidth: NativeMacLayout.contentWidth, alignment: .top)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .nativeZoomDestination(fallback: .healthItem(health))
                }
                .navigationDestination(for: NativeMoreItem.self) { more in
                    more.destination
                        .nativeStyleBridge()
                        .frame(maxWidth: NativeMacLayout.contentWidth, alignment: .top)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .navigationDestination(for: NativeHeartRateRoute.self) { _ in
                    NativeHeartRatePage()
                        .nativeStyleBridge()
                        .frame(maxWidth: NativeMacLayout.contentWidth, alignment: .top)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .navigationDestination(for: NativeJournalImpactRoute.self) { _ in
                    NativeJournalImpactView()
                        .nativeStyleBridge()
                        .frame(maxWidth: NativeMacLayout.contentWidth, alignment: .top)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .nativeStyleBridge()
        }
        .environment(\.nativeNavigationPath, $path)
        .nativeContinuityStack()
        .background(NativePageFill().ignoresSafeArea())
    }
}
#endif

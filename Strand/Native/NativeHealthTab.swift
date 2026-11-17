import SwiftUI
import StrandDesign
import WhoopStore

/// iOS tab tags for the native shell. Home stays 0 and More stays 4 so anything that
/// still names those slots keeps working; Health sits between them as tag 1.
enum NativeRootTab: Int, CaseIterable, Equatable {
    case home = 0
    case health = 1
    case more = 4

    /// Slots in `tabPaths` / `scrollTop`, including unused legacy tags (Coach was 3).
    static let pathSlotCount = 5
    /// Leftover Coach tag. Not a visible tab; the shell still maps it back to Home.
    static let coachTag = 3
    static var ordered: [NativeRootTab] { [.home, .health, .more] }

    static func next(from raw: Int, direction: Int) -> Int {
        let tags = ordered.map(\.rawValue)
        guard let idx = tags.firstIndex(of: raw) else { return raw }
        let next = min(tags.count - 1, max(0, idx + direction))
        return tags[next]
    }
}

/// Health tab index. Order is the product contract the tests pin.
enum NativeHealthItem: String, CaseIterable, Identifiable, Hashable {
    case healthspan
    case healthMonitor
    case stressMonitor
    case trends
    case reports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .healthspan: return "Healthspan"
        case .healthMonitor: return "Health Monitor"
        case .stressMonitor: return "Stress Monitor"
        case .trends: return "Trends"
        case .reports: return "Reports"
        }
    }

    var icon: String {
        switch self {
        case .healthspan: return "sparkles"
        case .healthMonitor: return "heart.fill"
        case .stressMonitor: return "waveform.path.ecg"
        case .trends: return "chart.xyaxis.line"
        case .reports: return "calendar"
        }
    }

    var color: Color {
        switch self {
        case .healthspan: return NativeChrome.recovery
        case .healthMonitor: return NativeChrome.heart
        case .stressMonitor: return NativeChrome.stress
        case .trends: return NativeChrome.strain
        case .reports: return NativeChrome.activity
        }
    }

    var subtitle: String {
        switch self {
        case .healthspan: return "Band Age and Pace of Aging"
        case .healthMonitor: return "Overnight vitals vs typical"
        case .stressMonitor: return "Daytime stress 0–3"
        case .trends: return "All metrics over weeks and months"
        case .reports: return "Weekly and monthly assessments"
        }
    }

    static var titles: [String] { allCases.map(\.title) }

    @ViewBuilder var destination: some View {
        switch self {
        case .healthspan: NativeHealthspanPage()
        case .healthMonitor: NativeHealthMonitorPage()
        case .stressMonitor: NativeStressPage()
        case .trends: NativeTrendsPage()
        case .reports: NativePerformanceAssessmentView()
        }
    }
}

enum NativeHealthTabLogic {
    /// Cheap in-memory headline for a Health row. Band Age is skipped — it needs a 400-day rebuild.
    static func liveSummary(for item: NativeHealthItem, days: [DailyMetric], todayKey: String) -> String? {
        switch item {
        case .healthMonitor:
            let summary = NativeHealthRange.report(days: days, todayKey: todayKey).summary
            guard summary.measured > 0 else { return nil }
            return HomeMonitorTile.healthPrimary(summary)
        case .stressMonitor:
            let level = NativeStressResolver.level(hours: [], days: days, todayKey: todayKey)
            let tile = HomeMonitorTile.stress(level: level, at: nil)
            guard let value = tile.value, let band = tile.band else { return nil }
            return "\(value) \(band)"
        case .healthspan, .trends, .reports:
            return nil
        }
    }
}

/// Large-title Health index: Healthspan, monitors, Trends, Reports.
struct NativeHealthTab: View {
    @Binding var suppressTabReselect: Bool
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    @State private var repoHandle: Repository?
    @State private var refreshSeq = 0
    @State private var handlesReady = false
    @State private var live: [NativeHealthItem: String] = [:]

    init(suppressTabReselect: Binding<Bool> = .constant(false)) {
        _suppressTabReselect = suppressTabReselect
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(NativeHealthItem.allCases) { item in
                        healthLink(item)
                    }
                }
                .id("health-top")
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("Health")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .onChangeCompat(of: scrollToTopSignal) { _ in
                proxy.scrollTo("health-top", anchor: .top)
            }
        }
        .background {
            NativeRepoSink(refreshSeq: $refreshSeq, ready: $handlesReady) { repoHandle = $0 }
        }
        .task(id: handlesReady ? "\(refreshSeq)" : "boot") {
            guard handlesReady, let repo = repoHandle else { return }
            let today = NativeDayLogic.logicalToday()
            var next: [NativeHealthItem: String] = [:]
            for item in NativeHealthItem.allCases {
                if let summary = NativeHealthTabLogic.liveSummary(for: item, days: repo.days, todayKey: today) {
                    next[item] = summary
                }
            }
            live = next
        }
    }

    @ViewBuilder
    private func healthLink(_ item: NativeHealthItem) -> some View {
        let subtitle = live[item] ?? item.subtitle
        let row = NavigationLink(value: item) {
            NativeSettingsRow(title: item.title, icon: item.icon, color: item.color, subtitle: subtitle)
        }
        .simultaneousGesture(TapGesture().onEnded { suppressTabReselect = true })
        if !subtitle.isEmpty {
            row.accessibilityHint(subtitle)
        } else {
            row
        }
    }
}

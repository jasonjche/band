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
    case trends
    case reports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .healthspan: return "Healthspan"
        case .trends: return "Trends"
        case .reports: return "Reports"
        }
    }

    var icon: String {
        switch self {
        case .healthspan: return "sparkles"
        case .trends: return "chart.xyaxis.line"
        case .reports: return "calendar"
        }
    }

    var color: Color {
        switch self {
        case .healthspan: return NativeChrome.recovery
        case .trends: return NativeChrome.strain
        case .reports: return NativeChrome.activity
        }
    }

    var subtitle: String {
        switch self {
        case .healthspan: return "Band Age and Pace of Aging"
        case .trends: return "All metrics over weeks and months"
        case .reports: return "Weekly and monthly assessments"
        }
    }

    static var titles: [String] { allCases.map(\.title) }

    /// Rows on the Health tab root; Healthspan itself is the page.
    static let tabLinks: [NativeHealthItem] = [.trends, .reports]

    @ViewBuilder var destination: some View {
        switch self {
        case .healthspan: NativeHealthspanPage()
        case .trends: NativeTrendsPage()
        case .reports: NativePerformanceAssessmentView()
        }
    }
}

enum NativeHealthTabLogic {
    /// Cheap in-memory headline for a Health row. Band Age is skipped — it needs a 400-day rebuild.
    static func liveSummary(for item: NativeHealthItem, days: [DailyMetric], todayKey: String) -> String? {
        // Healthspan needs a long rebuild and Trends/Reports have no single headline, so rows
        // show their static subtitle. The monitors live on Home.
        _ = (item, days, todayKey)
        return nil
    }
}

/// Health tab root: Healthspan first (as in WHOOP), with Trends and Reports rows under Pace of Aging.
struct NativeHealthTab: View {
    @Binding var suppressTabReselect: Bool

    init(suppressTabReselect: Binding<Bool> = .constant(false)) {
        _suppressTabReselect = suppressTabReselect
    }

    var body: some View {
        NativeHealthspanPage(links: NativeHealthItem.tabLinks, title: "Health")
            .environment(\.nativeHealthLinkTapped) { suppressTabReselect = true }
    }
}

enum NativeHealthLinksLayout {
    static let rowMinHeight: CGFloat = 48
    static let dividerLeading: CGFloat = 42
    static let rowVerticalPadding: CGFloat = 6
}

/// Grouped rows that push a Health destination onto the tab's stack.
struct NativeHealthLinks: View {
    var items: [NativeHealthItem]
    @Environment(\.nativeNavigationPath) private var navigationPath
    @Environment(\.nativeHealthLinkTapped) private var onTap
    @Environment(\.nativeContinuityActiveID) private var continuityID

    var body: some View {
        NativeChrome.panel {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    if index > 0 { Divider().padding(.leading, NativeHealthLinksLayout.dividerLeading) }
                    Button {
                        onTap()
                        continuityID.select(.healthItem(item))
                        navigationPath.wrappedValue.append(item)
                    } label: {
                        HStack(spacing: 0) {
                            NativeSettingsRow(title: item.title, icon: item.icon, color: item.color)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, NativeHealthLinksLayout.rowVerticalPadding)
                        .frame(minHeight: NativeHealthLinksLayout.rowMinHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .nativeZoomSource(.healthItem(item))
                    .accessibilityHint("Opens \(item.title)")
                }
            }
        }
    }
}

private struct NativeHealthLinkTappedKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Lets the tab shell know a row push started, so the tab-reselect handler leaves the path alone.
    var nativeHealthLinkTapped: () -> Void {
        get { self[NativeHealthLinkTappedKey.self] }
        set { self[NativeHealthLinkTappedKey.self] = newValue }
    }
}

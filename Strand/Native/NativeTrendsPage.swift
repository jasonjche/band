import SwiftUI
import StrandDesign

/// WHOOP Trend View groups. Catalog categories (Effort / Charge / Rest) map onto these.
enum NativeTrendsGroup: String, CaseIterable, Identifiable {
    case strain
    case recovery
    case sleep
    case health
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strain: return "Strain"
        case .recovery: return "Recovery"
        case .sleep: return "Sleep"
        case .health: return "Health"
        case .activity: return "Activity"
        }
    }
}

struct NativeTrendsSection: Identifiable, Equatable {
    var group: NativeTrendsGroup
    var metrics: [MetricDescriptor]
    var id: NativeTrendsGroup { group }
}

/// One row per unique `MetricCatalog` key, grouped the way WHOOP's Trend View lists them.
enum NativeTrendsCatalog {
    static let storageKey = "native.trends.metricKey"
    static let defaultKey = "hrv"

    static func resolvedKey(_ stored: String, catalog: [MetricDescriptor] = MetricCatalog.all) -> String {
        if catalog.contains(where: { $0.key == stored }) { return stored }
        return defaultKey
    }

    static func route(for key: String) -> TabRoute { .metric(key) }

    static func title(for key: String, catalog: [MetricDescriptor] = MetricCatalog.all) -> String {
        if key == "vo2max" || key == "vo2max_est" { return "VO₂ Max" }
        return catalog.first { $0.key == key }?.title
            ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func symbol(for key: String, catalog: [MetricDescriptor] = MetricCatalog.all) -> String {
        catalog.first { $0.key == key }?.icon ?? "chart.xyaxis.line"
    }

    static func tint(for key: String, style: NativeStyle) -> Color {
        switch key {
        case "hrv", "rhr", "resting_hr", "avg_hr", "max_hr": return NativePaint.heart(style)
        case "resp_rate", "vo2max", "vo2max_est": return NativePaint.respiratory(style)
        case "steps", "steps_est", "energy_kcal", "active_kcal": return NativePaint.activity(style)
        case "strain": return NativePaint.strain(style)
        case "recovery": return NativePaint.recovery(style)
        default: return NativePaint.sleep(style)
        }
    }

    static func group(for key: String, catalog: [MetricDescriptor] = MetricCatalog.all) -> NativeTrendsGroup {
        switch key {
        case "strain", "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min",
             "energy_kcal", "active_kcal", "avg_hr", "max_hr":
            return .strain
        case "recovery", "hrv", "rhr", "resting_hr", "resp_rate", "spo2", "skin_temp":
            return .recovery
        case "steps", "steps_est", "strength_min", "intensity_min":
            return .activity
        default:
            switch catalog.first(where: { $0.key == key })?.category {
            case "Rest": return .sleep
            case "Charge": return .recovery
            case "Effort": return .strain
            default: return .health
            }
        }
    }

    static func uniqueMetrics(in catalog: [MetricDescriptor] = MetricCatalog.all) -> [MetricDescriptor] {
        var seen = Set<String>()
        return catalog.filter { seen.insert($0.key).inserted }
    }

    static func sections(in catalog: [MetricDescriptor] = MetricCatalog.all) -> [NativeTrendsSection] {
        let unique = uniqueMetrics(in: catalog)
        return NativeTrendsGroup.allCases.map { group in
            let members = unique.filter { Self.group(for: $0.key, catalog: catalog) == group }
            let preferredKeys = preferred[group] ?? []
            let leading = preferredKeys.compactMap { key in members.first { $0.key == key } }
            let rest = members.filter { !preferredKeys.contains($0.key) }
            return NativeTrendsSection(group: group, metrics: leading + rest)
        }
    }

    static let sections: [NativeTrendsSection] = NativeTrendsCatalog.sections(in: MetricCatalog.all)
    static var metrics: [MetricDescriptor] { sections.flatMap(\.metrics) }
    static var keys: [String] { metrics.map(\.key) }

    private static let preferred: [NativeTrendsGroup: [String]] = [
        .strain: ["strain", "hr_zones13_min", "hr_zones45_min", "energy_kcal", "avg_hr"],
        .recovery: ["recovery", "hrv", "rhr", "resp_rate"],
        .sleep: ["sleep_performance"],
        .health: ["vo2max", "weight", "body_fat", "stress"],
        .activity: ["steps", "strength_min"],
    ]
}

/// WHOOP Trend View: glass metric picker over the existing metric page (W / M / 6M).
struct NativeTrendsPage: View {
    @AppStorage(NativeTrendsCatalog.storageKey) private var storedKey = NativeTrendsCatalog.defaultKey
    @Environment(\.nativeStyle) private var style

    private var selectedKey: String { NativeTrendsCatalog.resolvedKey(storedKey) }

    var body: some View {
        NativeTrendsMetricHost(key: selectedKey)
            .equatable()
            .safeAreaInset(edge: .top, spacing: 0) {
                picker
            }
            .navigationTitle("Trends")
            .modifier(NativeInlineTitle())
    }

    private var picker: some View {
        Menu {
            ForEach(NativeTrendsCatalog.sections) { section in
                Section(section.group.title) {
                    ForEach(section.metrics, id: \.key) { metric in
                        Button {
                            storedKey = metric.key
                        } label: {
                            Label(
                                NativeTrendsCatalog.title(for: metric.key),
                                systemImage: metric.icon
                            )
                        }
                    }
                }
            }
        } label: {
            NativeTrendsHeader(
                title: NativeTrendsCatalog.title(for: selectedKey),
                symbol: NativeTrendsCatalog.symbol(for: selectedKey),
                tint: NativeTrendsCatalog.tint(for: selectedKey, style: style)
            )
        }
        .menuIndicator(.hidden)
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.top, NoopMetrics.space2)
        .padding(.bottom, NoopMetrics.space2)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background {
            NativePaint.page(style)
                .ignoresSafeArea(edges: .top)
        }
        .accessibilityLabel(NativeTrendsCatalog.title(for: selectedKey))
        .accessibilityHint("Shows all metrics over weeks and months")
    }
}

/// Isolates the metric page so picker chrome invalidations do not rebuild the chart.
private struct NativeTrendsMetricHost: View, Equatable {
    var key: String

    var body: some View {
        NativeMetricPage(key: key, showsNavigationTitle: false)
            .id(key)
    }
}

private struct NativeTrendsHeader: View {
    var title: String
    var symbol: String
    var tint: Color
    @Environment(\.nativeStyle) private var style

    var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(title)
                .font(style == .whoop ? NativeTokens.whoopCaps() : .headline)
                .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: NoopMetrics.space2)
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, NoopMetrics.space3)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.controlHeight)
        .contentShape(Capsule())
        .nativeTrendsGlass()
    }
}

private extension View {
    @ViewBuilder func nativeTrendsGlass() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
        #else
        self.background(NativeTokens.card, in: Capsule())
        #endif
    }
}

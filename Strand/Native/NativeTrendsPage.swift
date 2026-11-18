import SwiftUI
import StrandDesign

/// WHOOP Trend View groups. Catalog categories (Effort / Charge / Rest) stay as-is;
/// this is only the Trends menu's section order and titles.
enum NativeTrendsGroup: String, CaseIterable, Identifiable {
    case healthspan
    case other
    case sleep
    case strain
    case recovery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .healthspan: return "Healthspan"
        case .other: return "Other"
        case .sleep: return "Sleep"
        case .strain: return "Strain"
        case .recovery: return "Recovery"
        }
    }
}

struct NativeTrendsSection: Identifiable, Equatable {
    var group: NativeTrendsGroup
    var metrics: [MetricDescriptor]
    var id: NativeTrendsGroup { group }
}

/// WHOOP Trend View rows Band can series. Grouped and named like WHOOP; catalog
/// category ids (Effort / Charge / Rest) are unchanged.
enum NativeTrendsCatalog {
    static let storageKey = "native.trends.metricKey"
    static let defaultKey = "hrv"

    static func resolvedKey(_ stored: String, catalog: [MetricDescriptor] = MetricCatalog.all) -> String {
        if catalog.contains(where: { $0.key == stored }) { return stored }
        return defaultKey
    }

    static func route(for key: String) -> TabRoute { .metric(key) }

    static func title(for key: String, catalog: [MetricDescriptor] = MetricCatalog.all) -> String {
        switch key {
        case "band_age": return "Band Age"
        case "pace_of_aging": return "Pace of Aging"
        case "lean_mass": return "Lean Body Mass"
        case "weight": return "Weight"
        case "stress": return "Total Day Stress"
        case "sleep_performance": return "Sleep Performance"
        case "in_bed_min": return "Time in Bed"
        case "hours_vs_needed_hours": return "Hours vs. Needed (Hours)"
        case "hours_vs_needed_pct": return "Hours vs. Needed (%)"
        case "sleep_consistency": return "Sleep Consistency"
        case "restorative_pct": return "Restorative Sleep (%)"
        case "restorative_min": return "Restorative Sleep (Hours)"
        case "sleep_efficiency": return "Sleep Efficiency"
        case "sleep_debt_min": return "Sleep Debt"
        case "strain": return "Strain"
        case "hr_zones13_min": return "Heart Rate Zones 1-3"
        case "hr_zones45_min": return "Heart Rate Zones 4-5"
        case "hr_zones_all_min": return "Heart Rate Zones All"
        case "strength_min": return "Strength Activity Time"
        case "avg_hr": return "Average Heart Rate"
        case "energy_kcal", "active_kcal": return "Calories"
        case "vo2max", "vo2max_est": return "VO₂ Max"
        case "recovery": return "Recovery"
        case "hrv": return "Heart Rate Variability"
        case "rhr", "resting_hr": return "Resting Heart Rate"
        case "resp_rate": return "Respiratory Rate"
        default:
            return catalog.first { $0.key == key }?.title
                ?? key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func symbol(for key: String, catalog: [MetricDescriptor] = MetricCatalog.all) -> String {
        catalog.first { $0.key == key }?.icon ?? "chart.xyaxis.line"
    }

    static func tint(for key: String, style: NativeStyle) -> Color {
        switch key {
        case "hrv", "rhr", "resting_hr", "avg_hr", "max_hr": return NativePaint.heart(style)
        case "resp_rate", "vo2max", "vo2max_est": return NativePaint.respiratory(style)
        case "steps", "steps_est", "energy_kcal", "active_kcal", "strength_min",
             "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min":
            return NativePaint.activity(style)
        case "strain": return NativePaint.strain(style)
        case "recovery", "band_age", "pace_of_aging": return NativePaint.recovery(style)
        case "stress", "lean_mass", "weight": return NativePaint.strain(style)
        default: return NativePaint.sleep(style)
        }
    }

    static func opensHealthspan(_ key: String) -> Bool {
        key == "band_age" || key == "pace_of_aging"
    }

    static func group(for key: String, catalog: [MetricDescriptor] = MetricCatalog.all) -> NativeTrendsGroup {
        if let match = orderedKeys.first(where: { $0.keys.contains(key) }) {
            return match.group
        }
        switch catalog.first(where: { $0.key == key })?.category {
        case "Rest": return .sleep
        case "Charge": return .recovery
        case "Effort": return .strain
        default: return .other
        }
    }

    static func uniqueMetrics(in catalog: [MetricDescriptor] = MetricCatalog.all) -> [MetricDescriptor] {
        var seen = Set<String>()
        return catalog.filter { seen.insert($0.key).inserted }
    }

    static func sections(in catalog: [MetricDescriptor] = MetricCatalog.all) -> [NativeTrendsSection] {
        let byKey = Dictionary(uniqueKeysWithValues: uniqueMetrics(in: catalog).map { ($0.key, $0) })
        return orderedKeys.compactMap { entry in
            let metrics = entry.keys.compactMap { byKey[$0] }
            guard !metrics.isEmpty else { return nil }
            return NativeTrendsSection(group: entry.group, metrics: metrics)
        }
    }

    static let sections: [NativeTrendsSection] = NativeTrendsCatalog.sections(in: MetricCatalog.all)
    static var metrics: [MetricDescriptor] { sections.flatMap(\.metrics) }
    static var keys: [String] { metrics.map(\.key) }

    /// WHOOP Trend View order. Keys Band cannot cheaply series are omitted here
    /// (Sleep Stress, Non-Activity Stress, Total Volume Load).
    static let orderedKeys: [(group: NativeTrendsGroup, keys: [String])] = [
        (.healthspan, ["band_age", "pace_of_aging"]),
        (.other, ["lean_mass", "weight", "stress"]),
        (.sleep, [
            "sleep_performance", "in_bed_min", "hours_vs_needed_hours", "hours_vs_needed_pct",
            "sleep_consistency", "restorative_pct", "restorative_min", "sleep_efficiency",
            "sleep_debt_min",
        ]),
        (.strain, [
            "strain", "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min",
            "strength_min", "avg_hr", "energy_kcal", "vo2max",
        ]),
        (.recovery, ["recovery", "hrv", "rhr", "resp_rate"]),
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
        Group {
            if NativeTrendsCatalog.opensHealthspan(key) {
                NativeHealthspanPage(title: NativeTrendsCatalog.title(for: key))
            } else {
                NativeMetricPage(key: key, showsNavigationTitle: false)
            }
        }
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

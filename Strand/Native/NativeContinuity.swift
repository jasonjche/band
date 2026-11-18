import SwiftUI

// MARK: - Continuity
//
// Make the important state jumps continuous: the element the user touched carries
// into what comes next instead of disappearing and being replaced. Navigation still
// pushes the same `TabRoute` / score / health values; this file only names the
// zoom source and shares one `Namespace.ID` per stack.
//
// iOS 18+ uses `.matchedTransitionSource` + `.navigationTransition(.zoom)`. Older
// iOS, macOS, and Reduce Motion keep the system push / sheet.

/// Stable zoom-source identities. Destinations capture the ID that was selected
/// on tap so two Home tiles that push the same `TabRoute` still retract into the
/// ring or card that opened them.
enum NativeContinuityID: Hashable {
    case tab(TabRoute)
    case homeRing(NativeScoreKind)
    case homeHealthTile
    case homeStressTile
    case homeStressChart
    case homeJournal
    case homeJournalLog
    case homeDashboard(String)
    case homeActivitySleep
    case addActivity
    case morningJournal
    case liftSession
    case healthItem(NativeHealthItem)
    case healthspanTrend(NativeHealthspanTrendKind)
    case scoreMetric(String)
    case scoreTrend(String)
    case sleepHypnogram
    case sleepConsistency
    case sleepStress
    case activity(Int)
}

enum NativeContinuity {
    /// In-screen scope / expand. Band's calm spring, ~0.36s, almost no bounce.
    static let inScreen = Animation.spring(response: 0.36, dampingFraction: 0.90)

    /// Sheet / large surface. Slightly heavier than in-screen, still in the 0.32–0.42s band.
    static let sheet = Animation.spring(response: 0.40, dampingFraction: 0.88)

    static func gated(_ animation: Animation, reduced: Bool) -> Animation? {
        reduced ? nil : animation
    }

    /// Zoom geometry is iOS 18+ and off when Reduce Motion is on.
    static func allowsZoom(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    static func animate(reduced: Bool, _ body: () -> Void) {
        withAnimation(gated(inScreen, reduced: reduced), body)
    }

    static func ring(for route: TabRoute) -> NativeContinuityID {
        switch route {
        case .sleep:
            return .homeRing(.sleep)
        case .metric(HeroRingMetric.charge):
            return .homeRing(.recovery)
        case .metric(HeroRingMetric.effort):
            return .homeRing(.strain)
        default:
            return .tab(route)
        }
    }

    static func dashboard(_ item: HomeMetricItem) -> NativeContinuityID {
        .homeDashboard(item.id)
    }

    static func row(_ row: NativeScore.Row) -> NativeContinuityID {
        if row.title == "Sleep Consistency" { return .sleepConsistency }
        if case .metric(let key) = row.route { return .scoreMetric(key) }
        return .tab(row.route)
    }

    static func weekCard(title: String) -> NativeContinuityID {
        switch title {
        case "Hours of Sleep", "Time in Bed", "Heart Rate Zones 1–3", "Heart Rate Zones 4–5",
             "Strength Activity Time", "Restorative Sleep":
            return .scoreTrend(title)
        case "Sleep Stress":
            return .sleepStress
        case "Sleep Consistency":
            return .sleepConsistency
        case "Sleep Debt":
            return .scoreMetric("sleep_debt_min")
        default:
            if let key = NativeScoreRoutes.metricKey(for: title) {
                return .scoreMetric(key)
            }
            return .scoreTrend(title)
        }
    }

    static func sleepCard(title: String) -> NativeContinuityID {
        switch title {
        case "Last Night", "Last Night's Sleep": return .sleepHypnogram
        case "Heart Rate", "Overnight Heart Rate": return .scoreMetric("avg_hr")
        case "Hours vs. Needed": return .scoreMetric("hours_vs_needed_pct")
        case "Sleep Consistency": return .sleepConsistency
        case "Sleep Efficiency": return .scoreMetric("sleep_efficiency")
        case "Sleep Stress": return .sleepStress
        default: return .scoreTrend(title)
        }
    }
}

private struct NativeContinuityNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private struct NativeContinuityActiveIDKey: EnvironmentKey {
    static let defaultValue = Binding<NativeContinuityID?>(
        get: { nil },
        set: { _ in }
    )
}

extension EnvironmentValues {
    /// The current tab stack's zoom namespace. Set by `nativeContinuityStack()`.
    var nativeContinuityNamespace: Namespace.ID? {
        get { self[NativeContinuityNamespaceKey.self] }
        set { self[NativeContinuityNamespaceKey.self] = newValue }
    }

    /// The source that the in-flight push or sheet should zoom from.
    var nativeContinuityActiveID: Binding<NativeContinuityID?> {
        get { self[NativeContinuityActiveIDKey.self] }
        set { self[NativeContinuityActiveIDKey.self] = newValue }
    }
}

extension Binding where Value == NativeContinuityID? {
    func select(_ id: NativeContinuityID) {
        wrappedValue = id
    }
}

/// One namespace + active source ID for a `NavigationStack`. Apply on the stack
/// (alongside `nativeNavigationPath`) so pushed destinations inherit both.
private struct NativeContinuityStackModifier: ViewModifier {
    @Namespace private var namespace
    @State private var activeID: NativeContinuityID?

    func body(content: Content) -> some View {
        content
            .environment(\.nativeContinuityNamespace, namespace)
            .environment(\.nativeContinuityActiveID, $activeID)
    }
}

private struct NativeZoomSourceModifier: ViewModifier {
    var id: NativeContinuityID
    @Environment(\.nativeContinuityNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            NativeZoomSourceIOS18(
                id: id,
                namespace: namespace,
                reduceMotion: reduceMotion,
                content: content
            )
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct NativeZoomDestinationModifier: ViewModifier {
    var fallback: NativeContinuityID
    @Environment(\.nativeContinuityNamespace) private var namespace
    @Environment(\.nativeContinuityActiveID) private var activeID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var captured: NativeContinuityID?

    private var resolved: NativeContinuityID {
        captured ?? activeID.wrappedValue ?? fallback
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                if captured == nil {
                    captured = activeID.wrappedValue ?? fallback
                }
            }
            .modifier(
                NativeZoomDestinationApply(
                    id: resolved,
                    namespace: namespace,
                    reduceMotion: reduceMotion
                )
            )
    }
}

private struct NativeZoomDestinationApply: ViewModifier {
    var id: NativeContinuityID
    var namespace: Namespace.ID?
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            NativeZoomDestinationIOS18(
                id: id,
                namespace: namespace,
                reduceMotion: reduceMotion,
                content: content
            )
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(iOS)
@available(iOS 18.0, *)
private struct NativeZoomSourceIOS18<Content: View>: View {
    var id: NativeContinuityID
    var namespace: Namespace.ID?
    var reduceMotion: Bool
    var content: Content

    var body: some View {
        if let namespace, NativeContinuity.allowsZoom(reduceMotion: reduceMotion) {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct NativeZoomDestinationIOS18<Content: View>: View {
    var id: NativeContinuityID
    var namespace: Namespace.ID?
    var reduceMotion: Bool
    var content: Content

    var body: some View {
        if let namespace, NativeContinuity.allowsZoom(reduceMotion: reduceMotion) {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}
#endif

extension View {
    /// Injects a zoom namespace and active-source binding for this stack.
    func nativeContinuityStack() -> some View {
        modifier(NativeContinuityStackModifier())
    }

    /// Marks this view as the zoom source for a later push or sheet.
    func nativeZoomSource(_ id: NativeContinuityID) -> some View {
        modifier(NativeZoomSourceModifier(id: id))
    }

    /// Zooms this destination out of `nativeContinuityActiveID`, or `fallback`
    /// when nothing was selected (deep link / first launch).
    func nativeZoomDestination(fallback: NativeContinuityID) -> some View {
        modifier(NativeZoomDestinationModifier(fallback: fallback))
    }
}

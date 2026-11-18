import SwiftUI
import StrandDesign

/// Presentation language for the Native shell. Same screens and facts; two drawings.
enum NativeStyle: String, CaseIterable, Identifiable {
    case apple
    case whoop

    var id: String { rawValue }
    static let storageKey = "noop.nativeStyle"

    var label: String {
        switch self {
        case .apple: return "Apple"
        case .whoop: return "WHOOP"
        }
    }

    /// Apple Health chrome that keeps WHOOP's rings, contributor bands, and chart marks.
    var isHybrid: Bool { self == .apple }

    /// Appearance is Apple Health chrome. The WHOOP case stays on the enum so parallel
    /// callers compile, but resolve never returns it.
    static func resolve(_ raw: String) -> NativeStyle {
        _ = raw
        return .apple
    }
}

private struct NativeStyleKey: EnvironmentKey {
    static let defaultValue: NativeStyle = .apple
}

extension EnvironmentValues {
    /// Apple Health chrome or WHOOP-faithful chrome. Destinations do not inherit
    /// this; re-inject with `NativeStyleBridge` (see `NativeDaySelection`).
    var nativeStyle: NativeStyle {
        get { self[NativeStyleKey.self] }
        set { self[NativeStyleKey.self] = newValue }
    }
}

/// Pushes Apple Health chrome into the environment. Apply at the Native root
/// and at every navigation destination. `override` is unused: WHOOP color mode
/// is gone; the app follows the system light/dark appearance.
struct NativeStyleBridge: ViewModifier {
    var override: NativeStyle? = nil

    func body(content: Content) -> some View {
        content
            .environment(\.nativeStyle, .apple)
            .preferredColorScheme(nil)
    }
}

extension View {
    func nativeStyleBridge(override: NativeStyle? = nil) -> some View {
        modifier(NativeStyleBridge(override: override))
    }
}

enum NativePaint {
    static func page(_ style: NativeStyle) -> Color {
        style == .whoop ? NativeTokens.whoopPage : NativeTokens.page
    }

    static func card(_ style: NativeStyle) -> Color {
        style == .whoop ? NativeTokens.whoopCard : NativeTokens.card
    }

    static func separator(_ style: NativeStyle) -> Color {
        style == .whoop ? NativeTokens.whoopSeparator : NativeTokens.separator
    }

    static func sleep(_ style: NativeStyle) -> Color {
        style == .whoop ? NativeTokens.whoopSleep : NativeTokens.sleep
    }

    static func strain(_ style: NativeStyle) -> Color {
        style == .whoop ? NativeTokens.whoopStrain : NativeTokens.strain
    }

    static func recovery(_ style: NativeStyle) -> Color {
        style == .whoop ? NativeTokens.whoopRecoveryHigh : NativeTokens.recoveryHigh
    }

    static func heart(_ style: NativeStyle) -> Color {
        style == .whoop ? NativeTokens.whoopHeart : NativeTokens.heart
    }

    static func respiratory(_ style: NativeStyle) -> Color {
        style == .whoop ? NativeTokens.whoopRespiratory : NativeTokens.respiratory
    }

    static func activity(_ style: NativeStyle) -> Color {
        style == .whoop ? NativeTokens.whoopActivity : NativeTokens.activity
    }

    static func recoveryBand(_ value: Double, style: NativeStyle) -> Color {
        style == .whoop ? NativeTokens.whoopRecoveryBand(value) : NativeTokens.recoveryBand(value)
    }

    static func sleepBand(_ percent: Double, style: NativeStyle) -> Color {
        style == .whoop ? NativeTokens.whoopSleepBand(percent) : NativeTokens.sleepBand(percent)
    }

    static func positiveDelta(_ style: NativeStyle) -> Color {
        style == .whoop ? NativeTokens.whoopPositiveDelta : NativeTokens.positiveDelta
    }

    static func negativeDelta(_ style: NativeStyle) -> Color {
        style == .whoop ? NativeTokens.whoopNegativeDelta : NativeTokens.negativeDelta
    }

    static func stressBand(_ value: Double, style: NativeStyle) -> Color {
        if style == .whoop {
            if value < 1 { return NativeTokens.whoopStressLow }
            if value < 2 { return NativeTokens.whoopStressMid }
            return NativeTokens.whoopStressHigh
        }
        return NativeChrome.stressBandColor(value)
    }

    static func sleepStage(named name: String, style: NativeStyle) -> Color {
        switch NativeSleepStageKind.parse(name) {
        case .awake:
            return style == .whoop ? NativeTokens.whoopSleepAwake : NativeChrome.sleepAwake
        case .rem:
            return style == .whoop ? NativeTokens.whoopSleepREM : NativeChrome.sleepREM
        case .deep:
            return style == .whoop ? NativeTokens.whoopSleepDeep : NativeChrome.sleepDeep
        case .light:
            return style == .whoop ? NativeTokens.whoopSleepLight : NativeChrome.sleepLight
        }
    }

    static func cardRadius(_ style: NativeStyle) -> CGFloat {
        style == .whoop ? NativeTokens.whoopCardRadius : NativeChrome.cardRadius
    }

    static func number(_ size: CGFloat, weight: Font.Weight = .bold, style: NativeStyle) -> Font {
        style == .whoop ? NativeTokens.whoopNumber(size, weight: weight) : StrandFont.rounded(size, weight: weight)
    }
}

/// Mini three-dash Poor / Sufficient / Optimal band used on contributor rows.
struct NativeWhoopBandTick: View {
    var percent: Double
    @Environment(\.nativeStyle) private var style

    var body: some View {
        HStack(spacing: 3) {
            capsule(poor, active: percent < 70)
            capsule(sufficient, active: percent >= 70 && percent < 85)
            capsule(optimal, active: percent >= 85)
        }
        .accessibilityHidden(true)
    }

    private var poor: Color {
        style == .whoop ? NativeTokens.whoopBandPoor : NativeTokens.bandPoor
    }
    private var sufficient: Color {
        style == .whoop ? NativeTokens.whoopBandSufficient : NativeTokens.bandSufficient
    }
    private var optimal: Color {
        style == .whoop ? NativeTokens.whoopBandOptimal : NativeTokens.bandOptimal
    }

    private func capsule(_ color: Color, active: Bool) -> some View {
        Capsule()
            .fill(active ? color : color.opacity(0.28))
            .frame(width: 18, height: 5)
    }
}

/// Poor / Sufficient / Optimal key under Sleep contributors.
struct NativeWhoopBandLegend: View {
    @Environment(\.nativeStyle) private var style

    var body: some View {
        if style == .whoop {
            whoop
        } else {
            hybrid
        }
    }

    private var hybrid: some View {
        HStack(spacing: 10) {
            legend(NativeTokens.bandPoor, "Poor")
            legend(NativeTokens.bandSufficient, "Sufficient")
            legend(NativeTokens.bandOptimal, "Optimal")
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Poor, Sufficient, Optimal")
    }

    private var whoop: some View {
        HStack(spacing: 12) {
            legend(NativeTokens.whoopBandPoor, "Poor")
            legend(NativeTokens.whoopBandSufficient, "Sufficient")
            legend(NativeTokens.whoopBandOptimal, "Optimal")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Poor, Sufficient, Optimal")
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 10, height: 6)
            Text(title)
                .font(style == .whoop ? NativeTokens.whoopCaps(11) : .caption)
                .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
        }
    }
}

/// Diagonal hatch used as the typical-range track on Last Night stage rows.
struct NativeWhoopHatch: View {
    var color: Color = NativeTokens.whoopHatch

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 5
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(color), lineWidth: 1.15)
                x += step
            }
        }
        .mask(Capsule())
        .opacity(0.85)
        .accessibilityHidden(true)
    }
}

/// Last Night stage: name, %, duration, pill + hatched typical.
struct NativeWhoopStageRow: View {
    var stage: NativeStage
    var total: Double
    @Environment(\.nativeStyle) private var style

    var body: some View {
        let minutes = stage.minutes ?? 0
        let typical = stage.typical ?? 0
        let tint = NativePaint.sleepStage(named: stage.name, style: style)
        let share = total > 0 ? minutes / total : 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(tint, lineWidth: 2)
                    .frame(width: 14, height: 14)
                Text(stageLabel)
                    .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline.weight(.semibold))
                    .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                    .foregroundStyle(Color.primary)
                Text("\(Int((share * 100).rounded()))%")
                    .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline)
                    .foregroundStyle(tint)
                Spacer(minLength: 8)
                Text(NativeScoreMath.duration(minutes))
                    .font(style == .whoop ? NativeTokens.whoopNumber(17, weight: .semibold) : StrandFont.rounded(17, weight: .semibold))
                    .monospacedDigit()
            }
            NativeWhoopRangeBar(minutes: minutes, typical: typical, tint: tint)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stageLabel), \(NativeScoreMath.duration(minutes)), \(Int((share * 100).rounded())) percent")
    }

    private var stageLabel: String {
        if style == .whoop {
            if stage.name == "Light" { return "LIGHT" }
            if stage.name == "Deep" { return "SWS (DEEP)" }
            return stage.name.uppercased()
        }
        if stage.name == "Deep" { return "Deep" }
        if stage.name == "Light" { return "Light" }
        return stage.name
    }
}

struct NativeWhoopRangeBar: View {
    var minutes: Double
    var typical: Double
    var tint: Color
    @Environment(\.nativeStyle) private var style

    var body: some View {
        GeometryReader { geo in
            let ceiling = max(max(minutes, typical) * 1.35, 1)
            let width = geo.size.width
            ZStack(alignment: .leading) {
                NativeWhoopHatch(color: style == .whoop ? NativeTokens.whoopHatch : NativeTokens.separator)
                    .frame(width: width, height: 10)
                Capsule()
                    .fill(tint)
                    .frame(width: max(6, width * CGFloat(minutes / ceiling)), height: 10)
                if typical > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 2, height: 16)
                        .offset(x: max(0, width * CGFloat(typical / ceiling) - 1))
                }
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

/// Page fill: Apple grouped colour, or WHOOP's near-black gradient.
struct NativePageFill: View {
    @Environment(\.nativeStyle) private var style

    var body: some View {
        if style == .whoop {
            LinearGradient(
                colors: [NativeTokens.whoopPageTop, NativeTokens.whoopPage],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            NativeTokens.page
        }
    }
}

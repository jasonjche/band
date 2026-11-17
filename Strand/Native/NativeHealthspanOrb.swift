import SwiftUI
import StrandDesign

/// Visual language for the Band Age hero. Persisted as `band.orbStyle`.
enum NativeHealthspanOrbStyle: String, CaseIterable, Identifiable {
    case ring
    case bloom
    case glass

    var id: String { rawValue }

    /// `@AppStorage` / `defaults write` key. Unset resolves to `ring`.
    static let storageKey = "band.orbStyle"
}

/// Delta → ring fill and hue. Pure so StrandTests can cover it without rendering.
enum NativeHealthspanOrbMap {
    static let deltaSpan: Double = 5
    static let deadband: Double = 0.05

    /// 0 at 5 years older, 1 at 5 years younger. Nil delta sits at 0.5.
    static func fillFraction(delta: Double?) -> Double {
        guard let delta else { return 0.5 }
        let clamped = min(max(delta, -deltaSpan), deltaSpan)
        return (clamped + deltaSpan) / (2 * deltaSpan)
    }

    static func tone(delta: Double?, isLoading: Bool) -> NativeHealthspanOrbTone {
        NativeHealthspanOrbTone.resolve(delta: delta, isLoading: isLoading)
    }
}

enum NativeHealthspanOrbTone: Equatable {
    case younger
    case older
    case neutral
    case loading

    static func resolve(delta: Double?, isLoading: Bool) -> NativeHealthspanOrbTone {
        if isLoading { return .loading }
        guard let delta, abs(delta) >= NativeHealthspanOrbMap.deadband else { return .neutral }
        return delta > 0 ? .younger : .older
    }
}

/// Band Age hero. Apple Watch Activity / Mindfulness / glass — not a WHOOP particle ball.
struct NativeHealthspanOrb: View {
    var value: Double?
    var delta: Double?
    var isLoading: Bool
    var compact: Bool = false
    var reduceMotion: Bool = false

    @AppStorage(NativeHealthspanOrbStyle.storageKey) private var styleRaw = NativeHealthspanOrbStyle.ring.rawValue
    @Environment(\.nativeStyle) private var nativeStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var onScreen = false
    @State private var drawn: Double = 0

    private var orbStyle: NativeHealthspanOrbStyle {
        NativeHealthspanOrbStyle(rawValue: styleRaw) ?? .ring
    }
    private var poseStill: Bool { motion.poseStill(reduceMotion) }
    private var live: Bool { onScreen && scenePhase == .active && !poseStill }
    private var size: CGFloat { compact ? NativeHealthspanOrbLayout.compactSize : NativeHealthspanOrbLayout.heroSize }
    private var tone: NativeHealthspanOrbTone { NativeHealthspanOrbMap.tone(delta: delta, isLoading: isLoading) }
    private var targetFill: Double {
        isLoading ? 0 : NativeHealthspanOrbMap.fillFraction(delta: delta)
    }
    /// Ring only ticks while loading so the pulse can run; bloom/glass tick whenever live.
    private var clockPaused: Bool {
        compact || !live || (orbStyle == .ring && !isLoading)
    }

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: NativeHealthspanOrbLayout.clockInterval, paused: clockPaused)) { timeline in
                let t = clockPaused ? 0 : timeline.date.timeIntervalSinceReferenceDate
                artwork(t: t)
                    .frame(width: size, height: size)
            }
            .frame(width: size, height: size)
            if !compact {
                labels
            }
        }
        .frame(width: size, height: size)
        .modifier(NativeHealthspanGlassRim(enabled: orbStyle == .glass && !isLoading && !compact, size: size))
        .animation(poseStill ? nil : NativeHealthspanOrbLayout.crossFade, value: isLoading)
        .onAppear {
            onScreen = true
            armFill(fromZero: true)
        }
        .onDisappear { onScreen = false }
        .onChangeCompat(of: isLoading) { loading in
            armFill(fromZero: !loading)
        }
        .onChangeCompat(of: delta) { _ in
            guard !isLoading else { return }
            armFill(fromZero: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if isLoading { return "Computing Band Age" }
        let age = value.map(NativeHealthspanFormat.ageText) ?? "unavailable"
        if let delta {
            return "Band Age \(age), \(NativeHealthspanFormat.youngerText(delta))"
        }
        return "Band Age \(age)"
    }

    @ViewBuilder
    private func artwork(t: TimeInterval) -> some View {
        let pulse: CGFloat = {
            guard isLoading else { return 1 }
            guard live, !compact else { return 0.72 }
            return 0.58 + 0.42 * CGFloat(0.5 + 0.5 * sin(t * 2 * .pi / NativeHealthspanOrbLayout.pulsePeriod))
        }()
        ZStack {
            switch orbStyle {
            case .ring:
                NativeHealthspanRingOrb(
                    fill: drawn,
                    tone: tone,
                    size: size,
                    nativeStyle: nativeStyle
                )
            case .bloom:
                NativeHealthspanBloomOrb(
                    t: t,
                    live: live && !isLoading,
                    tone: tone,
                    size: size,
                    nativeStyle: nativeStyle,
                    colorScheme: colorScheme
                )
            case .glass:
                NativeHealthspanGlassOrb(
                    t: t,
                    live: live && !isLoading,
                    tone: tone,
                    size: size,
                    nativeStyle: nativeStyle,
                    colorScheme: colorScheme
                )
            }
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .saturation(isLoading ? 0.18 : 1)
        .opacity(pulse)
    }

    private var labels: some View {
        VStack(spacing: NativeHealthspanOrbLayout.labelSpacing) {
            ageLabel
            Text("BAND AGE")
                .font(NativeTokens.whoopCaps(11))
                .tracking(NativeTokens.whoopCapsTracking)
                .foregroundStyle(.secondary)
            deltaLabel
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, NativeHealthspanOrbLayout.labelInset)
    }

    @ViewBuilder
    private var ageLabel: some View {
        let text = isLoading ? "00.0" : (value.map(NativeHealthspanFormat.ageText) ?? "—")
        Text(text)
            .font(NativeTokens.whoopNumber(NativeHealthspanOrbLayout.numberSize, weight: .semibold))
            .tracking(StrandFont.displayTracking(NativeHealthspanOrbLayout.numberSize))
            .monospacedDigit()
            .foregroundStyle(Color.primary)
            .redacted(reason: isLoading ? .placeholder : [])
            .healthspanNumericText(reduceMotion: poseStill)
    }

    @ViewBuilder
    private var deltaLabel: some View {
        if isLoading {
            Capsule()
                .fill(NativePaint.separator(nativeStyle).opacity(0.45))
                .frame(width: 120, height: 12)
                .redacted(reason: .placeholder)
        } else if let delta {
            Text(NativeHealthspanFormat.youngerText(delta))
                .font(NativeTokens.whoopNumber(15, weight: .semibold))
                .foregroundStyle(deltaColor(delta))
        }
    }

    private func deltaColor(_ delta: Double) -> Color {
        if abs(delta) < NativeHealthspanOrbMap.deadband { return Color.primary }
        return delta > 0 ? NativePaint.positiveDelta(nativeStyle) : NativePaint.negativeDelta(nativeStyle)
    }

    private func armFill(fromZero: Bool) {
        let target = targetFill
        if poseStill || compact {
            var transaction = Transaction(animation: nil)
            withTransaction(transaction) { drawn = target }
            return
        }
        if fromZero, drawn != 0 {
            var transaction = Transaction(animation: nil)
            withTransaction(transaction) { drawn = 0 }
        }
        withAnimation(NativeHealthspanOrbLayout.fillSpring) { drawn = target }
    }
}

/// Compact WHOOP-style header: years younger | small orb | pace.
struct NativeHealthspanCompactHeader: View {
    var bandAge: Double?
    var deltaYears: Double?
    var pace: Double?
    var forming: Bool
    @Environment(\.nativeStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            side(
                value: deltaYears.map(NativeHealthspanFormat.compactDeltaValue) ?? "—",
                caption: deltaYears.map(NativeHealthspanFormat.compactDeltaCaption) ?? "YEARS",
                tint: deltaTint
            )
            NativeHealthspanOrb(
                value: bandAge,
                delta: deltaYears,
                isLoading: forming,
                compact: true,
                reduceMotion: reduceMotion
            )
            side(
                value: pace.map(NativeHealthspanFormat.paceText) ?? "—",
                caption: "PACE OF AGING",
                tint: Color.primary
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(NativePageFill().opacity(0.92))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(compactLabel)
    }

    private var deltaTint: Color {
        guard let delta = deltaYears else { return .secondary }
        if abs(delta) < NativeHealthspanOrbMap.deadband { return Color.primary }
        return delta > 0 ? NativePaint.positiveDelta(style) : NativePaint.negativeDelta(style)
    }

    private var compactLabel: String {
        let age = bandAge.map(NativeHealthspanFormat.ageText) ?? "unavailable"
        let delta = deltaYears.map(NativeHealthspanFormat.youngerText) ?? ""
        let paceText = pace.map(NativeHealthspanFormat.paceText) ?? "unavailable"
        return "Band Age \(age), \(delta), Pace of Aging \(paceText)"
    }

    private func side(value: String, caption: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(NativePaint.number(22, weight: .bold, style: style))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(caption)
                .font(style == .whoop ? NativeTokens.whoopCaps(9) : .caption2.weight(.semibold))
                .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0.6)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

enum NativeHealthspanOrbLayout {
    static let heroSize: CGFloat = 220
    static let compactSize: CGFloat = 44
    static let numberSize: CGFloat = 44
    static let labelSpacing: CGFloat = 4
    static let labelInset: CGFloat = 28
    static let petalCount = 7
    static let bloomRevolution: TimeInterval = 36
    static let breathPeriod: TimeInterval = 6
    static let pulsePeriod: TimeInterval = 1.2
    static let glassDriftPeriod: TimeInterval = 22
    static let clockInterval: TimeInterval = 1.0 / 12.0
    static let fillSpring = Animation.spring(response: 0.6, dampingFraction: 1.0)
    static let crossFade = Animation.easeInOut(duration: 0.45)

    static func lineWidth(size: CGFloat) -> CGFloat { max(4, size * 0.09) }

    static func petalAngle(_ index: Int) -> Double {
        Double(index) * 2 * Double.pi / Double(petalCount)
    }
}

enum NativeHealthspanOrbSwatch {
    static func lead(_ tone: NativeHealthspanOrbTone, style: NativeStyle) -> Color {
        switch tone {
        case .younger: return NativePaint.recovery(style)
        case .older: return NativePaint.negativeDelta(style)
        case .neutral: return Color.secondary
        case .loading: return NativePaint.separator(style)
        }
    }

    static func trail(_ tone: NativeHealthspanOrbTone, style: NativeStyle) -> Color {
        switch tone {
        case .younger: return NativePaint.respiratory(style)
        case .older: return NativePaint.activity(style)
        case .neutral: return NativePaint.separator(style)
        case .loading: return NativePaint.separator(style)
        }
    }
}

/// Apple Watch Activity / Vitals: thick round-capped gradient ring over a faint track.
private struct NativeHealthspanRingOrb: View {
    var fill: Double
    var tone: NativeHealthspanOrbTone
    var size: CGFloat
    var nativeStyle: NativeStyle

    var body: some View {
        let width = NativeHealthspanOrbLayout.lineWidth(size: size)
        let lead = NativeHealthspanOrbSwatch.lead(tone, style: nativeStyle)
        let trail = NativeHealthspanOrbSwatch.trail(tone, style: nativeStyle)
        let inset = width / 2 + 1
        ZStack {
            Circle()
                .stroke(
                    lead.opacity(NativeTokens.trackOpacity),
                    style: StrokeStyle(lineWidth: width, lineCap: .round)
                )
            if fill > 0.001 {
                arc(fill: fill)
                    .stroke(
                        lead.opacity(0.28),
                        style: StrokeStyle(lineWidth: width * 2.4, lineCap: .round)
                    )
                    .blur(radius: size > 80 ? 6 : 0)
                    .allowsHitTesting(false)
                arc(fill: fill)
                    .stroke(
                        AngularGradient(colors: [lead, trail, lead], center: .center),
                        style: StrokeStyle(lineWidth: width, lineCap: .round)
                    )
            }
        }
        .padding(inset)
        .frame(width: size, height: size)
    }

    private func arc(fill: Double) -> some Shape {
        Circle()
            .trim(from: 0, to: CGFloat(min(max(fill, 0.001), 1)))
            .rotation(.degrees(-90))
    }
}

/// Apple Mindfulness / Breathe: overlapping translucent petals, slow spin, gentle breath.
private struct NativeHealthspanBloomOrb: View {
    var t: TimeInterval
    var live: Bool
    var tone: NativeHealthspanOrbTone
    var size: CGFloat
    var nativeStyle: NativeStyle
    var colorScheme: ColorScheme

    var body: some View {
        let lead = NativeHealthspanOrbSwatch.lead(tone, style: nativeStyle)
        let trail = NativeHealthspanOrbSwatch.trail(tone, style: nativeStyle)
        let turn = live ? t / NativeHealthspanOrbLayout.bloomRevolution * 360 : 0
        let breath = live ? 1 + 0.03 * sin(t * 2 * .pi / NativeHealthspanOrbLayout.breathPeriod) : 1
        let petalSize = size * 0.54
        let offset = size * 0.20
        ZStack {
            ForEach(0..<NativeHealthspanOrbLayout.petalCount, id: \.self) { i in
                let angle = NativeHealthspanOrbLayout.petalAngle(i)
                Circle()
                    .fill(i.isMultiple(of: 2) ? lead.opacity(0.42) : trail.opacity(0.36))
                    .frame(width: petalSize, height: petalSize)
                    .offset(x: CGFloat(cos(angle)) * offset, y: CGFloat(sin(angle)) * offset)
            }
        }
        .blendMode(colorScheme == .dark ? .plusLighter : .normal)
        .rotationEffect(.degrees(turn))
        .scaleEffect(breath)
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .fill(NativePaint.page(nativeStyle).opacity(colorScheme == .dark ? 0.72 : 0.88))
                .frame(width: size * 0.46, height: size * 0.46)
        }
    }
}

/// Dimensional sphere: dark falloff, top-left specular, tinted rim, slow colour drift. No particles.
private struct NativeHealthspanGlassOrb: View {
    var t: TimeInterval
    var live: Bool
    var tone: NativeHealthspanOrbTone
    var size: CGFloat
    var nativeStyle: NativeStyle
    var colorScheme: ColorScheme

    var body: some View {
        let lead = NativeHealthspanOrbSwatch.lead(tone, style: nativeStyle)
        let trail = NativeHealthspanOrbSwatch.trail(tone, style: nativeStyle)
        let drift = live ? sin(t * 2 * .pi / NativeHealthspanOrbLayout.glassDriftPeriod) * 0.05 : 0
        let specular = colorScheme == .dark ? Color.primary.opacity(0.55) : NativeTokens.card.opacity(0.92)
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            NativePaint.card(nativeStyle),
                            NativePaint.page(nativeStyle),
                            NativePaint.page(nativeStyle).opacity(0.92)
                        ],
                        center: UnitPoint(x: 0.38 + drift, y: 0.32),
                        startRadius: 0,
                        endRadius: size * 0.62
                    )
                )
            ZStack {
                Circle()
                    .fill(lead.opacity(0.22))
                    .blur(radius: size > 80 ? 18 : 4)
                    .offset(x: CGFloat(drift) * size * 0.4, y: CGFloat(-drift) * size * 0.15)
                Circle()
                    .fill(trail.opacity(0.16))
                    .blur(radius: size > 80 ? 14 : 3)
                    .offset(x: CGFloat(-drift) * size * 0.35, y: size * 0.12)
            }
            .mask(Circle())
            Circle()
                .fill(
                    RadialGradient(
                        colors: [specular, specular.opacity(0)],
                        center: UnitPoint(x: 0.30, y: 0.26),
                        startRadius: 0,
                        endRadius: size * 0.28
                    )
                )
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [lead.opacity(0.95), trail.opacity(0.45), lead.opacity(0.2), lead.opacity(0.95)],
                        center: .center
                    ),
                    lineWidth: max(1.25, size * 0.018)
                )
        }
        .frame(width: size, height: size)
    }
}

/// iOS 26 Liquid Glass on a thin outer rim only. Body stays a normal gradient (HIG: glass is for controls).
private struct NativeHealthspanGlassRim: ViewModifier {
    var enabled: Bool
    var size: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        content.background {
            if enabled {
                glassPlate
            }
        }
    }

    @ViewBuilder
    private var glassPlate: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            Circle()
                .fill(Color.clear)
                .frame(width: size + 10, height: size + 10)
                .glassEffect(.regular, in: Circle())
                .allowsHitTesting(false)
        }
        #endif
    }
}

private extension View {
    @ViewBuilder func healthspanNumericText(reduceMotion: Bool) -> some View {
        if reduceMotion {
            self
        } else if #available(iOS 17.0, macOS 14.0, *) {
            self.contentTransition(.numericText())
        } else {
            self
        }
    }
}

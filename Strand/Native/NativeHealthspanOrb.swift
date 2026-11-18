import SwiftUI
import StrandDesign

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

/// Band Age hero. Apple Watch Activity ring — colour carries younger/older.
struct NativeHealthspanOrb: View {
    var value: Double?
    var delta: Double?
    var isLoading: Bool
    var compact: Bool = false
    var reduceMotion: Bool = false

    @Environment(\.nativeStyle) private var nativeStyle
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var onScreen = false
    @State private var drawn: Double = 0

    private var poseStill: Bool { motion.poseStill(reduceMotion) }
    private var live: Bool { onScreen && scenePhase == .active && !poseStill }
    private var size: CGFloat { compact ? NativeHealthspanOrbLayout.compactSize : NativeHealthspanOrbLayout.heroSize }
    private var tone: NativeHealthspanOrbTone { NativeHealthspanOrbMap.tone(delta: delta, isLoading: isLoading) }
    private var targetFill: Double {
        if isLoading { return 0 }
        // The ring closes once loaded: a partial arc implied a scale the number doesn't have.
        // Colour carries younger/older; the draw-in on load is the only motion.
        return 1
    }
    /// Ring only ticks while loading so the pulse can run.
    private var clockPaused: Bool {
        compact || !live || !isLoading
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
            NativeHealthspanRingOrb(
                fill: drawn,
                tone: tone,
                size: size,
                nativeStyle: nativeStyle
            )
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

enum NativeHealthspanOrbLayout {
    static let heroSize: CGFloat = 220
    static let compactSize: CGFloat = 44
    static let numberSize: CGFloat = 44
    static let labelSpacing: CGFloat = 4
    static let labelInset: CGFloat = 28
    static let pulsePeriod: TimeInterval = 1.2
    static let clockInterval: TimeInterval = 1.0 / 12.0
    static let fillSpring = Animation.spring(response: 0.6, dampingFraction: 1.0)
    static let crossFade = Animation.easeInOut(duration: 0.45)

    static func lineWidth(size: CGFloat) -> CGFloat { max(4, size * 0.09) }
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
        // A full ring is a plain circle, so no round-cap seam shows at the top.
        Circle()
            .trim(from: 0, to: fill >= 0.999 ? 1 : CGFloat(min(max(fill, 0.001), 1)))
            .rotation(.degrees(-90))
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

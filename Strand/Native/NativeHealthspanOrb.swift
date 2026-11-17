import SwiftUI
import StrandDesign

/// Soft living sphere for Band Age. Apple Watch Mindfulness / Siri glow, not a WHOOP particle storm.
struct NativeHealthspanOrb: View {
    var bandAge: Double?
    var deltaYears: Double?
    var forming: Bool
    var diameter: CGFloat = 280
    var showsCaption: Bool = true
    var showsDelta: Bool = true
    /// Compact header keeps a still frame so two orbs are not both on a 30 fps clock.
    var animates: Bool = true

    @Environment(\.nativeStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var onScreen = false

    private var poseStill: Bool { motion.poseStill(reduceMotion) }
    private var live: Bool { animates && onScreen && scenePhase == .active && !poseStill }
    private var hue: NativeHealthspanOrbHue {
        NativeHealthspanOrbHue.resolve(deltaYears: deltaYears, forming: forming)
    }

    var body: some View {
        ZStack {
            if live {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    orbLayers(t: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                orbLayers(t: 0)
            }
            labels
        }
        .frame(width: diameter, height: diameter)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if forming { return "Computing Band Age" }
        let age = bandAge.map(NativeHealthspanFormat.ageText) ?? "unavailable"
        if let delta = deltaYears {
            return "Band Age \(age), \(NativeHealthspanFormat.youngerText(delta))"
        }
        return "Band Age \(age)"
    }

    @ViewBuilder
    private func orbLayers(t: TimeInterval) -> some View {
        let breath = live ? 1 + 0.02 * sin(t * 2 * .pi / (forming ? 6.4 : 4.6)) : 1
        ZStack {
            fill(t: t)
            NativeHealthspanOrbParticles(t: t, hue: hue, style: style, live: live)
            glow
        }
        .clipShape(Circle())
        .scaleEffect(breath)
        .saturation(forming ? 0.38 : 1)
        .opacity(forming ? 0.88 : 1)
    }

    @ViewBuilder
    private func fill(t: TimeInterval) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            NativeHealthspanMeshFill(t: live ? t : 0, hue: hue, style: style)
        } else {
            NativeHealthspanFallbackFill(t: live ? t : 0, hue: hue, style: style)
        }
    }

    private var glow: some View {
        let rim = NativeHealthspanOrbPalette.rim(hue, style: style)
        return RadialGradient(
            colors: [Color.clear, Color.clear, rim.opacity(0.55)],
            center: .center,
            startRadius: diameter * 0.22,
            endRadius: diameter * 0.5
        )
        .allowsHitTesting(false)
    }

    private var labels: some View {
        VStack(spacing: 6) {
            ageLabel
            if showsCaption {
                Text("BAND AGE")
                    .font(style == .whoop ? NativeTokens.whoopCaps(12) : .footnote.weight(.semibold))
                    .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 1.2)
                    .foregroundStyle(.secondary)
            }
            if showsCaption, showsDelta {
                deltaLabel
            }
        }
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private var ageLabel: some View {
        let text = forming ? "00.0" : (bandAge.map(NativeHealthspanFormat.ageText) ?? "—")
        Text(text)
            .font(NativePaint.number(diameter > 160 ? 56 : 22, weight: .bold, style: style))
            .monospacedDigit()
            .foregroundStyle(Color.primary)
            .redacted(reason: forming ? .placeholder : [])
            .healthspanNumericText(reduceMotion: poseStill)
    }

    @ViewBuilder
    private var deltaLabel: some View {
        if forming {
            Capsule()
                .fill(NativePaint.separator(style).opacity(0.45))
                .frame(width: 132, height: 14)
                .redacted(reason: .placeholder)
        } else if let delta = deltaYears {
            Text(NativeHealthspanFormat.youngerText(delta))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(deltaColor(delta))
                .multilineTextAlignment(.center)
        }
    }

    private func deltaColor(_ delta: Double) -> Color {
        if abs(delta) < 0.05 { return Color.primary }
        return delta > 0 ? NativePaint.positiveDelta(style) : NativePaint.negativeDelta(style)
    }
}

/// Compact WHOOP-style header: years younger | small orb | pace.
struct NativeHealthspanCompactHeader: View {
    var bandAge: Double?
    var deltaYears: Double?
    var pace: Double?
    var forming: Bool
    @Environment(\.nativeStyle) private var style

    var body: some View {
        HStack(spacing: 8) {
            side(
                value: deltaYears.map(NativeHealthspanFormat.compactDeltaValue) ?? "—",
                caption: deltaYears.map(NativeHealthspanFormat.compactDeltaCaption) ?? "YEARS",
                tint: deltaTint
            )
            NativeHealthspanOrb(
                bandAge: bandAge,
                deltaYears: deltaYears,
                forming: forming,
                diameter: 72,
                showsCaption: true,
                showsDelta: false,
                animates: false
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
        if abs(delta) < 0.05 { return Color.primary }
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

enum NativeHealthspanOrbPalette {
    static func rim(_ hue: NativeHealthspanOrbHue, style: NativeStyle) -> Color {
        switch hue {
        case .younger: return NativePaint.recovery(style)
        case .older: return NativePaint.negativeDelta(style)
        case .mixed: return NativePaint.sleep(style)
        case .forming: return NativePaint.separator(style)
        }
    }

    static func mint(_ style: NativeStyle) -> Color {
        NativePaint.recovery(style)
    }

    static func teal(_ style: NativeStyle) -> Color {
        NativePaint.sleep(style)
    }

    static func blue(_ style: NativeStyle) -> Color {
        NativePaint.respiratory(style)
    }

    static func amber(_ style: NativeStyle) -> Color {
        NativePaint.negativeDelta(style)
    }

    static func orange(_ style: NativeStyle) -> Color {
        NativePaint.activity(style)
    }
}

@available(iOS 18.0, macOS 15.0, *)
private struct NativeHealthspanMeshFill: View {
    var t: TimeInterval
    var hue: NativeHealthspanOrbHue
    var style: NativeStyle

    var body: some View {
        let drift = CGFloat(sin(t * 0.13) * 0.07)
        let driftY = CGFloat(cos(t * 0.09) * 0.05)
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                SIMD2<Float>(0.0, 0.0), SIMD2<Float>(0.5, 0.0), SIMD2<Float>(1.0, 0.0),
                SIMD2<Float>(0.0, 0.5), SIMD2<Float>(Float(0.5) + Float(drift), Float(0.5) + Float(driftY)), SIMD2<Float>(1.0, 0.5),
                SIMD2<Float>(0.0, 1.0), SIMD2<Float>(0.5, 1.0), SIMD2<Float>(1.0, 1.0)
            ],
            colors: colors
        )
    }

    private var colors: [Color] {
        let dark = NativePaint.page(style)
        let mint = NativeHealthspanOrbPalette.mint(style)
        let teal = NativeHealthspanOrbPalette.teal(style)
        let blue = NativeHealthspanOrbPalette.blue(style)
        let amber = NativeHealthspanOrbPalette.amber(style)
        let orange = NativeHealthspanOrbPalette.orange(style)
        let grey = NativePaint.separator(style)
        switch hue {
        case .younger:
            return [mint, mint, teal, teal, dark, blue, teal, blue, blue]
        case .older:
            return [amber, amber, orange, amber, dark, orange, orange, orange, amber]
        case .mixed:
            return [mint, teal, blue, amber.opacity(0.7), dark, teal, teal, blue, orange.opacity(0.6)]
        case .forming:
            return [grey, teal.opacity(0.45), grey, grey, dark, grey, grey, teal.opacity(0.35), grey]
        }
    }
}

private struct NativeHealthspanFallbackFill: View {
    var t: TimeInterval
    var hue: NativeHealthspanOrbHue
    var style: NativeStyle

    var body: some View {
        let rim = NativeHealthspanOrbPalette.rim(hue, style: style)
        let inner = NativePaint.page(style)
        let second: Color = {
            switch hue {
            case .younger: return NativeHealthspanOrbPalette.blue(style)
            case .older: return NativeHealthspanOrbPalette.orange(style)
            case .mixed: return NativeHealthspanOrbPalette.teal(style)
            case .forming: return NativePaint.separator(style)
            }
        }()
        let angle = Angle.degrees(t * 8)
        ZStack {
            RadialGradient(
                colors: [inner, rim.opacity(0.55), rim.opacity(0.15)],
                center: .center,
                startRadius: 8,
                endRadius: 160
            )
            AngularGradient(
                colors: [rim.opacity(0.0), rim.opacity(0.65), second.opacity(0.7), rim.opacity(0.0)],
                center: .center,
                angle: angle
            )
            .opacity(0.85)
        }
    }
}

/// A few drifting light points. Static seeds, no per-frame allocations, ≤ 40 dots.
private struct NativeHealthspanOrbParticles: View {
    var t: TimeInterval
    var hue: NativeHealthspanOrbHue
    var style: NativeStyle
    var live: Bool

    private static let count = 32

    var body: some View {
        let color = NativeHealthspanOrbPalette.rim(hue, style: style)
        Canvas { context, size in
            let half = min(size.width, size.height) * 0.5
            let cx = size.width * 0.5
            let cy = size.height * 0.5
            let clock = live ? t : 0
            for i in 0..<Self.count {
                let u = Double((i * 47) % 97) / 97.0
                let v = Double((i * 23) % 89) / 89.0
                let w = Double((i * 13) % 53) / 53.0
                let angle = u * 2 * .pi + clock * (0.035 + v * 0.055)
                let radius = (0.56 + v * 0.32) * half
                let x = cx + CGFloat(cos(angle)) * radius
                let y = cy + CGFloat(sin(angle) * 0.96) * radius
                let dot = 1.3 + CGFloat(w) * 2.4
                let alpha = 0.22 + w * 0.55
                let rect = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
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

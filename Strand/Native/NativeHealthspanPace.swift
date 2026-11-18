import SwiftUI
import StrandDesign

struct NativeHealthspanPaceCard: View {
    var pace: Double?
    var weekDelta: Double?
    @Environment(\.nativeStyle) private var style

    private var chip: NativeHealthspanPaceChip? {
        NativeHealthspanPaceChip.from(weekDelta: weekDelta)
    }

    var body: some View {
        NativeChrome.panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("PACE OF AGING")
                        .font(style == .whoop ? NativeTokens.whoopCaps(12) : .footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let chip {
                        NativeHealthspanPaceChipView(chip: chip)
                    }
                }
                HStack {
                    endLabel("Slow", leading: true)
                    Spacer(minLength: 8)
                    Text(pace.map(NativeHealthspanFormat.paceText) ?? "—")
                        .font(NativePaint.number(28, weight: .bold, style: style))
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    endLabel("Fast", leading: false)
                }
                NativeHealthspanPaceMeter(pace: pace ?? 1)
                HStack {
                    Text("−1.0x")
                    Spacer()
                    Text("1.0x")
                    Spacer()
                    Text("3.0x")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }

    private func endLabel(_ title: String, leading: Bool) -> some View {
        HStack(spacing: 6) {
            if leading {
                Circle()
                    .stroke(NativePaint.separator(style), lineWidth: 1.5)
                    .frame(width: 14, height: 14)
            }
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if !leading {
                Capsule()
                    .fill(NativePaint.separator(style))
                    .frame(width: 16, height: 10)
            }
        }
    }
}

struct NativeHealthspanPaceChipView: View {
    var chip: NativeHealthspanPaceChip
    @Environment(\.nativeStyle) private var style

    var body: some View {
        let tint = chip == .faster ? NativePaint.negativeDelta(style) : NativePaint.positiveDelta(style)
        HStack(spacing: 4) {
            Image(systemName: chip == .faster ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .font(.system(size: 8, weight: .bold))
            Text(chip.label)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.16)))
        .accessibilityLabel(chip.label)
    }
}

struct NativeHealthspanPaceMeter: View {
    var pace: Double
    @Environment(\.nativeStyle) private var style

    var body: some View {
        Canvas { context, size in
            let count = 41
            let midY = size.height * 0.5
            for i in 0..<count {
                let x = CGFloat(i) / CGFloat(count - 1) * size.width
                let major = i % 10 == 0
                let h: CGFloat = major ? 18 : 11
                var path = Path()
                path.move(to: CGPoint(x: x, y: midY - h / 2))
                path.addLine(to: CGPoint(x: x, y: midY + h / 2))
                context.stroke(
                    path,
                    with: .color(NativePaint.separator(style).opacity(major ? 0.9 : 0.55)),
                    lineWidth: 1
                )
            }
            let x = CGFloat(NativeHealthspanFormat.paceProgress(pace)) * size.width
            var indicator = Path()
            indicator.move(to: CGPoint(x: x, y: 0))
            indicator.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(indicator, with: .color(Color.primary), lineWidth: 3)
            var twin = Path()
            twin.move(to: CGPoint(x: x + 3, y: 2))
            twin.addLine(to: CGPoint(x: x + 3, y: size.height - 2))
            context.stroke(twin, with: .color(Color.primary.opacity(0.85)), lineWidth: 1.5)
        }
        .frame(height: 28)
        .accessibilityLabel("Pace of aging \(NativeHealthspanFormat.paceText(pace))")
    }
}

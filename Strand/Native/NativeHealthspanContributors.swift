import SwiftUI
import StrandDesign
import StrandAnalytics

struct NativeHealthspanSectionBlock: View {
    var title: String
    var rows: [HealthspanEngine.Contributor]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeHealthspanSectionHeader(title: title)
            NativeChrome.panel {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(rows, id: \.key) { row in
                        NativeHealthspanContributorRow(row: row)
                    }
                }
            }
        }
    }
}

struct NativeHealthspanSectionHeader: View {
    var title: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            NativeHealthspanAvgLegend()
        }
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

struct NativeHealthspanAvgLegend: View {
    var body: some View {
        HStack(spacing: 8) {
            legend(system: "arrowtriangle.down.fill", title: "6 Month avg")
            Text("|")
                .foregroundStyle(.tertiary)
            legend(system: "arrowtriangle.up.fill", title: "30 Day avg")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Down 6 month average, up 30 day average")
    }

    private func legend(system: String, title: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: system)
                .font(.system(size: 7, weight: .bold))
            Text(title)
        }
    }
}

struct NativeHealthspanContributorRow: View {
    var row: HealthspanEngine.Contributor
    @Environment(\.nativeStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(NoopMotion.gated(NoopMotion.card, reduced: reduceMotion)) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label.uppercased())
                        .font(style == .whoop ? NativeTokens.whoopCaps(11) : .caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapse" : "Expand for a short explanation")

            if row.available, let value = row.value {
                HStack(alignment: .center, spacing: 10) {
                    NativeHealthspanRangeBar(
                        value: value,
                        value30: row.value30,
                        scaleMin: row.scaleMin,
                        scaleMax: row.scaleMax,
                        higherIsBetter: row.higherIsBetter,
                        valueLabel: NativeHealthspanFormat.valueText(value, unit: row.unit, key: row.key),
                        minLabel: NativeHealthspanFormat.scaleLabel(row.scaleMin, key: row.key),
                        maxLabel: NativeHealthspanFormat.scaleLabel(row.scaleMax, key: row.key)
                    )
                    .equatable()
                    Text(NativeHealthspanFormat.yearsImpact(row.years, available: row.available))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(yearsColor)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 72, alignment: .trailing)
                }
            } else {
                HStack {
                    Text("Not available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("—")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if row.available, let value = row.value {
                        Text("6 Month avg. \(NativeHealthspanFormat.valueText(value, unit: row.unit, key: row.key))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let value30 = row.value30 {
                            Text("30 Day avg. \(NativeHealthspanFormat.valueText(value30, unit: row.unit, key: row.key))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(NativeHealthspanFormat.contributorNote(row))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NativeHealthspanFormat.accessibility(row))
    }

    private var yearsColor: Color {
        guard row.available, let years = row.years else { return .secondary }
        if years < -0.05 { return NativePaint.positiveDelta(style) }
        if years > 0.05 { return NativePaint.negativeDelta(style) }
        return Color.primary
    }
}

struct NativeHealthspanRangeBar: View, Equatable {
    var value: Double
    var value30: Double?
    var scaleMin: Double
    var scaleMax: Double
    var higherIsBetter: Bool
    var valueLabel: String = ""
    var minLabel: String = ""
    var maxLabel: String = ""
    @Environment(\.nativeStyle) private var style

    static func == (lhs: NativeHealthspanRangeBar, rhs: NativeHealthspanRangeBar) -> Bool {
        lhs.value == rhs.value
            && lhs.value30 == rhs.value30
            && lhs.scaleMin == rhs.scaleMin
            && lhs.scaleMax == rhs.scaleMax
            && lhs.higherIsBetter == rhs.higherIsBetter
            && lhs.valueLabel == rhs.valueLabel
            && lhs.minLabel == rhs.minLabel
            && lhs.maxLabel == rhs.maxLabel
    }

    private let segmentCount = 8

    private var progress6: Double {
        NativeHealthspanFormat.markerProgress(value: value, scaleMin: scaleMin, scaleMax: scaleMax)
    }

    private var progress30: Double? {
        value30.map {
            NativeHealthspanFormat.markerProgress(value: $0, scaleMin: scaleMin, scaleMax: scaleMax)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let x6 = CGFloat(progress6) * geo.size.width
                let x30 = progress30.map { CGFloat($0) * geo.size.width }
                VStack(spacing: 0) {
                    Text(valueLabel)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .offset(x: labelOffset(x6, width: geo.size.width))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 8))
                        .offset(x: x6 - 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                    HStack(spacing: 2) {
                        ForEach(0..<segmentCount, id: \.self) { index in
                            Capsule()
                                .fill(segmentColor(index))
                                .frame(height: 8)
                        }
                    }
                    .padding(.top, 2)
                    if let x30 {
                        Image(systemName: "arrowtriangle.up.fill")
                            .font(.system(size: 8))
                            .offset(x: x30 - 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                }
            }
            .frame(height: 54)
            HStack {
                Text(minLabel)
                Spacer()
                Text(maxLabel)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    private func labelOffset(_ markerX: CGFloat, width: CGFloat) -> CGFloat {
        min(max(0, markerX - 24), max(0, width - 80))
    }

    private func segmentColor(_ index: Int) -> Color {
        let t = higherIsBetter ? index : (segmentCount - 1 - index)
        let poor = style == .whoop ? NativeTokens.whoopBandPoor : NativeTokens.bandPoor
        let mid = style == .whoop ? NativeTokens.whoopBandSufficient : NativeTokens.bandSufficient
        let good = style == .whoop ? NativeTokens.whoopBandOptimal : NativeTokens.bandOptimal
        if t <= 2 { return poor }
        if t <= 4 { return mid }
        return good
    }
}

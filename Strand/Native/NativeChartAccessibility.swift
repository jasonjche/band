import SwiftUI
import Accessibility

/// Reusable VoiceOver chart descriptor for Native plots (scope, stress, HR, hypnogram).
struct NativeChartDescriptor: AXChartDescriptorRepresentable {
    enum XKind {
        case date
        case category
    }

    struct Point {
        var xLabel: String
        var xValue: Double
        var y: Double
    }

    var title: String
    var unit: String
    var xKind: XKind
    var points: [Point]
    var yRange: ClosedRange<Double>
    var yDescription: ((Double) -> String)? = nil

    static func yRange(of values: [Double], fallback: ClosedRange<Double> = 0...1) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        guard let lo = finite.min(), let hi = finite.max() else { return fallback }
        if lo == hi { return (lo - 0.5)...(hi + 0.5) }
        return lo...hi
    }

    static func downsample(_ points: [Point], limit: Int = 80) -> [Point] {
        guard points.count > limit, limit > 0 else { return points }
        let step = max(1, Int((Double(points.count) / Double(limit)).rounded(.up)))
        return stride(from: 0, to: points.count, by: step).map { points[$0] }
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let sampled = Self.downsample(points)
        let yLo = yRange.lowerBound
        let yHi = max(yRange.upperBound, yLo + 0.001)
        let yAxis = AXNumericDataAxisDescriptor(
            title: unit.isEmpty ? "Value" : unit,
            range: yLo...yHi,
            gridlinePositions: [],
            valueDescriptionProvider: { [unit, yDescription] value in
                if let yDescription { return yDescription(value) }
                let number = String(format: "%g", value)
                return unit.isEmpty ? number : "\(number) \(unit)"
            }
        )
        switch xKind {
        case .date:
            let xs = sampled.map(\.xValue)
            let xLo = xs.min() ?? 0
            let xHi = max(xs.max() ?? 1, xLo + 1)
            let xAxis = AXNumericDataAxisDescriptor(
                title: "Time",
                range: xLo...xHi,
                gridlinePositions: [],
                valueDescriptionProvider: { [sampled] value in
                    sampled.min(by: { abs($0.xValue - value) < abs($1.xValue - value) })?.xLabel
                        ?? String(format: "%g", value)
                }
            )
            let series = AXDataSeriesDescriptor(
                name: title,
                isContinuous: true,
                dataPoints: sampled.map { AXDataPoint(x: $0.xValue, y: $0.y) }
            )
            return AXChartDescriptor(
                title: title,
                summary: nil,
                xAxis: xAxis,
                yAxis: yAxis,
                additionalAxes: [],
                series: [series]
            )
        case .category:
            let xAxis = AXCategoricalDataAxisDescriptor(
                title: "Category",
                categoryOrder: sampled.map(\.xLabel)
            )
            let series = AXDataSeriesDescriptor(
                name: title,
                isContinuous: false,
                dataPoints: sampled.map { AXDataPoint(x: $0.xLabel, y: $0.y) }
            )
            return AXChartDescriptor(
                title: title,
                summary: nil,
                xAxis: xAxis,
                yAxis: yAxis,
                additionalAxes: [],
                series: [series]
            )
        }
    }
}

extension View {
    func nativeChartDescriptor(_ descriptor: NativeChartDescriptor) -> some View {
        accessibilityChartDescriptor(descriptor)
    }

    /// Navigation on a tappable card. Does not wrap a scrubbing chart.
    @ViewBuilder
    func nativeOpenButton(action: (() -> Void)?) -> some View {
        if let action {
            Button(action: action) { self }
                .buttonStyle(.plain)
        } else {
            self
        }
    }

    /// VoiceOver button on a chart that also scrubs. Does not wrap in `Button`.
    func nativeChartButton(action: (() -> Void)?) -> some View {
        self
            .accessibilityAddTraits(action == nil ? [] : .isButton)
            .accessibilityAction {
                action?()
            }
    }
}

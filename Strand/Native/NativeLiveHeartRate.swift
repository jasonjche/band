import SwiftUI
import Combine
import Charts
import StrandDesign
import StrandAnalytics

/// Arms the strap live-HR stream only while visible. Health Monitor and the
/// compact sheet both use this — `startRealtimeHR` / `stopRealtimeHR` stay 1:1.
struct NativeLiveHRArm: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @Binding var bpm: Int?
    @Binding var samples: [NativeHourPoint]
    var window: TimeInterval = 60

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { model.startRealtimeHR() }
            .onDisappear { model.stopRealtimeHR() }
            .onReceive(
                live.$heartRate.throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            ) { value in
                bpm = value
                let now = Date()
                if let value {
                    samples.append(NativeHourPoint(time: now, value: Double(value)))
                }
                samples.removeAll { now.timeIntervalSince($0.time) > window }
            }
    }
}

/// Compact live heart-rate sheet. Arms the strap stream only while visible.
struct NativeLiveHeartRate: View {
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.nativeStyle) private var style
    @Environment(\.dismiss) private var dismiss

    @State private var bpm: Int?
    @State private var samples: [NativeHourPoint] = []

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                hero
                zoneLine
                NativeChrome.panel { spark }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(NativePageFill())
            .navigationTitle("Heart Rate")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        .background { NativeLiveHRArm(bpm: $bpm, samples: $samples) }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BPM")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if let bpm {
                NativeValueText(value: "\(bpm)", unit: "BPM", size: 48)
                    .foregroundStyle(NativePaint.heart(style))
            } else {
                NativeValueText(value: "No data", size: 34)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bpm.map { "Heart rate \($0) BPM" } ?? "No data")
    }

    @ViewBuilder private var zoneLine: some View {
        if let bpm {
            let zone = profile.hrZoneSet.zoneNumber(forBPM: Double(bpm))
            HStack(spacing: 8) {
                Text(zoneLabel(zone))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(zoneTint(zone))
                Spacer(minLength: 0)
            }
        }
    }

    private var spark: some View {
        Group {
            if plotSamples.count >= 2 {
                Chart(plotSamples) { sample in
                    LineMark(
                        x: .value("Time", sample.time),
                        y: .value("BPM", sample.value)
                    )
                    .foregroundStyle(NativePaint.heart(style))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                .chartXScale(domain: xDomain)
                .chartYScale(domain: yDomain)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: NativePlotAxis.yTicks(in: yDomain)) { value in
                        AxisGridLine(stroke: NativeChrome.gridStroke)
                            .foregroundStyle(NativeChrome.hairline)
                        AxisValueLabel {
                            if let bpm = value.as(Double.self) {
                                Text("\(Int(bpm.rounded()))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .chartPlotStyle { $0.clipped() }
                .accessibilityLabel("Heart rate, last 60 seconds")
            } else {
                NativeEmptyState(text: "No data", symbol: "heart")
            }
        }
        .frame(height: 120)
    }

    /// Smoothed polyline clipped to the last 60 seconds. Hero BPM stays on the latest raw sample.
    private var plotSamples: [NativeHourPoint] {
        let smoothed = NativeHRSmoothing.smooth(samples)
        guard let last = smoothed.last else { return smoothed }
        let start = last.time.addingTimeInterval(-60)
        return smoothed.filter { NativePlotAxis.inTimeDomain($0.time, start...last.time) }
    }

    private var xDomain: ClosedRange<Date> {
        guard let first = plotSamples.first, let last = plotSamples.last, last.time >= first.time else {
            let now = Date()
            return now.addingTimeInterval(-60)...now
        }
        return first.time...last.time
    }

    private func zoneLabel(_ zone: Int) -> String {
        switch zone {
        case 1: return "Zone 1"
        case 2: return "Zone 2"
        case 3: return "Zone 3"
        case 4: return "Zone 4"
        case 5: return "Zone 5"
        default: return "Below Zone 1"
        }
    }

    private var yDomain: ClosedRange<Double> {
        NativePlotAxis.yDomain(plotSamples.map(\.value), fallback: 40...180)
    }

    private func zoneTint(_ zone: Int) -> Color {
        switch zone {
        case 1: return NativeChrome.recovery
        case 2: return NativeChrome.activity
        case 3: return NativeChrome.strain
        case 4: return NativeChrome.sufficient
        case 5: return NativeChrome.poor
        default: return Color.secondary
        }
    }
}

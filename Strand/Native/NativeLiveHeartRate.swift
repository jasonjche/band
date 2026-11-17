import SwiftUI
import Combine
import Charts
import StrandDesign
import StrandAnalytics

/// Compact live heart-rate sheet. Arms the strap stream only while visible.
struct NativeLiveHeartRate: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.nativeStyle) private var style
    @Environment(\.dismiss) private var dismiss

    @State private var bpm: Int?
    @State private var samples: [Sample] = []

    private struct Sample: Identifiable {
        var time: Date
        var bpm: Int
        var id: Date { time }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                hero
                zoneLine
                spark
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
        .onAppear { model.startRealtimeHR() }
        .onDisappear { model.stopRealtimeHR() }
        .onReceive(
            live.$heartRate.throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
        ) { value in
            bpm = value
            let now = Date()
            if let value {
                samples.append(Sample(time: now, bpm: value))
            }
            samples.removeAll { now.timeIntervalSince($0.time) > 60 }
        }
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
                NativeValueText(value: "No Data", size: 34)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bpm.map { "Heart rate \($0) BPM" } ?? "No Data")
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
            if samples.count >= 2 {
                Chart(samples) { sample in
                    LineMark(
                        x: .value("Time", sample.time),
                        y: .value("BPM", sample.bpm)
                    )
                    .foregroundStyle(NativePaint.heart(style))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
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
                .chartYScale(domain: yDomain)
                .frame(height: 120)
                .accessibilityLabel("Heart rate, last 60 seconds")
            }
        }
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
        let values = samples.map { Double($0.bpm) }
        guard let lo = values.min(), let hi = values.max() else { return 40...180 }
        let pad = max(2, (hi - lo) / 8)
        return (lo - pad)...(hi + pad)
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

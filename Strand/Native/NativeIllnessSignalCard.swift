import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// Maps stored days into the consecutive-night overnight-load signal.
enum NativeIllnessSignal {
    static func nights(from days: [DailyMetric], alcoholDays: Set<String> = []) -> [BandIllnessSignal.Night] {
        days.map { day in
            BandIllnessSignal.Night(
                day: day.day,
                rhr: day.restingHr.map(Double.init),
                hrvMs: day.avgHrv,
                respRpm: day.respRateBpm,
                skinTemp: day.skinTempC ?? day.skinTempDevC,
                alcohol: alcoholDays.contains(day.day)
            )
        }
    }

    static func result(days: [DailyMetric], dayKey: String,
                       alcoholDays: Set<String> = []) -> BandIllnessSignal.DayResult? {
        BandIllnessSignal.result(on: dayKey, nights: nights(from: days, alcoholDays: alcoholDays))
    }
}

/// Recovery / Health card. Wellness wording only; never a notification.
struct NativeIllnessSignalCard: View {
    var result: BandIllnessSignal.DayResult?
    /// Home shows the card only on `.watch`.
    var compact: Bool = false
    @Environment(\.nativeStyle) private var style

    var body: some View {
        if let result {
            if compact && result.level != .watch {
                EmptyView()
            } else if result.level == .building {
                EmptyView()
            } else {
                NativeChrome.panel {
                    NativeCardHeader(
                        title: "Overnight load",
                        symbol: "heart.fill",
                        tint: headerTint(result.level)
                    )
                    Text(result.copy)
                        .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline)
                        .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                        .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if result.level == .watch, !result.fired.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(result.fired.enumerated()), id: \.element) { index, key in
                                if index > 0 { Divider().padding(.leading, 34) }
                                NativeContributorRow(
                                    symbol: symbol(key),
                                    title: title(key),
                                    value: zText(key, result: result),
                                    tint: tint(key)
                                )
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Overnight load, \(result.copy)")
            }
        }
    }

    private func headerTint(_ level: BandIllnessSignal.Level) -> Color {
        level == .watch ? NativePaint.negativeDelta(style) : NativePaint.heart(style)
    }

    private func symbol(_ key: BandIllnessSignal.SignalKey) -> String {
        switch key {
        case .rhr: return "heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .resp: return "lungs.fill"
        case .skin: return "thermometer.medium"
        }
    }

    private func title(_ key: BandIllnessSignal.SignalKey) -> String {
        switch key {
        case .rhr: return "Resting HR"
        case .hrv: return "HRV"
        case .resp: return "Respiratory"
        case .skin: return "Skin temp"
        }
    }

    private func tint(_ key: BandIllnessSignal.SignalKey) -> Color {
        switch key {
        case .resp: return NativePaint.respiratory(style)
        case .skin: return NativePaint.activity(style)
        default: return NativePaint.heart(style)
        }
    }

    private func zText(_ key: BandIllnessSignal.SignalKey, result: BandIllnessSignal.DayResult) -> String {
        let z: Double?
        switch key {
        case .rhr: z = result.zRhr
        case .hrv: z = result.zHrv
        case .resp: z = result.zResp
        case .skin: z = result.zSkin
        }
        guard let z else { return "—" }
        let magnitude = abs(z)
        if magnitude < BandIllnessSignal.zThreshold { return "Typical" }
        if magnitude < BandIllnessSignal.zThreshold + 1 { return "A bit high" }
        return "Well above typical"
    }
}

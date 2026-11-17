import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// Maps stored days into the Plews / Buchheit 7-day ln(RMSSD) trend.
enum NativeHRVTrend {
    static func nights(from days: [DailyMetric]) -> [HRVTrend.Night] {
        days.map { HRVTrend.Night(day: $0.day, rmssdMs: $0.avgHrv) }
    }

    static func result(days: [DailyMetric], dayKey: String) -> HRVTrend.DayResult? {
        HRVTrend.result(on: dayKey, nights: nights(from: days))
    }
}

/// Recovery / HRV page card. Hidden while the 60-day baseline is still building.
struct NativeHRVTrendCard: View {
    var result: HRVTrend.DayResult?
    /// Home uses the compact drawing (no band rows) and hides `.withinNormal`.
    var compact: Bool = false
    @Environment(\.nativeStyle) private var style

    var body: some View {
        if let result, result.state != .building {
            if compact && result.state == .withinNormal {
                EmptyView()
            } else {
                NativeChrome.panel {
                    NativeCardHeader(
                        title: "HRV Trend",
                        symbol: "waveform.path.ecg",
                        tint: NativePaint.heart(style)
                    )
                    NativeHeroValue(
                        caption: "7-day HRV",
                        value: result.trendMs.map { "\(Int($0.rounded()))" } ?? "—",
                        unit: "ms",
                        valueTint: stateTint(result.state)
                    )
                    Text(stateLabel(result.state))
                        .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline.weight(.semibold))
                        .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                        .foregroundStyle(stateTint(result.state))
                    if !compact {
                        VStack(spacing: 0) {
                            NativeContributorRow(
                                symbol: "circle.fill",
                                title: "60-day baseline",
                                value: result.baselineMs.map { "\(Int($0.rounded())) ms" } ?? "—",
                                tint: NativePaint.heart(style)
                            )
                            Divider().padding(.leading, 34)
                            NativeContributorRow(
                                symbol: "arrow.left.and.right",
                                title: "Usual band",
                                value: bandText(result),
                                tint: NativePaint.heart(style)
                            )
                            Divider().padding(.leading, 34)
                            NativeContributorRow(
                                symbol: "chart.xyaxis.line",
                                title: "7-day CV",
                                value: result.trendCV.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                                tint: NativePaint.heart(style)
                            )
                        }
                        NativeChrome.footnote("7-day mean of ln HRV versus your 60-day range. Day-to-day CV is stability, not a score.")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("HRV Trend, \(stateLabel(result.state))")
            }
        }
    }

    private func stateLabel(_ state: HRVTrend.State) -> String {
        switch state {
        case .building: return "Learning your range"
        case .withinNormal: return "Within usual"
        case .trendingBelow: return "Trending lower"
        case .trendingAbove: return "Trending higher"
        }
    }

    private func stateTint(_ state: HRVTrend.State) -> Color {
        switch state {
        case .building, .withinNormal: return .primary
        case .trendingBelow: return NativePaint.negativeDelta(style)
        case .trendingAbove: return NativePaint.positiveDelta(style)
        }
    }

    private func bandText(_ result: HRVTrend.DayResult) -> String {
        guard let low = result.bandLow, let high = result.bandHigh else { return "—" }
        return "\(Int(exp(low).rounded()))–\(Int(exp(high).rounded())) ms"
    }
}

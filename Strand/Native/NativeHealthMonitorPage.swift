import SwiftUI
import StrandDesign
import WhoopStore

/// WHOOP Health Monitor: every vital for the selected day, judged by `NativeHealthRange.report`.
/// Home's "N/M" header is that report's `summary`. Rows without data are hidden.
struct NativeHealthMonitorPage: View {
    @Environment(\.nativeNavigationPath) private var path
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""
    @State private var repoHandle: Repository?
    @State private var refreshSeq = 0
    @State private var handlesReady = false
    @State private var report = NativeHealthRange.Report(vitals: [])
    @State private var firstDay: String?

    private var selectedDay: Date {
        get { NativeDaySelection.date(from: selectedDayKey) }
        nonmutating set { selectedDayKey = NativeDaySelection.key(from: newValue) }
    }

    private var dayKey: String { NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }

    private var taskID: String {
        handlesReady ? "\(dayKey)|\(refreshSeq)" : "boot"
    }

    var body: some View {
        NativeChrome.screen {
            NativeHealthMonitorBody(
                report: report,
                selectedDay: selectedDay,
                firstDay: firstDay,
                onBack: { shiftDay(-1) },
                onForward: { shiftDay(1) },
                onSelect: { path.wrappedValue.append($0) }
            )
        }
        .navigationTitle("Health Monitor")
        .modifier(NativeInlineTitle())
        .nativeDateSubtitle(selectedDay)
        .background {
            NativeRepoSink(refreshSeq: $refreshSeq, ready: $handlesReady) { repoHandle = $0 }
        }
        .task(id: taskID) {
            guard handlesReady, let repo = repoHandle else { return }
            firstDay = repo.days.first?.day
            report = NativeHealthRange.report(days: repo.days, todayKey: dayKey)
        }
    }

    private func shiftDay(_ delta: Int) {
        guard let next = HomeDayNav.shift(from: selectedDay, delta: delta, firstDay: firstDay) else { return }
        selectedDay = next
    }
}

struct NativeHealthMonitorBody: View {
    var report: NativeHealthRange.Report
    var selectedDay: Date
    var firstDay: String?
    var onBack: () -> Void
    var onForward: () -> Void
    var onSelect: (TabRoute) -> Void

    private var dayKey: String { Repository.localDayKey(selectedDay) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeDateStepper(
                title: HomeDayTitle.text(for: selectedDay),
                canGoBack: HomeDayNav.canGoBack(selectedKey: dayKey, firstDay: firstDay),
                canGoForward: HomeDayNav.canGoForward(selectedKey: dayKey),
                onBack: onBack,
                onForward: onForward
            )
            .frame(maxWidth: .infinity)
            if let caption = report.summary.caption {
                Text(caption)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            NativeChrome.panel {
                if report.vitals.isEmpty {
                    NativeEmptyState(text: "No Data", symbol: "heart")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(report.vitals.enumerated()), id: \.element.id) { index, vital in
                            if index > 0 { Divider().padding(.leading, 32) }
                            Button { onSelect(vital.route) } label: {
                                NativeHealthMonitorRow(vital: vital)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

enum NativeHealthMonitorFormat {
    /// Compact trailing so "Respiratory Rate" stays the same title size as the other rows.
    /// `NativeContributorRow` rewrites `rpm` → `breaths/min`, so the page draws its own value.
    static func trailingValue(_ vital: NativeHealthRange.Vital) -> String {
        guard vital.id == "resp" else { return vital.valueText }
        return vital.valueText.replacingOccurrences(of: "breaths/min", with: "rpm")
    }

    static func accessibilityLabel(_ vital: NativeHealthRange.Vital) -> String {
        let range = vital.inRange ? "In Range" : "Out of Range"
        return "\(vital.title), \(vital.valueText), Typical \(vital.typicalText), \(range)"
    }
}

struct NativeHealthMonitorRow: View {
    var vital: NativeHealthRange.Vital
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row
            NativeVitalRangeBar(
                value: vital.value,
                typical: vital.typical,
                tint: vital.heartFamily ? NativePaint.heart(style) : NativePaint.respiratory(style)
            )
            .padding(.leading, 32)
            .padding(.bottom, 6)
        }
    }

    private var row: some View {
        let tint = vital.heartFamily ? NativePaint.heart(style) : NativePaint.respiratory(style)
        let valueTint = vital.inRange ? Color.primary : NativeTokens.recoveryLow
        let prior = "Typical \(vital.typicalText) · \(vital.inRange ? "In Range" : "Out of Range")"
        return HStack(spacing: 10) {
            Image(systemName: vital.symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(style == .whoop ? vital.title.uppercased() : vital.title)
                .font(style == .whoop ? NativeTokens.whoopCaps(13) : .body)
                .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(NativeHealthMonitorFormat.trailingValue(vital))
                    .font(style == .whoop
                          ? NativeTokens.whoopNumber(17, weight: .semibold)
                          : StrandFont.rounded(17, weight: .semibold))
                    .foregroundStyle(style == .whoop ? Color.primary : valueTint)
                    .lineLimit(1)
                    .monospacedDigit()
                Text(prior)
                    .font(style == .whoop ? NativeTokens.whoopNumber(12, weight: .regular) : .footnote)
                    .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NativeHealthMonitorFormat.accessibilityLabel(vital))
    }
}

/// Min–max typical band with a dot at today's value. Tokens only.
struct NativeVitalRangeBar: View {
    var value: Double
    var typical: ClosedRange<Double>
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let lo = min(typical.lowerBound, value)
            let hi = max(typical.upperBound, value)
            let pad = max((hi - lo) * 0.12, 0.01)
            let minX = lo - pad
            let span = (hi + pad) - minX
            let bandX = CGFloat((typical.lowerBound - minX) / span) * geo.size.width
            let bandW = CGFloat((typical.upperBound - typical.lowerBound) / span) * geo.size.width
            let dotX = CGFloat((value - minX) / span) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 6)
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: max(bandW, 6), height: 6)
                    .offset(x: bandX)
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .offset(x: max(0, min(geo.size.width - 8, dotX - 4)))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

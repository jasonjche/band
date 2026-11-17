import SwiftUI
import WhoopStore
import StrandDesign

/// Stress Monitor. Date stepper, level hero, 24 h chart with sleep shaded. No Sessions.
struct NativeStressPage: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""

    private var selectedDay: Date {
        get { NativeDaySelection.date(from: selectedDayKey) }
        nonmutating set { selectedDayKey = NativeDaySelection.key(from: newValue) }
    }

    @State private var workouts: [WorkoutRow] = []
    @State private var scrubValue: Double = 0
    @State private var scrubTime: Date?
    @State private var sampleHours: [NativeHourPoint] = []

    private var dayKey: String { NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }

    private var level: Double? {
        NativeHomeCharts.stressLevel(hours: sampleHours, days: repo.days, todayKey: dayKey)
    }

    var body: some View {
        let sleep = repo.sleeps.last {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == dayKey
        }
        let bouts: [(start: Date, end: Date)] = workouts.compactMap { row in
            let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
            guard NativeDayLogic.sleepSessionDayKey(start) == dayKey else { return nil }
            return (start, Date(timeIntervalSince1970: TimeInterval(row.endTs)))
        }
        NativeChrome.screen {
            HomeDateStepper(
                title: HomeDayTitle.text(for: selectedDay),
                canGoBack: HomeDayNav.canGoBack(selectedKey: dayKey, firstDay: repo.days.first?.day),
                canGoForward: HomeDayNav.canGoForward(selectedKey: dayKey),
                onBack: { shiftDay(-1) },
                onForward: { shiftDay(1) }
            )
            .frame(maxWidth: .infinity)
            HomeStressBody(
                level: level,
                date: HomeDayTitle.text(for: selectedDay),
                hours: sampleHours,
                sleepStart: sleep.map { Date(timeIntervalSince1970: TimeInterval($0.effectiveStartTs)) },
                sleepEnd: sleep.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) },
                workouts: bouts,
                dayStart: Calendar.current.startOfDay(for: selectedDay),
                now: min(
                    Date(),
                    Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: selectedDay)) ?? Date()
                ),
                scrubValue: $scrubValue,
                scrubTime: $scrubTime
            )
        }
        .navigationTitle("Stress Monitor")
        .modifier(NativeInlineTitle())
        .nativeDateSubtitle(selectedDay)
        .task(id: dayKey) { await reload() }
    }

    private func shiftDay(_ delta: Int) {
        guard let next = HomeDayNav.shift(from: selectedDay, delta: delta, firstDay: repo.days.first?.day) else { return }
        selectedDay = next
    }

    private func reload() async {
        workouts = await repo.workoutRows(days: 14)
        let start = Calendar.current.startOfDay(for: selectedDay)
        let from = Int(start.timeIntervalSince1970)
        let raw = await repo.hrSamples(from: from, to: from + 86_400, limit: 12_000)
        sampleHours = NativeHomeCharts.stressSeries(samples: raw.map { (ts: $0.ts, bpm: $0.bpm) })
        if let latest = NativeHomeCharts.stressLevel(hours: sampleHours, days: repo.days, todayKey: dayKey) {
            scrubValue = latest
        }
        scrubTime = nil
    }
}

/// Level hero + 24 h chart. Shared with Home snapshots so the series cannot drift.
struct HomeStressBody: View {
    var level: Double?
    var date: String
    var hours: [NativeHourPoint]
    var sleepStart: Date?
    var sleepEnd: Date?
    var workouts: [(start: Date, end: Date)]
    var dayStart: Date
    var now: Date
    @Binding var scrubValue: Double
    @Binding var scrubTime: Date?

    private var lastUpdated: String {
        if let time = hours.last?.time {
            return time.formatted(date: .omitted, time: .shortened)
        }
        return date
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeStressGauge(value: shownLevel, lastUpdated: lastUpdated)
                .frame(width: 152, height: 96)
                .frame(maxWidth: .infinity)

            NativeChrome.panel {
                if hours.isEmpty {
                    NativeEmptyState(text: "No Data", symbol: "chart.xyaxis.line")
                        .frame(height: 220)
                } else {
                    NativeStressMonitor(
                        score: shownLevel ?? hours.last?.value ?? 0,
                        sleepStart: sleepStart,
                        sleepEnd: sleepEnd,
                        workouts: workouts,
                        dayStart: dayStart,
                        now: now,
                        sampleHours: hours,
                        scrubValue: $scrubValue,
                        scrubTime: $scrubTime
                    )
                    .frame(height: 260)
                }
            }
        }
    }

    private var shownLevel: Double? {
        scrubTime == nil ? level : scrubValue
    }
}

/// WHOOP-shaped 0–3 semicircle with band colours. Drawn with Apple type.
struct NativeStressGauge: View {
    var value: Double?
    var lastUpdated: String
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                NativeStressArc(progress: 1, color: track)
                if let value {
                    NativeStressArc(progress: min(1, max(0, value / 3)), color: NativePaint.stressBand(value, style: style))
                }
                VStack(spacing: 1) {
                    if let value {
                        Text(String(format: "%.1f", value))
                            .font(NativePaint.number(28, style: style))
                            .monospacedDigit()
                        Text(NativeHomeCharts.stressBandWord(value))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(NativePaint.stressBand(value, style: style))
                    } else {
                        Text("No Data")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(lastUpdated)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .offset(y: 10)
            }
            .frame(height: 80)
            HStack {
                Text("0.0")
                Spacer()
                Text("3.0")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { "Stress \($0), last updated \(lastUpdated)" } ?? "No stress data")
    }

    private var track: Color {
        style == .whoop ? NativeTokens.whoopTrack : NativeTokens.separator.opacity(0.55)
    }
}

private struct NativeStressArc: View {
    var progress: Double
    var color: Color

    var body: some View {
        Canvas { context, size in
            let line: CGFloat = 10
            let rect = CGRect(
                x: line / 2,
                y: line / 2,
                width: size.width - line,
                height: (size.height - line) * 2
            )
            var path = Path()
            path.addArc(
                center: CGPoint(x: rect.midX, y: rect.minY + rect.width / 2),
                radius: rect.width / 2,
                startAngle: .degrees(180),
                endAngle: .degrees(180 + 180 * min(1, max(0, progress))),
                clockwise: false
            )
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: line, lineCap: .round)
            )
        }
    }
}

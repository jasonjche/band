#if DEBUG
import XCTest
import SwiftUI
import AppKit
import StrandAnalytics
import StrandDesign
@testable import Strand

/// Metric D/W/M/6M and Stress idle/selected snapshots → `/tmp/native-snaps/`.
@MainActor
final class NativeMetricSnapshotRender: XCTestCase {
    func testRenderMetricAndStressScopes() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NATIVE_SNAPSHOTS"] == "1",
            "Set NATIVE_SNAPSHOTS=1 to write metric/stress PNGs"
        )
        guard #available(macOS 13.1, *) else {
            throw XCTSkip("ImageRenderer.nsImage needs macOS 13.1+")
        }

        let dir = URL(fileURLWithPath: "/tmp/native-snaps", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }

        for section in Self.sections {
            for pass in NativeSnapshotPass.all {
                NSApp.appearance = NSAppearance(named: pass.scheme == .dark ? .darkAqua : .aqua)
                let url = dir.appendingPathComponent("\(section.name)-\(pass.suffix).png")
                try render(section.view, pass: pass, to: url)
            }
        }
    }

    private struct Section {
        var name: String
        var view: AnyView
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }

    private static let endKey = "2026-11-15"

    private static var hrvPoints: [NativeDayPoint] {
        var points: [NativeDayPoint] = []
        let cal = calendar
        var day = NativeScopeSeries.date(from: "2026-05-10", calendar: cal)!
        let end = NativeScopeSeries.date(from: endKey, calendar: cal)!
        var value = 58.0
        while day <= end {
            let key = NativeScopeSeries.key(from: day, calendar: cal)
            if cal.component(.weekday, from: day) != 4 {
                points.append(NativeDayPoint(key: key, value: value))
            }
            value = 50 + Double((Int(value) * 17) % 40)
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return points
    }

    private static func series(_ scope: NativeMetricScope, cfg: MetricCfg? = Baselines.hrvCfg) -> NativeScopeSeries {
        let end = NativeScopeSeries.date(from: endKey, calendar: calendar)!
        return NativeScopeSeries.make(
            points: hrvPoints, scope: scope, kind: .rate,
            calendar: calendar, now: end, ending: end, cfg: cfg
        )
    }

    private static func metricPage(scope: NativeMetricScope, selected: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("D   W   M   6M")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            NativeScopeChart(
                series: series(scope),
                bars: false,
                tint: NativeTokens.heart,
                format: { "\(Int($0.rounded()))" },
                unit: "ms",
                highlightKey: endKey,
                higherIsBetter: true,
                previewSelected: selected,
                calendar: calendar,
                accessibilityName: "Heart Rate Variability",
                plotHeight: 240,
                scrolls: false
            )
        }
        .padding(16)
    }

    private static var recoveryPoints: [NativeDayPoint] {
        hrvPoints.enumerated().map { index, point in
            let value = [18.0, 52, 63, 71, 44, 78, 33][index % 7]
            return NativeDayPoint(key: point.key, value: value)
        }
    }

    private static func recoveryPage(selected: String?) -> some View {
        let end = NativeScopeSeries.date(from: endKey, calendar: calendar)!
        let series = NativeScopeSeries.make(
            points: recoveryPoints, scope: .week, kind: .rate,
            calendar: calendar, now: end, ending: end
        )
        return VStack(alignment: .leading, spacing: 12) {
            Text("D   W   M   6M")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            NativeScopeChart(
                series: series,
                bars: true,
                tint: NativeTokens.recoveryHigh,
                format: { "\(Int($0.rounded()))" },
                unit: "%",
                highlightKey: endKey,
                higherIsBetter: true,
                previewSelected: selected,
                calendar: calendar,
                accessibilityName: "Recovery",
                color: { NativeTokens.recoveryBand($0) },
                plotHeight: 240,
                scrolls: false
            )
        }
        .padding(16)
    }

    private static var stressHours: [NativeHourPoint] {
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 0, minute: 20))!
        return stride(from: 0, through: 18 * 60, by: 20).map { minute in
            let t = Double(minute)
            let value = min(3, max(0, 0.4 + 1.6 * sin(t / 180) + (minute > 700 ? 1.1 : 0)))
            return NativeHourPoint(time: start.addingTimeInterval(t * 60), value: value)
        }
    }

    private static var stressDaily: NativeScopeSeries {
        let points = hrvPoints.enumerated().map { index, point in
            NativeDayPoint(key: point.key, value: min(3, 0.6 + Double(index % 7) * 0.25))
        }
        let end = NativeScopeSeries.date(from: endKey, calendar: calendar)!
        return NativeScopeSeries.make(
            points: points, scope: .week, kind: .rate,
            calendar: calendar, now: end, ending: end
        )
    }

    private static func stressPage(selected: Bool) -> some View {
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15))!
        return VStack(alignment: .leading, spacing: 12) {
            NativeHeroValue(
                caption: NativeStressHero.caption(scrubbing: selected),
                value: String(format: "%.1f", selected ? 2.1 : (stressHours.last?.value ?? 0)),
                date: selected
                    ? NativeScopeFormat.time(stressHours[12].time, calendar: calendar)
                    : NativeScopeFormat.weekdayDate(dayStart, calendar: calendar)
            )
            NativeStressMonitor(
                score: selected ? 2.1 : (stressHours.last?.value ?? 0),
                sleepStart: calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 0, minute: 37)),
                sleepEnd: calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 8, minute: 0)),
                workouts: [],
                dayStart: dayStart,
                now: calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 16))!,
                sampleHours: stressHours,
                previewSelected: selected ? stressHours[12].time : nil,
                scrubValue: .constant(selected ? 2.1 : (stressHours.last?.value ?? 0)),
                scrubTime: .constant(selected ? stressHours[12].time : nil)
            )
            .frame(height: 260)
        }
        .padding(16)
    }

    private static var sections: [Section] {
        [
            Section(name: "metric-hrv-d", view: AnyView(metricPage(scope: .day, selected: nil))),
            Section(name: "metric-hrv-w", view: AnyView(metricPage(scope: .week, selected: nil))),
            Section(name: "metric-hrv-w-selected", view: AnyView(metricPage(scope: .week, selected: "2026-11-10"))),
            Section(name: "metric-hrv-m", view: AnyView(metricPage(scope: .month, selected: nil))),
            Section(name: "metric-hrv-m-selected", view: AnyView(metricPage(scope: .month, selected: "2026-11-01"))),
            Section(name: "metric-hrv-6m", view: AnyView(metricPage(scope: .sixMonths, selected: nil))),
            Section(name: "metric-hrv-6m-selected", view: AnyView(metricPage(scope: .sixMonths, selected: "2026-11-09"))),
            Section(name: "metric-recovery-w", view: AnyView(recoveryPage(selected: nil))),
            Section(name: "metric-recovery-w-selected", view: AnyView(recoveryPage(selected: "2026-11-10"))),
            Section(name: "stress-idle", view: AnyView(stressPage(selected: false))),
            Section(name: "stress-selected", view: AnyView(stressPage(selected: true))),
        ]
    }

    @available(macOS 13.1, *)
    private func render<V: View>(_ view: V, pass: NativeSnapshotPass, to url: URL) throws {
        let canvas = pass.style == .whoop
            ? Color(hex: "#0D1114")
            : (pass.scheme == .dark ? Color(hex: "#000000") : Color(hex: "#F2F2F7"))
        let host = view
            .frame(width: 393)
            .fixedSize(horizontal: false, vertical: true)
            .nativeStyleBridge(override: pass.style)
            .environment(\.nativeStyle, pass.style)
            .environment(\.colorScheme, pass.scheme)
            .preferredColorScheme(pass.scheme)
            .background(canvas)
        let appearance = NSAppearance(named: pass.scheme == .dark ? .darkAqua : .aqua)
        let previous = NSApp.appearance
        NSApp.appearance = appearance
        let renderer = ImageRenderer(content: host)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(width: 393, height: nil)
        let image = renderer.nsImage
        NSApp.appearance = previous
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            XCTFail("ImageRenderer produced no PNG for \(url.lastPathComponent)")
            return
        }
        try png.write(to: url)
    }
}
#endif

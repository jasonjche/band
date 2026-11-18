#if DEBUG
import XCTest
import SwiftUI
import AppKit
import WhoopStore
import StrandAnalytics
@testable import Strand

@MainActor
final class NativeAddActivitySnapshotRender: XCTestCase {

    func testRenderAddActivityViews() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NATIVE_SNAPSHOTS"] == "1",
            "Set NATIVE_SNAPSHOTS=1 to write add-activity PNGs"
        )
        guard #available(macOS 13.1, *) else {
            throw XCTSkip("ImageRenderer.nsImage needs macOS 13.1+")
        }

        let dir = URL(fileURLWithPath: "/tmp/native-snaps", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }

        let start = Date(timeIntervalSince1970: 1_763_297_220)
        let sections: [(name: String, height: CGFloat, view: AnyView)] = [
            ("add-activity-picker", 720, AnyView(picker)),
            ("add-activity-form", 640, AnyView(form(start: start))),
            ("add-activity-live", 720, AnyView(live(start: start))),
        ]

        for section in sections {
            for pass in NativeSnapshotPass.all {
                NSApp.appearance = NSAppearance(named: pass.scheme == .dark ? .darkAqua : .aqua)
                let url = dir.appendingPathComponent("\(section.name)-\(pass.suffix).png")
                try render(section.view, height: section.height, pass: pass, to: url)
            }
        }
    }

    private var picker: some View {
        NavigationStack {
            NativeSportPicker(
                workouts: snapshotWorkouts,
                selected: "Running",
                title: "Start Activity"
            ) { _ in }
        }
    }

    private func form(start: Date) -> some View {
        NativeAddPastActivityForm(
            editing: WorkoutRow(
                startTs: Int(start.timeIntervalSince1970),
                endTs: Int(start.addingTimeInterval(28 * 60).timeIntervalSince1970),
                sport: "Running", source: "manual",
                durationS: 28 * 60, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                distanceM: nil, zonesJSON: nil, notes: nil, steps: nil
            ),
            workouts: snapshotWorkouts,
            onSave: { _, _ in }
        )
    }

    private func live(start: Date) -> some View {
        NativeActiveWorkoutScreen(
            snapshot: NativeActiveWorkoutSnapshot(
                sport: "Running",
                elapsed: "0:12:34",
                strainText: "4.2",
                strainBand: "Light",
                strainFraction: 4.2 / 21,
                bpm: 148,
                zone: 3,
                zoneSet: HRZones.zones(maxHR: 190, restingHR: 60),
                avgHr: 141,
                maxHr: 156,
                caloriesText: "128",
                caloriesHint: nil,
                distanceText: "1.2 km",
                paceText: "5:24 /km",
                isRecovery: false,
                isPaused: false,
                targetFraction: nil,
                hrPoints: [
                    NativeHourPoint(time: start, value: 140),
                    NativeHourPoint(time: start.addingTimeInterval(60), value: 148),
                ],
                route: [],
                showsMap: true,
                showsDistancePace: true
            ),
            onPause: {},
            onEnd: {}
        )
    }

    private var snapshotWorkouts: [WorkoutRow] {
        let start = 1_763_297_220
        return [
            row("Running", start),
            row("Running", start - 86_400),
            row("Running", start - 2 * 86_400),
            row("Strength", start - 3 * 86_400),
            row("Yoga", start - 4 * 86_400),
        ]
    }

    private func row(_ sport: String, _ start: Int) -> WorkoutRow {
        WorkoutRow(
            startTs: start, endTs: start + 1_800, sport: sport, source: "manual",
            durationS: 1_800, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil
        )
    }

    @available(macOS 13.1, *)
    private func render<V: View>(_ view: V, height: CGFloat, pass: NativeSnapshotPass, to url: URL) throws {
        let canvas = pass.style == .whoop
            ? Color(red: 13 / 255, green: 17 / 255, blue: 20 / 255)
            : (pass.scheme == .dark
                ? Color(red: 0, green: 0, blue: 0)
                : Color(red: 242 / 255, green: 242 / 255, blue: 247 / 255))
        let host = view
            .frame(width: 393, height: height)
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
        renderer.proposedSize = ProposedViewSize(width: 393, height: height)
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

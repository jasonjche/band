#if DEBUG
import XCTest
import SwiftUI
import AppKit
import WhoopStore
@testable import Strand

/// Renders Native Home / Stress / Journal sections to `/tmp/native-snaps/home-*`.
/// Skipped unless `NATIVE_SNAPSHOTS=1` (pass `TEST_RUNNER_NATIVE_SNAPSHOTS=1` to xcodebuild).
@MainActor
final class NativeHomeSnapshotRender: XCTestCase {

    func testStressSeriesInventNothingWithoutSamples() {
        let synthetic = NativeHomeCharts.stressHours(
            dayStart: Date(),
            now: Date(),
            sleepStart: Date(),
            sleepEnd: Date().addingTimeInterval(8 * 3600),
            workouts: [(Date(), Date().addingTimeInterval(1800))],
            daily: 2.4
        )
        XCTAssertTrue(synthetic.isEmpty, "No HR samples must not invent a stress curve")

        let emptySeries = NativeHomeCharts.stressSeries(samples: [])
        XCTAssertTrue(emptySeries.isEmpty)

        let mapped = NativeHomeCharts.stressSeries(samples: [(ts: 1_000, bpm: 86)], stride: 1)
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].value, NativeHomeCharts.stressValue(bpm: 86), accuracy: 0.01)

        XCTAssertNil(NativeHomeCharts.stressLevel(hours: [], days: [], todayKey: "2026-11-12"))
    }

    func testBucketedStressLevelMatchesRawOnFlatSyntheticDay() {
        let start = 1_700_000_000
        let bucketSeconds = 300
        var samples: [(ts: Int, bpm: Int)] = []
        var buckets: [HRBucket] = []
        for index in 0..<10 {
            let bpm = 50 + index * 5
            let ts0 = start + index * bucketSeconds
            for offset in 0..<bucketSeconds {
                samples.append((ts: ts0 + offset, bpm: bpm))
            }
            buckets.append(HRBucket(ts: ts0, bpm: Double(bpm), minBpm: Double(bpm), maxBpm: Double(bpm)))
        }
        let rawHours = NativeHomeCharts.stressSeries(samples: samples, stride: 3)
        let bucketHours = NativeHomeCharts.stressSeries(buckets: buckets)
        let rawLevel = NativeHomeCharts.stressLevel(hours: rawHours, days: [], todayKey: "2026-11-12")
        let bucketLevel = NativeHomeCharts.stressLevel(hours: bucketHours, days: [], todayKey: "2026-11-12")
        XCTAssertEqual(rawLevel ?? -1, bucketLevel ?? -1, accuracy: 0.01)
        XCTAssertEqual(bucketLevel ?? -1, NativeHomeCharts.stressValue(bpm: 95), accuracy: 0.01)
    }

    func testStressHeroCaptionIsStressWhileScrubbing() {
        XCTAssertEqual(NativeStressHero.caption(scrubbing: false), "Average")
        XCTAssertEqual(NativeStressHero.caption(scrubbing: true), "Stress")
    }

    func testTonightSleepFollowsActivitiesAndStrainOnlySnapshotExists() {
        let names = HomeSnapshot.sections.map(\.name)
        XCTAssertTrue(names.contains("myday"))
        XCTAssertTrue(names.contains("page-strain-only"))
        XCTAssertEqual(HomeSnapshot.activities.first?.kind, .sleep)
        XCTAssertFalse(HomeSnapshot.strainOnlyModel.sleep.known)
        XCTAssertEqual(HomeSnapshot.strainOnlyModel.sleep.value, "—")
        XCTAssertNil(HomeSnapshot.strainOnlyModel.sleep.fraction)
        XCTAssertFalse(HomeSnapshot.strainOnlyModel.recovery.known)
        XCTAssertEqual(HomeSnapshot.strainOnlyModel.recovery.value, "—")
        XCTAssertTrue(HomeSnapshot.strainOnlyModel.strain.known)
        XCTAssertEqual(HomeSnapshot.caloriesMetric.title, "Calories")
    }

    func testHomeAndStressResolveTheSameSeries() {
        let samples = [(ts: 100, bpm: 48), (ts: 200, bpm: 86), (ts: 300, bpm: 124)]
        let home = NativeHomeCharts.stressSeries(samples: samples, stride: 1)
        let page = NativeHomeCharts.stressSeries(samples: samples, stride: 1)
        XCTAssertEqual(home.map(\.value), page.map(\.value))
        XCTAssertEqual(home.map(\.time), page.map(\.time))
        XCTAssertEqual(
            NativeHomeCharts.stressLevel(hours: home, days: [], todayKey: "2026-11-12") ?? -1,
            NativeHomeCharts.stressValue(bpm: 124),
            accuracy: 0.01
        )
        XCTAssertEqual(
            NativeStressResolver.level(hours: home, days: [], todayKey: "2026-11-12"),
            NativeHomeCharts.stressLevel(hours: home, days: [], todayKey: "2026-11-12")
        )
    }

    func testRenderHomeSections() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NATIVE_SNAPSHOTS"] == "1",
            "Set NATIVE_SNAPSHOTS=1 to write Home PNGs"
        )
        guard #available(macOS 13.1, *) else {
            throw XCTSkip("ImageRenderer.nsImage needs macOS 13.1+")
        }

        let dir = URL(fileURLWithPath: "/tmp/native-snaps", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }

        for section in HomeSnapshot.sections {
            for pass in NativeSnapshotPass.all {
                NSApp.appearance = NSAppearance(named: pass.scheme == .dark ? .darkAqua : .aqua)
                let url = dir.appendingPathComponent("home-\(section.name)-\(pass.suffix).png")
                try render(section.view, padded: section.padded, pass: pass, to: url)
            }
        }
        for section in NativeGallerySnapshot.sections where [
            "sleep-page", "sleep-page-empty", "recovery-page", "strain-page", "activity-page",
        ].contains(section.name) {
            for pass in NativeSnapshotPass.all {
                NSApp.appearance = NSAppearance(named: pass.scheme == .dark ? .darkAqua : .aqua)
                let url = dir.appendingPathComponent("\(section.name)-\(pass.suffix).png")
                try render(section.view, padded: section.padded, pass: pass, to: url)
            }
        }

        try NativeComparePage.write(to: dir)
    }

    func testRenderSettingsPages() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NATIVE_SNAPSHOTS"] == "1",
            "Set NATIVE_SNAPSHOTS=1 to write settings PNGs"
        )
        guard #available(macOS 13.1, *) else {
            throw XCTSkip("ImageRenderer.nsImage needs macOS 13.1+")
        }

        let dir = URL(fileURLWithPath: "/tmp/native-snaps", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel()
        let pages: [(name: String, view: AnyView)] = [
            ("power-saving", AnyView(PowerSavingView().environmentObject(model))),
            ("backup-sync", AnyView(BackupSyncView().environmentObject(model))),
            ("licenses", AnyView(LicensesView())),
            ("apple-health-settings", AnyView(AppleHealthSettingsView())),
        ]
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for page in pages {
            for pass in [(scheme: ColorScheme.light, suffix: "light", aqua: NSAppearance.Name.aqua),
                         (scheme: .dark, suffix: "dark", aqua: .darkAqua)] {
                NSApp.appearance = NSAppearance(named: pass.aqua)
                let url = dir.appendingPathComponent("settings-\(page.name)-\(pass.suffix).png")
                try render(page.view, padded: false, pass: NativeSnapshotPass(
                    style: .apple, scheme: pass.scheme, suffix: pass.suffix
                ), to: url)
            }
        }
    }

    @available(macOS 13.1, *)
    private func render<V: View>(_ view: V, padded: Bool, pass: NativeSnapshotPass, to url: URL) throws {
        let page = pass.style == .whoop
            ? Color(red: 13 / 255, green: 17 / 255, blue: 20 / 255)
            : (pass.scheme == .dark
                ? Color(red: 0, green: 0, blue: 0)
                : Color(red: 242 / 255, green: 242 / 255, blue: 247 / 255))
        let host = view
            .padding(padded ? 16 : 0)
            .frame(width: 393)
            .fixedSize(horizontal: false, vertical: true)
            .nativeStyleBridge(override: pass.style)
            .environment(\.nativeStyle, pass.style)
            .environment(\.colorScheme, pass.scheme)
            .preferredColorScheme(pass.scheme)
            .background(page)
        let renderer = ImageRenderer(content: host)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(width: 393, height: nil)
        guard let image = renderer.nsImage,
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

enum NativeComparePage {
    static func write(to dir: URL) throws {
        let repo = URL(fileURLWithPath: "/Users/jasonhe/dev/noop")
        let whoop = repo.appendingPathComponent("Tools/whoop-parity/out")
        let cmp = dir.appendingPathComponent("cmp", isDirectory: true)
        try FileManager.default.createDirectory(at: cmp, withIntermediateDirectories: true)
        let rows: [(title: String, snap: String, id: String)] = [
            ("Home", "home-page", "home_top"),
            ("Sleep", "sleep-page", "sleep_score"),
            ("Recovery", "recovery-page", "recovery_score"),
            ("Strain", "strain-page", "strain_week"),
            ("Stress", "home-stress", "stress"),
            ("Journal", "home-journal-list", "journal"),
            ("Activity", "activity-page", "activity"),
        ]
        func jpeg(_ png: URL, name: String) -> String {
            let dest = cmp.appendingPathComponent("\(name).jpg")
            if let written = try? writeJPEG(from: png, to: dest) {
                return written.path
            }
            return png.path
        }
        func img(_ path: String) -> String {
            "<img src=\"\(path)\" alt=\"\">"
        }
        var html = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Native full-page comparison</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 24px; color: var(--foreground); }
          h1 { font-size: 22px; font-weight: 650; margin: 0 0 8px; }
          .lede { font-size: 13px; margin: 0 0 28px; opacity: 0.7; }
          .row { margin-bottom: 40px; }
          .row h2 { font-size: 15px; font-weight: 650; margin: 0 0 10px; }
          .cols { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 12px; align-items: start; }
          figure { margin: 0; }
          figure img { width: 100%; max-width: 420px; height: auto; display: block; border-radius: 8px; }
          figcaption { font-size: 11px; margin-top: 6px; opacity: 0.75; }
        </style>
        </head>
        <body>
        <h1>Native hybrid vs WHOOP-style vs real WHOOP vs previous NOOP</h1>
        <p class="lede">Full page bodies. Same facts; five drawings.</p>
        """
        for row in rows {
            let hybridLight = jpeg(dir.appendingPathComponent("\(row.snap)-hybrid-light.png"), name: "\(row.snap)-hybrid-light")
            let hybridDark = jpeg(dir.appendingPathComponent("\(row.snap)-hybrid-dark.png"), name: "\(row.snap)-hybrid-dark")
            let whoopStyle = jpeg(dir.appendingPathComponent("\(row.snap)-whoop.png"), name: "\(row.snap)-whoop")
            let whoopDir = whoop.appendingPathComponent(row.id)
            let realPNG = whoopDir.appendingPathComponent("whoop_full.png")
            let realSource = FileManager.default.fileExists(atPath: realPNG.path)
                ? realPNG
                : whoopDir.appendingPathComponent("whoop.png")
            let real = jpeg(realSource, name: "\(row.id)-whoop")
            let prev = jpeg(whoop.appendingPathComponent("\(row.id)/noop.png"), name: "\(row.id)-noop")
            html += """
            <section class="row">
              <h2>\(row.title)</h2>
              <div class="cols">
                <figure>
                  \(img(hybridLight))
                  <figcaption>Hybrid light</figcaption>
                </figure>
                <figure>
                  \(img(hybridDark))
                  <figcaption>Hybrid dark</figcaption>
                </figure>
                <figure>
                  \(img(whoopStyle))
                  <figcaption>WHOOP-style</figcaption>
                </figure>
                <figure>
                  \(img(real))
                  <figcaption>Real WHOOP</figcaption>
                </figure>
                <figure>
                  \(img(prev))
                  <figcaption>NOOP before</figcaption>
                </figure>
              </div>
            </section>
            """
        }
        html += "</body></html>\n"
        try html.write(to: dir.appendingPathComponent("compare.html"), atomically: true, encoding: .utf8)
    }

    static func writeJPEG(from png: URL, to dest: URL, maxWidth: CGFloat = 420) throws -> URL {
        guard let image = NSImage(contentsOf: png) else { return png }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return png }
        let scale = min(1, maxWidth / size.width)
        let pixelsWide = max(1, Int((size.width * scale).rounded()))
        let pixelsHigh = max(1, Int((size.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return png }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(
            in: NSRect(x: 0, y: 0, width: CGFloat(pixelsWide), height: CGFloat(pixelsHigh)),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
            return png
        }
        try data.write(to: dest)
        return dest
    }
}
#endif

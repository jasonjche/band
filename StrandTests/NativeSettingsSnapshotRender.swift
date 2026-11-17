#if DEBUG
import XCTest
import SwiftUI
import AppKit
import WhoopStore
@testable import Strand

/// Snapshots for journal editor, More, Data & Backup, and Profile.
/// Skipped unless `NATIVE_SNAPSHOTS=1` (pass `TEST_RUNNER_NATIVE_SNAPSHOTS=1` to xcodebuild).
@MainActor
final class NativeSettingsSnapshotRender: XCTestCase {

    func testRenderJournalMoreBackupProfile() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NATIVE_SNAPSHOTS"] == "1",
            "Set NATIVE_SNAPSHOTS=1 to write settings PNGs"
        )
        guard #available(macOS 13.1, *) else {
            throw XCTSkip("ImageRenderer.nsImage needs macOS 13.1+")
        }

        let dir = URL(fileURLWithPath: "/tmp/native-snaps", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12))!
        let lastDrink = NativeJournalNotes.date(minutes: 21 * 60 + 30, on: day, calendar: cal)

        let model = AppModel()
        let alcohol = JournalCatalogItem(
            canonical: "Did you drink any alcohol?", displayName: nil, kind: .bool,
            group: .nutrition, sortIndex: 0, hidden: false, custom: false
        )
        let caffeine = JournalCatalogItem(
            canonical: "Did you have caffeine?", displayName: nil, kind: .bool,
            group: .nutrition, sortIndex: 1, hidden: false, custom: false
        )
        let screen = JournalCatalogItem(
            canonical: "Did you view a screen in bed?", displayName: nil, kind: .bool,
            group: .lifestyle, sortIndex: 2, hidden: false, custom: false
        )
        let stressed = JournalCatalogItem(
            canonical: "Did you feel stressed?", displayName: nil, kind: .bool,
            group: .behaviour, sortIndex: 3, hidden: false, custom: false
        )

        let pages: [(name: String, view: AnyView)] = [
            ("journal-editor", AnyView(NativeJournalLogForm(
                items: [alcohol, caffeine, screen, stressed],
                answers: [
                    "Did you drink any alcohol?": true,
                    "Did you have caffeine?": true,
                    "Did you view a screen in bed?": false,
                    "Did you feel stressed?": false,
                ],
                numeric: [
                    "Did you drink any alcohol?": 2,
                    "Did you have caffeine?": 1,
                ],
                times: [
                    "Did you drink any alcohol?": lastDrink,
                    "Did you have caffeine?": lastDrink,
                ],
                day: day,
                onToggle: { _, _ in },
                onNumeric: { _, _ in }
            ))),
            // More and Data & Backup are Lists, which ImageRenderer cannot draw on macOS.
            ("profile", AnyView(NativeProfileView()
                .environmentObject(ProfileStore())
                .environmentObject(Repository(deviceId: "preview")))),
        ]

        for page in pages {
            for pass in NativeSnapshotPass.all {
                NSApp.appearance = NSAppearance(named: pass.scheme == .dark ? .darkAqua : .aqua)
                let url = dir.appendingPathComponent("settings-\(page.name)-\(pass.suffix).png")
                try render(page.view, pass: pass, to: url)
            }
        }
    }

    @available(macOS 13.1, *)
    private func render<V: View>(_ view: V, pass: NativeSnapshotPass, to url: URL) throws {
        let page = pass.style == .whoop
            ? Color(red: 13 / 255, green: 17 / 255, blue: 20 / 255)
            : (pass.scheme == .dark
                ? Color(red: 0, green: 0, blue: 0)
                : Color(red: 242 / 255, green: 242 / 255, blue: 247 / 255))
        let host = view
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
#endif

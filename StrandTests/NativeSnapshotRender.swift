#if DEBUG
import XCTest
import SwiftUI
import AppKit
import StrandDesign
@testable import Strand

/// Renders Native gallery sections to `/tmp/native-snaps`. Never fails CI: skipped unless
/// `NATIVE_SNAPSHOTS=1` (pass `TEST_RUNNER_NATIVE_SNAPSHOTS=1` to xcodebuild).
@MainActor
final class NativeSnapshotRender: XCTestCase {
    func testRenderGallerySections() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NATIVE_SNAPSHOTS"] == "1",
            "Set NATIVE_SNAPSHOTS=1 to write gallery PNGs"
        )
        guard #available(macOS 13.1, *) else {
            throw XCTSkip("ImageRenderer.nsImage needs macOS 13.1+")
        }

        let dir = URL(fileURLWithPath: "/tmp/native-snaps", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }

        for section in NativeGallerySnapshot.sections {
            for pass in NativeSnapshotPass.all {
                NSApp.appearance = NSAppearance(named: pass.scheme == .dark ? .darkAqua : .aqua)
                let url = dir.appendingPathComponent("\(section.name)-\(pass.suffix).png")
                try render(section.view, padded: section.padded, pass: pass, to: url)
            }
        }
        for section in NativeSleepGallery.sections {
            for pass in NativeSnapshotPass.all {
                NSApp.appearance = NSAppearance(named: pass.scheme == .dark ? .darkAqua : .aqua)
                let url = dir.appendingPathComponent("\(section.name)-\(pass.suffix).png")
                try render(section.view, padded: section.padded, pass: pass, to: url)
            }
        }
    }

    @available(macOS 13.1, *)
    private func render<V: View>(_ view: V, padded: Bool, pass: NativeSnapshotPass, to url: URL) throws {
        let canvas = pass.style == .whoop
            ? Color(hex: "#0D1114")
            : (pass.scheme == .dark ? Color(hex: "#000000") : Color(hex: "#F2F2F7"))
        let host = view
            .padding(padded ? 16 : 0)
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

struct NativeSnapshotPass {
    var style: NativeStyle
    var scheme: ColorScheme
    var suffix: String

    static let all: [NativeSnapshotPass] = [
        NativeSnapshotPass(style: .apple, scheme: .light, suffix: "hybrid-light"),
        NativeSnapshotPass(style: .apple, scheme: .dark, suffix: "hybrid-dark"),
        NativeSnapshotPass(style: .whoop, scheme: .dark, suffix: "whoop"),
    ]
}
#endif

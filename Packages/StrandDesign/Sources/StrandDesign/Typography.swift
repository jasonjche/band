import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Strand Typography (§9.2)
//
// SF Rounded follows the supplied reference's friendly Apple-native geometry. Tabular digits keep live
// metrics stable, while named text styles retain Dynamic Type scaling. SF Mono remains reserved for logs.
//
// All numeric styles use `.monospacedDigit()` so live values don't reflow.

public enum StrandFont {

    // MARK: Family

    /// Maps a point size onto the Dynamic Type style whose scaling curve it should follow.
    /// At the default (Large) size the scaled face matches `size` exactly.
    public static func scalingTextStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ...11: return .caption2
        case ...13: return .caption
        case ...15: return .subheadline
        case ...17: return .body
        case ...20: return .title3
        case ...22: return .title2
        case ...28: return .title2
        case ...34: return .title
        default: return .largeTitle
        }
    }

    /// System face at a custom size that still tracks Dynamic Type via `UIFontMetrics`.
    /// macOS has no equivalent scaler, so the face stays at `size` there.
    public static func scaledSystem(
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design,
        relativeTo textStyle: Font.TextStyle? = nil
    ) -> Font {
        let style = textStyle ?? scalingTextStyle(for: size)
        return cachedFont(size: size, weight: weight, design: design, textStyle: style, tabular: false)
    }

    private static func roundedSystem(_ size: CGFloat, weight: Font.Weight) -> Font {
        cachedFont(
            size: size,
            weight: weight,
            design: .rounded,
            textStyle: scalingTextStyle(for: size),
            tabular: true
        )
    }

    private struct FontCacheKey: Hashable {
        var size: CGFloat
        var weight: Int
        var design: Int
        var textStyle: Int
        var tabular: Bool
    }

    private static let fontCacheLock = NSLock()
    private static var fontCache: [FontCacheKey: Font] = [:]
    private static var fontCacheObserver: NSObjectProtocol?

    private static func cachedFont(
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design,
        textStyle: Font.TextStyle,
        tabular: Bool
    ) -> Font {
        observeContentSizeCategory()
        let key = FontCacheKey(
            size: size,
            weight: weightID(weight),
            design: designID(design),
            textStyle: textStyleID(textStyle),
            tabular: tabular
        )
        fontCacheLock.lock()
        if let hit = fontCache[key] {
            fontCacheLock.unlock()
            return hit
        }
        fontCacheLock.unlock()
        var font = makeSystemFont(size: size, weight: weight, design: design, textStyle: textStyle)
        if tabular {
            font = font.monospacedDigit()
        }
        fontCacheLock.lock()
        fontCache[key] = font
        fontCacheLock.unlock()
        return font
    }

    private static func makeSystemFont(
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design,
        textStyle: Font.TextStyle
    ) -> Font {
        #if canImport(UIKit)
        let base = UIFont.systemFont(ofSize: size, weight: uiWeight(weight))
        let descriptor: UIFontDescriptor
        if design == .default {
            descriptor = base.fontDescriptor
        } else {
            descriptor = base.fontDescriptor.withDesign(uiDesign(design)) ?? base.fontDescriptor
        }
        let font = UIFont(descriptor: descriptor, size: size)
        return Font(UIFontMetrics(forTextStyle: uiTextStyle(textStyle)).scaledFont(for: font))
        #elseif canImport(AppKit)
        let base = NSFont.systemFont(ofSize: size, weight: nsWeight(weight))
        guard design != .default,
              let descriptor = base.fontDescriptor.withDesign(nsDesign(design)),
              let designed = NSFont(descriptor: descriptor, size: size) else {
            return Font(base)
        }
        return Font(designed)
        #else
        return .system(size: size, weight: weight, design: design)
        #endif
    }

    private static func observeContentSizeCategory() {
        fontCacheLock.lock()
        let needed = fontCacheObserver == nil
        fontCacheLock.unlock()
        guard needed else { return }
        #if os(iOS) || os(tvOS)
        let observer = NotificationCenter.default.addObserver(
            forName: UIContentSizeCategory.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            fontCacheLock.lock()
            fontCache.removeAll(keepingCapacity: true)
            fontCacheLock.unlock()
        }
        fontCacheLock.lock()
        if fontCacheObserver == nil {
            fontCacheObserver = observer
        } else {
            NotificationCenter.default.removeObserver(observer)
        }
        fontCacheLock.unlock()
        #endif
    }

    private static func weightID(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight: return 0
        case .thin: return 1
        case .light: return 2
        case .regular: return 3
        case .medium: return 4
        case .semibold: return 5
        case .bold: return 6
        case .heavy: return 7
        case .black: return 8
        default: return 3
        }
    }

    private static func designID(_ design: Font.Design) -> Int {
        switch design {
        case .serif: return 1
        case .rounded: return 2
        case .monospaced: return 3
        default: return 0
        }
    }

    private static func textStyleID(_ style: Font.TextStyle) -> Int {
        switch style {
        case .largeTitle: return 0
        case .title: return 1
        case .title2: return 2
        case .title3: return 3
        case .headline: return 4
        case .body: return 5
        case .callout: return 6
        case .subheadline: return 7
        case .footnote: return 8
        case .caption: return 9
        case .caption2: return 10
        default: return 5
        }
    }

    #if DEBUG
    public static func resetFontCacheForTests() {
        fontCacheLock.lock()
        fontCache.removeAll()
        fontCacheLock.unlock()
    }

    public static func fontCacheCountForTests() -> Int {
        fontCacheLock.lock()
        defer { fontCacheLock.unlock() }
        return fontCache.count
    }
    #endif

    #if canImport(UIKit)
    private static func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    private static func uiDesign(_ design: Font.Design) -> UIFontDescriptor.SystemDesign {
        switch design {
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        default: return .default
        }
    }

    private static func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .body: return .body
        case .callout: return .callout
        case .subheadline: return .subheadline
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
    #elseif canImport(AppKit)
    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    private static func nsDesign(_ design: Font.Design) -> NSFontDescriptor.SystemDesign {
        switch design {
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        default: return .default
        }
    }
    #endif

    // MARK: Scale (§9.2)

    /// Display 64–80 / Bold — the gauge score number. Helvetica Neue 700 with tight
    /// tracking (≈ -0.04em), tabular digits so a changing value never reflows.
    public static func display(_ size: CGFloat = 72) -> Font {
        roundedSystem(size, weight: .bold).monospacedDigit()
    }

    /// The tight tracking for big display numbers (≈ -0.04em). Apply alongside
    /// `display(_:)` at the use site, e.g. `.tracking(StrandFont.displayTracking(72))`.
    public static func displayTracking(_ size: CGFloat = 72) -> CGFloat {
        -size * 0.04
    }

    /// A Helvetica-Neue numeric style at an arbitrary size/weight — the house
    /// numeral. Tabular so live values align. Use anywhere a score/number is shown.
    public static func rounded(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        roundedSystem(size, weight: weight)
    }

    /// Title1 28 / Bold. Scales with Dynamic Type.
    public static let title1 = Font.system(.title, design: .rounded, weight: .bold)

    /// Title2 22 / Semibold. Scales with Dynamic Type.
    public static let title2 = Font.system(.title2, design: .rounded, weight: .semibold)

    /// Headline 17 / Semibold. Scales with Dynamic Type.
    public static let headline = Font.system(.headline, design: .rounded, weight: .semibold)

    /// Body 15 / Regular. Scales with Dynamic Type.
    public static let body = Font.system(.body, design: .rounded, weight: .regular)

    /// Subhead 13. Scales with Dynamic Type.
    public static let subhead = Font.system(.subheadline, design: .rounded, weight: .regular)

    /// Caption 12. Scales with Dynamic Type.
    public static let caption = Font.system(.caption, design: .rounded, weight: .regular)

    /// Footnote 11. Scales with Dynamic Type.
    public static let footnote = Font.system(.footnote, design: .rounded, weight: .regular)

    /// Overline 11 / Bold, +1.4 tracking (apply `.tracking(1.4)` at use site;
    /// `overlineText(_:)` does it for you). Sparing ALL-CAPS labels. Scales with Dynamic Type.
    ///
    /// Also the face for compact status copy in constrained chrome (the Today header's sync capsule),
    /// used there WITHOUT the tracking — that is sentence case, not an overline, and the letter-spacing
    /// is what makes an overline read as one.
    public static let overline = Font.system(.caption2, design: .rounded, weight: .semibold)

    /// `overline` at a custom point size — same Helvetica face, weight and Dynamic-Type scaling
    /// (relativeTo `.caption2`), just smaller. Passing 11 returns exactly `.overline`. Lets a caller
    /// shrink an ALL-CAPS label to fit a small container without losing accessibility text-scaling.
    public static func overlineScaled(_ size: CGFloat) -> Font {
        #if canImport(UIKit)
        let base = UIFont.systemFont(ofSize: size, weight: .semibold)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let rounded = UIFont(descriptor: descriptor, size: size)
        return Font(UIFontMetrics(forTextStyle: .caption2).scaledFont(for: rounded))
        #elseif canImport(AppKit)
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: size) else {
            return Font(base)
        }
        return Font(rounded)
        #else
        return roundedSystem(size, weight: .semibold)
        #endif
    }

    /// Mono 13 (SF Mono) — raw / log views. Tabular by nature.
    public static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    // MARK: Numeric variants (tabular digits)

    /// A numeric style at an arbitrary size/weight, for live values — Helvetica
    /// Neue, tabular digits. This is the tile/value numeral.
    public static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        roundedSystem(size, weight: weight)
    }

    /// Helvetica-Neue body number — for inline live values that should align. Scales with Dynamic
    /// Type alongside its sibling `body`/`caption` labels so a value and its label stay matched.
    public static let bodyNumber = Font.system(.body, design: .rounded, weight: .medium).monospacedDigit()

    /// Helvetica-Neue caption number — for small live values (sparklines, chips). Scales with Dynamic Type.
    public static let captionNumber = Font.system(.caption, design: .rounded, weight: .medium).monospacedDigit()

    /// Mono at an arbitrary size.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The recommended tracking for overline text (wide ALL-CAPS labels, ≈ 0.13em).
    public static let overlineTracking: CGFloat = 0.45
}

// MARK: - Text helpers

public extension Text {
    /// Style as an overline label: ALL-CAPS, bold, +1.4 tracking, tertiary text.
    func strandOverline() -> some View {
        self.font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(StrandPalette.textSecondary)
    }
}

public extension View {
    /// Convenience: an overline-styled label string.
    static func strandOverline(_ string: String) -> some View {
        Text(string).strandOverline()
    }
}

#if DEBUG
#Preview("Typography") {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("88").font(StrandFont.display(72)).tracking(StrandFont.displayTracking(72)).foregroundStyle(StrandPalette.textPrimary)
            Text("Title 1 / Bold 28").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
            Text("Title 2 / Semibold 22").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text("Headline / Semibold 17").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text("Body / Regular 15 — the thread of you, read in full.")
                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Text("Subhead 13").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Text("Caption 12").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text("Footnote 11").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Text("Overline").strandOverline()
            Text("0xAA 41 00 1c crc32=f3a1  mono 13").font(StrandFont.mono).foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 4) {
                Text("HRV").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Text("62").font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                Text("ms").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 520, height: 620)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif

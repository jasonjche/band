import SwiftUI

/// Health-app colour world for the Native shell: saturated category tints that sit
/// on `systemGroupedBackground`, with independent light and dark hexes.
///
/// These are presentation tokens only. Recovery / sleep band thresholds match the
/// existing Native chrome (`<34` / `<67` recovery, `<70` / `<85` sleep).
public enum NativeTokens {

    // MARK: Recovery

    /// Low recovery band. WHOOP red, readable on white.
    public static let recoveryLow = Color(light: "#E53935", dark: "#FF3B30")
    /// Mid recovery band. WHOOP yellow, darkened in light so it reads on white.
    public static let recoveryMid = Color(light: "#C9A000", dark: "#F5D000")
    /// High recovery band. WHOOP green, darkened in light so it reads on white.
    public static let recoveryHigh = Color(light: "#00B85C", dark: "#00E66A")

    // MARK: Strain / Sleep / Stress

    /// Strain (blue), Health-like saturation rather than neon.
    public static let strain = Color(light: "#2B6DE5", dark: "#5B9BFF")
    /// Sleep chrome: WHOOP steel-blue sampled from the sleep ring (`sleep_score/whoop.png`)
    /// and the Sleep pill (`home_top/whoop.png`) at `#7BA2BA`. Light hex is the same hue,
    /// darkened so it still reads on white.
    public static let sleep = Color(light: "#3E6E8A", dark: "#7BA2BA")

    public static let stressLow = Color(light: "#1AA3B5", dark: "#4DD0E0")
    public static let stressMid = Color(light: "#2E9E4F", dark: "#4CD964")
    public static let stressHigh = Color(light: "#E09A16", dark: "#FFC043")

    // MARK: Sleep performance bands

    public static let bandPoor = Color(light: "#E07A20", dark: "#FF9F45")
    public static let bandSufficient = Color(light: "#6B7785", dark: "#A0AAB4")
    public static let bandOptimal = Color(light: "#1B9E57", dark: "#3DDB7C")

    // MARK: Heart / respiratory / activity

    /// HRV, resting HR, and heart rate. Health pink, measured `#FF375F` / `#FE375E`.
    public static let heart = Color(light: "#E31B4D", dark: "#FF375F")
    /// Respiratory rate. Health cyan, measured `#3CD3FE`.
    public static let respiratory = Color(light: "#00A3C8", dark: "#3CD3FE")
    /// Steps and calories. Health activity orange, measured `#FF5813`.
    public static let activity = Color(light: "#E85D13", dark: "#FF5813")
    /// Legacy alias for heart-family charts that still read `vitals`.
    public static let vitals = heart

    // MARK: Heart-rate zones (stacked Strain trends)

    public static let hrZone1 = Color(light: "#C6C6C8", dark: "#8E8E93")
    public static let hrZone2 = Color(light: "#2B6DE5", dark: "#5B9BFF")
    public static let hrZone3 = Color(light: "#00B85C", dark: "#00E66A")
    public static let hrZone4 = Color(light: "#E85D13", dark: "#FF5813")
    public static let hrZone5 = Color(light: "#E53935", dark: "#FF3B30")

    public static func hrZone(_ number: Int) -> Color {
        switch number {
        case 2: return hrZone2
        case 3: return hrZone3
        case 4: return hrZone4
        case 5: return hrZone5
        default: return hrZone1
        }
    }

    // MARK: Sleep stages (Apple hypnogram)

    /// Awake. Measured `#FF684F` / `#FE6A4E`.
    public static let sleepAwake = Color(light: "#E85A40", dark: "#FF684F")
    /// REM. Measured `#3CD3FE` / `#0191FD`.
    public static let sleepREM = Color(light: "#0191FD", dark: "#3CD3FE")
    /// Light / Core. WHOOP lavender `#A3A3F1`, distinct from the steel-blue sleep tint.
    /// Light hex is the same hue, darkened so it reads on white.
    public static let sleepCore = Color(light: "#5B5BC7", dark: "#A3A3F1")
    /// Deep. Measured `#3634A2`.
    public static let sleepDeep = Color(light: "#3634A2", dark: "#5B59C7")

    public static let positiveDelta = Color(light: "#1B9E57", dark: "#3DDB7C")
    public static let negativeDelta = Color(light: "#D35400", dark: "#FF8A3D")

    /// Grouped page. Matches iOS `systemGroupedBackground` on macOS snapshots too.
    public static let page = Color(light: "#F2F2F7", dark: "#000000")
    /// Card fill. Matches iOS `secondarySystemGroupedBackground`.
    public static let card = Color(light: "#FFFFFF", dark: "#1C1C1E")
    /// Hairline / chart grid. Dark hex measured from Health dashed gridlines.
    public static let separator = Color(light: "#C6C6C8", dark: "#363638")
    /// Soft selected-day column behind a weekly bar (Apple / hybrid).
    public static let highlight = Color(light: "#E5E5EA", dark: "#2C2C2E")

    /// Ring track opacity applied to the metric tint (not grey). Spec: ~0.2.
    public static let trackOpacity: Double = 0.2

    /// 0 red / 1 yellow / 2 green. 37% is the middle WHOOP band (34–66).
    public static func recoveryBand(_ percent: Double) -> Color {
        if percent < 34 { return recoveryLow }
        if percent < 67 { return recoveryMid }
        return recoveryHigh
    }

    public static func sleepBand(_ percent: Double) -> Color {
        if percent < 70 { return bandPoor }
        if percent < 85 { return bandSufficient }
        return bandOptimal
    }

    // MARK: WHOOP style (dark-only)

    /// Deep near-black canvas. WHOOP is dark-only.
    public static let whoopPage = Color(hex: "#0D1114")
    /// Slightly lifted top of the page gradient.
    public static let whoopPageTop = Color(hex: "#151A1F")
    /// Raised dark card fill.
    public static let whoopCard = Color(hex: "#1A2026")
    /// Selected-day column behind a weekly bar.
    public static let whoopHighlight = Color(hex: "#2A3138")
    /// Hairline / hatch / track grey.
    public static let whoopSeparator = Color(hex: "#2C333A")
    public static let whoopTrack = Color(hex: "#3A424A")
    public static let whoopHatch = Color(hex: "#4A545C")
    public static let whoopLabel = Color(hex: "#8B929A")

    /// Sleep steel-blue ring and sleep bars. Sampled `#7BA2BA`.
    public static let whoopSleep = Color(hex: "#7BA2BA")
    /// Strain azure.
    public static let whoopStrain = Color(hex: "#1A9BFF")
    /// Recovery green (high band).
    public static let whoopRecoveryHigh = Color(hex: "#00E66A")
    /// Recovery yellow (mid band).
    public static let whoopRecoveryMid = Color(hex: "#F5D000")
    /// Recovery red (low band).
    public static let whoopRecoveryLow = Color(hex: "#FF3B30")

    public static let whoopBandPoor = Color(hex: "#FF9A2E")
    public static let whoopBandSufficient = Color(hex: "#8B929A")
    public static let whoopBandOptimal = Color(hex: "#00E66A")

    public static let whoopHeart = Color(hex: "#9BB6C9")
    public static let whoopRespiratory = Color(hex: "#4DD0E0")
    public static let whoopActivity = Color(hex: "#1A9BFF")

    public static let whoopSleepAwake = Color(hex: "#C5C9CE")
    /// Light stage. Sampled `#A3A3F1` from `sleep_last_night/whoop.png`.
    public static let whoopSleepLight = Color(hex: "#A3A3F1")
    public static let whoopSleepDeep = Color(hex: "#E056A0")
    public static let whoopSleepREM = Color(hex: "#A05EE8")

    public static let whoopPositiveDelta = Color(hex: "#00E66A")
    public static let whoopNegativeDelta = Color(hex: "#FF9A2E")
    public static let whoopStressLow = Color(hex: "#4DD0E0")
    public static let whoopStressMid = Color(hex: "#00E66A")
    public static let whoopStressHigh = Color(hex: "#F5D000")

    public static let whoopTrackOpacity: Double = 1

    public static func whoopRecoveryBand(_ percent: Double) -> Color {
        if percent < 34 { return whoopRecoveryLow }
        if percent < 67 { return whoopRecoveryMid }
        return whoopRecoveryHigh
    }

    public static func whoopSleepBand(_ percent: Double) -> Color {
        if percent < 70 { return whoopBandPoor }
        if percent < 85 { return whoopBandSufficient }
        return whoopBandOptimal
    }

    /// Heavy WHOOP numerals. Default SF, not Rounded, not a WHOOP face.
    public static func whoopNumber(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }

    /// Small ALL-CAPS letter-spaced labels.
    public static func whoopCaps(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    public static let whoopCapsTracking: CGFloat = 0.8
    public static let whoopCardRadius: CGFloat = 16
}

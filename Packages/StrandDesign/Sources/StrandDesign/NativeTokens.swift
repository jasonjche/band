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

    /// Stress Monitor line, sampled from WHOOP (`IMG` 9:01 PM chart).
    /// Cyan at 0, teal at 1.0, green through 1.2–2.0, yellow-green at 2.4,
    /// gold at 2.7, orange-gold only at 3.0. Medium must not read yellow.
    public static let stressLine0 = Color(light: "#1AA3B5", dark: "#5CB9D2")
    public static let stressLine1 = Color(light: "#1A9E88", dark: "#44D8AE")
    public static let stressLine12 = Color(light: "#1BB87A", dark: "#3DE2A5")
    public static let stressLine2 = Color(light: "#2E9E4F", dark: "#90D973")
    public static let stressLine24 = Color(light: "#8A9A28", dark: "#B7C55D")
    public static let stressLine27 = Color(light: "#C9A000", dark: "#DBB041")
    public static let stressLine3 = Color(light: "#E09A16", dark: "#E5A638")

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

    // MARK: Heart-rate zones (list, bars, tap-to-highlight chart)

    /// Sampled from WHOOP activity screens (IMG_9448–9451). Zone 0 is the darker grey;
    /// zone 1 is silver. One function colours the zone list, the duration bars, and the
    /// selected-zone chart highlight.
    public static let hrZone0 = Color(light: "#6C7278", dark: "#5C646C")
    public static let hrZone1 = Color(light: "#8E97A3", dark: "#A8B2BC")
    public static let hrZone2 = Color(light: "#2B7FD4", dark: "#5BA3E0")
    public static let hrZone3 = Color(light: "#1A9E80", dark: "#6FCBB4")
    public static let hrZone4 = Color(light: "#D4893C", dark: "#E0A06A")
    public static let hrZone5 = Color(light: "#D4522A", dark: "#E86B3C")

    public static func hrZone(_ number: Int) -> Color {
        switch number {
        case 0: return hrZone0
        case 1: return hrZone1
        case 2: return hrZone2
        case 3: return hrZone3
        case 4: return hrZone4
        case 5: return hrZone5
        default: return number < 0 ? hrZone0 : hrZone5
        }
    }

    // MARK: Sleep stages (WHOOP hypnogram)

    /// Awake. Dark `#C8C8C8` sampled from the Last Night bar in `IMG_9429`.
    /// Light hex is the same grey, darkened so it reads on white.
    public static let sleepAwake = Color(light: "#8E8E93", dark: "#C8C8C8")
    /// Light. Dark `#A4A3EB` sampled from the Light bar in `IMG_9429` and the
    /// Light ticks in `IMG_9430`.
    public static let sleepLight = Color(light: "#6E6DD4", dark: "#A4A3EB")
    /// Light / Core alias — same WHOOP periwinkle as `sleepLight`.
    public static let sleepCore = sleepLight
    /// Deep / SWS. Dark `#EC9AF4` sampled from the SWS bar in `IMG_9429` and
    /// the Deep stack in `IMG_9434`.
    public static let sleepDeep = Color(light: "#C45CCE", dark: "#EC9AF4")
    /// REM. Dark `#A15EE5` sampled from the REM bar in `IMG_9429` and the REM
    /// stack in `IMG_9434`.
    public static let sleepREM = Color(light: "#7A3DC4", dark: "#A15EE5")

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

    /// Awake. Sampled `#C8C8C8` from `IMG_9429` Last Night bar.
    public static let whoopSleepAwake = Color(hex: "#C8C8C8")
    /// Light. Sampled `#A4A3EB` from `IMG_9429` / `IMG_9430`.
    public static let whoopSleepLight = Color(hex: "#A4A3EB")
    /// Deep / SWS. Sampled `#EC9AF4` from `IMG_9429` and `IMG_9434`.
    public static let whoopSleepDeep = Color(hex: "#EC9AF4")
    /// REM. Sampled `#A15EE5` from `IMG_9429` and `IMG_9434`.
    public static let whoopSleepREM = Color(hex: "#A15EE5")

    public static let whoopPositiveDelta = Color(hex: "#00E66A")
    public static let whoopNegativeDelta = Color(hex: "#FF9A2E")
    public static let whoopStressLow = Color(hex: "#4DD0E0")
    public static let whoopStressMid = Color(hex: "#00E66A")
    public static let whoopStressHigh = Color(hex: "#F5D000")
    public static let whoopStressLine0 = Color(hex: "#5CB9D2")
    public static let whoopStressLine1 = Color(hex: "#44D8AE")
    public static let whoopStressLine12 = Color(hex: "#3DE2A5")
    public static let whoopStressLine2 = Color(hex: "#90D973")
    public static let whoopStressLine24 = Color(hex: "#B7C55D")
    public static let whoopStressLine27 = Color(hex: "#DBB041")
    public static let whoopStressLine3 = Color(hex: "#E5A638")

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
    /// Scales with Dynamic Type; at the default size the face matches `size`.
    public static func whoopNumber(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        StrandFont.scaledSystem(size: size, weight: weight, design: .default).monospacedDigit()
    }

    /// Small ALL-CAPS letter-spaced labels. Scales with Dynamic Type.
    public static func whoopCaps(_ size: CGFloat = 11) -> Font {
        StrandFont.scaledSystem(size: size, weight: .semibold, design: .default)
    }

    public static let whoopCapsTracking: CGFloat = 0.8
    public static let whoopCardRadius: CGFloat = 16
}

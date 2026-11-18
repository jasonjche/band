import Foundation

/// Single resolver for Band's battery-policy behaviours (live HR notify, offload cadence,
/// analysis gating, widget reload coalescing).
///
/// One UserDefaults flag so the whole set can be turned off and the previous cadence returns.
/// Stock NOOP never registers the key, so `bool(forKey:)` reads false and nothing changes.
/// Band pins it true via `PersonalDefaults.registeredDefaults`.
enum BandPowerPolicy {
    static let defaultsKey = "noopBandPowerPolicy"

    static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}

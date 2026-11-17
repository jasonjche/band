import Foundation

/// Runtime brand for the running bundle. Stock builds read "NOOP" from Info.plist; a personal
/// iOS build overrides `CFBundleDisplayName` and `NoopPersonalBuild` via xcconfig.
enum AppBrand {
    /// Home-screen / navigation name. Falls back to "NOOP" when the plist key is missing or empty
    /// so a stock macOS build and tests keep the upstream name.
    static var name: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "NOOP" : trimmed
    }

    /// True when `NoopPersonalBuild` is YES in this target's Info.plist (set from
    /// `NOOP_PERSONAL_BUILD` in xcconfig). Missing key → stock behaviour.
    static var isPersonalBuild: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "NoopPersonalBuild")
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "yes", "true", "1": return true
            default: return false
            }
        }
        return false
    }
}

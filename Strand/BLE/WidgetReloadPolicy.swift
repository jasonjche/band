import Foundation

/// Widget / watch timeline reloads after an offload. At most once per offload that
/// actually stored new records while the Band power policy is on.
enum WidgetReloadPolicy {
    static func shouldReload(policyEnabled: Bool, storedNewData: Bool) -> Bool {
        if !policyEnabled { return true }
        return storedNewData
    }
}

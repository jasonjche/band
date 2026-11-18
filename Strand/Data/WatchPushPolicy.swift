import Foundation

/// When the phone may spend a WatchConnectivity transfer on a new score snapshot.
///
/// Complication/context transfers share a ~50/day budget. Building the snapshot (an `exploreSeries`
/// Rest read) is itself the cost a throttled caller used to pay on every dashboard refresh, so the
/// spacing check is a pure function the caller can apply BEFORE that work.
enum WatchPushPolicy {
    static let minInterval: TimeInterval = 30 * 60

    /// True when nothing has been pushed this process, or at least `interval` has elapsed since one was.
    static func spacingAllowsPush(lastPushedAt: Date?, now: Date,
                                  interval: TimeInterval = minInterval) -> Bool {
        guard let at = lastPushedAt else { return true }
        return now.timeIntervalSince(at) >= interval
    }
}

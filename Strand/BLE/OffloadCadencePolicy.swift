import Foundation

/// Whether an incoming strap EVENT packet may kick a historical offload.
///
/// With the Band power policy on, a strap EVENT packet starts a sync only when the last one is
/// at least 15 minutes old. In the background nothing else wakes the app (the periodic timer is
/// suspended and 0x2A37 no longer notifies), so blocking `.strap` outright stopped background
/// sync entirely. With the flag off, `.strap` keeps its 90 s floor in `BackfillPolicy`.
enum OffloadTriggerPolicy {
    static let strapFloorSeconds: TimeInterval = 900

    static func shouldRequest(trigger: BackfillTrigger, policyEnabled: Bool,
                              secondsSinceLast: TimeInterval? = nil) -> Bool {
        guard policyEnabled, trigger == .strap else { return true }
        guard let secondsSinceLast else { return true }
        return secondsSinceLast >= strapFloorSeconds
    }
}

/// Auto-continue only when the previous slice ended on the idle-timeout slice cap AND the
/// existing backlog guards still say the strap has more pending. Short HISTORY_COMPLETE
/// chatter waits for the next scheduled offload, which is what stopped `backfilling`
/// flipping every few seconds.
enum OffloadContinuePolicy {
    static func shouldAutoContinue(policyEnabled: Bool,
                                   endedOnSliceCap: Bool,
                                   stillConnected: Bool,
                                   strapNewestTs: Int?,
                                   ourFrontierTs: Int?,
                                   wallNowUnix: Int,
                                   persistedSensorRows: Bool,
                                   lastTrimAdvanced: Bool,
                                   consecutiveCount: Int,
                                   maxAutoContinues: Int = BackfillContinuation.defaultMaxAutoContinues,
                                   behindGapSeconds: Int = BackfillContinuation.defaultBehindGapSeconds) -> Bool {
        if policyEnabled && !endedOnSliceCap { return false }
        // Under the Band policy "more pending" means the strap is measurably ahead of what we hold.
        // Rows persisted this slice are not enough on their own: that is what kept re-kicking.
        if policyEnabled, let newest = strapNewestTs, let frontier = ourFrontierTs,
           (newest - frontier) <= max(behindGapSeconds, 900) {
            return false
        }
        return BackfillContinuation.shouldAutoContinue(
            stillConnected: stillConnected,
            strapNewestTs: strapNewestTs,
            ourFrontierTs: ourFrontierTs,
            wallNowUnix: wallNowUnix,
            persistedSensorRows: persistedSensorRows,
            lastTrimAdvanced: lastTrimAdvanced,
            consecutiveCount: consecutiveCount,
            maxAutoContinues: maxAutoContinues,
            // Under the Band policy a strap only minutes ahead is not a backlog; the next
            // scheduled offload picks it up. Continue immediately only for a real gap.
            behindGapSeconds: policyEnabled ? max(behindGapSeconds, 900) : behindGapSeconds)
    }
}

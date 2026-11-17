import Foundation

/// Whether an incoming strap EVENT packet should kick a historical offload.
///
/// When the Band power policy is on, EVENT packets no longer start a sync — connect,
/// foreground, the 15-minute periodic timer, manual, and auto-continue still do.
/// When the flag is off, `.strap` keeps its 90 s floor in `BackfillPolicy`.
enum OffloadTriggerPolicy {
    static func shouldRequest(trigger: BackfillTrigger, policyEnabled: Bool) -> Bool {
        if policyEnabled && trigger == .strap { return false }
        return true
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

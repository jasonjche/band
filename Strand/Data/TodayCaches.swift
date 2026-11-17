import Foundation
import WhoopStore
import StrandDesign

struct TodayHistoryWideCache {
    let sparks: [String: [Double]]
    let stepsEstByDay: [String: Int]
    let workouts: [WorkoutRow]
    let appleDays: [AppleDaily]
    let xiaomiDays: Int
    let xiaomiSleeps: Int
    let stressToday: Double?
    let fitnessAgeToday: Double?
    let vo2maxToday: Double?
    let vitalityToday: Double?
}

struct TodayDayScopedCache {
    let restSpark: [Double]
    let restScore: Double?
    let provenanceByMetric: [String: String]
    let providerByMetric: [String: ScoreInputProvider]
    let hrPoints: [TrendPoint]
    let stepActivityClassToday: Int?
    let liveTodayStrain: Double?
    let hrAxis: ClosedRange<Date>
    let sleepToday: CachedSleepSession?
    let bankedAt: Date
}

/// Sync-status chip used by the Devices screen.
enum SyncChipState: Equatable {
    case syncing(chunks: Int, pagesBehind: Int?)
    case synced(agoText: String)
    case experimentalLive
    case hidden

    @MainActor
    static func resolve(live: LiveState) -> SyncChipState {
        if live.backfilling {
            return .syncing(chunks: live.syncChunksThisSession,
                            pagesBehind: live.pagesBehindAtConnect.flatMap { $0 > 0 ? $0 : nil })
        }
        if let ts = live.lastSyncedAt { return .synced(agoText: shortAgo(ts)) }
        if live.historySyncExperimental { return .experimentalLive }
        return .hidden
    }

    private static func shortAgo(_ ts: TimeInterval) -> String {
        let secs = max(0, Int(Date().timeIntervalSince1970 - ts))
        if secs < 60 { return "<1m" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs)h" }
        return "\(hrs / 24)d"
    }
}

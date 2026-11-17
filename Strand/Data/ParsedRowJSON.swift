import Foundation
import WhoopStore

/// One hypnogram segment decoded from a sleep row's `stagesJSON`
/// (`[{start,end,stage}]`). Parsed once per row id and reused.
struct ParsedSleepStage: Equatable, Sendable {
    let start: Int
    let end: Int
    let stage: String
}

extension Repository {
    /// Stable cache key for a sleep row: owner + detected start + the JSON itself so an edit
    /// that rewrites stages without changing startTs still misses.
    nonisolated static func sleepStageCacheKey(_ session: CachedSleepSession) -> String {
        "\(session.deviceId ?? "")|\(session.startTs)|\(session.stagesJSON ?? "")"
    }

    /// Stable cache key for a workout row's zone blob.
    nonisolated static func workoutZoneCacheKey(_ row: WorkoutRow) -> String {
        "\(row.startTs)|\(row.sport)|\(row.source)|\(row.zonesJSON ?? "")"
    }

    nonisolated static func parseStagesJSON(_ json: String?) -> [ParsedSleepStage] {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { seg in
            guard let s = (seg["start"] as? NSNumber)?.intValue,
                  let e = (seg["end"] as? NSNumber)?.intValue, e > s,
                  let name = seg["stage"] as? String else { return nil }
            return ParsedSleepStage(start: s, end: e, stage: name)
        }
    }

    nonisolated static func parseZonesJSON(_ json: String?) -> [Double]? {
        WorkoutZones.percents(json)
    }
}

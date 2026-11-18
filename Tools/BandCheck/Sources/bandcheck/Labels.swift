import Foundation

/// User-confirmed workout labels, kept OUTSIDE the repository (private). Each entry says whether
/// a time span really was a workout. `real: true` adds it to the detection reference; `real: false`
/// removes any reference span it overlaps (e.g. an auto-saved row the user says was not a workout).
///
///     {"workouts": [{"start": "2026-01-05T18:00:00-05:00", "end": "2026-01-05T19:00:00-05:00", "real": true}]}
struct WorkoutLabels: Decodable {
    struct Entry: Decodable {
        let start: String
        let end: String
        let real: Bool
        var startTs: Int { WorkoutLabels.ts(start) }
        var endTs: Int { WorkoutLabels.ts(end) }
    }
    var workouts: [Entry] = []

    init() {}

    static func load(path: String) throws -> WorkoutLabels {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return try JSONDecoder().decode(WorkoutLabels.self, from: Data(contentsOf: url))
    }

    static func ts(_ iso: String) -> Int {
        let f = ISO8601DateFormatter()
        return Int(f.date(from: iso)?.timeIntervalSince1970 ?? 0)
    }
}

import Foundation
import WhoopProtocol
import WhoopStore

/// Collapse Apple Health workout duplicates and score imported strain with BandStrain.
///
/// Another app can write a generic `Workout` row for the same window as a specific
/// sport that already has HR. Those two rows share no primary key (`sport` is in it),
/// so both land in the store and the generic one has no heart rate. Drop the generic
/// when a specific sport occupies the same window (±60 s on start and end).
///
/// Strain on import uses the BandStrain activity map over whatever HR the window has.
/// NULL only when there are no samples at all.
public enum AppleWorkoutImport {

    public static let genericSport = "Workout"
    public static let windowToleranceSec = 60
    public static let backfillVersion = 1

    public static func isGenericSport(_ sport: String) -> Bool {
        sport.compare(genericSport, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    public static func sameWindow(_ a: WorkoutRow, _ b: WorkoutRow,
                                  tolerance: Int = windowToleranceSec) -> Bool {
        abs(a.startTs - b.startTs) <= tolerance && abs(a.endTs - b.endTs) <= tolerance
    }

    /// Keep specific sports; drop a generic `Workout` that shares a window with one.
    public static func partition(_ rows: [WorkoutRow]) -> (keep: [WorkoutRow], drop: [WorkoutRow]) {
        var dropIdx = Set<Int>()
        for i in rows.indices where isGenericSport(rows[i].sport) {
            let generic = rows[i]
            let hasSpecific = rows.indices.contains { j in
                j != i && !isGenericSport(rows[j].sport) && sameWindow(generic, rows[j])
            }
            if hasSpecific { dropIdx.insert(i) }
        }
        var keep: [WorkoutRow] = []
        var drop: [WorkoutRow] = []
        keep.reserveCapacity(rows.count - dropIdx.count)
        for i in rows.indices {
            if dropIdx.contains(i) { drop.append(rows[i]) } else { keep.append(rows[i]) }
        }
        return (keep, drop)
    }

    public static func collapseDuplicates(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        partition(rows).keep
    }

    /// Avg / peak / Effort 0–100 from any non-empty HR window. Nil only when there are no samples
    /// or BandStrain params are missing.
    public static func scored(samples: [HRSample], maxHR: Double,
                              restingHR: Double = BandStrain.defaultRestingHR) -> (avgHr: Int, maxHr: Int, strain100: Double)? {
        guard !samples.isEmpty, let params = BandStrain.bundledParams() else { return nil }
        let total = samples.reduce(0) { $0 + $1.bpm }
        let avg = Int((Double(total) / Double(samples.count)).rounded())
        let peak = samples.map(\.bpm).max() ?? avg
        let s21 = BandStrain.strain(samples, maxHR: maxHR, restingHR: restingHR, params: params) ?? 0
        let s100 = BandStrain.effort100(s21) ?? 0
        return (avg, peak, s100)
    }

    /// Fill missing avgHr / maxHr / strain from `samples`. Nil when nothing was missing or there
    /// is no HR to score.
    public static func filled(_ row: WorkoutRow, samples: [HRSample], maxHR: Double,
                              restingHR: Double = BandStrain.defaultRestingHR) -> WorkoutRow? {
        guard row.strain == nil || row.avgHr == nil || row.maxHr == nil else { return nil }
        guard let s = scored(samples: samples, maxHR: maxHR, restingHR: restingHR) else { return nil }
        return WorkoutRow(
            startTs: row.startTs, endTs: row.endTs, sport: row.sport, source: row.source,
            durationS: row.durationS, energyKcal: row.energyKcal,
            avgHr: row.avgHr ?? s.avgHr, maxHr: row.maxHr ?? s.maxHr,
            strain: row.strain ?? s.strain100,
            distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes, steps: row.steps)
    }
}

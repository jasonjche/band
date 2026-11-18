import Foundation

/// Personalized HRmax from stored workout peaks.
///
/// Keeps values in 120...225 and requires at least 10. A peak must be confirmed:
/// it appears as a workout max on at least two workouts, or it sits 1 bpm above
/// such a repeated peak. Isolated spikes 2+ bpm above the repeated cluster are
/// ignored. On WHOOP's workout-export aggregates that rule is 198 (197 appears
/// three times; 198 is adjacent; 199...202 each appear once). If nothing repeats,
/// falls back to the 99th nearest-rank percentile.
public enum ObservedHRMax {
    public static let validRange = 120...225
    public static let minCount = 10

    public static func estimate(_ values: [Int]) -> Int? {
        let kept = values.filter { validRange.contains($0) }
        let n = kept.count
        guard n >= minCount else { return nil }
        var counts: [Int: Int] = [:]
        for value in kept { counts[value, default: 0] += 1 }
        let repeated = counts.filter { $0.value >= 2 }.map(\.key)
        if let base = repeated.max() {
            return kept.contains(base + 1) ? base + 1 : base
        }
        let sorted = kept.sorted()
        let index = Int((0.99 * Double(n)).rounded(.up)) - 1
        return sorted[min(max(index, 0), n - 1)]
    }
}

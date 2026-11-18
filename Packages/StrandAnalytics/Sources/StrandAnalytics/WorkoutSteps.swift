import Foundation

/// Workout-window step count from stored streams. Strap counter first, Apple Health hours
/// as fallback. Steps do not feed strain.
///
/// Prefer `StepsCounter.stepsInWindow` over the workout's `[start, end]`, then scale by the
/// user's `stepTicksPerStep`. When that window is empty, fold overlapping Apple Health
/// hourly buckets in proportion to the overlap. A stored row count is last resort.
public enum WorkoutSteps {
    public static let hourSeconds = 3_600

    /// Scale raw strap ticks to steps. Nil when there is nothing countable.
    public static func scaledTicks(_ ticks: Int?, ticksPerStep: Double) -> Int? {
        guard let ticks, ticks > 0 else { return nil }
        let scaled = Int((Double(ticks) / max(ticksPerStep, 0.5)).rounded())
        return scaled > 0 ? scaled : nil
    }

    /// Steps from Apple Health hourly buckets overlapping `[from, to)`. Each hour contributes
    /// `steps × overlap / 3600`. Nil when nothing overlaps.
    public static func appleStepsInWindow(
        _ hours: [(ts: Int, steps: Int)],
        from: Int,
        to: Int
    ) -> Int? {
        guard to > from else { return nil }
        var total = 0.0
        for hour in hours {
            let hourEnd = hour.ts + hourSeconds
            let overlap = min(to, hourEnd) - max(from, hour.ts)
            guard overlap > 0, hour.steps > 0 else { continue }
            total += Double(hour.steps) * Double(overlap) / Double(hourSeconds)
        }
        let rounded = Int(total.rounded())
        return rounded > 0 ? rounded : nil
    }

    /// Strap wins, then Apple Health, then a stored row count.
    public static func resolve(strap: Int?, apple: Int?, stored: Int?) -> Int? {
        if let strap, strap > 0 { return strap }
        if let apple, apple > 0 { return apple }
        if let stored, stored > 0 { return stored }
        return nil
    }
}

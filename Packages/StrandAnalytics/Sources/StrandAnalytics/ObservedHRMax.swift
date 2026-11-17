import Foundation

/// Personalized HRmax from stored workout peaks.
///
/// Keeps values in 120...225, requires at least 10, and returns the 99th
/// nearest-rank percentile so one or two sensor spikes do not set the number.
public enum ObservedHRMax {
    public static let validRange = 120...225
    public static let minCount = 10

    public static func estimate(_ values: [Int]) -> Int? {
        let kept = values.filter { validRange.contains($0) }
        let n = kept.count
        guard n >= minCount else { return nil }
        let sorted = kept.sorted()
        let index = Int((0.99 * Double(n)).rounded(.up)) - 1
        return sorted[min(max(index, 0), n - 1)]
    }
}

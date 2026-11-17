import SwiftUI
import StrandDesign

/// Selection box. `@Published` updates observers (hero, marker) without
/// invalidating the chart that holds this in `@State`.
final class NativeScopeScrub: ObservableObject {
    @Published var key: String?
    @Published var time: Date?
}

/// Display-only HR polyline. Stats and scrub keep the raw samples.
enum NativeHRDisplay {
    static func line(_ points: [NativeHourPoint]) -> [NativeHourPoint] {
        NativeHRSmoothing.smooth(points)
    }
}

/// Nearest-point snapping and selection chrome. Pure; views never fold this in `body`.
enum NativeChartScrubMath {
    /// Nearest finite hour sample. Nil when the series is empty or the nearest
    /// sample is farther than `maxGap` (a hole, not a point).
    static func nearestHour(
        to time: Date,
        in points: [NativeHourPoint],
        maxGap: TimeInterval? = nil
    ) -> NativeHourPoint? {
        guard !points.isEmpty else { return nil }
        let nearest = points.min {
            abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time))
        }
        guard let nearest else { return nil }
        if let maxGap, abs(nearest.time.timeIntervalSince(time)) > maxGap {
            return nil
        }
        return nearest
    }

    /// 1.5× the smallest adjacent gap. A hole larger than that is not a point.
    static func inferredMaxGap(in points: [NativeHourPoint]) -> TimeInterval? {
        guard points.count >= 2 else { return nil }
        let gaps = zip(points, points.dropFirst()).map {
            $1.time.timeIntervalSince($0.time)
        }.filter { $0 > 0 }
        guard let minGap = gaps.min() else { return nil }
        return minGap * 1.5
    }

    /// Nearest bucket with a value. Nil when the closest bucket is a gap.
    static func nearestBucket(to date: Date, in buckets: [NativeScopeBucket]) -> NativeScopeBucket? {
        buckets.min {
            abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date))
        }.flatMap { $0.value == nil ? nil : $0 }
    }

    /// Point whose key matches, only if finite. Nil for gaps.
    static func finitePoint(key: String, in points: [NativeDayPoint]) -> NativeDayPoint? {
        points.first { $0.key == key || $0.day == key }.flatMap { $0.value.isFinite ? $0 : nil }
    }

    static func night(key: String, in nights: [NativeSleepNight]) -> NativeSleepNight? {
        nights.first { $0.key == key }
    }

    /// Selected bar stays opaque; others dim only while a real point is selected.
    static func barOpacity(isSelected: Bool, hasSelection: Bool) -> Double {
        if !hasSelection || isSelected { return 1 }
        return 0.35
    }

    /// Horizontal drag vs vertical page scroll.
    static func isHorizontalScrub(translation: CGSize, minimum: CGFloat = 8) -> Bool {
        abs(translation.width) >= minimum && abs(translation.width) >= abs(translation.height)
    }

    static func isTap(translation: CGSize, maximum: CGFloat = 8) -> Bool {
        hypot(translation.width, translation.height) < maximum
    }
}

/// Filled series-coloured dot with a thin card-coloured ring so it reads on the line.
struct NativeSelectedVertex: View {
    var tint: Color
    var size: CGFloat = 10
    @Environment(\.nativeStyle) private var style

    var body: some View {
        ZStack {
            Circle().fill(NativePaint.card(style))
            Circle()
                .fill(tint)
                .padding(2)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

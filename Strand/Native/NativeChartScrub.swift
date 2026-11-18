import SwiftUI
import Charts
import StrandDesign

/// Selection box. `@Published` updates observers (hero, marker) without
/// invalidating the chart that holds this in `@State`.
final class NativeScopeScrub: ObservableObject {
    @Published var key: String?
    @Published var time: Date?
}

/// Display-only HR polyline. Stats and scrub keep the raw samples.
enum NativeHRDisplay {
    static let plotBudget = 480

    static func line(_ points: [NativeHourPoint]) -> [NativeHourPoint] {
        NativeStressMonitorMath.drawPoints(NativeHRSmoothing.smooth(points), budget: plotBudget)
    }
}

/// Nearest-point snapping and selection chrome. Pure; views never fold this in `body`.
enum NativeChartScrubMath {
    static let hourDuration: TimeInterval = 3_600
    /// Dashed vertical hairline used by every line / hypnogram scrub cursor.
    static let hairlineStyle = StrokeStyle(lineWidth: 1, dash: [4, 3])

    /// Midpoint of `[start, end)`. Swift Charts places unit BarMarks at this x,
    /// so selection must use it too — `start` sits on the leading edge of the bar.
    static func unitCenter(start: Date, end: Date) -> Date {
        start.addingTimeInterval(end.timeIntervalSince(start) / 2)
    }

    static func unitCenter(of date: Date, unit: Calendar.Component, calendar: Calendar) -> Date {
        guard let interval = calendar.dateInterval(of: unit, for: date) else { return date }
        return unitCenter(start: interval.start, end: interval.end)
    }

    /// Date Charts should bind for a unit bar so the selection mark shares the bar's x.
    static func selectionDate(for bucket: NativeScopeBucket) -> Date {
        unitCenter(start: bucket.start, end: bucket.end)
    }

    static func selectionDate(forHour time: Date, calendar: Calendar) -> Date {
        unitCenter(of: time, unit: .hour, calendar: calendar)
    }

    /// Overlay coordinates from `ChartProxy.position` are plot-relative.
    static func overlayPoint(plotOrigin: CGPoint, x: CGFloat, y: CGFloat) -> CGPoint {
        CGPoint(x: plotOrigin.x + x, y: plotOrigin.y + y)
    }

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

    /// Nearest hour *bar*: compare the finger to each slot's unit centre, not its start.
    /// A drag at 10:50 must hit the 10:00 bar (centre 10:30), not 11:00.
    static func nearestCentered(
        to time: Date,
        in points: [NativeHourPoint],
        duration: TimeInterval,
        maxGap: TimeInterval? = nil
    ) -> NativeHourPoint? {
        guard !points.isEmpty, duration > 0 else { return nil }
        let nearest = points.min {
            abs(unitCenter(start: $0.time, end: $0.time.addingTimeInterval(duration)).timeIntervalSince(time))
                < abs(unitCenter(start: $1.time, end: $1.time.addingTimeInterval(duration)).timeIntervalSince(time))
        }
        guard let nearest else { return nil }
        let center = unitCenter(start: nearest.time, end: nearest.time.addingTimeInterval(duration))
        if let maxGap, abs(center.timeIntervalSince(time)) > maxGap {
            return nil
        }
        return nearest
    }

    static func snapHour(
        date: Date?,
        points: [NativeHourPoint],
        calendar: Calendar
    ) -> Date? {
        guard let date,
              let point = nearestCentered(to: date, in: points, duration: hourDuration)
        else { return nil }
        return selectionDate(forHour: point.time, calendar: calendar)
    }

    /// 1.5× the lower-median adjacent gap. A hole larger than that is not a point.
    /// `min()` collapses when a live-appended tail sits ~90s after 5-minute buckets;
    /// the lower median keeps bucket spacing so the scrub dot still lands between them.
    static func inferredMaxGap(in points: [NativeHourPoint]) -> TimeInterval? {
        guard points.count >= 2 else { return nil }
        let gaps = zip(points, points.dropFirst()).map {
            $1.time.timeIntervalSince($0.time)
        }.filter { $0 > 0 }
        guard !gaps.isEmpty else { return nil }
        let sorted = gaps.sorted()
        return sorted[(sorted.count - 1) / 2] * 1.5
    }

    /// Nearest bucket with a value, by unit centre. Nil when the closest bucket is a gap.
    static func nearestBucket(to date: Date, in buckets: [NativeScopeBucket]) -> NativeScopeBucket? {
        buckets.min {
            abs(unitCenter(start: $0.start, end: $0.end).timeIntervalSince(date))
                < abs(unitCenter(start: $1.start, end: $1.end).timeIntervalSince(date))
        }.flatMap { $0.value == nil ? nil : $0 }
    }

    static func snapBucket(
        date: Date?,
        buckets: [NativeScopeBucket],
        bars: Bool
    ) -> (key: String, time: Date)? {
        guard let date, let bucket = nearestBucket(to: date, in: buckets) else { return nil }
        let time = bars ? selectionDate(for: bucket) : bucket.start
        return (bucket.key, time)
    }

    /// Point whose key matches, only if finite. Nil for gaps.
    static func finitePoint(key: String, in points: [NativeDayPoint]) -> NativeDayPoint? {
        points.first { $0.key == key || $0.day == key }.flatMap { $0.value.isFinite ? $0 : nil }
    }

    /// Scrubbed day while dragging; otherwise the page's `highlightKey`.
    /// Ignores a selection that is not a plotted key (Swift Charts can emit the axis label).
    static func emphasizedKey(selected: String?, highlight: String?, keys: [String]) -> String? {
        if let selected, keys.contains(selected) { return selected }
        return highlight
    }

    static func highlightIndex(keys: [String], emphasized: String?) -> Int? {
        guard let emphasized else { return nil }
        return keys.firstIndex(of: emphasized)
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

    /// Nil on lift so the hero returns to its resting summary.
    static func snapTime(
        _ date: Date?,
        in points: [NativeHourPoint],
        maxGap: TimeInterval? = nil
    ) -> Date? {
        guard let date else { return nil }
        return nearestHour(
            to: date,
            in: points,
            maxGap: maxGap ?? inferredMaxGap(in: points)
        )?.time
    }

    /// Category-axis selection. Nil on lift or when Charts emits an axis label.
    static func snapKey(_ key: String?, in keys: [String]) -> String? {
        guard let key, keys.contains(key) else { return nil }
        return key
    }

    static func nearestDate(_ date: Date, in dates: [Date]) -> Date? {
        guard !dates.isEmpty else { return nil }
        return dates.min {
            abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date))
        }
    }

    /// Nil on lift so the hero snaps back to latest / average.
    static func snapDate(_ date: Date?, in dates: [Date]) -> Date? {
        guard let date else { return nil }
        return nearestDate(date, in: dates)
    }

    /// Overlay coordinates from `ChartProxy.position` are plot-relative.
    static func plotFrame(proxy: ChartProxy, geo: GeometryProxy) -> CGRect {
        if #available(iOS 17.0, macOS 14.0, *), let frame = proxy.plotFrame {
            return geo[frame]
        }
        return geo[proxy.plotAreaFrame]
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

/// Dashed vertical hairline plus series-coloured vertices. Overlay-only so LineMarks stay static.
struct NativeChartScrubGuide: View {
    struct Dot: Equatable {
        var y: CGFloat
        var tint: Color
        var size: CGFloat = 10
    }

    var x: CGFloat
    var dots: [Dot]
    var plotFrame: CGRect
    var hairlineColor: Color = NativeTokens.separator

    init(
        x: CGFloat,
        y: CGFloat?,
        tint: Color,
        plotFrame: CGRect,
        vertexSize: CGFloat = 10,
        hairlineColor: Color = NativeTokens.separator
    ) {
        self.x = x
        self.dots = y.map { [Dot(y: $0, tint: tint, size: vertexSize)] } ?? []
        self.plotFrame = plotFrame
        self.hairlineColor = hairlineColor
    }

    init(
        x: CGFloat,
        dots: [Dot],
        plotFrame: CGRect,
        hairlineColor: Color = NativeTokens.separator
    ) {
        self.x = x
        self.dots = dots
        self.plotFrame = plotFrame
        self.hairlineColor = hairlineColor
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: plotFrame.minY))
                path.addLine(to: CGPoint(x: x, y: plotFrame.maxY))
            }
            .stroke(hairlineColor, style: NativeChartScrubMath.hairlineStyle)
            ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                NativeSelectedVertex(tint: dot.tint, size: dot.size)
                    .position(x: x, y: dot.y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Date-axis overlay: hairline at `time`, vertex at each y.
struct NativeChartTimeScrubGuide: View {
    var proxy: ChartProxy
    var time: Date?
    var y: Double?
    var tint: Color
    var vertexSize: CGFloat = 10
    var extra: [(y: Double, tint: Color)] = []
    var hairlineColor: Color = NativeTokens.separator

    var body: some View {
        GeometryReader { geo in
            if let time, let xRel = proxy.position(forX: time) {
                let frame = NativeChartScrubMath.plotFrame(proxy: proxy, geo: geo)
                let x = frame.origin.x + xRel
                let placed = NativeChartScrubMath.overlayPoint(plotOrigin: frame.origin, x: xRel, y: 0)
                if frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: placed.x, y: frame.midY)) {
                    NativeChartScrubGuide(
                        x: x,
                        dots: dots(origin: frame.origin),
                        plotFrame: frame,
                        hairlineColor: hairlineColor
                    )
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func dots(origin: CGPoint) -> [NativeChartScrubGuide.Dot] {
        var out: [NativeChartScrubGuide.Dot] = []
        if let y, let yRel = proxy.position(forY: y) {
            out.append(NativeChartScrubGuide.Dot(y: origin.y + yRel, tint: tint, size: vertexSize))
        }
        for item in extra {
            if let yRel = proxy.position(forY: item.y) {
                out.append(NativeChartScrubGuide.Dot(y: origin.y + yRel, tint: item.tint))
            }
        }
        return out
    }
}

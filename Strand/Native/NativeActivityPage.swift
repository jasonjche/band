import SwiftUI
import Charts
import MapKit
import WhoopStore
import StrandDesign
import StrandAnalytics

// WHOOP activity page drawn in Apple Health chrome.
// Sport + time in the nav, strain/duration hero, HR chart, zones 5→0, stored stats, route if stored.

enum NativeActivityPageLogic {
    static let priorSameSportMinimum = 3
    static let statsWindowDays = 30
    static let hrBucketSeconds = 20

    /// Mean bpm per `seconds` bucket, in time order. Empty buckets are absent, so gaps stay gaps.
    static func bucketed(_ samples: [(ts: Int, bpm: Double)], seconds: Int) -> [NativeHourPoint] {
        guard seconds > 0 else { return [] }
        var sums: [Int: (total: Double, n: Int)] = [:]
        for s in samples {
            let key = s.ts / seconds
            let cur = sums[key] ?? (0, 0)
            sums[key] = (cur.total + s.bpm, cur.n + 1)
        }
        return sums.keys.sorted().map { key in
            let b = sums[key]!
            return NativeHourPoint(time: Date(timeIntervalSince1970: TimeInterval(key * seconds)),
                                   value: b.total / Double(b.n))
        }
    }

    struct Zone: Equatable, Identifiable {
        var id: Int { number }
        var number: Int
        var label: String
        var minutes: Double
        var percent: Double
        var bpmRange: String?
    }

    struct Stat: Equatable, Identifiable {
        var id: String { title }
        var title: String
        var value: String
        var prior: String?
        var delta: NativeScore.Delta
        var symbol: String
        var heartFamily: Bool
        var neutralDelta: Bool = false
    }

    struct Model: Equatable {
        var sport: String
        var timeRange: String
        var sourceLine: String?
        var strainText: String
        var strainDelta: NativeScore.Delta
        var duration: String
        var zones: [Zone]
        var stats: [Stat]
        var isManual: Bool
        var hasStrain: Bool
    }

    static func make(
        _ workout: WorkoutRow,
        prior: [WorkoutRow],
        scale: EffortScale,
        zoneSet: HRZoneSet?,
        percents: [Double]?
    ) -> Model {
        let sameAll = sameSport(as: workout, in: prior, windowDays: nil)
        let sameWindow = sameSport(as: workout, in: prior, windowDays: statsWindowDays)
        let strainValues = sameAll.compactMap(NativeStrain.workout)
        let strain = NativeStrain.workout(workout)
        return Model(
            sport: WorkoutSource.displaySport(workout.sport),
            timeRange: dateTimeRange(startTs: workout.startTs, endTs: workout.endTs),
            sourceLine: importSourceLine(workout.source),
            strainText: NativeDayLogic.strainText(strain, scale: scale),
            strainDelta: strainDelta(current: strain, prior: strainValues),
            duration: durationClock(workout),
            zones: zones(percents: percents, durationS: durationSeconds(workout), zoneSet: zoneSet),
            stats: stats(workout, same: sameWindow),
            isManual: WorkoutSource.classify(workout.source) == .manual,
            hasStrain: strain != nil
        )
    }

    /// True when the window has no HR yet — strap samples have not offloaded, so skip empty cards.
    static func awaitingHeartRate(hrPointCount: Int, zoneCount: Int, heartStatCount: Int) -> Bool {
        hrPointCount == 0 && zoneCount == 0 && heartStatCount == 0
    }

    /// Strain delta vs the average of prior same-sport workouts, only when at least three exist.
    static func strainDelta(current: Double?, prior: [Double]) -> NativeScore.Delta {
        guard prior.count >= priorSameSportMinimum else { return .none }
        return NativeScoreMath.delta(current, prior)
    }

    static func sameSport(as workout: WorkoutRow, in rows: [WorkoutRow], windowDays: Int?) -> [WorkoutRow] {
        let lo: Int? = windowDays.map { workout.startTs - $0 * 86_400 }
        return rows.filter { row in
            row.sport == workout.sport
                && row.startTs != workout.startTs
                && row.startTs < workout.startTs
                && (lo == nil || row.startTs >= lo!)
        }
    }

    /// Z1…Z5 percents of duration; remainder is zone 0. Empty when the row has no zone split.
    static func zoneTimes(percents: [Double]?, durationS: Double) -> [(number: Int, minutes: Double, percent: Double)] {
        guard let percents, percents.count >= 5, durationS > 0 else { return [] }
        let z1to5 = (0..<5).map { i -> Double in
            min(max(percents[i], 0), 100)
        }
        let covered = min(z1to5.reduce(0, +), 100)
        let z0 = max(0, 100 - covered)
        let minutes = durationS / 60
        func row(_ number: Int, _ pct: Double) -> (number: Int, minutes: Double, percent: Double) {
            (number, minutes * pct / 100, pct)
        }
        return [
            row(5, z1to5[4]),
            row(4, z1to5[3]),
            row(3, z1to5[2]),
            row(2, z1to5[1]),
            row(1, z1to5[0]),
            row(0, z0),
        ]
    }

    static func zoneClock(_ minutes: Double) -> String {
        let total = max(0, Int((minutes * 60).rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func importSourceLine(_ source: String) -> String? {
        switch WorkoutSource.classify(source) {
        case .whoop: return "Imported from WHOOP"
        case .apple: return "Imported from Apple Health"
        case .activityFile, .lifting: return "Imported"
        case .manual, .detected: return nil
        }
    }

    static func bpmRange(zone: Int, set: HRZoneSet?) -> String? {
        guard let set else { return nil }
        if zone == 0 {
            guard let z1 = set.zones.first(where: { $0.number == 1 }) else { return nil }
            return "< \(Int(z1.lower.rounded())) BPM"
        }
        guard let bounds = set.zones.first(where: { $0.number == zone }) else { return nil }
        if zone == 5 {
            return "\(Int(bounds.lower.rounded()))+ BPM"
        }
        let hi = max(bounds.lower, bounds.upper - 1)
        return "\(Int(bounds.lower.rounded()))–\(Int(hi.rounded())) BPM"
    }

    static func durationSeconds(_ workout: WorkoutRow) -> Double {
        workout.durationS ?? Double(max(0, workout.endTs - workout.startTs))
    }

    private static func durationClock(_ workout: WorkoutRow) -> String {
        let total = max(0, Int(durationSeconds(workout).rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static let monthDay: DateFormatter = {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "MMM d"
        return day
    }()

    static func dateTimeRange(startTs: Int, endTs: Int) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(startTs))
        let end = Date(timeIntervalSince1970: TimeInterval(endTs))
        let clock = AppClock.hourMinuteFormatter()
        return "\(monthDay.string(from: start)) \(clock.string(from: start)) – \(clock.string(from: end))"
    }

    private static func zones(percents: [Double]?, durationS: Double, zoneSet: HRZoneSet?) -> [Zone] {
        zoneTimes(percents: percents, durationS: durationS).map { row in
            Zone(
                number: row.number,
                label: "Zone \(row.number)",
                minutes: row.minutes,
                percent: row.percent,
                bpmRange: bpmRange(zone: row.number, set: zoneSet)
            )
        }
    }

    private static func stats(_ workout: WorkoutRow, same: [WorkoutRow]) -> [Stat] {
        var rows: [Stat] = []
        if let hr = workout.avgHr {
            rows.append(stat(
                "Average HR", "\(hr) BPM", Double(hr),
                same.compactMap { $0.avgHr.map(Double.init) },
                "heart.fill", heart: true, unit: "BPM", neutralDelta: true
            ))
        }
        if let hr = workout.maxHr {
            rows.append(stat(
                "Max HR", "\(hr) BPM", Double(hr),
                same.compactMap { $0.maxHr.map(Double.init) },
                "heart", heart: true, unit: "BPM", neutralDelta: true
            ))
        }
        if let kcal = workout.energyKcal {
            rows.append(stat(
                "Calories", "\(Int(kcal.rounded())) cal", kcal,
                same.compactMap(\.energyKcal),
                "flame.fill", heart: false, unit: "cal"
            ))
        }
        if let meters = workout.distanceM, meters > 0 {
            let imperial = UserDefaults.standard.string(forKey: UnitPrefs.distanceSystemKey) != UnitSystem.metric.rawValue
            let perUnit = imperial ? 1609.344 : 1000.0
            let unit = imperial ? "mi" : "km"
            let shown = meters / perUnit
            rows.append(stat(
                "Distance", String(format: "%.2f \(unit)", shown), shown,
                same.compactMap(\.distanceM).filter { $0 > 0 }.map { $0 / perUnit },
                "point.topleft.down.to.point.bottomright.curvepath",
                heart: false, unit: unit, decimals: 2
            ))
        }
        if let steps = workout.steps {
            rows.append(stat(
                "Steps", NativeScoreMath.count(Double(steps)), Double(steps),
                same.compactMap { $0.steps.map(Double.init) },
                "figure.walk", heart: false, unit: "steps", grouped: true
            ))
        }
        return rows
    }

    private static func stat(
        _ title: String, _ value: String, _ current: Double, _ prior: [Double],
        _ symbol: String, heart: Bool, unit: String, decimals: Int = 0, grouped: Bool = false,
        neutralDelta: Bool = false
    ) -> Stat {
        let priorText: String?
        if let mean = NativeScoreMath.mean(prior) {
            priorText = NativeScoreMath.labeled(mean, unit: unit, decimals: decimals, grouped: grouped)
        } else {
            priorText = nil
        }
        return Stat(
            title: title,
            value: value,
            prior: priorText,
            delta: NativeScoreMath.delta(current, prior),
            symbol: symbol,
            heartFamily: heart,
            neutralDelta: neutralDelta
        )
    }
}

struct NativeActivityView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @State private var repoHandle: Repository?
    @State private var profileHandle: ProfileStore?
    @State private var intelligenceHandle: IntelligenceEngine?
    @State private var refreshSeq = 0
    @State private var handlesReady = false
    @State private var keyTs: Int
    @State private var workout: WorkoutRow?
    @State private var prior: [WorkoutRow] = []
    @State private var percents: [Double]?
    @State private var hr: [NativeHourPoint] = []
    @State private var hrFromAppleHealth = false
    @State private var route: [RouteMath.LatLng] = []
    @State private var zoneSet: HRZoneSet?
    @State private var showEdit = false
    @State private var confirmDelete = false

    init(startTs: Int) {
        _keyTs = State(initialValue: startTs)
    }

    var body: some View {
        Group {
            if let workout {
                let model = NativeActivityPageLogic.make(
                    workout,
                    prior: prior,
                    scale: UnitPrefs.resolveEffortScale(effortScaleRaw),
                    zoneSet: zoneSet,
                    percents: percents
                )
                NativeActivityBody(
                    model: model,
                    hr: hr,
                    hrFromAppleHealth: hrFromAppleHealth,
                    zoneSet: zoneSet,
                    route: route
                )
                .toolbar {
                    if model.isManual {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Edit") { showEdit = true }
                        }
                        ToolbarItem(placement: .destructiveAction) {
                            Button("Delete", role: .destructive) { confirmDelete = true }
                        }
                    }
                }
                .sheet(isPresented: $showEdit) {
                    NativeAddPastActivityForm(editing: workout, workouts: prior) { row, replacing in
                        Task {
                            await repoHandle?.saveManualWorkout(row, replacing: replacing)
                            await intelligenceHandle?.analyzeRecent()
                            keyTs = row.startTs
                            await load()
                        }
                    }
                }
                .alert("Delete this activity?", isPresented: $confirmDelete) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) {
                        Task {
                            RouteStore.remove(startTs: workout.startTs, sport: workout.sport)
                            await repoHandle?.deleteWorkout(workout)
                            dismiss()
                        }
                    }
                } message: {
                    Text("Removes this workout from your history.")
                }
            } else {
                ProgressView("Loading activity")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(NativePageFill())
        .navigationTitle(workout.map { WorkoutSource.displaySport($0.sport) } ?? "Activity")
        .modifier(NativeInlineTitle())
        .modifier(NativeActivitySubtitle(text: workout.map {
            NativeActivityPageLogic.dateTimeRange(startTs: $0.startTs, endTs: $0.endTs)
        } ?? ""))
        .background {
            NativeRepoSink(refreshSeq: $refreshSeq, ready: $handlesReady) { repoHandle = $0 }
            NativeProfileSink { profileHandle = $0 }
            NativeIntelligenceSink { intelligenceHandle = $0 }
        }
        .task(id: handlesReady ? "\(refreshSeq)-\(keyTs)" : "boot") {
            guard handlesReady else { return }
            await load()
        }
    }

    private func load() async {
        guard let repo = repoHandle else { return }
        zoneSet = profileHandle?.hrZoneSet
        let rows = await repo.workoutRows(days: 120)
        let found = rows.first { $0.startTs == keyTs }
        workout = found
        prior = rows
        guard let workout else {
            hr = []
            percents = nil
            route = []
            return
        }
        percents = repo.parsedZones(for: workout) ?? WorkoutZones.percents(workout.zonesJSON)
        // Strap samples when they cover the workout, else the Apple Health samples stored for it.
        let series = await repo.workoutHeartRate(
            startTs: workout.startTs, endTs: workout.endTs,
            sport: workout.sport, source: workout.source
        )
        hrFromAppleHealth = series.origin == .appleHealth
        hr = NativeActivityPageLogic.bucketed(
            series.samples.map { (ts: $0.ts, bpm: Double($0.bpm)) },
            seconds: NativeActivityPageLogic.hrBucketSeconds
        )
        if let stored = RouteStore.load(startTs: workout.startTs, sport: workout.sport) {
            let pts = RouteMath.decode(stored.polyline)
            route = pts.count >= 2 ? pts : []
        } else {
            route = []
        }
    }
}

struct NativeActivityBody: View {
    var model: NativeActivityPageLogic.Model
    var hr: [NativeHourPoint] = []
    var hrFromAppleHealth: Bool = false
    var zoneSet: HRZoneSet? = nil
    var route: [RouteMath.LatLng] = []
    var scrolls: Bool = true

    var body: some View {
        Group {
            if scrolls {
                NativeChrome.screen { activityBody }
            } else {
                NativeChrome.stack { activityBody }
            }
        }
    }

    @ViewBuilder private var activityBody: some View {
        if let source = model.sourceLine {
            Text(source)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }

        HStack(alignment: .firstTextBaseline) {
            if model.hasStrain {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        NativeValueText(value: model.strainText, size: 34)
                        NativeDelta(delta: model.strainDelta)
                    }
                    Text("Activity Strain")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                Spacer()
            }
            if !model.hasStrain { Spacer() }
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.duration)
                    .font(StrandFont.rounded(28, weight: .semibold))
                    .monospacedDigit()
                Text("Duration")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
        }
        .padding(.top, model.sourceLine == nil ? 8 : 0)

        if awaitingHeartRate {
            Text("Heart rate appears after the next sync")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }

        if hrFromAppleHealth, !hr.isEmpty {
            Text("Heart rate from Apple Health")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }

        if !hr.isEmpty {
            NativeChrome.panel {
                NativeActivityHRChart(points: hr, zoneSet: zoneSet)
                    .frame(minHeight: 256)
            }
        }

        if !model.zones.isEmpty {
            NativeChrome.panel {
                ForEach(model.zones) { zone in
                    NativeActivityZoneRow(zone: zone, totalMinutes: totalZoneMinutes)
                }
            }
        }

        if route.count >= 2 {
            NativeChrome.panel {
                NativeActivityRouteMap(points: route)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: NativeChrome.cardRadius, style: .continuous))
            }
        }

        if !model.stats.isEmpty {
            NativeChrome.section("Key Statistics")
            NativeChrome.panel {
                VStack(spacing: 0) {
                    ForEach(Array(model.stats.enumerated()), id: \.element.id) { index, stat in
                        if index > 0 {
                            Divider().padding(.leading, 34)
                        }
                        NativeContributorRow(
                            symbol: stat.symbol,
                            title: stat.title,
                            value: stat.value,
                            prior: stat.prior,
                            delta: stat.delta,
                            tint: stat.heartFamily ? NativeChrome.heart : NativeChrome.activity,
                            neutralDelta: stat.neutralDelta
                        )
                    }
                }
            }
            if model.stats.contains(where: { $0.prior != nil }) {
                NativeChrome.footnote("Compared with your last 30 days")
            }
        }
    }

    private var totalZoneMinutes: Double {
        max(model.zones.reduce(0) { $0 + $1.minutes }, 1)
    }

    private var awaitingHeartRate: Bool {
        NativeActivityPageLogic.awaitingHeartRate(
            hrPointCount: hr.count,
            zoneCount: model.zones.count,
            heartStatCount: model.stats.filter(\.heartFamily).count
        )
    }
}

struct NativeActivityHRChart: View {
    var points: [NativeHourPoint]
    var zoneSet: HRZoneSet? = nil
    @Environment(\.nativeStyle) private var style
    @State private var scrub = NativeScopeScrub()

    private var yDomain: ClosedRange<Double> {
        NativeChartDay.fittedDomain(points.map(\.value), fallback: 80...180)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            NativeActivityHRHero(scrub: scrub, points: points)
                .frame(height: 76, alignment: .topLeading)
            NativeActivityHRPlot(
                points: points,
                yDomain: yDomain,
                lineTint: lineTint,
                zoneSet: zoneSet,
                scrub: scrub
            )
            .frame(height: 180)
        }
    }

    private var lineTint: Color {
        style == .whoop ? NativeTokens.whoopLabel : Color.primary
    }
}

private struct NativeActivityHRHero: View {
    @ObservedObject var scrub: NativeScopeScrub
    var points: [NativeHourPoint]

    var body: some View {
        if let time = scrub.time,
           let point = NativeChartScrubMath.nearestHour(
            to: time,
            in: points,
            maxGap: NativeChartScrubMath.inferredMaxGap(in: points)
           ) {
            NativeHeroValue(
                caption: "Heart Rate",
                value: "\(Int(point.value.rounded()))",
                unit: "BPM",
                date: NativeScopeFormat.time(point.time)
            )
        } else if let average = NativeScoreMath.mean(points.map(\.value)) {
            NativeHeroValue(
                caption: "Average",
                value: "\(Int(average.rounded()))",
                unit: "BPM"
            )
        }
    }
}

private struct NativeActivityHRPlot: View {
    var points: [NativeHourPoint]
    var yDomain: ClosedRange<Double>
    var lineTint: Color
    var zoneSet: HRZoneSet?
    var scrub: NativeScopeScrub

    private var timeBinding: Binding<Date?> {
        Binding(
            get: { scrub.time },
            set: { scrub.time = $0 }
        )
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Time", point.time), y: .value("HR", point.value))
                    .foregroundStyle(lineTint)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .trailing, values: NativeChartTicks.values(in: yDomain, maxCount: 3)) { _ in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 2)) { value in
                AxisGridLine(stroke: NativeChrome.gridStroke)
                    .foregroundStyle(NativeChrome.hairline)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.hour().minute())
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .modifier(NativeTimeSelect(selected: timeBinding, onChange: { _ in }))
        .chartOverlay { proxy in
            NativeActivityHRMarker(proxy: proxy, points: points, zoneSet: zoneSet, scrub: scrub)
        }
        .accessibilityLabel("Heart rate")
    }
}

private struct NativeActivityHRMarker: View {
    var proxy: ChartProxy
    var points: [NativeHourPoint]
    var zoneSet: HRZoneSet?
    @ObservedObject var scrub: NativeScopeScrub

    var body: some View {
        GeometryReader { _ in
            if let time = scrub.time,
               let point = NativeChartScrubMath.nearestHour(
                to: time,
                in: points,
                maxGap: NativeChartScrubMath.inferredMaxGap(in: points)
               ),
               let x = proxy.position(forX: point.time),
               let y = proxy.position(forY: point.value) {
                NativeSelectedVertex(tint: scrubTint(for: point.value))
                    .position(x: x, y: y)
            }
        }
        .allowsHitTesting(false)
    }

    private func scrubTint(for bpm: Double) -> Color {
        guard let zoneSet else { return NativeTokens.heart }
        return NativeTokens.hrZone(zoneSet.zoneNumber(forBPM: bpm))
    }
}

struct NativeActivityZoneRow: View {
    var zone: NativeActivityPageLogic.Zone
    var totalMinutes: Double

    var body: some View {
        let share = totalMinutes > 0 ? zone.minutes / totalMinutes : 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(NativeTokens.hrZone(zone.number))
                    .frame(width: 8, height: 8)
                Text(zone.label)
                    .font(.subheadline.weight(.semibold))
                if let bpmRange = zone.bpmRange {
                    Text(bpmRange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(Int(zone.percent.rounded()))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NativeTokens.hrZone(zone.number))
                Spacer(minLength: 8)
                Text(NativeActivityPageLogic.zoneClock(zone.minutes))
                    .font(StrandFont.rounded(15, weight: .semibold))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(NativeTokens.separator.opacity(0.35))
                    Capsule()
                        .fill(NativeTokens.hrZone(zone.number))
                        .frame(width: max(zone.minutes > 0 ? 6 : 0, geo.size.width * CGFloat(share)))
                }
            }
            .frame(height: 10)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(zone.label), \(NativeActivityPageLogic.zoneClock(zone.minutes))")
    }
}

struct NativeActivityRouteMap: View {
    var points: [RouteMath.LatLng]

    var body: some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            NativeActivitySwiftMap(points: points)
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct NativeActivitySwiftMap: View {
    var points: [RouteMath.LatLng]

    private var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    private var region: MKCoordinateRegion {
        let lats = points.map(\.lat)
        let lons = points.map(\.lon)
        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? 0
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.4, 0.002),
                longitudeDelta: max((maxLon - minLon) * 1.4, 0.002)
            )
        )
    }

    var body: some View {
        Map(position: .constant(.region(region)), interactionModes: []) {
            MapPolyline(coordinates: coordinates)
                .stroke(Color.primary, lineWidth: 3)
        }
        .disabled(true)
        .allowsHitTesting(false)
        .accessibilityLabel("Workout route")
    }
}

private struct NativeActivitySubtitle: ViewModifier {
    var text: String

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.navigationSubtitle(text)
        } else {
            content
        }
        #elseif os(macOS)
        content.navigationSubtitle(text)
        #else
        content
        #endif
    }
}

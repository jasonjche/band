import SwiftUI
import Charts
import MapKit
import WhoopStore
import WhoopProtocol
import StrandDesign
import StrandAnalytics

// WHOOP activity page drawn in Apple Health chrome.
// Sport + time in the nav, strain/steps hero, HR chart, zones 5→0, compact stats, route if stored.

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

    struct Typical: Equatable {
        var delta: NativeScore.Delta
        var valueText: String
        var accessibilityLabel: String
    }

    struct Stat: Equatable, Identifiable {
        var id: String { title }
        var title: String
        var value: String
        var unit: String
        var typical: Typical?
        var delta: NativeScore.Delta
        var symbol: String
        var heartFamily: Bool
        var neutralDelta: Bool = false
    }

    struct MuscularSplit: Equatable {
        var cardioPercent: Int
        var muscularPercent: Int
    }

    struct Model: Equatable {
        var sport: String
        var timeRange: String
        var sourceLine: String?
        var strainText: String
        var strainTypical: Typical?
        var duration: String
        var stepsText: String?
        var stepsTypical: Typical?
        var zones: [Zone]
        var stats: [Stat]
        var isManual: Bool
        var hasStrain: Bool
        var isRecovery: Bool
        var muscularSplit: MuscularSplit?
    }

    static func make(
        _ workout: WorkoutRow,
        prior: [WorkoutRow],
        scale: EffortScale,
        zoneSet: HRZoneSet?,
        percents: [Double]?,
        heartRateRecovery: Int? = nil,
        priorHeartRateRecovery: [Double] = [],
        steps: Int? = nil,
        muscular: ActivityScoring.Muscular? = nil
    ) -> Model {
        let sameAll = sameSport(as: workout, in: prior, windowDays: nil)
        let sameWindow = sameSport(as: workout, in: prior, windowDays: statsWindowDays)
        let strainValues = sameAll.compactMap(NativeStrain.workout)
        let isRecovery = WorkoutCatalog.isRecovery(workout.sport)
        let storedStrain = isRecovery ? nil : NativeStrain.workout(workout)
        let strain: Double?
        if isRecovery {
            strain = nil
        } else if let muscular {
            strain = StrainScorer.effortValue(fromWhoopStrain: muscular.combinedStrain21)
        } else {
            strain = storedStrain
        }
        let sport = WorkoutSource.displaySport(workout.sport)
        let stepCount = steps ?? workout.steps
        let stepsValue = stepCount.map(Double.init)
        let priorSteps = sameAll.compactMap { $0.steps.map(Double.init) }
        let showSteps = !isRecovery && muscular == nil
        return Model(
            sport: sport,
            timeRange: dateTimeRange(startTs: workout.startTs, endTs: workout.endTs),
            sourceLine: isRecovery ? recoverySourceLine(workout.source) : importSourceLine(workout.source),
            strainText: NativeDayLogic.strainText(strain, scale: scale),
            strainTypical: typical(
                current: strain, prior: strainValues, sport: sport, metric: "strain"
            ) { NativeDayLogic.strainText($0, scale: scale) },
            duration: durationClock(workout),
            stepsText: showSteps ? stepsValue.flatMap { NativeScoreMath.count($0) } : nil,
            stepsTypical: showSteps ? typical(
                current: stepsValue, prior: priorSteps, sport: sport, metric: "steps"
            ) { NativeScoreMath.count($0) } : nil,
            zones: isRecovery ? [] : zones(percents: percents, durationS: durationSeconds(workout), zoneSet: zoneSet),
            stats: stats(
                workout,
                same: sameWindow,
                sport: sport,
                heartRateRecovery: isRecovery ? nil : heartRateRecovery,
                priorHeartRateRecovery: priorHeartRateRecovery
            ),
            isManual: WorkoutSource.classify(workout.source) == .manual,
            hasStrain: strain != nil,
            isRecovery: isRecovery,
            muscularSplit: muscular.map { MuscularSplit(cardioPercent: $0.cardioPercent, muscularPercent: $0.muscularPercent) }
        )
    }

    /// True when the window has no HR yet — strap samples have not offloaded, so skip empty cards.
    static func awaitingHeartRate(hrPointCount: Int, zoneCount: Int, heartStatCount: Int) -> Bool {
        hrPointCount == 0 && zoneCount == 0 && heartStatCount == 0
    }

    /// Strain delta vs the average of prior same-sport workouts, only when at least three exist.
    static func strainDelta(current: Double?, prior: [Double]) -> NativeScore.Delta {
        typical(current: current, prior: prior, sport: "sport", metric: "strain") { "\($0)" }?.delta ?? .none
    }

    /// Typical-value chip vs prior same-sport workouts. Hidden until at least three exist.
    static func typical(
        current: Double?,
        prior: [Double],
        sport: String,
        metric: String,
        format: (Double) -> String
    ) -> Typical? {
        guard prior.count >= priorSameSportMinimum, current != nil,
              let mean = NativeScoreMath.mean(prior) else { return nil }
        let text = format(mean)
        let delta = NativeScoreMath.delta(current, prior)
        let direction: String
        if delta == .up { direction = "Above" }
        else if delta == .down { direction = "Below" }
        else { direction = "In line with" }
        return Typical(
            delta: delta,
            valueText: text,
            accessibilityLabel: "\(direction) your typical \(sport) \(metric) of \(text)"
        )
    }

    static func toggleZone(_ current: Int?, tapped: Int) -> Int? {
        current == tapped ? nil : tapped
    }

    /// Contiguous in-zone samples, for dimming the rest of the HR chart.
    static func zoneRuns(_ points: [NativeHourPoint], zone: Int, zoneSet: HRZoneSet) -> [[NativeHourPoint]] {
        var runs: [[NativeHourPoint]] = []
        var current: [NativeHourPoint] = []
        for point in points {
            if zoneSet.zoneNumber(forBPM: point.value) == zone {
                current.append(point)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
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

    /// Z1…Z5 percentages from samples using the same %HRmax bands as the rest of the app.
    static func zonePercents(from samples: [HRSample], zoneSet: HRZoneSet) -> [Double]? {
        guard !samples.isEmpty else { return nil }
        let tiz = HRZones.timeInZone(samples, zoneSet: zoneSet)
        let total = tiz.total
        guard total > 0 else { return nil }
        return tiz.seconds.map { $0 / total * 100 }
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

    static func recoverySourceLine(_ source: String) -> String {
        if let imported = importSourceLine(source) {
            return "\(imported). Recovery activity — no activity strain"
        }
        return "Recovery activity — no activity strain"
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

    private static func stats(
        _ workout: WorkoutRow,
        same: [WorkoutRow],
        sport: String,
        heartRateRecovery: Int?,
        priorHeartRateRecovery: [Double]
    ) -> [Stat] {
        var rows: [Stat] = []
        if let hr = workout.avgHr {
            rows.append(stat(
                "Avg HR", "\(hr)", Double(hr),
                same.compactMap { $0.avgHr.map(Double.init) },
                sport, "heart rate",
                "heart.fill", heart: true, unit: "BPM", neutralDelta: true
            ))
        }
        if let hr = workout.maxHr {
            rows.append(stat(
                "Max HR", "\(hr)", Double(hr),
                same.compactMap { $0.maxHr.map(Double.init) },
                sport, "max heart rate",
                "heart", heart: true, unit: "BPM", neutralDelta: true
            ))
        }
        if let recovery = heartRateRecovery {
            rows.append(stat(
                "HR Recovery", "\(recovery)", Double(recovery),
                priorHeartRateRecovery,
                sport, "heart rate recovery",
                "heart.circle", heart: true, unit: "BPM", neutralDelta: true
            ))
        }
        if let kcal = workout.energyKcal {
            rows.append(stat(
                "Calories", "\(Int(kcal.rounded()))", kcal,
                same.compactMap(\.energyKcal),
                sport, "calories",
                "flame.fill", heart: false, unit: "cal"
            ))
        }
        if let meters = workout.distanceM, meters > 0 {
            let imperial = UserDefaults.standard.string(forKey: UnitPrefs.distanceSystemKey) != UnitSystem.metric.rawValue
            let perUnit = imperial ? 1609.344 : 1000.0
            let unit = imperial ? "mi" : "km"
            let shown = meters / perUnit
            rows.append(stat(
                "Distance", String(format: "%.2f", shown), shown,
                same.compactMap(\.distanceM).filter { $0 > 0 }.map { $0 / perUnit },
                sport, "distance",
                "point.topleft.down.to.point.bottomright.curvepath",
                heart: false, unit: unit, decimals: 2
            ))
        }
        return rows
    }

    private static func stat(
        _ title: String, _ value: String, _ current: Double, _ prior: [Double],
        _ sport: String, _ metric: String,
        _ symbol: String, heart: Bool, unit: String, decimals: Int = 0,
        neutralDelta: Bool = false
    ) -> Stat {
        let chip = typical(current: current, prior: prior, sport: sport, metric: metric) { mean in
            if decimals == 0 { return "\(Int(mean.rounded()))" }
            return String(format: "%.\(decimals)f", mean)
        }
        return Stat(
            title: title,
            value: value,
            unit: unit,
            typical: chip,
            delta: chip?.delta ?? .none,
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
    @State private var heartRateRecoveryBpm: Int?
    @State private var priorHeartRateRecovery: [Double] = []
    @State private var route: [RouteMath.LatLng] = []
    @State private var zoneSet: HRZoneSet?
    @State private var activitySteps: Int?
    @State private var muscular: ActivityScoring.Muscular?
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
                    percents: percents,
                    heartRateRecovery: heartRateRecoveryBpm,
                    priorHeartRateRecovery: priorHeartRateRecovery,
                    steps: activitySteps,
                    muscular: muscular
                )
                NativeActivityBody(
                    model: model,
                    hr: hr,
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
        await profileHandle?.syncObservedHRMax(from: repo)
        let restingHR = HRZones.medianRestingHR(repo.days.compactMap(\.restingHr))
        zoneSet = profileHandle?.displayZoneSet(restingHR: restingHR)
        let rows = await repo.workoutRows(days: 120)
        let found = rows.first { $0.startTs == keyTs }
        workout = found
        prior = rows
        guard let workout else {
            hr = []
            percents = nil
            route = []
            heartRateRecoveryBpm = nil
            priorHeartRateRecovery = []
            activitySteps = nil
            muscular = nil
            return
        }
        percents = repo.parsedZones(for: workout) ?? WorkoutZones.percents(workout.zonesJSON)
        // Strap samples when they cover the workout, else the Apple Health samples stored for it.
        let series = await repo.workoutHeartRate(
            startTs: workout.startTs, endTs: workout.endTs,
            sport: workout.sport, source: workout.source
        )
        let rawPoints = NativeActivityPageLogic.bucketed(
            series.samples.map { (ts: $0.ts, bpm: Double($0.bpm)) },
            seconds: NativeActivityPageLogic.hrBucketSeconds
        )
        hr = NativeHRSmoothing.smooth(rawPoints)
        let isRecovery = WorkoutCatalog.isRecovery(workout.sport)
        let zones = zoneSet ?? HRZones.zones(
            maxHR: profileHandle?.effortHRmax ?? 197,
            restingHR: restingHR ?? BandStrain.defaultRestingHR
        )
        if isRecovery {
            percents = nil
        } else if percents == nil, !series.samples.isEmpty {
            percents = NativeActivityPageLogic.zonePercents(from: series.samples, zoneSet: zones)
            if zoneSet == nil { zoneSet = zones }
        }
        let ticksPerStep = profileHandle?.stepTicksPerStep ?? 1
        activitySteps = await repo.workoutStepCount(
            from: workout.startTs, to: workout.endTs,
            ticksPerStep: ticksPerStep, stored: workout.steps
        )
        let sets = await repo.liftSets(startTs: workout.startTs, sport: workout.sport)
        let cardio21 = NativeStrain.workout(workout).map {
            NativeDayLogic.strainDisplayValue($0, scale: .whoop)
        }
        muscular = ActivityScoring.muscularLoad(
            sport: workout.sport,
            sets: sets,
            bodyWeightKg: profileHandle?.weightKg,
            cardioStrain21: cardio21
        )
        heartRateRecoveryBpm = nil
        priorHeartRateRecovery = []
        if !isRecovery, series.origin == .strap, let maxHR = profileHandle?.effortHRmax, maxHR > 0 {
            let recovered = await repo.workoutHeartRateRecovery(
                from: workout.startTs, to: workout.endTs, maxHR: maxHR, source: workout.source
            )
            if let drop = recovered?.after1Minute {
                heartRateRecoveryBpm = drop
                let same = NativeActivityPageLogic.sameSport(
                    as: workout, in: rows, windowDays: NativeActivityPageLogic.statsWindowDays
                )
                var priors: [Double] = []
                for row in same {
                    if let prior = await repo.workoutHeartRateRecovery(
                        from: row.startTs, to: row.endTs, maxHR: maxHR, source: row.source
                    ), let minute = prior.after1Minute {
                        priors.append(Double(minute))
                    }
                }
                priorHeartRateRecovery = priors
            }
        }
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
    var zoneSet: HRZoneSet? = nil
    var route: [RouteMath.LatLng] = []
    var scrolls: Bool = true
    @State private var selectedZone: Int?
    @State private var hapticTick = 0

    var body: some View {
        Group {
            if scrolls {
                NativeChrome.screen { activityBody }
            } else {
                NativeChrome.stack { activityBody }
            }
        }
        .modifier(NativeActivityLightHaptic(trigger: hapticTick))
    }

    @ViewBuilder private var activityBody: some View {
        if let source = model.sourceLine {
            Text(source)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }

        heroRow
            .padding(.top, model.sourceLine == nil ? 8 : 0)

        if awaitingHeartRate {
            Text("Heart rate appears after the next sync")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }

        if !hr.isEmpty {
            NativeChrome.panel {
                NativeActivityHRChart(
                    points: hr,
                    zoneSet: zoneSet,
                    selectedZone: selectedZone,
                    onClearZone: { selectZone(nil) }
                )
                .frame(minHeight: 220)
            }
        }

        if !model.zones.isEmpty {
            NativeChrome.panel {
                HStack {
                    Text("Heart Rate Zones")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Text(model.duration)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Duration \(model.duration)")
                }
                .padding(.bottom, 4)
                ForEach(model.zones) { zone in
                    NativeActivityZoneRow(
                        zone: zone,
                        totalMinutes: totalZoneMinutes,
                        isSelected: selectedZone == zone.number,
                        dimmed: selectedZone != nil && selectedZone != zone.number
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selectZone(NativeActivityPageLogic.toggleZone(selectedZone, tapped: zone.number)) }
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
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(model.stats) { stat in
                    NativeActivityStatCell(stat: stat)
                }
            }
        }
    }

    @ViewBuilder private var heroRow: some View {
        let showStrain = model.hasStrain
        let showSteps = model.stepsText != nil
        if showStrain || showSteps {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                if showStrain {
                    NativeActivityHeroMetric(
                        value: model.strainText,
                        caption: "Activity Strain",
                        typical: model.strainTypical,
                        accessibilityValue: "\(model.strainText) activity strain"
                    )
                }
                if let split = model.muscularSplit {
                    NativeActivityStrainSplit(split: split)
                } else if let steps = model.stepsText {
                    NativeActivityHeroMetric(
                        value: steps,
                        caption: "Activity Steps",
                        typical: model.stepsTypical,
                        accessibilityValue: "\(steps) activity steps"
                    )
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.duration)
                    .font(StrandFont.rounded(28, weight: .semibold))
                    .monospacedDigit()
                Text("Duration")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
        }
    }

    private func selectZone(_ zone: Int?) {
        selectedZone = zone
        hapticTick += 1
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

private struct NativeActivityStrainSplit: View {
    var split: NativeActivityPageLogic.MuscularSplit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Cardio")
                Spacer()
                Text("Muscular")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            GeometryReader { geo in
                let cardioWidth = geo.size.width * CGFloat(split.cardioPercent) / 100
                HStack(spacing: 2) {
                    Capsule().fill(NativeTokens.strain)
                        .frame(width: max(cardioWidth, split.cardioPercent > 0 ? 4 : 0))
                    Capsule().fill(NativeTokens.strain.opacity(0.45))
                }
            }
            .frame(height: 10)
            HStack {
                Text("\(split.cardioPercent)%")
                Spacer()
                Text("\(split.muscularPercent)%")
            }
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .frame(minWidth: 140, maxWidth: 200)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cardio \(split.cardioPercent) percent, muscular \(split.muscularPercent) percent")
    }
}

private struct NativeActivityHeroMetric: View {
    var value: String
    var caption: String
    var typical: NativeActivityPageLogic.Typical?
    var accessibilityValue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                NativeValueText(value: value, size: 34)
                if let typical {
                    NativeTypicalValueChip(typical: typical)
                }
            }
            Text(caption)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(caption)
        .accessibilityValue(typical.map { "\(accessibilityValue). \($0.accessibilityLabel)" } ?? accessibilityValue)
    }
}

private struct NativeTypicalValueChip: View {
    var typical: NativeActivityPageLogic.Typical

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: triangle)
                .font(.caption2.weight(.bold))
            Text(typical.valueText)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .accessibilityLabel(typical.accessibilityLabel)
    }

    private var triangle: String {
        if typical.delta == .up { return "arrowtriangle.up.fill" }
        if typical.delta == .down { return "arrowtriangle.down.fill" }
        return "minus"
    }
}

private struct NativeActivityStatCell: View {
    var stat: NativeActivityPageLogic.Stat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stat.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                NativeValueText(value: stat.value, unit: stat.unit, size: 22)
                if let typical = stat.typical {
                    NativeTypicalValueChip(typical: typical)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stat.title)
        .accessibilityValue(
            stat.typical.map { "\(stat.value) \(stat.unit). \($0.accessibilityLabel)" }
            ?? "\(stat.value) \(stat.unit)"
        )
    }
}

private struct NativeActivityLightHaptic: ViewModifier {
    var trigger: Int
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.sensoryFeedback(.impact(weight: .light), trigger: trigger)
        } else {
            content
        }
    }
}

struct NativeActivityHRChart: View {
    var points: [NativeHourPoint]
    var zoneSet: HRZoneSet? = nil
    var selectedZone: Int? = nil
    var onClearZone: () -> Void = {}
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
                selectedZone: selectedZone,
                scrub: scrub,
                onClearZone: onClearZone
            )
            .frame(height: 180)
        }
    }

    private var lineTint: Color {
        style == .whoop ? NativeTokens.whoopLabel : NativeTokens.heart
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
    var selectedZone: Int?
    var scrub: NativeScopeScrub
    var onClearZone: () -> Void

    private var timeBinding: Binding<Date?> {
        Binding(
            get: { scrub.time },
            set: { scrub.time = $0 }
        )
    }

    private var highlightTint: Color {
        guard let selectedZone else { return lineTint }
        return NativeTokens.hrZone(selectedZone)
    }

    private var zoneRuns: [[NativeHourPoint]] {
        guard let selectedZone, let zoneSet else { return [] }
        return NativeActivityPageLogic.zoneRuns(points, zone: selectedZone, zoneSet: zoneSet)
    }

    var body: some View {
        Chart {
            if let first = points.first {
                RuleMark(x: .value("Start", first.time))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .accessibilityHidden(true)
            }
            if let last = points.last, points.count > 1 {
                RuleMark(x: .value("End", last.time))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .accessibilityHidden(true)
            }
            ForEach(points) { point in
                AreaMark(
                    x: .value("Time", point.time),
                    yStart: .value("Low", yDomain.lowerBound),
                    yEnd: .value("HR", point.value)
                )
                .foregroundStyle(lineTint.opacity(selectedZone == nil ? 0.18 : 0.05))
                .interpolationMethod(.linear)
                LineMark(x: .value("Time", point.time), y: .value("HR", point.value))
                    .foregroundStyle(lineTint.opacity(selectedZone == nil ? 1 : 0.18))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            ForEach(Array(zoneRuns.enumerated()), id: \.offset) { offset, run in
                ForEach(run) { point in
                    AreaMark(
                        x: .value("Time", point.time),
                        yStart: .value("Low", yDomain.lowerBound),
                        yEnd: .value("HR", point.value),
                        series: .value("Zone", "z\(offset)")
                    )
                    .foregroundStyle(highlightTint.opacity(0.28))
                    .interpolationMethod(.linear)
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("HR", point.value),
                        series: .value("Zone", "z\(offset)")
                    )
                    .foregroundStyle(highlightTint)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                if run.count == 1, let point = run.first {
                    PointMark(x: .value("Time", point.time), y: .value("HR", point.value))
                        .foregroundStyle(highlightTint)
                        .symbolSize(24)
                }
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
        .onTapGesture { if selectedZone != nil { onClearZone() } }
        .accessibilityLabel("Heart rate")
        .accessibilityValue(selectedZone.map { "Showing zone \($0)" } ?? "Full workout")
        .accessibilityHint(selectedZone == nil ? "" : "Clears the zone highlight")
        .accessibilityAddTraits(selectedZone == nil ? AccessibilityTraits() : .isSelected)
        .animation(.easeInOut(duration: 0.18), value: selectedZone)
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
    var isSelected: Bool = false
    var dimmed: Bool = false

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
        .opacity(dimmed ? 0.4 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(zone.label), \(zone.bpmRange ?? ""), \(Int(zone.percent.rounded())) percent, \(NativeActivityPageLogic.zoneClock(zone.minutes))")
        .accessibilityHint(isSelected ? "Clears the heart rate chart highlight" : "Highlights this zone on the heart rate chart")
        .accessibilityValue(isSelected ? "Selected" : "")
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

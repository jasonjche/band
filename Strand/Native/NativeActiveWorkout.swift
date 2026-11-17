import SwiftUI
import Combine
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore

struct NativeActiveWorkoutState: Codable, Equatable, Identifiable {
    var sport: String
    var startTs: Int
    var trackRoute: Bool
    var strainTargetEnabled: Bool
    var pausedAtTs: Int?
    var pausedDuration: TimeInterval
    var samples: [HRSample]

    var id: Int { startTs }
    var startedAt: Date { Date(timeIntervalSince1970: TimeInterval(startTs)) }
    var pausedAt: Date? { pausedAtTs.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var isPaused: Bool { pausedAtTs != nil }

    static let defaultsKey = "native.activeWorkout.v1"
    static let minimumDuration: TimeInterval = 60

    init(
        sport: String,
        startTs: Int,
        trackRoute: Bool = false,
        strainTargetEnabled: Bool = false,
        pausedAtTs: Int? = nil,
        pausedDuration: TimeInterval = 0,
        samples: [HRSample] = []
    ) {
        self.sport = sport
        self.startTs = startTs
        self.trackRoute = trackRoute
        self.strainTargetEnabled = strainTargetEnabled
        self.pausedAtTs = pausedAtTs
        self.pausedDuration = pausedDuration
        self.samples = samples
    }

    static func shouldDiscard(elapsed: TimeInterval) -> Bool {
        elapsed < minimumDuration
    }

    static func elapsedClock(
        from start: Date,
        to now: Date,
        pausedAt: Date? = nil,
        pausedDuration: TimeInterval = 0
    ) -> String {
        let total = Int(NativeLiveActivityLogic.elapsed(
            start: start, now: now, pausedAt: pausedAt, pausedDuration: pausedDuration
        ))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func load(_ defaults: UserDefaults = .standard) -> NativeActiveWorkoutState? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(NativeActiveWorkoutState.self, from: data)
    }

    static func persist(_ state: NativeActiveWorkoutState, in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    enum CodingKeys: String, CodingKey {
        case sport, startTs, trackRoute, strainTargetEnabled, pausedAtTs, pausedDuration, samples
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sport = try c.decode(String.self, forKey: .sport)
        startTs = try c.decode(Int.self, forKey: .startTs)
        trackRoute = try c.decodeIfPresent(Bool.self, forKey: .trackRoute) ?? false
        strainTargetEnabled = try c.decodeIfPresent(Bool.self, forKey: .strainTargetEnabled) ?? false
        pausedAtTs = try c.decodeIfPresent(Int.self, forKey: .pausedAtTs)
        pausedDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .pausedDuration) ?? 0
        samples = try c.decodeIfPresent([HRSample].self, forKey: .samples) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sport, forKey: .sport)
        try c.encode(startTs, forKey: .startTs)
        try c.encode(trackRoute, forKey: .trackRoute)
        try c.encode(strainTargetEnabled, forKey: .strainTargetEnabled)
        try c.encodeIfPresent(pausedAtTs, forKey: .pausedAtTs)
        try c.encode(pausedDuration, forKey: .pausedDuration)
        try c.encode(samples, forKey: .samples)
    }
}

/// Snapshot-friendly live overview: strain ring, HR + zone bar, stats, pause/end.
struct NativeActiveWorkoutScreen: View {
    var snapshot: NativeActiveWorkoutSnapshot
    var onPause: () -> Void
    var onEnd: () -> Void
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
            header
            if snapshot.isRecovery && !snapshot.showsMap {
                overview
            } else {
                TabView {
                    overview
                        .tabItem { Text("Overview") }
                        .tag(0)
                    if !snapshot.isRecovery {
                        heartPage
                            .tabItem { Text("Heart rate") }
                            .tag(1)
                    }
                    if snapshot.showsMap {
                        mapPage
                            .tabItem { Text("Map") }
                            .tag(2)
                    }
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                #endif
            }
            controls
        }
        .background(NativePageFill().ignoresSafeArea())
        .navigationTitle(snapshot.sport)
        .modifier(NativeInlineTitle())
    }

    private var header: some View {
        HStack {
            Text(snapshot.sport.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Spacer()
            Text(snapshot.elapsed)
                .font(NativePaint.number(22, style: style))
                .monospacedDigit()
                .accessibilityLabel("Elapsed time")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var overview: some View {
        NativeActiveWorkoutOverview(snapshot: snapshot)
    }

    private var heartPage: some View {
        NativeActiveWorkoutHeartPage(points: snapshot.hrPoints, zoneSet: snapshot.zoneSet)
            .padding(16)
    }

    private var mapPage: some View {
        NativeActiveWorkoutMapPage(
            points: snapshot.route,
            distanceText: snapshot.distanceText,
            paceText: snapshot.paceText
        )
        .padding(16)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button(snapshot.isPaused ? "Resume" : "Pause", action: onPause)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            Button("End", action: onEnd)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
    }
}

struct NativeActiveWorkoutOverview: View {
    var snapshot: NativeActiveWorkoutSnapshot
    @Environment(\.nativeStyle) private var style

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if snapshot.isRecovery {
                    recoveryHero
                } else {
                    strainRing
                }
                hrBlock
                if !snapshot.isRecovery {
                    statsRow
                }
                if snapshot.showsDistancePace, let distance = snapshot.distanceText {
                    distanceRow(distance)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
    }

    private var strainRing: some View {
        VStack(spacing: 8) {
            NativeRing(
                fraction: snapshot.strainFraction,
                tint: NativePaint.strain(style),
                value: snapshot.strainText,
                caption: "Activity Strain",
                diameter: 196,
                targetFraction: snapshot.targetFraction
            )
            Text(snapshot.strainBand.uppercased())
                .font(style == .whoop ? NativeTokens.whoopCaps(11) : .subheadline.weight(.semibold))
                .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0.4)
                .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
                .accessibilityLabel(snapshot.strainBand)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Activity strain \(snapshot.strainText), \(snapshot.strainBand)"
        )
    }

    private var recoveryHero: some View {
        VStack(spacing: 4) {
            Text(snapshot.elapsed)
                .font(NativePaint.number(56, style: style))
                .monospacedDigit()
            Text("Duration")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private var hrBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Heart Rate")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(snapshot.bpm.map { "\($0)" } ?? "—")
                    .font(NativePaint.number(44, style: style))
                    .monospacedDigit()
                    .foregroundStyle(NativeTokens.hrZone(snapshot.zone))
                Text("BPM")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let zones = snapshot.zoneSet?.zones, zones.count >= 5 {
                NativeHRZoneBar(zones: zones, current: snapshot.zone)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            snapshot.bpm.map { "Heart rate \($0) BPM, Zone \(snapshot.zone)" } ?? "No heart rate"
        )
    }

    private var statsRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                NativeLiveStat(
                    symbol: "heart.fill",
                    title: "Avg HR",
                    value: snapshot.avgHr.map { "\($0)" } ?? "—"
                )
                NativeLiveStat(
                    symbol: "heart",
                    title: "Max HR",
                    value: snapshot.maxHr.map { "\($0)" } ?? "—"
                )
                NativeLiveStat(
                    symbol: "flame.fill",
                    title: "Calories",
                    value: snapshot.caloriesText
                )
            }
            .frame(maxWidth: .infinity)
            if let hint = snapshot.caloriesHint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func distanceRow(_ distance: String) -> some View {
        HStack(spacing: 12) {
            NativeLiveStat(
                symbol: "point.topleft.down.to.point.bottomright.curvepath",
                title: "Distance",
                value: distance
            )
            NativeLiveStat(
                symbol: "speedometer",
                title: "Pace",
                value: snapshot.paceText ?? "—"
            )
        }
        .frame(maxWidth: .infinity)
    }
}

struct NativeHRZoneBar: View {
    var zones: [HRZone]
    var current: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(zones, id: \.number) { zone in
                    Capsule()
                        .fill(NativeTokens.hrZone(zone.number).opacity(current == zone.number ? 1 : 0.35))
                        .frame(height: 6)
                        .overlay(alignment: .leading) {
                            if current == zone.number {
                                Circle()
                                    .fill(Color.primary)
                                    .frame(width: 10, height: 10)
                                    .offset(x: -2)
                            }
                        }
                }
            }
            HStack {
                ForEach(zones, id: \.number) { zone in
                    Text(NativeLiveActivityLogic.zoneBarLabel(zone))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct NativeLiveStat: View {
    var symbol: String
    var title: String
    var value: String
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(NativePaint.number(22, style: style))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}

struct NativeActiveWorkoutHeartPage: View {
    var points: [NativeHourPoint]
    var zoneSet: HRZoneSet?

    var body: some View {
        Group {
            if points.count >= 2 {
                NativeActivityHRChart(points: points, zoneSet: zoneSet)
            } else {
                NativeEmptyState(text: "Heart rate builds as you go", symbol: "heart")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NativeActiveWorkoutMapPage: View {
    var points: [RouteMath.LatLng]
    var distanceText: String?
    var paceText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let distanceText {
                HStack {
                    Text(distanceText)
                        .font(.headline.monospacedDigit())
                    Spacer()
                    if let paceText {
                        Text(paceText)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if points.count >= 2 {
                NativeActivityRouteMap(points: points)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: NativeChrome.cardRadius, style: .continuous))
            } else {
                NativeEmptyState(text: "Waiting for GPS", symbol: "location")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Live workout: retains realtime HR while on screen, releases on disappear or background.
struct NativeActiveWorkoutView: View {
    var session: NativeActiveWorkoutState
    var onEnd: (NativeLiveWorkoutResult) -> Void

    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""

    @State private var holdingHR = false
    @State private var confirmingEnd = false
    @State private var bpm: Int?
    @State private var modelHandle: AppModel?
    @State private var samples: [HRSample] = []
    @State private var effort100: Double?
    @State private var avgHr: Int?
    @State private var maxHr: Int?
    @State private var kcal: Double?
    @State private var lastMetricsTs = 0
    @State private var pausedAtTs: Int?
    @State private var pausedDuration: TimeInterval
    @State private var targetFired = false
    @State private var targetHaptic = 0
    @State private var gpsDistance: Double = 0
    @State private var gpsPace: Double?
    @State private var gpsPoints: [RouteMath.LatLng] = []
    @State private var gpsArmed = false

    init(
        session: NativeActiveWorkoutState,
        onEnd: @escaping (NativeLiveWorkoutResult) -> Void
    ) {
        self.session = session
        self.onEnd = onEnd
        _pausedAtTs = State(initialValue: session.pausedAtTs)
        _pausedDuration = State(initialValue: session.pausedDuration)
        _samples = State(initialValue: session.samples)
        _avgHr = State(initialValue: NativeLiveActivityLogic.averageHr(session.samples))
        _maxHr = State(initialValue: NativeLiveActivityLogic.peakHr(session.samples))
    }

    private var sport: String { session.sport }
    private var startedAt: Date { session.startedAt }
    private var isPaused: Bool { pausedAtTs != nil }
    private var isRecovery: Bool { !NativeLiveActivityLogic.showsStrain(sport) }
    private var showsMap: Bool { session.trackRoute }
    private var distanceSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: distanceSystemRaw
        )
    }

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            NativeActiveWorkoutScreen(
                snapshot: snapshot(now: context.date),
                onPause: togglePause,
                onEnd: { confirmingEnd = true }
            )
            .onChangeCompat(of: Int(context.date.timeIntervalSince1970)) { _ in
                pullGPS()
                refreshMetrics(now: context.date, force: false)
            }
        }
        .confirmationDialog("End activity?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("Save") { finish(discard: false) }
            Button("Discard", role: .destructive) { finish(discard: true) }
            Button("Resume", role: .cancel) {}
        }
        .nativeStyleBridge()
        .interactiveDismissDisabled()
        .modifier(NativeTargetHaptic(trigger: targetHaptic))
        .background {
            WorkoutHRArm(holdingHR: $holdingHR, bpm: $bpm, modelHandle: $modelHandle)
            if let model = modelHandle, gpsArmed {
                WorkoutGPSPull(
                    recorder: model.gpsRecorder,
                    distanceM: $gpsDistance,
                    paceSecPerKm: $gpsPace,
                    points: $gpsPoints
                )
            }
        }
        .onChangeCompat(of: bpm) { value in
            guard let value, !isPaused else { return }
            if NativeLiveActivityLogic.recordSample(into: &samples, bpm: value, at: Date()) {
                avgHr = NativeLiveActivityLogic.averageHr(samples)
                maxHr = NativeLiveActivityLogic.peakHr(samples)
            }
        }
        .onChangeCompat(of: modelHandle != nil) { ready in
            if ready { armGPS() }
        }
        .onAppear {
            armGPS()
            refreshMetrics(now: Date(), force: true)
        }
        .onDisappear { releaseHR() }
    }

    private func snapshot(now: Date) -> NativeActiveWorkoutSnapshot {
        let caloriesReady = profile.weightKg > 0 && profile.age > 0
        return NativeActiveWorkoutSnapshot(
            sport: sport,
            elapsed: NativeActiveWorkoutState.elapsedClock(
                from: startedAt, to: now, pausedAt: pausedAt, pausedDuration: pausedDuration
            ),
            strainText: NativeLiveActivityLogic.strainText(effort100),
            strainBand: NativeLiveActivityLogic.strainBand(effort100).rawValue,
            strainFraction: NativeLiveActivityLogic.strainFraction(effort100),
            bpm: bpm,
            zone: zone(for: bpm) ?? 0,
            zoneSet: zoneSet,
            avgHr: avgHr,
            maxHr: maxHr,
            caloriesText: kcal.map { "\(Int($0.rounded()))" } ?? "—",
            caloriesHint: caloriesReady
                ? nil
                : "Add weight, birthdate and sex to your profile to estimate calories.",
            distanceText: UnitFormatter.distanceFromMeters(gpsDistance, system: distanceSystem),
            paceText: UnitFormatter.paceFromSecPerKm(gpsPace, system: distanceSystem),
            isRecovery: isRecovery,
            isPaused: isPaused,
            targetFraction: session.strainTargetEnabled
                ? strainTarget.map { NativeStrainTarget.ringFraction($0.range) }
                : nil,
            hrPoints: NativeHRSmoothing.smooth(NativeLiveActivityLogic.hrPoints(samples)),
            route: gpsPoints,
            showsMap: showsMap,
            showsDistancePace: NativeLiveActivityLogic.showsDistancePace(sport) && showsMap
        )
    }

    private var zoneSet: HRZoneSet {
        profile.displayZoneSet(restingHR: restingHR)
    }

    private var restingHR: Double {
        NativeStrain.restingHR(
            day: repo.days.last { $0.day == NativeDayLogic.logicalToday() },
            days: repo.days,
            dayKey: NativeDayLogic.logicalToday()
        )
    }

    private var pausedAt: Date? {
        pausedAtTs.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private var strainTarget: BandStrainTarget.Result? {
        guard session.strainTargetEnabled else { return nil }
        let today = NativeDayLogic.logicalToday()
        return NativeStrainTarget.resolve(
            viewingKey: today,
            todayKey: today,
            days: repo.days,
            sleeps: repo.sleeps,
            workouts: [],
            importedSleep: repo.importedSleep
        )
    }

    private var userProfile: UserProfile {
        UserProfile(
            weightKg: profile.weightKg,
            heightCm: profile.heightCm,
            age: Double(profile.age),
            sex: profile.sex
        )
    }

    private func zone(for bpm: Int?) -> Int? {
        guard let bpm else { return nil }
        return zoneSet.zoneNumber(forBPM: Double(bpm))
    }

    private func refreshMetrics(now: Date, force: Bool) {
        guard NativeLiveActivityLogic.shouldRefreshMetrics(lastTs: lastMetricsTs, now: now, force: force) else {
            return
        }
        lastMetricsTs = Int(now.timeIntervalSince1970)
        persistSession()
        if !isRecovery {
            effort100 = NativeLiveActivityLogic.strain(
                samples: samples,
                maxHR: profile.effortHRmax ?? Double(profile.hrMax),
                restingHR: restingHR
            )
            if NativeLiveActivityLogic.shouldFireTarget(
                enabled: session.strainTargetEnabled,
                alreadyFired: targetFired,
                strain21: NativeLiveActivityLogic.strain21(effort100),
                range: strainTarget?.range
            ) {
                targetFired = true
                targetHaptic += 1
            }
        }
        kcal = NativeLiveActivityLogic.calories(
            samples: samples,
            profile: userProfile,
            maxHR: profile.effortHRmax ?? Double(profile.hrMax),
            restingHR: restingHR
        )
        pullGPS()
    }

    private func togglePause() {
        if let paused = pausedAt {
            pausedDuration += Date().timeIntervalSince(paused)
            pausedAtTs = nil
            modelHandle?.gpsRecorder.resume()
        } else {
            pausedAtTs = Int(Date().timeIntervalSince1970)
            modelHandle?.gpsRecorder.pause()
        }
        persistSession()
    }

    private func persistSession() {
        var next = session
        next.pausedAtTs = pausedAtTs
        next.pausedDuration = pausedDuration
        next.samples = samples
        NativeActiveWorkoutState.persist(next)
    }

    private func finish(discard: Bool) {
        let now = Date()
        let elapsed = NativeLiveActivityLogic.elapsed(
            start: startedAt, now: now, pausedAt: pausedAt, pausedDuration: pausedDuration
        )
        refreshMetrics(now: now, force: true)
        var route: WorkoutRoute?
        if gpsArmed {
            modelHandle?.gpsRecorder.stop()
            route = modelHandle?.gpsRecorder.capturedRoute()
            gpsArmed = false
        }
        releaseHR()
        if discard {
            onEnd(NativeLiveWorkoutResult(
                elapsed: 0, samples: [], avgHr: nil, maxHr: nil,
                strain: nil, energyKcal: nil, route: nil, discarded: true
            ))
            return
        }
        onEnd(NativeLiveWorkoutResult(
            elapsed: elapsed,
            samples: samples,
            avgHr: avgHr,
            maxHr: maxHr,
            strain: isRecovery ? nil : effort100,
            energyKcal: kcal,
            route: route,
            discarded: false
        ))
    }

    private func armGPS() {
        guard session.trackRoute, !gpsArmed else { return }
        guard let model = modelHandle else {
            DispatchQueue.main.async {
                guard modelHandle != nil else { return }
                armGPS()
            }
            return
        }
        gpsArmed = true
        let startMs = Int64(session.startTs) * 1000
        if let banked = ActiveRouteStore.load() {
            model.gpsRecorder.restore(
                startMs: startMs,
                pausedAtMs: pausedAtTs.map { Int64($0) * 1000 },
                pausedDurationMs: Int64(pausedDuration * 1000)
            )
        } else {
            model.gpsRecorder.start(startMs: startMs)
            if isPaused { model.gpsRecorder.pause() }
        }
        pullGPS()
    }

    private func pullGPS() {
        guard let recorder = modelHandle?.gpsRecorder else { return }
        gpsDistance = recorder.distanceM
        gpsPace = recorder.paceSecPerKm
        gpsPoints = recorder.points
    }

    private func releaseHR() {
        guard holdingHR else { return }
        modelHandle?.stopRealtimeHR()
        holdingHR = false
    }
}

private struct NativeTargetHaptic: ViewModifier {
    var trigger: Int
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.sensoryFeedback(.success, trigger: trigger)
        } else {
            content
        }
    }
}

private struct WorkoutGPSPull: View {
    @ObservedObject var recorder: GpsWorkoutRecorder
    @Binding var distanceM: Double
    @Binding var paceSecPerKm: Double?
    @Binding var points: [RouteMath.LatLng]

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { pull() }
            .onChangeCompat(of: recorder.pointCount) { _ in pull() }
            .onChangeCompat(of: recorder.distanceM) { _ in pull() }
    }

    private func pull() {
        distanceM = recorder.distanceM
        paceSecPerKm = recorder.paceSecPerKm
        points = recorder.points
    }
}

/// Holds AppModel so TimelineView does not rebuild on import/cycle/illness publishes.
/// Forwards BPM and arms realtime HR while this screen is visible.
private struct WorkoutHRArm: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Binding var holdingHR: Bool
    @Binding var bpm: Int?
    @Binding var modelHandle: AppModel?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { modelHandle = model; arm() }
            .onDisappear { release() }
            .onChangeCompat(of: scenePhase) { phase in
                if phase == .background {
                    release()
                } else if phase == .active {
                    arm()
                }
            }
            .onReceive(model.$bpm.removeDuplicates()) { bpm = $0 }
    }

    private func arm() {
        guard !holdingHR else { return }
        model.startRealtimeHR()
        holdingHR = true
    }

    private func release() {
        guard holdingHR else { return }
        model.stopRealtimeHR()
        holdingHR = false
    }
}

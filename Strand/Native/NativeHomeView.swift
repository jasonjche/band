import SwiftUI
import Combine
import StrandDesign
import StrandAnalytics
import WhoopStore

// Native Home: WHOOP order, Apple Health chrome.
// Sections take plain value models so snapshots can render without Repository.
//
// Home content order (WHOOP capture, top to bottom):
// date stepper + battery, rings, Health | Stress tiles, My Day (Activities,
// Tonight's Sleep, Journal), My Dashboard rows, Stress Monitor chart,
// Strain & Recovery.

enum HomeSectionOrder {
    static let content = [
        "rings",
        "Health Monitor",
        "Stress Monitor",
        "My Day",
        "Activities",
        "Tonight's Sleep",
        "Journal",
        "My Dashboard",
        "Stress Monitor chart",
        "Strain & Recovery",
    ]
}

/// Pull-to-refresh on Home: kick the #334 user-initiated strap sync (`BLEManager.syncNow`),
/// hold the system spinner until that offload ends or 20 s, then re-read. Disconnected → reload only.
enum NativeHomeSync {
    static let timeout: TimeInterval = 20

    @MainActor
    static func pull(ble: BLEManager, repo: Repository, reload: () async -> Void) async {
        if ble.state.historyReady {
            ble.syncNow()
            await waitForBackfill(ble)
            await repo.refresh()
        }
        await reload()
    }

    @MainActor
    static func waitForBackfill(_ ble: BLEManager, timeout: TimeInterval = timeout) async {
        let deadline = Date().addingTimeInterval(timeout)
        var saw = ble.state.backfilling
        if !saw {
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if ble.state.backfilling { saw = true; break }
            }
        }
        guard saw else { return }
        while ble.state.backfilling, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}

/// Survives a Home re-appear / remount so live strain is not rescored unless `refreshSeq` or the day changed.
/// Counts coalesced Home applies so a day switch can be measured as one snapshot, not a cascade.
enum NativeHomeLoadMetrics {
    static var applyCount = 0
    static var modelRebuilds = 0
    /// One published snapshot per finished load: day switch or `refreshSeq`.
    static let publishedSnapshotsPerLoad = 1
}

enum NativeLiveStrainMemo {
    private static var seq = -1
    private static var day = ""
    private static var value: Double?
    private static var stored = false

    static func read(seq: Int, day: String) -> Double?? {
        guard stored, seq == self.seq, day == self.day else { return nil }
        return Optional.some(value)
    }

    /// The live strain Home last showed for `day`. Pushed pages pass this to `NativeDay.make`
    /// so the Strain page opens on the number the ring had, not the older stored one.
    static func latest(day: String) -> Double? {
        stored && day == self.day ? value : nil
    }

    static func store(seq: Int, day: String, value: Double?) {
        self.seq = seq
        self.day = day
        self.value = value
        stored = true
    }
}

struct NativeHomeView: View {
    @Environment(\.nativeNavigationPath) private var path
    @Environment(\.nativeContinuityActiveID) private var continuityID
    @State private var showingCalendar = false
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @State private var workouts: [WorkoutRow] = []
    @State private var journalEntries: [JournalEntry] = []
    @State private var sampleHours: [NativeHourPoint] = []
    @State private var vo2max: Double?
    @State private var liveTodayStrain: Double?
    @State private var dayModel: NativeDay.Model?
    @State private var strainTarget: BandStrainTarget.Result?
    @State private var healthReport = NativeHealthRange.Report(vitals: [])
    /// Shown on Home only when it reaches `.watch` (two nights in a row of 2+ off signals).
    @State private var overnightLoad: BandIllnessSignal.DayResult?
    @State private var tonight: NativeTonightSleep.Model?
    @State private var stressLevel: Double?
    @State private var stressSleepStart: Date?
    @State private var stressSleepEnd: Date?
    @State private var stressBouts: [(start: Date, end: Date)] = []
    /// Walking/running and post-workout recovery windows, drawn as excluded spans.
    @State private var stressExtraExclusions: [(start: Date, end: Date)] = []
    @State private var stressDayStart = Date()
    @State private var stressNow = Date()
    @State private var stressPlot = NativeStressDayPlotModel.placeholder
    @State private var stressUpdatedAt: Date?
    @State private var strainTargetFraction: ClosedRange<Double>?
    @State private var activityItems: [HomeActivityItem] = []
    @State private var journalDots: [HomeJournalDot] = []
    @State private var journalHasEntry = false
    @State private var journalFetched = false
    @State private var showingMorningJournal = false
    @AppStorage(NativeMorningJournal.storageKey) private var promptedJournalDay = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var morningJournalPath = NavigationPath()
    @State private var calendarRecovery: [String: Double] = [:]
    @State private var weekRecovery: [NativeDayPoint] = []
    @State private var weekStrain: [NativeDayPoint] = []
    @State private var dashboardItems: [HomeMetricItem] = []
    @State private var addingActivity = false
    @State private var editingDashboard = false
    @State private var sleepStreak = 0
    /// Unobserved handles. Home must not `@EnvironmentObject` Repository / BLE / Profile:
    /// hydrationSeq, scan RSSI, and steps-calibration publishes would re-diff the whole scroll.
    @State private var repoHandle: Repository?
    @State private var bleHandle: BLEManager?
    @State private var profileHandle: ProfileStore?
    @State private var refreshSeq = 0
    @State private var loaded = false
    @State private var firstDay: String?
    @State private var storeEmpty = false
    @State private var handlesReady = false
    /// `refreshSeq` last used for workouts / journal / VO₂. Day steps reuse those rows.
    @State private var sharedFetchSeq = -1
    @State private var rebuildGen = 0
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""
    @AppStorage("behavior.smartAlarmEnabled") private var smartAlarmEnabled = false
    @AppStorage("behavior.smartAlarmMinutes") private var smartAlarmMinutes = 7 * 60
    @AppStorage(HomeDashboardStore.key) private var dashboardJSON = ""

    private var selectedDay: Date {
        get { NativeDaySelection.date(from: selectedDayKey) }
        nonmutating set { selectedDayKey = NativeDaySelection.key(from: newValue) }
    }

    private var selectedKey: String { NativeDaySelection.resolvedKey(from: selectedDayKey) }

    var body: some View {
        homeScroll
            .background(NativePageFill().ignoresSafeArea())
            .background {
                NativeHomeEnvSink(
                    refreshSeq: $refreshSeq,
                    loaded: $loaded,
                    handlesReady: $handlesReady,
                    onHandles: { repo, ble, profile in
                        repoHandle = repo
                        bleHandle = ble
                        profileHandle = profile
                    }
                )
            }
            .refreshable {
                guard let ble = bleHandle, let repo = repoHandle else { return }
                await NativeHomeSync.pull(ble: ble, repo: repo, reload: reload)
            }
            .navigationTitle("Home")
            .environment(\.nativeSelectedDay, selectedDay)
            .nativeStyleBridge()
            .task(id: handlesReady ? "\(refreshSeq)-\(selectedKey)" : "boot") {
                guard handlesReady else { return }
                await reload()
            }
            .onChange(of: effortScaleRaw) { _ in Task { await rebuildModel() } }
            .onChange(of: smartAlarmEnabled) { _ in Task { await rebuildModel() } }
            .onChange(of: smartAlarmMinutes) { _ in Task { await rebuildModel() } }
            .onChange(of: dashboardJSON) { _ in Task { await rebuildModel() } }
            .navigationDestination(for: NativePairRoute.self) { _ in
                DevicesView()
            }
            .navigationDestination(for: NativeAlarmRoute.self) { _ in
                SmartAlarmView()
            }
            .sheet(isPresented: $addingActivity) {
                HomeAddActivitySheet { await reload() }
                    .nativeZoomDestination(fallback: .addActivity)
            }
            .sheet(isPresented: $editingDashboard) {
                HomeDashboardEditor(selectedIds: HomeDashboardStore.decode(dashboardJSON)) { ids in
                    let encoded = HomeDashboardStore.encode(ids)
                    HomeDashboardStore.save(ids)
                    dashboardJSON = encoded
                }
            }
            .sheet(isPresented: $showingMorningJournal, onDismiss: {
                morningJournalPath = NavigationPath()
                Task { await reload() }
            }) {
                NavigationStack(path: $morningJournalPath) {
                    NativeJournalView(startsLogging: true, onFinish: { showingMorningJournal = false })
                        .environment(\.nativeNavigationPath, $morningJournalPath)
                        .nativeStyleBridge()
                }
                .nativeZoomDestination(fallback: .homeJournal)
            }
            .onChangeCompat(of: scenePhase) { phase in
                if phase == .active {
                    Task { await reload() }
                }
            }
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: streakPlacement) {
                    HomeStreakBadge(count: sleepStreak)
                }
                ToolbarItem(placement: .principal) {
                    HomeDateStepper(
                        title: HomeDayTitle.text(for: selectedDay),
                        canGoBack: canGoBack,
                        canGoForward: canGoForward,
                        onBack: { shiftDay(-1) },
                        onForward: { shiftDay(1) }
                    )
                }
                ToolbarItem(placement: .automatic) {
                    HomeStrapStatus()
                }
                #endif
            }
            .accessibilityElement(children: .contain)
    }

    private var homeScroll: some View {
        ScrollView {
            NativeChrome.stack {
                #if os(iOS)
                // Streak leading, stepper centred, strap status trailing (WHOOP header).
                ZStack {
                    HomeDateStepper(
                        title: HomeDayTitle.text(for: selectedDay),
                        canGoBack: canGoBack,
                        canGoForward: canGoForward,
                        onBack: { shiftDay(-1) },
                        onForward: { shiftDay(1) },
                        onTitleTap: { showingCalendar = true }
                    )
                    HStack {
                        HomeStreakBadge(count: sleepStreak)
                        Spacer(minLength: 0)
                        HomeStrapStatus()
                    }
                }
                .frame(maxWidth: .infinity)
                .sheet(isPresented: $showingCalendar) {
                    HomeCalendarSheet(
                        selected: selectedDay,
                        range: calendarRange,
                        recoveryByDay: calendarRecovery
                    ) { picked in
                        selectedDay = Calendar.current.startOfDay(for: picked)
                    }
                }
                #endif
                if let model = dayModel, !storeEmpty {
                    homeContent(model)
                } else if loaded && storeEmpty {
                    NativeNoDataCard(
                        onImport: { path.wrappedValue.append(TabRoute.dataSources) },
                        onPair: { path.wrappedValue.append(NativePairRoute()) }
                    )
                } else {
                    HomeLoadingSkeleton()
                }
            }
            .padding(.bottom, 136)
        }
    }

    #if os(macOS)
    private var streakPlacement: ToolbarItemPlacement { .navigation }
    #endif

    private var canGoBack: Bool {
        HomeDayNav.canGoBack(selectedKey: selectedKey, firstDay: firstDay)
    }

    /// First stored day through logical today: the same bounds the arrows use.
    private var calendarRange: ClosedRange<Date> {
        let today = NativeDayLogic.startOfLocalDay(NativeDayLogic.logicalToday(now: Date()))
            ?? Calendar.current.startOfDay(for: Date())
        let first = firstDay.flatMap { NativeDayLogic.startOfLocalDay($0) } ?? today
        return min(first, today)...today
    }

    private var canGoForward: Bool {
        HomeDayNav.canGoForward(selectedKey: selectedKey)
    }

    private func shiftDay(_ delta: Int) {
        guard let next = HomeDayNav.shift(from: selectedDay, delta: delta, firstDay: firstDay) else { return }
        selectedDay = next
    }

    private func reload() async {
        guard let repo = repoHandle else { return }
        let day = selectedKey
        let seq = refreshSeq
        let viewingDay = selectedDay

        var nextWorkouts = workouts
        var nextJournal = journalEntries
        var nextVO2 = vo2max
        if sharedFetchSeq != seq {
            nextWorkouts = await repo.workoutRows(days: 120)
            if Task.isCancelled { return }
            nextJournal = await repo.journalEntries(days: 40)
            if Task.isCancelled { return }
            // Measured Apple Health VO2 max only (same resolver as the VO2 page); nil hides the tile.
            let apple = await repo.appleDailyRows(days: 400)
            if Task.isCancelled { return }
            nextVO2 = NativeVo2Max.latest(apple)?.value
        }

        let start = Calendar.current.startOfDay(for: viewingDay)
        let from = Int(start.timeIntervalSince1970)
        let to = from + 86_400
        let buckets = await repo.hrSamples(from: from, to: to, bucketSeconds: 300)
        if Task.isCancelled { return }
        guard day == selectedKey else { return }
        let timeline = await NativeDerivedSeries.stressDay(
            repo: repo, dayKey: day, dayStart: start, days: repo.days,
            sleeps: repo.sleeps, workouts: nextWorkouts
        )
        if Task.isCancelled { return }
        let series = timeline.hours
        // Walking and recovery exclude the line. They are not drawn as activities.
        let extraExclusions: [(start: Date, end: Date)] = []
        guard day == selectedKey else { return }

        let liveStrain = await liveStrainValue(buckets: buckets, day: day, seq: seq)
        if Task.isCancelled { return }
        guard day == selectedKey else { return }

        workouts = nextWorkouts
        journalEntries = nextJournal
        journalFetched = true
        vo2max = nextVO2
        sampleHours = series
        stressExtraExclusions = extraExclusions
        liveTodayStrain = liveStrain
        sharedFetchSeq = seq
        NativeHomeLoadMetrics.applyCount += 1
        await rebuildModel()
    }

    /// Rings, dashboard, tonight, week — once per data change, off the main actor.
    private func rebuildModel() async {
        guard let repo = repoHandle else { return }
        rebuildGen += 1
        let gen = rebuildGen
        let viewingKey = selectedKey
        let input = NativeHomeRebuild.Input(
            days: repo.days,
            sleeps: repo.sleeps,
            importedSleep: repo.importedSleep,
            workouts: workouts,
            journalEntries: journalEntries,
            vo2max: vo2max,
            sampleHours: sampleHours,
            liveTodayStrain: liveTodayStrain,
            selectedKey: viewingKey,
            selectedDay: selectedDay,
            effortScale: UnitPrefs.resolveEffortScale(effortScaleRaw),
            smartAlarmEnabled: smartAlarmEnabled,
            smartAlarmMinutes: smartAlarmMinutes,
            dashboardJSON: dashboardJSON,
            temperature: UnitPrefs.resolveTemperature(
                system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                override: temperatureRaw
            ),
            stressExtraExclusions: stressExtraExclusions,
            now: Date()
        )
        let snapshot = await Task.detached(priority: .userInitiated) {
            NativeHomeRebuild.run(input)
        }.value
        guard gen == rebuildGen, viewingKey == selectedKey else { return }
        firstDay = snapshot.firstDay
        storeEmpty = snapshot.storeEmpty
        dayModel = snapshot.dayModel
        strainTarget = snapshot.strainTarget
        healthReport = snapshot.healthReport
        overnightLoad = snapshot.overnightLoad
        tonight = snapshot.tonight
        stressLevel = snapshot.stressLevel
        stressUpdatedAt = snapshot.stressUpdatedAt
        stressDayStart = snapshot.stressDayStart
        stressNow = snapshot.stressNow
        stressPlot = snapshot.stressPlot
        strainTargetFraction = snapshot.strainTargetFraction
        activityItems = snapshot.activityItems
        journalDots = snapshot.journalDots
        journalHasEntry = snapshot.journalHasEntry
        calendarRecovery = snapshot.calendarRecovery
        stressSleepStart = snapshot.stressSleepStart
        stressSleepEnd = snapshot.stressSleepEnd
        stressBouts = snapshot.stressBouts
        weekRecovery = snapshot.weekRecovery
        weekStrain = snapshot.weekStrain
        sleepStreak = snapshot.sleepStreak
        dashboardItems = snapshot.dashboardItems
        NativeHomeLoadMetrics.modelRebuilds += 1
        presentMorningJournalIfNeeded()
    }

    private func presentMorningJournalIfNeeded() {
        guard scenePhase == .active, !showingMorningJournal else { return }
        let sleepPresent = repoHandle?.sleeps.contains {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs)))
                == selectedKey
        } ?? false
        guard NativeMorningJournal.shouldPresent(
            now: Date(),
            selectedKey: selectedKey,
            loaded: loaded,
            storeEmpty: storeEmpty,
            journalFetched: journalFetched,
            hasTodayEntry: journalHasEntry,
            promptedDay: promptedJournalDay,
            sleepPresent: sleepPresent
        ) else { return }
        promptedJournalDay = selectedKey
        continuityID.select(.homeJournal)
        showingMorningJournal = true
    }

    /// Live day strain via `BandStrain` on today's HR, then `NativeStrain.day` with the stored row.
    /// Uses the 300 s buckets already read for the stress chart (within 0.05 of per-sample on the
    /// golden vectors). Recomputes only when `refreshSeq` or the selected day changed.
    private func liveStrainValue(buckets: [HRBucket], day: String, seq: Int) async -> Double? {
        if let cached = NativeLiveStrainMemo.read(seq: seq, day: day) {
            return cached
        }
        guard day == NativeDayLogic.logicalToday() else {
            NativeLiveStrainMemo.store(seq: seq, day: day, value: nil)
            return nil
        }
        guard let repo = repoHandle, let profile = profileHandle else { return liveTodayStrain }
        let maxHR = profile.effortHRmax
        let restHR = NativeStrain.restingHR(
            day: repo.days.last { $0.day == day },
            days: repo.days,
            dayKey: day
        )
        let times = buckets.map { Double($0.ts) }
        let hr = buckets.map(\.bpm)
        let scored = await Task.detached(priority: .utility) {
            NativeStrain.score(times: times, hr: hr, maxHR: maxHR, restingHR: restHR)
        }.value
        NativeLiveStrainMemo.store(seq: seq, day: day, value: scored)
        return scored
    }

    @ViewBuilder private func homeContent(_ model: NativeDay.Model) -> some View {
        HomeRingsRow(
            sleep: model.sleep,
            recovery: model.recovery,
            strain: model.strain,
            onOpen: { path.wrappedValue.append($0) },
            strainTargetFraction: strainTargetFraction
        )
        .equatable()
        .padding(.bottom, HomeMonitorTileLayout.ringsGap)
        HStack(alignment: .top, spacing: HomeMonitorTileLayout.spacing) {
            Button {
                continuityID.select(.homeHealthTile)
                path.wrappedValue.append(TabRoute.healthMonitor)
            } label: {
                HomeHealthMonitorTile(report: healthReport)
                    .equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .buttonStyle(.plain)
            .nativeZoomSource(.homeHealthTile)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Button {
                continuityID.select(.homeStressTile)
                path.wrappedValue.append(TabRoute.stress)
            } label: {
                HomeStressMonitorTile(level: stressLevel, updated: stressUpdatedAt)
                    .equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .buttonStyle(.plain)
            .nativeZoomSource(.homeStressTile)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
        NativeIllnessSignalCard(result: overnightLoad, compact: true)
        NativeChrome.section("My Day")
        HomeActivitiesCard(
            items: activityItems,
            onSleep: {
                continuityID.select(.homeActivitySleep)
                path.wrappedValue.append(TabRoute.sleep)
            },
            onActivity: {
                continuityID.select(.activity($0))
                path.wrappedValue.append(NativeActivityRoute(startTs: $0))
            },
            onAdd: {
                continuityID.select(.addActivity)
                addingActivity = true
            }
        )
        if let tonight {
            HomeTonightSleepCard(
                model: tonight,
                onAlarm: { path.wrappedValue.append(NativeAlarmRoute()) }
            )
        }
        HomeJournalCard(
            dots: journalDots,
            hasEntry: journalHasEntry,
            onOpen: {
                continuityID.select(.homeJournal)
                path.wrappedValue.append(TabRoute.journal)
            },
            onLog: {
                continuityID.select(.homeJournalLog)
                path.wrappedValue.append(TabRoute.journalLog)
            }
        )
        HStack(alignment: .firstTextBaseline) {
            NativeChrome.section("My Dashboard")
            Spacer(minLength: 8)
            Button("Edit") { editingDashboard = true }
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
                .padding(.top, 18)
                .padding(.bottom, 8)
                .accessibilityLabel("Edit Dashboard")
        }
        ForEach(dashboardItems) { item in
            Button {
                continuityID.select(NativeContinuity.dashboard(item))
                path.wrappedValue.append(item.route)
            } label: {
                HomeMetricCard(item: item)
                    .equatable()
            }
            .buttonStyle(.plain)
            .nativeZoomSource(NativeContinuity.dashboard(item))
        }
        HomeStressMonitorHost(
            level: stressLevel,
            hours: sampleHours,
            sleepStart: stressSleepStart,
            sleepEnd: stressSleepEnd,
            workouts: stressBouts,
            dayStart: stressDayStart,
            now: stressNow,
            plot: stressPlot,
            onOpen: {
                continuityID.select(.homeStressChart)
                path.wrappedValue.append(TabRoute.stress)
            }
        )
        .equatable()
        .id(selectedKey)
        HomeWeekCard(
            recovery: weekRecovery,
            strain: weekStrain,
            highlightKey: selectedKey
        )
        .equatable()
    }
}

// MARK: - Date stepper

enum HomeDayTitle {
    private static let weekdayMonthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()

    static func text(for date: Date, now: Date = Date()) -> String {
        if Repository.localDayKey(date) == NativeDayLogic.logicalToday(now: now) { return "Today" }
        return weekdayMonthDay.string(from: date)
    }
}

enum HomeDayNav {
    static func canGoBack(selectedKey: String, firstDay: String?) -> Bool {
        guard let first = firstDay else { return false }
        return selectedKey > first
    }

    @MainActor
    static func canGoForward(selectedKey: String, todayKey: String? = nil) -> Bool {
        selectedKey < (todayKey ?? NativeDayLogic.logicalToday())
    }

    @MainActor
    static func shift(from date: Date, delta: Int, firstDay: String?) -> Date? {
        guard let next = Calendar.current.date(byAdding: .day, value: delta, to: date) else { return nil }
        let key = Repository.localDayKey(next)
        if delta > 0, key > NativeDayLogic.logicalToday() { return nil }
        if delta < 0, let first = firstDay, key < first { return nil }
        return Calendar.current.startOfDay(for: next)
    }
}

/// Compact stepper: two circular chevrons plus a tappable title. Fits beside strap status on 393 pt.
enum HomeDateStepperLayout {
    static let chevronSize: CGFloat = 44
    static let titleMinWidth: CGFloat = 96
    static let spacing: CGFloat = 6
    static let strapGutter: CGFloat = 8
    static let capsulePaddingH: CGFloat = 10
    /// Minimum tappable height for the glass date capsule.
    static let hitHeight: CGFloat = 44
    /// Flame + a two-digit count. Overlay; the stepper stays centred.
    static let streakWidth: CGFloat = 44
    /// Capsule padding + chevrons + title. Leaves room for streak and strap on iPhone 15 (393 pt).
    static var compactWidth: CGFloat {
        capsulePaddingH + chevronSize + spacing + titleMinWidth + spacing + chevronSize + capsulePaddingH
    }
    static let iphone15Width: CGFloat = 393
}

struct HomeDateStepper: View {
    var title: String
    var canGoBack: Bool
    var canGoForward: Bool
    var onBack: () -> Void
    var onForward: () -> Void
    var onTitleTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: HomeDateStepperLayout.spacing) {
            chevron(systemName: "chevron.left", enabled: canGoBack, action: onBack)
                .accessibilityLabel("Previous day")

            Button { onTitleTap?() } label: {
                Text(title)
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
                    .frame(minWidth: HomeDateStepperLayout.titleMinWidth, minHeight: HomeDateStepperLayout.hitHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HomeStepperPressStyle())
            .disabled(onTitleTap == nil)
            .accessibilityLabel(title)
            .accessibilityHint(onTitleTap == nil ? "Steps through days" : "Shows the calendar")
            .accessibilityAddTraits(onTitleTap == nil ? [] : .isButton)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onForward()
                case .decrement: onBack()
                @unknown default: break
                }
            }

            chevron(systemName: "chevron.right", enabled: canGoForward, action: onForward)
                .accessibilityLabel("Next day")
        }
        .padding(.horizontal, HomeDateStepperLayout.capsulePaddingH)
        .frame(minHeight: HomeDateStepperLayout.hitHeight)
        .contentShape(Capsule())
        .homeStepperGlass()
    }

    private func chevron(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(HomeStepperPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// Fixed month-grid chrome. Height is known up front so the sheet does not reflow.
enum HomeCalendarSheetLayout {
    static let cell = NoopMetrics.profileAvatarDiameter
    static let circle = NoopMetrics.compactControlSize
    static let weekdayRow = NoopMetrics.space6
    static let header = NoopMetrics.controlHeight
    /// Today / Done row. Reserved at first frame so glass chrome cannot grow the detent.
    static let actions = NoopMetrics.controlHeight
    static let rows = HomeCalendarMath.rows
    static var gridHeight: CGFloat { cell * CGFloat(rows) }
    static var compactHeight: CGFloat {
        NoopMetrics.space4 + actions + NoopMetrics.space2 + header + weekdayRow + gridHeight + NoopMetrics.space4
    }
}

/// Recovery as calendar-number ink. Dark-sheet recovery tokens are already the brighter hexes.
private enum HomeCalendarInk {
    static func recovery(_ percent: Double) -> Color {
        NativeTokens.recoveryBand(percent)
    }

    /// Contrasting fill-circle text. `page` is near-white on a black (light) fill and black on a white (dark) fill.
    static let selectedText = NativeTokens.page
}

/// Calendar for jumping straight to a day. Past days carry that day's recovery zone.
struct HomeCalendarSheet: View {
    var range: ClosedRange<Date>
    var recoveryByDay: [String: Double]
    var onPick: (Date) -> Void
    @State private var month: Date
    @Environment(\.dismiss) private var dismiss

    private let calendar = Calendar.current
    private let selected: Date

    init(
        selected: Date,
        range: ClosedRange<Date>,
        recoveryByDay: [String: Double],
        onPick: @escaping (Date) -> Void
    ) {
        self.range = range
        self.recoveryByDay = recoveryByDay
        self.onPick = onPick
        let clamped = min(max(selected, range.lowerBound), range.upperBound)
        self.selected = Calendar.current.startOfDay(for: clamped)
        _month = State(initialValue: HomeCalendarMath.monthStart(clamped, calendar: .current))
    }

    var body: some View {
        let cells = HomeCalendarMath.cells(month: month, calendar: calendar)
        VStack(spacing: 0) {
            HStack {
                Button("Today") {
                    onPick(range.upperBound)
                    dismiss()
                }
                .homeCalendarGlassButton(prominent: false)
                Spacer(minLength: NoopMetrics.space2)
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
                    .homeCalendarGlassButton(prominent: true)
            }
            .padding(.horizontal, NoopMetrics.space4)
            .frame(height: HomeCalendarSheetLayout.actions)
            .padding(.top, NoopMetrics.space4)
            .padding(.bottom, NoopMetrics.space2)

            HStack {
                Button { page(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!HomeCalendarMath.canPage(from: month, delta: -1, range: range, calendar: calendar))
                Spacer(minLength: 0)
                Text(HomeCalendarMath.monthTitle(month, calendar: calendar))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button { page(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!HomeCalendarMath.canPage(from: month, delta: 1, range: range, calendar: calendar))
            }
            .padding(.horizontal, NoopMetrics.space2)
            .frame(height: HomeCalendarSheetLayout.header)

            HStack(spacing: 0) {
                ForEach(Array(HomeCalendarMath.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: HomeCalendarSheetLayout.weekdayRow)
            .padding(.horizontal, NoopMetrics.space2)
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                ForEach(0..<HomeCalendarMath.rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<HomeCalendarMath.columns, id: \.self) { column in
                            dayCell(cells[row * HomeCalendarMath.columns + column])
                        }
                    }
                }
            }
            .padding(.horizontal, NoopMetrics.space2)
            .frame(height: HomeCalendarSheetLayout.gridHeight)
            .animation(nil, value: month)
            Spacer(minLength: 0)
        }
        .presentationDetents([.height(HomeCalendarSheetLayout.compactHeight), .large])
        .presentationDragIndicator(.visible)
    }

    private func dayCell(_ date: Date?) -> HomeCalendarDayCell {
        HomeCalendarDayCell(
            date: date,
            selected: selected,
            today: range.upperBound,
            enabled: date.map { HomeCalendarMath.isEnabled($0, range: range, calendar: calendar) } ?? false,
            recovery: date.flatMap { recoveryByDay[Repository.localDayKey($0)] },
            calendar: calendar,
            onPick: { picked in
                onPick(picked)
                dismiss()
            }
        )
    }

    private func page(_ delta: Int) {
        guard HomeCalendarMath.canPage(from: month, delta: delta, range: range, calendar: calendar),
              let next = calendar.date(byAdding: .month, value: delta, to: month)
        else { return }
        month = HomeCalendarMath.monthStart(next, calendar: calendar)
    }
}

private struct HomeCalendarDayCell: View {
    var date: Date?
    var selected: Date
    var today: Date
    var enabled: Bool
    var recovery: Double?
    var calendar: Calendar
    var onPick: (Date) -> Void

    var body: some View {
        Group {
            if let date {
                Button { onPick(date) } label: { glyph(date) }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .accessibilityLabel(accessibility(date))
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, minHeight: HomeCalendarSheetLayout.cell, maxHeight: HomeCalendarSheetLayout.cell)
    }

    private func glyph(_ date: Date) -> some View {
        let isSelected = HomeCalendarMath.isSameDay(date, selected, calendar: calendar)
        let isToday = HomeCalendarMath.isSameDay(date, today, calendar: calendar)
        return ZStack {
            if isSelected {
                Circle().fill(Color.primary)
            } else if isToday {
                Circle().strokeBorder(Color.secondary, lineWidth: NoopMetrics.hairlineWidth)
            }
            Text("\(calendar.component(.day, from: date))")
                .font(.body.weight(isToday || isSelected ? .bold : .regular))
                .foregroundStyle(numberInk(selected: isSelected))
                .monospacedDigit()
            if let recovery {
                VStack {
                    Spacer(minLength: 0)
                    Circle()
                        .fill(isSelected ? HomeCalendarInk.selectedText : HomeCalendarInk.recovery(recovery))
                        .frame(width: 4, height: 4)
                        .padding(.bottom, 3)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: HomeCalendarSheetLayout.circle, height: HomeCalendarSheetLayout.circle)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Circle())
    }

    private func numberInk(selected: Bool) -> Color {
        if selected { return HomeCalendarInk.selectedText }
        if !enabled { return Color.secondary }
        if let recovery { return HomeCalendarInk.recovery(recovery) }
        return Color.primary
    }

    private func accessibility(_ date: Date) -> String {
        var parts = [NativeChartDay.longLabel(Repository.localDayKey(date))]
        if let recovery {
            let percent = Int(recovery.rounded())
            parts.append("recovery \(percent)%")
            parts.append(recoveryColorName(recovery))
        }
        if !enabled { parts.append("Unavailable") }
        return parts.joined(separator: ", ")
    }

    private func recoveryColorName(_ percent: Double) -> String {
        if percent < 34 { return "red" }
        if percent < 67 { return "yellow" }
        return "green"
    }
}

private struct HomeStepperPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

private extension View {
    /// Capsule Liquid Glass on the date stepper. iOS 26 uses `glassEffect`; iOS 17
    /// uses ultra-thin material; macOS uses the card token.
    @ViewBuilder func homeStepperGlass() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
        #else
        self.background(NativeTokens.card, in: Capsule())
        #endif
    }

    /// Liquid Glass on the calendar Today / Done buttons. iOS 26 uses `.glass` / `.glassProminent`;
    /// older OS and macOS fall back to bordered styles.
    @ViewBuilder func homeCalendarGlassButton(prominent: Bool) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            // Prominent glass fills with the app tint, which is white here, so its white label vanished.
            // Plain glass for both; Done stays emphasised by its semibold label.
            self.buttonStyle(.glass)
        } else if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
        #endif
    }
}

// MARK: - Rings

struct HomeRingsRow: View {
    var sleep: NativeScore
    var recovery: NativeScore
    var strain: NativeScore
    var onOpen: (TabRoute) -> Void
    var strainTargetFraction: ClosedRange<Double>? = nil
    @Environment(\.nativeStyle) private var style
    @Environment(\.nativeContinuityActiveID) private var continuityID

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ring(sleep, tint: NativePaint.sleep(style))
            ring(recovery, tint: recoveryTint)
            ring(strain, tint: NativePaint.strain(style), targetFraction: strainTargetFraction)
        }
        .padding(.top, 8)
    }

    private var recoveryTint: Color {
        if let percent = NativeScoreMath.percentValue(recovery.value) {
            return NativePaint.recoveryBand(percent, style: style)
        }
        return NativePaint.recovery(style)
    }

    private func ring(_ score: NativeScore, tint: Color, targetFraction: ClosedRange<Double>? = nil) -> some View {
        let id = NativeContinuity.ring(for: score.route)
        return Button {
            continuityID.select(id)
            onOpen(score.route)
        } label: {
            NativeRing(
                fraction: score.fraction,
                tint: tint,
                value: score.value,
                caption: score.name,
                diameter: 96,
                targetFraction: targetFraction
            )
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nativeZoomSource(id)
        .accessibilityHint("Opens \(score.name)")
    }
}

// MARK: - Health + Stress tiles

enum HomeMonitorTileLayout {
    static let spacing: CGFloat = 10
    /// Breathing room between the ring labels and the monitor tiles.
    static let ringsGap: CGFloat = 12
    static let valueMinHeight: CGFloat = 28
    static let captionMinHeight: CGFloat = 18
}

/// Apple Health summary-card header: tinted SF Symbol + title, chevron trailing.
private struct HomeSummaryTileHeader: View {
    var title: String
    var symbol: String
    var tint: Color

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(tint)
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityElement(children: .combine)
    }
}

struct HomeHealthMonitorTile: View {
    var report: NativeHealthRange.Report
    @Environment(\.nativeStyle) private var style

    var body: some View {
        let summary = report.summary
        let primary = HomeMonitorTile.healthPrimary(summary)
        let inRange = summary.tileWithinRange
        let valueTint: Color = {
            if summary.measured == 0 || summary.judged == 0 { return Color.secondary }
            return inRange ? NativeTokens.recoveryHigh : NativeTokens.recoveryLow
        }()
        NativeChrome.panel(expands: true) {
            HomeSummaryTileHeader(
                title: "Health Monitor",
                symbol: "heart.fill",
                tint: NativePaint.heart(style)
            )
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if summary.measured > 0, summary.judged > 0 {
                    Image(systemName: inRange ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(valueTint)
                }
                Text(primary)
                    .foregroundStyle(valueTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(style == .whoop
                  ? NativeTokens.whoopNumber(22, weight: .semibold)
                  : .title3.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: HomeMonitorTileLayout.valueMinHeight, alignment: .leading)
            Text(summary.tileDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: HomeMonitorTileLayout.captionMinHeight, alignment: .leading)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.tileHeadline), \(summary.tileDetail)")
    }
}

struct HomeStressMonitorTile: View {
    var level: Double?
    var updated: Date?
    @Environment(\.nativeStyle) private var style

    var body: some View {
        let tile = HomeMonitorTile.stress(level: level, at: updated)
        let tint = level.map { NativePaint.stressBand($0, style: style) } ?? NativeChrome.stress
        NativeChrome.panel(expands: true) {
            HomeSummaryTileHeader(
                title: "Stress Monitor",
                symbol: "chart.xyaxis.line",
                tint: tint
            )
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let value = tile.value, let band = tile.band, let level {
                    Text(value)
                        .font(style == .whoop
                              ? NativeTokens.whoopNumber(22, weight: .bold)
                              : .title3.weight(.semibold))
                        .monospacedDigit()
                    Text(band.uppercased())
                        .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline.weight(.semibold))
                        .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                        .foregroundStyle(NativePaint.stressBand(level, style: style))
                } else {
                    Text("No data")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: HomeMonitorTileLayout.valueMinHeight, alignment: .leading)
            Text(tile.time.map { "Updated \($0)" } ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: HomeMonitorTileLayout.captionMinHeight, alignment: .leading)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tile.accessibility)
    }
}

// MARK: - Health + Stress monitors

struct HomeHealthMonitorCard: View {
    var report: NativeHealthRange.Report
    @Environment(\.nativeStyle) private var style

    private var rows: [NativeHealthRange.Vital] {
        let preferred = ["hrv", "rhr", "resp"]
        let picked = preferred.compactMap { id in report.vitals.first { $0.id == id } }
        return picked.isEmpty ? report.vitals : picked
    }

    var body: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: "Health Monitor",
                symbol: "heart.fill",
                tint: NativePaint.heart(style),
                trailing: report.summary.headerTrailing,
                chevron: true
            )
            if rows.isEmpty {
                NativeEmptyState(text: "No data", symbol: "heart")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, vital in
                        if index > 0 {
                            Divider().padding(.leading, 32)
                        }
                        NativeContributorRow(
                            symbol: vital.symbol,
                            title: compactTitle(vital.id),
                            value: compactValue(vital),
                            prior: vital.building ? "Building baseline" : "Typical \(vital.typicalText)",
                            delta: vital.flagDelta,
                            tint: vital.id == "resp" ? NativePaint.respiratory(style) : NativePaint.heart(style),
                            valueTint: vital.flagged ? NativeTokens.recoveryLow : .primary
                        )
                    }
                }
            }
        }
    }

    private func compactTitle(_ id: String) -> String {
        switch id {
        case "hrv": return "HRV"
        case "rhr": return "RHR"
        case "resp": return "RR"
        default: return report.vitals.first { $0.id == id }?.title ?? id
        }
    }

    private func compactValue(_ vital: NativeHealthRange.Vital) -> String {
        NativeHealthMonitorFormat.trailingValue(vital)
    }
}

/// Owns stress scrub so dragging the chart does not invalidate the whole Home scroll.
private struct HomeStressMonitorHost: View, Equatable {
    var level: Double?
    var hours: [NativeHourPoint]
    var sleepStart: Date?
    var sleepEnd: Date?
    var workouts: [(start: Date, end: Date)]
    var dayStart: Date
    var now: Date
    var plot: NativeStressDayPlotModel
    var onOpen: () -> Void
    @State private var scrubValue = 0.0
    @State private var scrubTime: Date?

    static func == (lhs: HomeStressMonitorHost, rhs: HomeStressMonitorHost) -> Bool {
        lhs.level == rhs.level
            && lhs.hours == rhs.hours
            && lhs.sleepStart == rhs.sleepStart
            && lhs.sleepEnd == rhs.sleepEnd
            && lhs.dayStart == rhs.dayStart
            && lhs.now == rhs.now
            && lhs.plot == rhs.plot
            && lhs.workouts.count == rhs.workouts.count
            && zip(lhs.workouts, rhs.workouts).allSatisfy {
                $0.start == $1.start && $0.end == $1.end
            }
    }

    var body: some View {
        HomeStressMonitorCard(
            level: level,
            hours: hours,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            workouts: workouts,
            dayStart: dayStart,
            now: now,
            plot: plot,
            scrubValue: $scrubValue,
            scrubTime: $scrubTime,
            onOpen: onOpen
        )
    }
}

struct HomeStressMonitorCard: View {
    var level: Double?
    var hours: [NativeHourPoint]
    var sleepStart: Date?
    var sleepEnd: Date?
    var workouts: [(start: Date, end: Date)]
    var dayStart: Date
    var now: Date
    var plot: NativeStressDayPlotModel? = nil
    @Binding var scrubValue: Double
    @Binding var scrubTime: Date?
    var onOpen: () -> Void
    @Environment(\.nativeStyle) private var style

    private var shownLevel: Double? {
        scrubTime == nil ? level : scrubValue
    }

    private var updatedText: String? {
        guard let time = scrubTime ?? hours.last?.time else { return nil }
        return "Updated \(NativeScopeFormat.time(time))"
    }

    var body: some View {
        NativeChrome.panel {
            Button(action: onOpen) {
                NativeCardHeader(
                    title: "Stress Monitor",
                    symbol: "chart.xyaxis.line",
                    tint: shownLevel.map { NativePaint.stressBand($0, style: style) } ?? NativeChrome.stress,
                    chevron: true
                )
            }
            .buttonStyle(.plain)
            HomeStressHero(level: shownLevel, updated: updatedText)
                .frame(height: 56, alignment: .topLeading)
            NativeStressDayChart(
                model: plot ?? NativeStressDayPlotModel.make(
                    score: shownLevel ?? hours.last?.value ?? 0,
                    hours: hours,
                    sleepStart: sleepStart,
                    sleepEnd: sleepEnd,
                    workouts: workouts,
                    workoutSymbols: [],
                    dayStart: dayStart,
                    now: now
                ),
                height: NativeStressDayChart.heightHome,
                scrubValue: $scrubValue,
                scrubTime: $scrubTime
            )
        }
        .nativeZoomSource(.homeStressChart)
    }
}

struct HomeStressHero: View {
    var level: Double?
    var updated: String?
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let level {
                    NativeValueText(value: String(format: "%.1f", level), size: 28)
                    Text(NativeHomeCharts.stressBandWord(level))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NativePaint.stressBand(level, style: style))
                } else {
                    NativeValueText(value: "No data", size: 28)
                }
            }
            Text(updated ?? " ")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .opacity(updated == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        if let level {
            var parts = ["Stress \(String(format: "%.1f", level))", NativeHomeCharts.stressBandWord(level)]
            if let updated { parts.append(updated) }
            return parts.joined(separator: ", ")
        }
        return "No data"
    }
}

// MARK: - My Day

struct HomeActivityItem: Identifiable, Equatable {
    enum Kind: Equatable { case sleep, strain }
    var id: String
    var symbol: String
    var kind: Kind
    var title: String
    var startClock: String
    var endClock: String
    var trailing: String
    var startTs: Int?

    static func make(from model: NativeDay.Model) -> [HomeActivityItem] {
        var items: [HomeActivityItem] = []
        if let duration = model.sleepBlock {
            let startClock = model.sleepStart.map { NativeDay.clockTime(Int($0.timeIntervalSince1970)) } ?? ""
            let endClock = model.sleepEnd.map { NativeDay.clockTime(Int($0.timeIntervalSince1970)) } ?? ""
            items.append(HomeActivityItem(
                id: "sleep",
                symbol: "moon.fill",
                kind: .sleep,
                title: "Sleep",
                startClock: startClock,
                endClock: endClock,
                trailing: duration,
                startTs: nil
            ))
        }
        // Chronological: sleep first, then activities by start time.
        for activity in model.activities.sorted(by: { $0.startTs < $1.startTs }) {
            items.append(HomeActivityItem(
                id: "\(activity.startTs)",
                symbol: activity.symbol,
                kind: .strain,
                title: activity.sport.localizedCapitalized,
                startClock: activity.startClock,
                endClock: activity.endClock,
                trailing: activity.strainText,
                startTs: activity.startTs
            ))
        }
        return items
    }
}

struct HomeActivitiesCard: View {
    var items: [HomeActivityItem]
    var onSleep: () -> Void
    var onActivity: (Int) -> Void
    var onAdd: (() -> Void)? = nil

    var body: some View {
        NativeChrome.panel {
            HStack(alignment: .firstTextBaseline) {
                NativeCardHeader(title: "Activities", symbol: "figure.run", tint: NativeChrome.strain)
                if let onAdd {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NativeChrome.strain)
                    .nativeZoomSource(.addActivity)
                    .accessibilityLabel("Add Activity")
                }
            }
            if items.isEmpty {
                Text("No activities")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    let firstID = items.first?.id
                    ForEach(items) { item in
                        if item.id != firstID {
                            Divider().padding(.vertical, 4)
                        }
                        Button {
                            if let startTs = item.startTs {
                                onActivity(startTs)
                            } else {
                                onSleep()
                            }
                        } label: {
                            HomeActivityRow(item: item)
                                .equatable()
                        }
                        .buttonStyle(.plain)
                        .nativeZoomSource(
                            item.startTs.map(NativeContinuityID.activity) ?? .homeActivitySleep
                        )
                    }
                }
            }
        }
    }
}

private struct HomeActivityRow: View, Equatable {
    var item: HomeActivityItem
    @Environment(\.nativeStyle) private var style

    static func == (lhs: HomeActivityRow, rhs: HomeActivityRow) -> Bool {
        lhs.item == rhs.item
    }

    var body: some View {
        let tint = item.kind == .sleep ? NativePaint.sleep(style) : NativePaint.strain(style)
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: item.symbol)
                    .font(.body.weight(.semibold))
                    .frame(width: HomeActivityLayout.iconWidth, alignment: .center)
                Text(item.trailing)
                    .font(style == .whoop
                          ? NativeTokens.whoopNumber(17, weight: .bold)
                          : StrandFont.rounded(17, weight: .semibold))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, HomeActivityLayout.paddingH)
            .padding(.vertical, HomeActivityLayout.paddingV)
            .frame(width: HomeActivityLayout.pillWidth)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint)
            )

            Text(style == .whoop ? item.title.uppercased() : item.title)
                .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline.weight(.semibold))
                .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 6)

            if !item.startClock.isEmpty || !item.endClock.isEmpty {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(item.startClock)
                    Text(item.endClock)
                }
                .font(style == .whoop ? NativeTokens.whoopCaps(10) : .caption2)
                .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
            }

            Capsule()
                .fill(tint)
                .frame(width: 3, height: 28)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.trailing), \(item.startClock) \(item.endClock)")
    }
}

struct HomeStreakBadge: View {
    var count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
            Text("\(count)")
                .font(.body.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(NativeChrome.activity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) day sleep streak")
    }
}

struct HomeJournalDot: Identifiable, Equatable {
    var key: String
    var filled: Bool
    var id: String { key }
}

/// WHOOP journal week: filled days are a tinted check, empty days an empty circle.
enum HomeJournalGlyph {
    static let filled = "checkmark.circle.fill"

    static func symbol(filled: Bool) -> String? {
        filled ? Self.filled : nil
    }
}

private struct HomeJournalDayDot: View {
    var dot: HomeJournalDot
    @Environment(\.nativeStyle) private var style

    var body: some View {
        let fill = NativePaint.sleep(style)
        VStack(spacing: 6) {
            Text(NativeChartDay.weekday(dot.key).uppercased())
                .font(style == .whoop ? NativeTokens.whoopCaps(9) : .caption2)
                .foregroundStyle(.secondary)
            if dot.filled {
                Image(systemName: HomeJournalGlyph.filled)
                    .font(.body)
                    .foregroundStyle(fill)
            } else if style == .whoop {
                Circle()
                    .strokeBorder(NativeTokens.whoopTrack, lineWidth: 1.5)
                    .frame(width: 16, height: 16)
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1.5)
                    .frame(width: 16, height: 16)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(dot.filled ? "Journal logged" : "No journal")
    }
}

struct HomeJournalCard: View {
    var dots: [HomeJournalDot]
    var hasEntry: Bool = false
    var onOpen: () -> Void
    var onLog: (() -> Void)? = nil

    var body: some View {
        NativeChrome.panel {
            HStack(alignment: .firstTextBaseline) {
                Button(action: onOpen) {
                    NativeCardHeader(
                        title: "Journal",
                        symbol: "book.closed.fill",
                        tint: NativeChrome.sleep,
                        chevron: true
                    )
                }
                .buttonStyle(.plain)
                if let onLog {
                    Button(hasEntry ? "Edit" : "Log", action: onLog)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(NativeChrome.sleep)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                        .nativeZoomSource(.homeJournalLog)
                }
            }
            Button(action: onOpen) {
                HStack(spacing: 0) {
                    ForEach(dots) { dot in
                        HomeJournalDayDot(dot: dot)
                    }
                }
                .padding(.top, 4)
            }
            .buttonStyle(.plain)
        }
        .nativeZoomSource(.homeJournal)
        .accessibilityLabel("Journal")
    }
}

// MARK: - Weekly Strain & Recovery

struct HomeWeekCard: View {
    var recovery: [NativeDayPoint]
    var strain: [NativeDayPoint]
    var highlightKey: String
    var previewSelected: String? = nil

    var body: some View {
        NativeChrome.panel {
            HomeDualSeriesHeader()
            if recovery.isEmpty && strain.isEmpty {
                NativeEmptyState(text: "No data")
                    .frame(height: 160)
            } else {
                NativeStrainRecoveryChart(
                    recovery: recovery,
                    strain: strain,
                    highlightKey: highlightKey,
                    showsHero: true,
                    previewSelected: previewSelected
                )
            }
        }
    }
}

private struct HomeDualSeriesHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
            Text("Strain")
                .foregroundStyle(NativeChrome.strain)
            Text("&")
                .foregroundStyle(.secondary)
            Text("Recovery")
                .foregroundStyle(NativeChrome.recovery)
            Spacer(minLength: 8)
        }
        .font(.footnote.weight(.semibold))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Strain and Recovery")
    }
}

// MARK: - Metric cards

struct HomeMetricItem: Identifiable, Equatable {
    var id: String { title }
    var title: String
    var value: String
    var unit: String?
    var prior: String?
    var delta: NativeScore.Delta
    var symbol: String
    var tint: Color
    var points: [NativeDayPoint]
    var bars: Bool
    var route: TabRoute

    static func make(dashboard: [NativeScore.Row], days: [DailyMetric], todayKey: String,
                     vo2max: Double? = nil, model: NativeDay.Model? = nil, stress: Double? = nil,
                     ids: [String] = HomeDashboardMetric.defaultIds) -> [HomeMetricItem] {
        let day = days.last { $0.day == todayKey }
        let filled = fill(
            dashboard: dashboard, day: day, vo2max: vo2max, model: model, stress: stress
        )
        return ids.compactMap { filled[$0] }
    }

    private static func fill(
        dashboard: [NativeScore.Row],
        day: DailyMetric?,
        vo2max: Double?,
        model: NativeDay.Model?,
        stress: Double?
    ) -> [String: HomeMetricItem] {
        var filled: [String: HomeMetricItem] = [:]
        func put(_ metric: HomeDashboardMetric, value: String, prior: String? = nil,
                 unit: String? = nil, delta: NativeScore.Delta = .none) {
            let known = NativeScoreMath.hasValue(value)
            filled[metric.rawValue] = HomeMetricItem(
                title: metric.title,
                value: known ? value : HomeDashboardMetric.emptyValue,
                unit: unit ?? metric.unit,
                prior: prior.flatMap { NativeScoreMath.hasValue($0) ? $0 : nil },
                delta: known ? delta : .none,
                symbol: metric.symbol,
                tint: metric.tint,
                points: [],
                bars: false,
                route: metric.route
            )
        }
        func fromDashboard(_ metric: HomeDashboardMetric, title: String, unit: String?) {
            guard let row = dashboard.first(where: { $0.title == title }) else { return }
            put(metric, value: row.value, prior: row.prior, unit: unit, delta: row.delta)
        }
        fromDashboard(.hrv, title: "Heart Rate Variability", unit: "ms")
        fromDashboard(.restingHr, title: "Resting Heart Rate", unit: "BPM")
        fromDashboard(.respiratory, title: "Respiratory Rate", unit: "breaths/min")
        fromDashboard(.steps, title: "Steps", unit: "steps")
        fromDashboard(.calories, title: "Calories", unit: "cal")
        fromDashboard(.hrZones13, title: "Heart Rate Zones 1–3", unit: nil)
        fromDashboard(.hrZones45, title: "Heart Rate Zones 4–5", unit: nil)
        fromDashboard(.strength, title: "Strength Activity Time", unit: nil)
        if let vo2max {
            put(.vo2max, value: String(format: "%.1f", vo2max))
        }
        if let spo2 = day?.spo2Pct {
            put(.spo2, value: "\(Int(spo2.rounded()))%")
        }
        if let skin = day?.skinTempC ?? day?.skinTempDevC {
            let unit = UnitPrefs.resolveTemperature(
                system: UnitSystem(rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .imperial,
                override: UserDefaults.standard.string(forKey: UnitPrefs.temperatureKey) ?? "")
            put(.skinTemp, value: VitalBands.isAbsoluteSkinTemp(skin)
                ? UnitFormatter.temperatureFromCelsius(skin, unit: unit)
                : UnitFormatter.temperatureDeltaFromCelsius(skin, unit: unit))
        }
        if let model, NativeScoreMath.hasValue(model.sleep.value) {
            put(.sleepPerformance, value: model.sleep.value, delta: .none)
        }
        if let hours = model?.sleepHours, NativeScoreMath.hasValue(hours) {
            put(.sleepHours, value: hours)
        }
        if let need = model?.sleepNeedMin, need > 0 {
            put(.sleepNeed, value: NativeTonightSleep.needText(need))
        }
        if let debt = model?.sleepDebtMin, debt > 0 {
            put(.sleepDebt, value: NativeDayLogic.durationText(debt))
        }
        if let stress {
            put(.stress, value: String(format: "%.1f", stress))
        }
        for metric in HomeDashboardMetric.allCases where filled[metric.rawValue] == nil {
            put(metric, value: HomeDashboardMetric.emptyValue)
        }
        return filled
    }
}

struct HomeMetricCard: View, Equatable {
    var item: HomeMetricItem
    @Environment(\.nativeStyle) private var style

    static func == (lhs: HomeMetricCard, rhs: HomeMetricCard) -> Bool {
        lhs.item == rhs.item
    }

    var body: some View {
        NativeChrome.panel {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.body)
                    .foregroundStyle(item.tint)
                    .frame(width: HomeActivityLayout.dashboardIconWidth, alignment: .center)
                Text(style == .whoop ? item.title.uppercased() : item.title)
                    .font(style == .whoop ? NativeTokens.whoopCaps(13) : .body)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(displayValue)
                            .font(style == .whoop
                                  ? NativeTokens.whoopNumber(17, weight: .semibold)
                                  : StrandFont.rounded(17, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                        NativeDelta(delta: item.delta)
                    }
                    if let prior = item.prior, NativeScoreMath.hasValue(prior) {
                        Text(prior)
                            .font(style == .whoop ? NativeTokens.whoopNumber(12, weight: .regular) : .footnote)
                            .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: HomeActivityLayout.dashboardValueMinWidth, alignment: .trailing)
                .layoutPriority(1)
            }
            .frame(minHeight: 48)
            .accessibilityElement(children: .combine)
        }
    }

    private var displayValue: String {
        guard NativeScoreMath.hasValue(item.value) else { return item.value }
        if let unit = item.unit, !unit.isEmpty, item.value.localizedCaseInsensitiveContains(unit) == false {
            return "\(item.value) \(unit)"
        }
        return item.value
    }
}

// MARK: - Charts / stress series

enum NativeHomeCharts {
    static func points(_ days: [DailyMetric], todayKey: String, keyPath: KeyPath<DailyMetric, Double?>) -> [NativeDayPoint] {
        NativeWeek.series(days, todayKey: todayKey) { $0[keyPath: keyPath] }
            .filter { $0.value.isFinite }
    }

    /// Same 0–3 derivation Stress Monitor uses, over the last 7 days that have HRV or resting heart rate.
    static func stress(_ days: [DailyMetric], todayKey: String) -> [NativeDayPoint] {
        let window = days.filter { $0.day <= todayKey }.suffix(37)
        let baseline = Array(window.dropLast(7))
        let recent = Array(window.suffix(7))
        let meanRHR = StressMath.mean(baseline.compactMap { $0.restingHr }.map(Double.init))
        let sdRHR = StressMath.std(baseline.compactMap { $0.restingHr }.map(Double.init), mean: meanRHR)
        let meanHRV = StressMath.mean(baseline.compactMap(\.avgHrv))
        let sdHRV = StressMath.std(baseline.compactMap(\.avgHrv), mean: meanHRV)
        return recent.compactMap { day in
            let raw = StressMath.rawScore(
                rhrToday: day.restingHr.map(Double.init), meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: day.avgHrv, meanHRV: meanHRV, sdHRV: sdHRV
            )
            guard day.restingHr != nil || day.avgHrv != nil else { return nil }
            return NativeDayPoint(key: day.day, value: StressMath.squash(raw))
        }
    }

    /// Personal overnight RHR / HRV, once per data load.
    static func stressBaselines(days: [DailyMetric], todayKey: String) -> BandStress.Baselines {
        let today = days.last { $0.day == todayKey }
        let prior = Array(days.filter { $0.day < todayKey }.suffix(BandStress.recentBaselineDays))
        return BandStress.Baselines.resolve(
            dayRestingHR: today?.restingHr.map(Double.init),
            recentRestingHRs: prior.compactMap { $0.restingHr.map(Double.init) },
            dayRMSSD: today?.avgHrv,
            recentRMSSDs: prior.compactMap(\.avgHrv)
        )
    }

    /// Maps HR samples onto the 0–3 series. Empty input → empty series. Never invents a curve.
    static func stressSeries(samples: [(ts: Int, bpm: Int)], stride: Int = 3,
                             baselines: BandStress.Baselines = .fallback,
                             asleep: Bool = false) -> [NativeHourPoint] {
        samples.enumerated().compactMap { index, sample in
            guard stride <= 1 || index % stride == 0 else { return nil }
            return NativeHourPoint(
                time: Date(timeIntervalSince1970: TimeInterval(sample.ts)),
                value: stressValue(bpm: Double(sample.bpm), baselines: baselines, asleep: asleep)
            )
        }
    }

    /// Minute buckets. Workout, post-workout recovery, and walking/running
    /// buckets are omitted so the line breaks. Gaps stay omitted. Scored minutes
    /// are centred-smoothed over ~5 minutes inside each contiguous run.
    static func stressSeries(buckets: [HRBucket],
                             baselines: BandStress.Baselines = .fallback,
                             sleepStart: Date? = nil,
                             sleepEnd: Date? = nil,
                             workouts: [(start: Date, end: Date)] = [],
                             rmssdByBucket: [Int: Double] = [:],
                             activityBuckets: Set<Int> = [],
                             recovery: [(start: Int, end: Int)] = []) -> [NativeHourPoint] {
        stressTimeline(
            buckets: buckets, baselines: baselines, sleepStart: sleepStart, sleepEnd: sleepEnd,
            workouts: workouts, rmssdByBucket: rmssdByBucket,
            activityBuckets: activityBuckets, recovery: recovery
        ).hours
    }

    /// Hours plus the excluded spans (workout / recovery / walking). Walking spans
    /// are merged for display; they are not drawn as activities.
    static func stressTimeline(buckets: [HRBucket],
                               baselines: BandStress.Baselines = .fallback,
                               sleepStart: Date? = nil,
                               sleepEnd: Date? = nil,
                               workouts: [(start: Date, end: Date)] = [],
                               rmssdByBucket: [Int: Double] = [:],
                               activityBuckets: Set<Int> = [],
                               recovery: [(start: Int, end: Int)] = []) -> (
                                hours: [NativeHourPoint],
                                exclusions: [BandStress.ExclusionSpan]
                               ) {
        let timeline = BandStress.timeline(
            buckets: buckets.map { (ts: $0.ts, bpm: $0.bpm) },
            baselines: baselines,
            sleepStart: sleepStart.map { Int($0.timeIntervalSince1970) },
            sleepEnd: sleepEnd.map { Int($0.timeIntervalSince1970) },
            workouts: workouts.map {
                (start: Int($0.start.timeIntervalSince1970), end: Int($0.end.timeIntervalSince1970))
            },
            rmssdByBucket: rmssdByBucket,
            activityBuckets: activityBuckets,
            recovery: recovery,
            smoothRadius: NativeHomeCharts.stressDisplayRadius
        )
        let hours = timeline.hours.map { point in
            NativeHourPoint(
                time: Date(timeIntervalSince1970: TimeInterval(point.ts)),
                value: point.value
            )
        }
        return (hours, timeline.exclusions)
    }

    /// Minutes either side for the displayed stress line: a 15-minute centred mean, close to
    /// WHOOP's smooth trace. The 5-minute default in `BandStress` stayed too jittery on the phone.
    static let stressDisplayRadius = 7

    static func stressValue(bpm: Double,
                            baselines: BandStress.Baselines = .fallback,
                            asleep: Bool = false,
                            rmssd: Double? = nil) -> Double {
        BandStress.score(bpm: bpm, rmssd: rmssd, isAsleep: asleep, baselines: baselines)
    }

    /// Last sample if the series exists, else the daily HRV/RHR score, else nil. Never 1.0 or 0 as a stand-in.
    static func stressLevel(hours: [NativeHourPoint], days: [DailyMetric], todayKey: String) -> Double? {
        // Latest reading at or before now, so the tile and the clipped chart end on the same point.
        hours.last(where: { $0.time <= Date() })?.value ?? stress(days, todayKey: todayKey).last?.value
    }

    /// NativeStressMonitor calls this when `sampleHours` is empty. Returns nothing so Home
    /// and the pushed page cannot disagree via a synthetic sleep/workout curve.
    static func stressHours(dayStart: Date, now: Date, sleepStart: Date?, sleepEnd: Date?,
                            workouts: [(Date, Date)], daily: Double) -> [NativeHourPoint] {
        _ = (dayStart, now, sleepStart, sleepEnd, workouts, daily)
        return []
    }

    static func journalDots(filled: [Bool], todayKey: String) -> [HomeJournalDot] {
        zip(NativeWeek.lastSevenKeys(ending: todayKey), filled).map {
            HomeJournalDot(key: $0.0, filled: $0.1)
        }
    }

    /// Two-line x-axis label for a `yyyy-MM-dd` key: weekday abbreviation over
    /// day-of-month ("Thu" / "12"). Unique across a week, including Sat/Sun.
    static func axisLabel(_ key: String) -> String {
        "\(NativeChartDay.weekday(key))\n\(NativeChartDay.dayOfMonth(key))"
    }

    static func weekday(_ key: String) -> String { axisLabel(key) }

    static func stressBand(_ value: Double) -> String {
        stressBandWord(value).uppercased()
    }

    static func stressBandWord(_ value: Double) -> String {
        if value < 1 { return "Low" }
        if value < 2 { return "Medium" }
        return "High"
    }
}

struct NativeActivityRoute: Hashable {
    var startTs: Int
}

struct NativePairRoute: Hashable {}

struct NativeAlarmRoute: Hashable {}

/// Holds Repository / BLE / Profile so NativeHomeView itself does not. Forwards only
/// `refreshSeq` and `loaded` — hydration, cycle, scan RSSI, and profile calibration
/// publishes stay in this Color.clear leaf.
private struct NativeHomeEnvSink: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var profile: ProfileStore
    @Binding var refreshSeq: Int
    @Binding var loaded: Bool
    @Binding var handlesReady: Bool
    var onHandles: (Repository, BLEManager, ProfileStore) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                onHandles(repo, ble, profile)
                refreshSeq = repo.refreshSeq
                loaded = repo.loaded
                handlesReady = true
            }
            .onReceive(repo.$refreshSeq.removeDuplicates()) { refreshSeq = $0 }
            .onReceive(repo.$loaded.removeDuplicates()) { loaded = $0 }
    }
}

/// Strap battery and a sync spinner beside the date stepper.
/// Observes only battery %, charging, connected and backfilling via `.onReceive` of those
/// publishers (removeDuplicates into `@State`), not the whole `LiveState` object.
/// The spinner appears only when an offload has run for three seconds; routine catch-ups stay silent.
struct HomeStrapStatus: View {
    @State private var connected = false
    @State private var batteryPct: Double?
    @State private var charging: Bool?
    @State private var backfilling = false
    @State private var showSync = false

    private var percent: Int? {
        guard connected else { return nil }
        return LiveConsoleReadout.batteryPercent(
            activeIsWhoop: true, whoopPct: batteryPct, ringPct: nil
        )
    }

    private func symbol(_ pct: Int) -> String {
        if charging == true { return "battery.100percent.bolt" }
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func batteryColor(percent: Int) -> Color {
        switch HomeBatteryTint.level(percent: percent, charging: charging == true) {
        case .low: return NativeTokens.recoveryLow
        case .mid: return NativeTokens.recoveryMid
        case .high, .charging: return NativeTokens.recoveryHigh
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if showSync {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Syncing")
            }
            if let percent {
                HStack(spacing: 3) {
                    Text("\(percent)%")
                        .font(.footnote.weight(.medium))
                        .monospacedDigit()
                    Image(systemName: symbol(percent))
                        .font(.footnote)
                }
                .foregroundStyle(batteryColor(percent: percent))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Strap battery \(percent) percent")
            }
        }
        .background { Sink(connected: $connected, batteryPct: $batteryPct,
                           charging: $charging, backfilling: $backfilling) }
        .task(id: backfilling) {
            guard backfilling else {
                showSync = false
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { showSync = true }
        }
    }

    /// Holds `@EnvironmentObject LiveState` so HomeStrapStatus itself does not. Forwards only
    /// the four strap-status publishers.
    private struct Sink: View {
        @EnvironmentObject private var live: LiveState
        @Binding var connected: Bool
        @Binding var batteryPct: Double?
        @Binding var charging: Bool?
        @Binding var backfilling: Bool

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .onReceive(live.$connected.removeDuplicates()) { connected = $0 }
                .onReceive(live.$batteryPct.removeDuplicates()) { batteryPct = $0 }
                .onReceive(live.$charging.removeDuplicates()) { charging = $0 }
                .onReceive(live.$backfilling.removeDuplicates()) { backfilling = $0 }
        }
    }
}

/// Manual activity entry from Home. Thin wrapper around NativeAddActivitySheet.
struct HomeAddActivitySheet: View {
    var onSaved: () async -> Void

    var body: some View {
        NativeAddActivitySheet(onSaved: onSaved)
    }
}

struct NativeNoDataCard: View {
    var onImport: () -> Void
    var onPair: () -> Void
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            VStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                Text("No data yet")
                    .font(style == .whoop ? NativeTokens.whoopNumber(22, weight: .bold) : .title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("Pair your strap or import a WHOOP export to see Recovery, Sleep and Strain.")
                    .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline)
                    .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    Button(action: onImport) {
                        Text("Import WHOOP Export")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button(action: onPair) {
                        Text("Pair Strap")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .accessibilityElement(children: .contain)
    }
}

struct HomeLoadingSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(spacing: 8) {
                        Circle()
                            .fill(NativeTokens.card)
                            .frame(width: 96, height: 96)
                        Text("Score")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
            skeletonCard
            skeletonCard
            skeletonCard
        }
        .redacted(reason: .placeholder)
        .nativeShimmer()
        .accessibilityLabel("Loading")
    }

    private var skeletonCard: some View {
        NativeChrome.panel {
            Text("Monitor")
                .font(.footnote.weight(.semibold))
            Text("88")
                .font(StrandFont.rounded(22, weight: .bold))
            Text("Typical")
                .font(.footnote)
        }
        .frame(minHeight: 140, alignment: .top)
    }
}

struct HomeTonightSleepCard: View {
    var model: NativeTonightSleep.Model
    var onAlarm: (() -> Void)? = nil
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: "Tonight's Sleep",
                symbol: "moon.fill",
                tint: NativePaint.sleep(style)
            )
            HStack(alignment: .top, spacing: 16) {
                if let bedtime = model.bedtimeClock {
                    clockBlock(caption: "Bedtime", value: bedtime)
                }
                if let wake = model.wakeClock {
                    clockBlock(caption: "Wake", value: wake)
                }
                if let need = model.needClock {
                    clockBlock(caption: "Need", value: need)
                }
                Spacer(minLength: 0)
            }
            if let onAlarm {
                Button(model.alarmLabel ?? "Set Alarm", action: onAlarm)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(NativePaint.sleep(style))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.top, 4)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.alarmLabel ?? "Set Alarm")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibility)
    }

    private func clockBlock(caption: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(style == .whoop ? caption.uppercased() : caption)
                .font(style == .whoop ? NativeTokens.whoopCaps(11) : .caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(style == .whoop ? NativeTokens.whoopNumber(22, weight: .bold) : StrandFont.rounded(22, weight: .bold))
                .monospacedDigit()
        }
    }

    private var accessibility: String {
        var parts = ["Tonight's Sleep"]
        if let bedtime = model.bedtimeClock { parts.append("Bedtime \(bedtime)") }
        if let wake = model.wakeClock { parts.append("Wake \(wake)") }
        if let need = model.needClock { parts.append("Sleep need \(need)") }
        return parts.joined(separator: ", ")
    }
}

struct HomeVO2Card: View {
    var value: Double
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            NativeContributorRow(
                symbol: "lungs.fill",
                title: "VO₂ Max",
                value: String(format: "%.1f", value),
                prior: "mL/kg·min",
                tint: NativePaint.respiratory(style)
            )
        }
        .accessibilityLabel("VO2 Max, \(String(format: "%.1f", value)) milliliters per kilogram minute")
    }
}

#if DEBUG
enum HomeSnapshot {
    struct Section: Identifiable {
        var id: String { name }
        var name: String
        var padded: Bool = true
        var view: AnyView
    }

    static let weekKeys = NativeGallerySnapshot.weekKeys
    static let highlightKey = NativeGallerySnapshot.highlightKey
    static let dayStart = Date(timeIntervalSince1970: 1_763_164_800)

    static var sleepScore: NativeScore { NativeGallerySnapshot.sleepScore }
    static var recoveryScore: NativeScore { NativeGallerySnapshot.recoveryScore }

    static var strainScore: NativeScore { NativeGallerySnapshot.snapshotModel.strain }

    static var activities: [HomeActivityItem] {
        HomeActivityItem.make(from: NativeGallerySnapshot.snapshotModel)
    }

    static var journalDots: [HomeJournalDot] {
        zip(weekKeys, [true, true, false, true, true, true, false]).map {
            HomeJournalDot(key: $0.0, filled: $0.1)
        }
    }

    static var stressHours: [NativeHourPoint] {
        stride(from: 0, through: 18 * 60, by: 12).map { minute in
            let t = Double(minute)
            let seed = Double((minute &* 1103515245 &+ 12345) & 0xffff) / 65535
            let diurnal = 0.7 + 0.28 * sin((t - 200) / 260)
            let noise = (seed - 0.5) * 0.22
            let bout = minute >= 500 && minute <= 620 ? 0.85 : 0
            return NativeHourPoint(
                time: dayStart.addingTimeInterval(t * 60),
                value: min(3, max(0.2, diurnal + noise + bout))
            )
        }
    }

    static var hrvMetric: HomeMetricItem {
        HomeMetricItem.make(
            dashboard: NativeGallerySnapshot.snapshotModel.dashboard,
            days: NativeGallerySnapshot.snapshotDays,
            todayKey: highlightKey
        ).first { $0.title == "Heart Rate Variability" } ?? HomeMetricItem(
            title: "Heart Rate Variability",
            value: "66",
            unit: "ms",
            prior: "60 ms",
            delta: .up,
            symbol: "waveform.path.ecg",
            tint: NativeChrome.heart,
            points: NativeGallerySnapshot.hrvLine,
            bars: false,
            route: .metric("hrv")
        )
    }

    static var stepsMetric: HomeMetricItem {
        HomeMetricItem.make(
            dashboard: NativeGallerySnapshot.snapshotModel.dashboard,
            days: NativeGallerySnapshot.snapshotDays,
            todayKey: highlightKey
        ).first { $0.title == "Steps" } ?? HomeMetricItem(
            title: "Steps",
            value: NativeDayLogic.countText(6545),
            unit: "steps",
            prior: nil,
            delta: .none,
            symbol: "figure.walk",
            tint: NativeChrome.activity,
            points: NativeWeek.series(NativeGallerySnapshot.snapshotDays, todayKey: highlightKey) {
                $0.steps.map(Double.init)
            },
            bars: true,
            route: .metric("steps")
        )
    }

    static var caloriesMetric: HomeMetricItem {
        HomeMetricItem.make(
            dashboard: NativeGallerySnapshot.snapshotModel.dashboard,
            days: NativeGallerySnapshot.snapshotDays,
            todayKey: highlightKey
        ).first { $0.title == "Calories" } ?? HomeMetricItem(
            title: "Calories",
            value: NativeDayLogic.countText(512),
            unit: "cal",
            prior: nil,
            delta: .none,
            symbol: "flame.fill",
            tint: NativeChrome.activity,
            points: NativeWeek.series(NativeGallerySnapshot.snapshotDays, todayKey: highlightKey) {
                $0.activeKcalEst
            },
            bars: true,
            route: .metric("energy_kcal")
        )
    }

    static var strainOnlyModel: NativeDay.Model {
        let day = DailyMetric(
            day: highlightKey,
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: 34,
            exerciseCount: 1
        )
        return NativeDay.make(
            days: [day], sleeps: [], workouts: [],
            todayKey: highlightKey, connected: false, effortScale: .whoop,
            now: NativeGallerySnapshot.sleepEnd
        )
    }

    static var strainOnlyPage: some View {
        NativeChrome.stack {
            HomeRingsRow(
                sleep: strainOnlyModel.sleep,
                recovery: strainOnlyModel.recovery,
                strain: strainOnlyModel.strain,
                onOpen: { _ in }
            )
            HStack(alignment: .top, spacing: HomeMonitorTileLayout.spacing) {
                HomeHealthMonitorTile(report: NativeHealthRange.Report(vitals: []))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                HomeStressMonitorTile(level: nil, updated: nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
            NativeChrome.section("My Day")
            HomeActivitiesCard(
                items: HomeActivityItem.make(from: strainOnlyModel),
                onSleep: {}, onActivity: { _ in }
            )
            HomeStressMonitorCard(
                level: nil,
                hours: [],
                sleepStart: nil,
                sleepEnd: nil,
                workouts: [],
                dayStart: dayStart,
                now: dayStart.addingTimeInterval(16 * 3600),
                scrubValue: .constant(0),
                scrubTime: .constant(nil),
                onOpen: {}
            )
        }
    }

    static var healthReport: NativeHealthRange.Report {
        NativeHealthRange.report(
            days: NativeGallerySnapshot.snapshotDays, todayKey: highlightKey
        )
    }

    static var tonightSleep: NativeTonightSleep.Model {
        NativeTonightSleep.make(needMin: 480, alarmEnabled: true, alarmMinutes: 7 * 60)
            ?? NativeTonightSleep.Model(
                bedtimeClock: "11:00 PM", wakeClock: "7:00 AM", needClock: "8:00",
                alarmArmed: true, alarmLabel: "Alarm 7:00 AM"
            )
    }

    static var healthCard: some View {
        HomeHealthMonitorCard(report: healthReport)
    }

    static var homeStressCard: some View {
        HomeStressMonitorCard(
            level: 1.2,
            hours: stressHours,
            sleepStart: dayStart.addingTimeInterval(37 * 60),
            sleepEnd: dayStart.addingTimeInterval(8 * 3600),
            workouts: [(start: dayStart.addingTimeInterval(8.45 * 3600), end: dayStart.addingTimeInterval(8.92 * 3600))],
            dayStart: dayStart,
            now: dayStart.addingTimeInterval(16 * 3600),
            scrubValue: .constant(1.2),
            scrubTime: .constant(nil),
            onOpen: {}
        )
    }

    static var homePage: some View {
        NativeChrome.stack {
            HomeRingsRow(
                sleep: sleepScore, recovery: recoveryScore, strain: strainScore, onOpen: { _ in }
            )
            HStack(alignment: .top, spacing: HomeMonitorTileLayout.spacing) {
                HomeHealthMonitorTile(report: healthReport)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                HomeStressMonitorTile(level: 1.2, updated: dayStart.addingTimeInterval(16 * 3600))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
            NativeChrome.section("My Day")
            HomeActivitiesCard(items: activities, onSleep: {}, onActivity: { _ in })
            HomeTonightSleepCard(model: tonightSleep, onAlarm: {})
            HomeJournalCard(dots: journalDots, hasEntry: true, onOpen: {}, onLog: {})
            HStack(alignment: .firstTextBaseline) {
                NativeChrome.section("My Dashboard")
                Spacer(minLength: 8)
                Button("Edit", action: {})
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.plain)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
            }
            HomeMetricCard(item: stepsMetric)
            HomeVO2Card(value: 48.2)
            HomeMetricCard(item: caloriesMetric)
            homeStressCard
            HomeWeekCard(
                recovery: NativeGallerySnapshot.recoveryBars,
                strain: NativeGallerySnapshot.strainBars,
                highlightKey: highlightKey
            )
        }
    }

    static var journalAnswers: [HomeJournalAnswer] {
        [
            HomeJournalAnswer(question: "Ate food close to bedtime?", value: "No"),
            HomeJournalAnswer(question: "Consumed caffeine?", value: "Yes"),
            HomeJournalAnswer(question: "Felt stressed?", value: "No"),
        ]
    }

    static var emptyPage: some View {
        NativeChrome.stack {
            NativeNoDataCard(onImport: {}, onPair: {})
        }
    }

    static var loadingPage: some View {
        NativeChrome.stack {
            HomeLoadingSkeleton()
        }
    }

    static var sections: [Section] {
        [
            Section(name: "page", padded: false, view: AnyView(homePage)),
            Section(name: "page-strain-only", padded: false, view: AnyView(strainOnlyPage)),
            Section(name: "empty", padded: false, view: AnyView(emptyPage)),
            Section(name: "loading", padded: false, view: AnyView(loadingPage)),
            Section(name: "rings", view: AnyView(HomeRingsRow(
                sleep: sleepScore, recovery: recoveryScore, strain: strainScore, onOpen: { _ in }
            ))),
            Section(name: "myday", view: AnyView(VStack(spacing: 10) {
                HomeActivitiesCard(items: activities, onSleep: {}, onActivity: { _ in })
                HomeTonightSleepCard(model: tonightSleep, onAlarm: {})
                HomeJournalCard(dots: journalDots, hasEntry: true, onOpen: {}, onLog: {})
            })),
            Section(name: "monitors", view: AnyView(VStack(spacing: 10) {
                HStack(alignment: .top, spacing: HomeMonitorTileLayout.spacing) {
                    HomeHealthMonitorTile(report: healthReport)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    HomeStressMonitorTile(level: 1.2, updated: dayStart.addingTimeInterval(16 * 3600))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .fixedSize(horizontal: false, vertical: true)
                homeStressCard
            })),
            Section(name: "activities", view: AnyView(HomeActivitiesCard(
                items: activities, onSleep: {}, onActivity: { _ in }
            ))),
            Section(name: "journal", view: AnyView(HomeJournalCard(dots: journalDots, hasEntry: true, onOpen: {}, onLog: {}))),
            Section(name: "week", view: AnyView(HomeWeekCard(
                recovery: NativeGallerySnapshot.recoveryBars,
                strain: NativeGallerySnapshot.strainBars,
                highlightKey: highlightKey
            ))),
            Section(name: "week-selected", view: AnyView(HomeWeekCard(
                recovery: NativeGallerySnapshot.recoveryBars,
                strain: NativeGallerySnapshot.strainBars,
                highlightKey: highlightKey,
                previewSelected: highlightKey
            ))),
            Section(name: "metrics", view: AnyView(VStack(spacing: 10) {
                HomeMetricCard(item: hrvMetric)
                HomeMetricCard(item: stepsMetric)
                HomeMetricCard(item: caloriesMetric)
            })),
            Section(name: "stress", view: AnyView(HomeStressBody(
                level: 1.2,
                date: "Thu, Nov 12",
                hours: stressHours,
                sleepStart: dayStart.addingTimeInterval(37 * 60),
                sleepEnd: dayStart.addingTimeInterval(8 * 3600),
                workouts: [(start: dayStart.addingTimeInterval(8.45 * 3600), end: dayStart.addingTimeInterval(8.92 * 3600))],
                dayStart: dayStart,
                now: dayStart.addingTimeInterval(16 * 3600),
                scrubValue: .constant(1.2),
                scrubTime: .constant(nil)
            ))),
            Section(name: "stress-empty", view: AnyView(HomeStressBody(
                level: nil,
                date: "Thu, Nov 12",
                hours: [],
                sleepStart: nil,
                sleepEnd: nil,
                workouts: [],
                dayStart: dayStart,
                now: dayStart.addingTimeInterval(16 * 3600),
                scrubValue: .constant(0),
                scrubTime: .constant(nil)
            ))),
            Section(name: "journal-list", view: AnyView(HomeJournalList(
                answers: journalAnswers,
                notes: "Late dinner after the run."
            ))),
            Section(name: "journal-empty", view: AnyView(HomeJournalList(answers: [], notes: nil))),
            Section(name: "health-monitor", padded: false, view: AnyView(
                NativeChrome.stack {
                    NativeHealthMonitorBody(
                        report: NativeHealthRange.report(
                            days: NativeGallerySnapshot.snapshotDays, todayKey: highlightKey
                        ),
                        selectedDay: NativeGallerySnapshot.sleepEnd,
                        firstDay: NativeGallerySnapshot.weekKeys.first,
                        onBack: {},
                        onForward: {},
                        onSelect: { _ in }
                    )
                }
            )),
            Section(name: "journal-log", padded: false, view: AnyView(
                NativeJournalLogForm(
                    items: journalLogItems,
                    answers: [
                        "Did you drink any alcohol?": false,
                        "Did you feel stressed?": true,
                    ],
                    numeric: ["Caffeine (mg)": 120],
                    onToggle: { _, _ in },
                    onNumeric: { _, _ in }
                )
            )),
        ]
    }

    static var journalLogItems: [JournalCatalogItem] {
        let starters = JournalCatalogStore.starterQuestions.prefix(6).enumerated().map { i, q in
            JournalCatalogItem(
                canonical: q, displayName: nil, kind: .bool,
                group: JournalCatalogStore.starterGroups[q] ?? .other,
                sortIndex: i, hidden: false, custom: false
            )
        }
        let caffeine = JournalCatalogItem(
            canonical: "Caffeine (mg)", displayName: nil,
            kind: .numeric(unitLabel: "mg"), group: .nutrition,
            sortIndex: 99, hidden: false, custom: true
        )
        return starters + [caffeine]
    }
}
#endif

import SwiftUI
import Combine
import StrandDesign
import StrandAnalytics
import WhoopStore

// Native Home: WHOOP order, Apple Health chrome.
// Sections take plain value models so snapshots can render without Repository.
//
// Home content order (WHOOP capture, top to bottom):
// date stepper + battery, rings, Health Monitor, My Day (Activities, Tonight's Sleep,
// Journal), My Dashboard rows, Stress Monitor, Strain & Recovery.

enum HomeSectionOrder {
    static let content = [
        "rings",
        "Health Monitor",
        "My Day",
        "Activities",
        "Tonight's Sleep",
        "Journal",
        "My Dashboard",
        "Stress Monitor",
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
    @State private var showingCalendar = false
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @State private var workouts: [WorkoutRow] = []
    @State private var journalEntries: [JournalEntry] = []
    @State private var sampleHours: [NativeHourPoint] = []
    @State private var vo2max: Double?
    @State private var liveTodayStrain: Double?
    @State private var dayModel: NativeDay.Model?
    @State private var healthSummary: NativeHealthRange.Summary?
    @State private var tonight: NativeTonightSleep.Model?
    @State private var stressLevel: Double?
    @State private var stressSleepStart: Date?
    @State private var stressSleepEnd: Date?
    @State private var stressBouts: [(start: Date, end: Date)] = []
    @State private var stressScrubValue: Double = 0
    @State private var stressScrubTime: Date?
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
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""
    @AppStorage("behavior.smartAlarmEnabled") private var smartAlarmEnabled = false
    @AppStorage("behavior.smartAlarmMinutes") private var smartAlarmMinutes = 7 * 60
    @AppStorage(HomeDashboardStore.key) private var dashboardJSON = ""

    private var selectedDay: Date {
        get { NativeDaySelection.date(from: selectedDayKey) }
        nonmutating set { selectedDayKey = NativeDaySelection.key(from: newValue) }
    }

    private var selectedKey: String { NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }

    var body: some View {
        ScrollView {
            NativeChrome.stack {
                #if os(iOS)
                HomeDateStepper(
                    title: HomeDayTitle.text(for: selectedDay),
                    canGoBack: canGoBack,
                    canGoForward: canGoForward,
                    onBack: { shiftDay(-1) },
                    onForward: { shiftDay(1) },
                    onTitleTap: { showingCalendar = true }
                )
                .frame(maxWidth: .infinity)
                .sheet(isPresented: $showingCalendar) {
                    HomeCalendarSheet(selected: selectedDay, range: calendarRange) { picked in
                        selectedDay = Calendar.current.startOfDay(for: picked)
                    }
                }
                .overlay(alignment: .trailing) { HomeStrapStatus() }
                #endif
                if !loaded {
                    HomeLoadingSkeleton()
                } else if storeEmpty {
                    NativeNoDataCard(
                        onImport: { path.wrappedValue.append(TabRoute.dataSources) },
                        onPair: { path.wrappedValue.append(NativePairRoute()) }
                    )
                } else if let model = dayModel {
                    homeContent(model)
                } else {
                    HomeLoadingSkeleton()
                }
            }
            .padding(.bottom, 136)
        }
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
        .onChange(of: effortScaleRaw) { _ in rebuildModel() }
        .onChange(of: smartAlarmEnabled) { _ in rebuildModel() }
        .onChange(of: smartAlarmMinutes) { _ in rebuildModel() }
        .onChange(of: dashboardJSON) { _ in rebuildModel() }
        .navigationDestination(for: NativePairRoute.self) { _ in
            DevicesView()
        }
        .navigationDestination(for: NativeAlarmRoute.self) { _ in
            SmartAlarmView()
        }
        .sheet(isPresented: $addingActivity) {
            HomeAddActivitySheet { await reload() }
        }
        .sheet(isPresented: $editingDashboard) {
            HomeDashboardEditor(selectedIds: HomeDashboardStore.decode(dashboardJSON)) { ids in
                let encoded = HomeDashboardStore.encode(ids)
                HomeDashboardStore.save(ids)
                dashboardJSON = encoded
            }
        }
        .toolbar {
            if sleepStreak >= 2 {
                ToolbarItem(placement: streakPlacement) {
                    HomeStreakBadge(count: sleepStreak)
                }
            }
            #if os(macOS)
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

    private var streakPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .navigationBarLeading
        #else
        .navigation
        #endif
    }

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
        workouts = await repo.workoutRows(days: 120)
        journalEntries = await repo.journalEntries(days: 40)
        let start = Calendar.current.startOfDay(for: selectedDay)
        let from = Int(start.timeIntervalSince1970)
        let buckets = await repo.hrSamples(from: from, to: from + 86_400, bucketSeconds: 300)
        sampleHours = NativeHomeCharts.stressSeries(buckets: buckets)
        let vo2 = await repo.exploreSeries(key: "vo2max_est", source: "my-whoop")
        vo2max = vo2.last?.value
        await refreshLiveStrain(from: from, buckets: buckets)
        rebuildModel()
    }

    /// Rings, dashboard, tonight, week — once per data change, not per `body` pass.
    private func rebuildModel() {
        guard let repo = repoHandle else { return }
        firstDay = repo.days.first?.day
        storeEmpty = NativeDayLogic.isEmptyStore(
            days: repo.days, sleeps: repo.sleeps, importedSleep: repo.importedSleep
        )
        let scale = UnitPrefs.resolveEffortScale(effortScaleRaw)
        let model = NativeDay.make(
            days: repo.days,
            sleeps: repo.sleeps,
            workouts: workouts,
            todayKey: selectedKey,
            connected: false,
            effortScale: scale,
            journalEntries: journalEntries,
            importedSleep: repo.importedSleep,
            liveStrain: liveTodayStrain
        )
        dayModel = model
        healthSummary = NativeHealthRange.summary(days: repo.days, todayKey: selectedKey)
        if selectedKey == NativeDayLogic.logicalToday() {
            tonight = NativeTonightSleep.make(
                needMin: model.sleepNeedMin,
                alarmEnabled: smartAlarmEnabled,
                alarmMinutes: smartAlarmMinutes
            )
        } else {
            tonight = nil
        }
        stressLevel = NativeStressResolver.level(hours: sampleHours, days: repo.days, todayKey: selectedKey)
        if let latest = stressLevel {
            stressScrubValue = latest
        }
        stressScrubTime = nil
        let sleep = repo.sleeps.last {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == selectedKey
        }
        stressSleepStart = sleep.map { Date(timeIntervalSince1970: TimeInterval($0.effectiveStartTs)) }
        stressSleepEnd = sleep.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) }
        stressBouts = workouts.compactMap { row in
            let boutStart = Date(timeIntervalSince1970: TimeInterval(row.startTs))
            guard NativeDayLogic.sleepSessionDayKey(boutStart) == selectedKey else { return nil }
            return (boutStart, Date(timeIntervalSince1970: TimeInterval(row.endTs)))
        }
        weekRecovery = NativeWeek.points(
            kind: .recovery, days: repo.days, todayKey: selectedKey,
            sleeps: repo.sleeps, workouts: workouts, importedSleep: repo.importedSleep
        )
        weekStrain = NativeWeek.points(
            kind: .strain, days: repo.days, todayKey: selectedKey,
            effortScale: scale,
            sleeps: repo.sleeps, workouts: workouts, importedSleep: repo.importedSleep
        )
        sleepStreak = HomeSleepStreak.days(
            sleeps: repo.sleeps,
            imported: repo.importedSleep,
            todayKey: NativeDayLogic.logicalToday()
        )
        dashboardItems = HomeMetricItem.make(
            dashboard: model.dashboard,
            days: repo.days,
            todayKey: selectedKey,
            vo2max: vo2max,
            model: model,
            stress: stressLevel,
            ids: HomeDashboardStore.decode(dashboardJSON)
        )
    }

    /// Live day strain via `BandStrain` on today's HR, then `NativeStrain.day` with the stored row.
    /// Uses the 300 s buckets already read for the stress chart (within 0.05 of per-sample on the
    /// golden vectors). Recomputes only when `refreshSeq` or the selected day changed.
    private func refreshLiveStrain(from: Int, buckets: [HRBucket]) async {
        guard let repo = repoHandle, let profile = profileHandle else { return }
        let seq = repo.refreshSeq
        let day = selectedKey
        if let cached = NativeLiveStrainMemo.read(seq: seq, day: day) {
            liveTodayStrain = cached
            return
        }
        guard day == NativeDayLogic.logicalToday() else {
            liveTodayStrain = nil
            NativeLiveStrainMemo.store(seq: seq, day: day, value: nil)
            return
        }
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
        liveTodayStrain = scored
        NativeLiveStrainMemo.store(seq: seq, day: day, value: scored)
    }

    @ViewBuilder private func homeContent(_ model: NativeDay.Model) -> some View {
        HomeRingsRow(
            sleep: model.sleep,
            recovery: model.recovery,
            strain: model.strain,
            onOpen: { path.wrappedValue.append($0) },
            dayKey: selectedKey
        )
        Button {
            path.wrappedValue.append(TabRoute.healthMonitor)
        } label: {
            HomeHealthMonitorCard(
                hrv: HomeMonitorValue.from(model.dashboard, title: "Heart Rate Variability", unit: "ms"),
                rhr: HomeMonitorValue.from(model.dashboard, title: "Resting Heart Rate", unit: "BPM"),
                resp: HomeMonitorValue.from(model.dashboard, title: "Respiratory Rate", unit: "breaths/min"),
                rangeCaption: healthSummary?.headerTrailing
            )
        }
        .buttonStyle(.plain)
        NativeChrome.section("My Day")
        HomeActivitiesCard(
            items: HomeActivityItem.make(from: model),
            onSleep: { path.wrappedValue.append(TabRoute.sleep) },
            onActivity: { path.wrappedValue.append(NativeActivityRoute(startTs: $0)) },
            onAdd: { addingActivity = true }
        )
        if let tonight {
            HomeTonightSleepCard(
                model: tonight,
                onAlarm: { path.wrappedValue.append(NativeAlarmRoute()) }
            )
        }
        HomeJournalCard(
            dots: NativeHomeCharts.journalDots(filled: model.journalDays, todayKey: selectedKey),
            hasEntry: model.journalDays.last == true,
            onOpen: { path.wrappedValue.append(TabRoute.journal) },
            onLog: { path.wrappedValue.append(TabRoute.journalLog) }
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
                path.wrappedValue.append(item.route)
            } label: {
                HomeMetricCard(item: item)
            }
            .buttonStyle(.plain)
        }
        HomeStressMonitorCard(
            level: stressLevel,
            hours: sampleHours,
            sleepStart: stressSleepStart,
            sleepEnd: stressSleepEnd,
            workouts: stressBouts,
            dayStart: Calendar.current.startOfDay(for: selectedDay),
            now: min(
                Date(),
                Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: selectedDay)) ?? Date()
            ),
            scrubValue: $stressScrubValue,
            scrubTime: $stressScrubTime,
            onOpen: { path.wrappedValue.append(TabRoute.stress) }
        )
        HomeWeekCard(
            recovery: weekRecovery,
            strain: weekStrain,
            highlightKey: selectedKey
        )
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

struct HomeDateStepper: View {
    var title: String
    var canGoBack: Bool
    var canGoForward: Bool
    var onBack: () -> Void
    var onForward: () -> Void
    var onTitleTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(!canGoBack)
            .opacity(canGoBack ? 1 : 0.35)

            Button { onTitleTap?() } label: {
                Text(title)
                    .font(.headline)
                    .monospacedDigit()
                    .frame(minWidth: 120, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .disabled(onTitleTap == nil)

            Button(action: onForward) {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(!canGoForward)
            .opacity(canGoForward ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .homeStepperGlass()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint("Steps through days")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onForward()
            case .decrement: onBack()
            @unknown default: break
            }
        }
    }
}

/// Calendar for jumping straight to a day. Picking a date selects it and closes the sheet.
struct HomeCalendarSheet: View {
    var range: ClosedRange<Date>
    var onPick: (Date) -> Void
    @State private var date: Date
    @Environment(\.dismiss) private var dismiss

    init(selected: Date, range: ClosedRange<Date>, onPick: @escaping (Date) -> Void) {
        self.range = range
        self.onPick = onPick
        _date = State(initialValue: min(max(selected, range.lowerBound), range.upperBound))
    }

    var body: some View {
        NavigationStack {
            DatePicker("Day", selection: $date, in: range, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Today") { onPick(range.upperBound); dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .onChangeCompat(of: date) { picked in
                    onPick(picked)
                    dismiss()
                }
        }
        .presentationDetents([.medium, .large])
    }
}

private extension View {
    /// Trial: the day stepper as one Liquid Glass capsule on iOS 26. Older systems and macOS
    /// keep the bare stepper.
    @ViewBuilder func homeStepperGlass() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Rings

struct HomeRingsRow: View {
    var sleep: NativeScore
    var recovery: NativeScore
    var strain: NativeScore
    var onOpen: (TabRoute) -> Void
    var dayKey: String = ""
    @Environment(\.nativeStyle) private var style

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ring(sleep, tint: NativePaint.sleep(style))
            ring(recovery, tint: recoveryTint)
            ring(strain, tint: NativePaint.strain(style))
        }
        .padding(.top, 8)
        .id(dayKey)
    }

    private var recoveryTint: Color {
        if let percent = NativeScoreMath.percentValue(recovery.value) {
            return NativePaint.recoveryBand(percent, style: style)
        }
        return NativePaint.recovery(style)
    }

    private func ring(_ score: NativeScore, tint: Color) -> some View {
        Button {
            onOpen(score.route)
        } label: {
            NativeRing(
                fraction: score.fraction,
                tint: tint,
                value: score.value,
                caption: score.name,
                diameter: 96
            )
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(score.name)")
    }
}

// MARK: - Health + Stress monitors

struct HomeMonitorValue {
    var value: String
    var unit: String
    var typical: String?

    static func from(_ rows: [NativeScore.Row], title: String, unit: String) -> HomeMonitorValue? {
        guard let row = rows.first(where: { $0.title == title }), NativeScoreMath.hasValue(row.value) else {
            return nil
        }
        let typical = NativeScoreMath.hasValue(row.prior) ? row.prior : nil
        return HomeMonitorValue(value: row.value, unit: unit, typical: typical)
    }
}

struct HomeHealthMonitorCard: View {
    var hrv: HomeMonitorValue?
    var rhr: HomeMonitorValue?
    var resp: HomeMonitorValue? = nil
    var rangeCaption: String? = nil
    @Environment(\.nativeStyle) private var style

    private var rows: [(id: String, symbol: String, title: String, value: HomeMonitorValue)] {
        var result: [(id: String, symbol: String, title: String, value: HomeMonitorValue)] = []
        if let hrv { result.append(("hrv", "waveform.path.ecg", "HRV", hrv)) }
        if let rhr { result.append(("rhr", "heart.fill", "RHR", rhr)) }
        if let resp { result.append(("resp", "lungs.fill", "RR", resp)) }
        return result
    }

    var body: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: "Health Monitor",
                symbol: "heart.fill",
                tint: NativePaint.heart(style),
                trailing: rangeCaption,
                chevron: true
            )
            if rows.isEmpty {
                NativeEmptyState(text: "No Data", symbol: "heart")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, 32)
                        }
                        NativeContributorRow(
                            symbol: row.symbol,
                            title: row.title,
                            value: compact(row.value),
                            prior: row.value.typical.map { compactValue($0, unit: row.value.unit) },
                            tint: row.id == "resp" ? NativePaint.respiratory(style) : NativePaint.heart(style)
                        )
                    }
                }
            }
        }
    }

    private func labeled(_ value: String, _ unit: String) -> String {
        if unit.isEmpty || value.localizedCaseInsensitiveContains(unit) { return value }
        return "\(value) \(unit)"
    }

    private func compact(_ item: HomeMonitorValue) -> String {
        if item.unit == "breaths/min" {
            return compactValue(item.value, unit: item.unit)
        }
        return labeled(item.value, item.unit)
    }

    private func compactValue(_ value: String, unit: String) -> String {
        var text = value
        for token in ["breaths/min", "BPM", "ms", unit] where !token.isEmpty {
            text = text.replacingOccurrences(of: "\u{00A0}\(token)", with: "")
            text = text.replacingOccurrences(of: " \(token)", with: "")
        }
        return text.trimmingCharacters(in: .whitespaces)
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
                level: shownLevel,
                hours: hours,
                sleepStart: sleepStart,
                sleepEnd: sleepEnd,
                workouts: workouts,
                dayStart: dayStart,
                now: now,
                height: NativeStressDayChart.heightHome,
                scrubValue: $scrubValue,
                scrubTime: $scrubTime
            )
        }
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
                    NativeValueText(value: "No Data", size: 28)
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
        return "No Data"
    }
}

// MARK: - My Day

struct HomeActivityItem: Identifiable {
    enum Kind { case sleep, strain }
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
        for activity in model.activities {
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
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NativeChrome.strain)
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
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
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
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct HomeActivityRow: View {
    var item: HomeActivityItem
    @Environment(\.nativeStyle) private var style

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

            Text(item.title.uppercased())
                .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline.weight(.semibold))
                .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

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
                        .buttonStyle(.plain)
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
                NativeEmptyState(text: "No Data")
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

struct HomeMetricItem: Identifiable {
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
            guard NativeScoreMath.hasValue(value) else { return }
            filled[metric.rawValue] = HomeMetricItem(
                title: metric.title,
                value: value,
                unit: unit ?? metric.unit,
                prior: prior.flatMap { NativeScoreMath.hasValue($0) ? $0 : nil },
                delta: delta,
                symbol: metric.symbol,
                tint: metric.tint,
                points: [],
                bars: false,
                route: metric.route
            )
        }
        func fromDashboard(_ metric: HomeDashboardMetric, title: String, unit: String?) {
            guard let row = dashboard.first(where: { $0.title == title }),
                  NativeScoreMath.hasValue(row.value) else { return }
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
        return filled
    }
}

struct HomeMetricCard: View {
    var item: HomeMetricItem
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.body)
                    .foregroundStyle(item.tint)
                    .frame(width: HomeActivityLayout.dashboardIconWidth, alignment: .center)
                Text(style == .whoop ? item.title.uppercased() : item.title)
                    .font(style == .whoop ? NativeTokens.whoopCaps(13) : .body)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
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

    /// Maps HR samples onto the 0–3 series. Empty input → empty series. Never invents a curve.
    static func stressSeries(samples: [(ts: Int, bpm: Int)], stride: Int = 3) -> [NativeHourPoint] {
        samples.enumerated().compactMap { index, sample in
            guard stride <= 1 || index % stride == 0 else { return nil }
            return NativeHourPoint(
                time: Date(timeIntervalSince1970: TimeInterval(sample.ts)),
                value: stressValue(bpm: Double(sample.bpm))
            )
        }
    }

    /// Chart-width buckets (300 s day sparkline / day chart). Stress level is the last bucket, matching the drawn series.
    static func stressSeries(buckets: [HRBucket]) -> [NativeHourPoint] {
        buckets.map { bucket in
            NativeHourPoint(
                time: Date(timeIntervalSince1970: TimeInterval(bucket.ts)),
                value: stressValue(bpm: bucket.bpm)
            )
        }
    }

    static func stressValue(bpm: Double) -> Double {
        min(3, max(0, (bpm - 48) / 38))
    }

    /// Last sample if the series exists, else the daily HRV/RHR score, else nil. Never 1.0 or 0 as a stand-in.
    static func stressLevel(hours: [NativeHourPoint], days: [DailyMetric], todayKey: String) -> Double? {
        hours.last?.value ?? stress(days, todayKey: todayKey).last?.value
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
/// publishers (removeDuplicates into `@State`), not the whole `LiveState` object, so live
/// heart-rate ticks do not redraw Home. The spinner appears only when an offload has run
/// for three seconds; routine catch-ups stay silent.
struct HomeStrapStatus: View {
    @State private var connected = false
    @State private var batteryPct: Double?
    @State private var charging: Bool?
    @State private var backfilling = false
    @State private var showSync = false
    @State private var liveFeedActive = false
    @State private var liveBpm: Int?
    @State private var showingLiveHR = false

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

    var body: some View {
        HStack(spacing: 6) {
            if showSync {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Syncing")
            }
            Button { showingLiveHR = true } label: {
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill")
                        .font(.footnote)
                    if liveFeedActive, let liveBpm {
                        Text("\(liveBpm)")
                            .font(.footnote.weight(.medium))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                liveFeedActive && liveBpm != nil
                    ? "Live heart rate \(liveBpm ?? 0) BPM"
                    : "Live heart rate"
            )
            if let percent {
                HStack(spacing: 3) {
                    Text("\(percent)%")
                        .font(.footnote.weight(.medium))
                        .monospacedDigit()
                    Image(systemName: symbol(percent))
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Strap battery \(percent) percent")
            }
        }
        .sheet(isPresented: $showingLiveHR) {
            NativeLiveHeartRate()
        }
        .background { Sink(connected: $connected, batteryPct: $batteryPct,
                           charging: $charging, backfilling: $backfilling,
                           liveFeedActive: $liveFeedActive, liveBpm: $liveBpm) }
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
        @Binding var liveFeedActive: Bool
        @Binding var liveBpm: Int?

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .onReceive(live.$connected.removeDuplicates()) { connected = $0 }
                .onReceive(live.$batteryPct.removeDuplicates()) { batteryPct = $0 }
                .onReceive(live.$charging.removeDuplicates()) { charging = $0 }
                .onReceive(live.$backfilling.removeDuplicates()) { backfilling = $0 }
                .onReceive(live.$liveFeedActive.removeDuplicates()) { liveFeedActive = $0 }
                .onReceive(
                    live.$heartRate.throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
                ) { liveBpm = $0 }
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
                Text("No Data Yet")
                    .font(style == .whoop ? NativeTokens.whoopNumber(22, weight: .bold) : .title2.bold())
                    .multilineTextAlignment(.center)
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
        .accessibilityLabel("No Data Yet")
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
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
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
            HomeHealthMonitorCard(hrv: nil, rhr: nil, resp: nil)
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

    static var healthRange: String? {
        NativeHealthRange.summary(
            days: NativeGallerySnapshot.snapshotDays, todayKey: highlightKey
        ).headerTrailing
    }

    static var tonightSleep: NativeTonightSleep.Model {
        NativeTonightSleep.make(needMin: 480, alarmEnabled: true, alarmMinutes: 7 * 60)
            ?? NativeTonightSleep.Model(
                bedtimeClock: "11:00 PM", wakeClock: "7:00 AM", needClock: "8:00",
                alarmArmed: true, alarmLabel: "Alarm 7:00 AM"
            )
    }

    static var healthCard: some View {
        HomeHealthMonitorCard(
            hrv: HomeMonitorValue.from(NativeGallerySnapshot.snapshotModel.dashboard, title: "Heart Rate Variability", unit: "ms"),
            rhr: HomeMonitorValue.from(NativeGallerySnapshot.snapshotModel.dashboard, title: "Resting Heart Rate", unit: "BPM"),
            resp: HomeMonitorValue.from(NativeGallerySnapshot.snapshotModel.dashboard, title: "Respiratory Rate", unit: "breaths/min"),
            rangeCaption: healthRange
        )
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
            healthCard
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
                healthCard
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

import SwiftUI
import StrandDesign
import WhoopStore

// Native add-activity flow: WHOOP's two actions (Start Activity / Add Past Activity),
// drawn with Apple List / Form / DatePicker. Sport names come only from WorkoutCatalog.

enum NativeAddActivityLogic {
    static let recentLimit = 5

    /// Catalogue keyed by `WorkoutSource.sportKey`, first match wins (same as `all.first(where:)`).
    static let sportsByKey: [String: WorkoutCatalog.Sport] = {
        var map: [String: WorkoutCatalog.Sport] = [:]
        map.reserveCapacity(WorkoutCatalog.all.count)
        for sport in WorkoutCatalog.all {
            let key = WorkoutSource.sportKey(sport.name)
            if map[key] == nil { map[key] = sport }
        }
        return map
    }()

    /// Most-used catalogue sports from stored workouts, top `limit`, count then recency.
    static func recentSports(from workouts: [WorkoutRow], limit: Int = recentLimit) -> [WorkoutCatalog.Sport] {
        var counts: [String: (count: Int, lastStart: Int)] = [:]
        for row in workouts {
            guard let sport = sportsByKey[WorkoutSource.sportKey(row.sport)] else {
                continue
            }
            let current = counts[sport.name] ?? (0, 0)
            counts[sport.name] = (current.count + 1, max(current.lastStart, row.startTs))
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                if lhs.value.lastStart != rhs.value.lastStart { return lhs.value.lastStart > rhs.value.lastStart }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .prefix(limit)
            .compactMap { WorkoutCatalog.sport(named: $0.key) }
    }

    /// Catalogue in A–Z order, optionally filtered by a case-insensitive name query.
    static func filteredSports(query: String, in sports: [WorkoutCatalog.Sport] = WorkoutCatalog.all) -> [WorkoutCatalog.Sport] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [WorkoutCatalog.Sport]
        if trimmed.isEmpty {
            base = sports
        } else {
            base = sports.filter { $0.name.range(of: trimmed, options: .caseInsensitive) != nil }
        }
        return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func isSelected(_ sport: WorkoutCatalog.Sport, selected: String?) -> Bool {
        guard let selected, !selected.isEmpty else { return false }
        return WorkoutSource.sportKey(sport.name) == WorkoutSource.sportKey(selected)
    }

    static func durationLabel(from start: Date, to end: Date) -> String {
        let total = max(0, Int(end.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }
}

enum NativeAddActivityRoute: Hashable {
    case startPicker
    case pastForm
}

/// Home + sheet: Start Activity, Add Past Activity, and a resume row when one is running.
struct NativeAddActivitySheet: View {
    var onSaved: () async -> Void

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nativeNavigationPath) private var homePath

    @State private var path = NavigationPath()
    @State private var workouts: [WorkoutRow] = []
    @State private var liveSession: NativeActiveWorkoutState?
    @State private var showingLive = false

    var body: some View {
        NavigationStack(path: $path) {
            menu
                .navigationTitle("Add Activity")
                .modifier(NativeInlineTitle())
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .navigationDestination(for: NativeAddActivityRoute.self) { route in
                    switch route {
                    case .startPicker:
                        NativeSportPicker(
                            workouts: workouts,
                            selected: nil,
                            title: "Start Activity"
                        ) { sport in
                            startLive(sport.name)
                        }
                    case .pastForm:
                        NativeAddPastActivityForm(
                            editing: nil,
                            workouts: workouts,
                            embedded: true,
                            onSave: { row, replacing in
                                Task { await persist(row, replacing: replacing) }
                            }
                        )
                    }
                }
        }
        .nativeStyleBridge()
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
        .task {
            workouts = await repo.workoutRows(days: 120)
            if liveSession == nil {
                liveSession = NativeActiveWorkoutState.load()
            }
        }
        .modifier(NativeLiveWorkoutPresentation(
            session: liveSession,
            isPresented: $showingLive,
            onEnd: { elapsed in
                Task { await endLive(elapsed: elapsed) }
            },
            onDismiss: {
                showingLive = false
            }
        ))
    }

    private var menu: some View {
        List {
            if let live = liveSession {
                Section {
                    Button {
                        showingLive = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "timer")
                                .foregroundStyle(NativeChrome.strain)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Activity in progress")
                                Text(live.sport)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityLabel("Activity in progress, \(live.sport)")
                }
            }
            Section {
                Button {
                    path.append(NativeAddActivityRoute.startPicker)
                } label: {
                    Label("Start Activity", systemImage: "play.circle.fill")
                }
                Button {
                    path.append(NativeAddActivityRoute.pastForm)
                } label: {
                    Label("Add Past Activity", systemImage: "clock")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(NativePageFill())
        #endif
    }

    private func startLive(_ sport: String) {
        let state = NativeActiveWorkoutState(
            sport: sport,
            startTs: Int(Date().timeIntervalSince1970)
        )
        NativeActiveWorkoutState.persist(state)
        liveSession = state
        showingLive = true
    }

    @MainActor
    private func endLive(elapsed: TimeInterval) async {
        let session = liveSession
        showingLive = false
        liveSession = nil
        NativeActiveWorkoutState.clear()
        guard let session else {
            dismiss()
            return
        }
        if NativeActiveWorkoutState.shouldDiscard(elapsed: elapsed) {
            dismiss()
            return
        }
        let start = session.startedAt
        let end = start.addingTimeInterval(elapsed)
        guard let row = WorkoutSource.buildManualRowFromSpan(
            start: start, end: end, sport: session.sport, avgHr: nil, energyKcal: nil
        ) else {
            dismiss()
            return
        }
        await persist(row, replacing: nil)
    }

    @MainActor
    private func persist(_ row: WorkoutRow, replacing: WorkoutRow?) async {
        await repo.saveManualWorkout(row, replacing: replacing)
        await intelligence.analyzeRecent()
        await onSaved()
        dismiss()
        homePath.wrappedValue.append(NativeActivityRoute(startTs: row.startTs))
    }
}

struct NativeSportPicker: View {
    var workouts: [WorkoutRow]
    var selected: String?
    var title: String = "Sport"
    var popsOnSelect: Bool = false
    var onSelect: (WorkoutCatalog.Sport) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var recents: [WorkoutCatalog.Sport]

    init(
        workouts: [WorkoutRow],
        selected: String?,
        title: String = "Sport",
        popsOnSelect: Bool = false,
        onSelect: @escaping (WorkoutCatalog.Sport) -> Void
    ) {
        self.workouts = workouts
        self.selected = selected
        self.title = title
        self.popsOnSelect = popsOnSelect
        self.onSelect = onSelect
        _recents = State(initialValue: NativeAddActivityLogic.recentSports(from: workouts))
    }

    private var allSports: [WorkoutCatalog.Sport] {
        NativeAddActivityLogic.filteredSports(query: query)
    }

    private var showRecent: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recents.isEmpty
    }

    var body: some View {
        List {
            if showRecent {
                Section("Recent") {
                    ForEach(recents) { sport in
                        sportRow(sport)
                    }
                }
            }
            Section {
                ForEach(allSports) { sport in
                    sportRow(sport)
                }
            }
        }
        .searchable(text: $query, prompt: "Search")
        .navigationTitle(title)
        .modifier(NativeInlineTitle())
        .onChangeCompat(of: workouts) { rows in
            recents = NativeAddActivityLogic.recentSports(from: rows)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(NativePageFill())
        #endif
    }

    private func sportRow(_ sport: WorkoutCatalog.Sport) -> some View {
        Button {
            onSelect(sport)
            if popsOnSelect { dismiss() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: sportSymbol(sport.name))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(NativeChrome.strain)
                    .frame(width: 28)
                Text(sport.name)
                    .foregroundStyle(.primary)
                Spacer()
                if NativeAddActivityLogic.isSelected(sport, selected: selected) {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sport.name)
        .accessibilityAddTraits(NativeAddActivityLogic.isSelected(sport, selected: selected) ? .isSelected : [])
    }
}

struct NativeAddPastActivityForm: View {
    var editing: WorkoutRow? = nil
    var workouts: [WorkoutRow] = []
    var onSave: (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void
    var embedded: Bool = false

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repo: Repository
    @State private var sport: String
    @State private var start: Date
    @State private var end: Date
    @State private var hrSamples: [NativeAddActivityChartLogic.Sample] = []
    @State private var storedWorkouts: [WorkoutRow]
    @State private var hrLoadedDay: Int?

    init(
        editing: WorkoutRow? = nil,
        workouts: [WorkoutRow] = [],
        embedded: Bool = false,
        onSave: @escaping (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void
    ) {
        self.editing = editing
        self.workouts = workouts
        self.embedded = embedded
        self.onSave = onSave
        let defaultEnd = Date()
        _start = State(initialValue: editing.map { Date(timeIntervalSince1970: TimeInterval($0.startTs)) }
                       ?? defaultEnd.addingTimeInterval(-45 * 60))
        _end = State(initialValue: editing.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) }
                     ?? defaultEnd)
        _sport = State(initialValue: editing.map { WorkoutSource.editableSport($0.sport) } ?? "")
        _storedWorkouts = State(initialValue: workouts)
    }

    var body: some View {
        Group {
            if embedded {
                form
            } else {
                NavigationStack { form }
            }
        }
        .nativeStyleBridge()
    }

    private var form: some View {
        Form {
            Section {
                NavigationLink {
                    NativeSportPicker(
                        workouts: workouts,
                        selected: sport,
                        title: "Sport",
                        popsOnSelect: true
                    ) { picked in
                        sport = picked.name
                    }
                } label: {
                    HStack {
                        Text("Sport")
                        Spacer()
                        if sport.isEmpty {
                            Text("Select")
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: sportSymbol(sport))
                                    .foregroundStyle(NativeChrome.strain)
                                Text(sport)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                heartRateSection
            }
            Section {
                DatePicker("Start", selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                DatePicker("End", selection: $end, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                HStack {
                    Text("Duration")
                    Spacer()
                    Text(NativeAddActivityLogic.durationLabel(from: start, to: end))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .navigationTitle(editing == nil ? "Add Past Activity" : "Edit Activity")
        .modifier(NativeInlineTitle())
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(builtRow == nil)
            }
        }
        .task(id: dayKey) {
            await loadHeartRate(for: dayKey)
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(NativePageFill())
        #endif
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    @ViewBuilder private var heartRateSection: some View {
        if hrLoadedDay != dayKey {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else if hrSamples.isEmpty {
            Text(NativeAddActivityChartLogic.emptyDayMessage)
                .foregroundStyle(.secondary)
        } else {
            NativeAddActivityDayChart(
                samples: hrSamples,
                windowStart: start,
                windowEnd: end,
                dayStart: dayStart,
                dayEnd: dayEnd,
                otherWorkouts: otherWorkouts,
                onMoveStart: moveWindow(to:)
            )
        }
    }

    private var dayStart: Date {
        NativeAddActivityChartLogic.dayBounds(for: start).start
    }

    private var dayEnd: Date {
        NativeAddActivityChartLogic.dayBounds(for: start).end
    }

    private var dayKey: Int {
        Int(dayStart.timeIntervalSince1970)
    }

    private var otherWorkouts: [NativeAddActivityChartLogic.WorkoutBand] {
        NativeAddActivityChartLogic.overlappingWorkouts(
            workouts: storedWorkouts,
            dayStart: dayKey,
            dayEnd: Int(dayEnd.timeIntervalSince1970),
            excludingStartTs: editing?.startTs
        )
    }

    @MainActor
    private func loadHeartRate(for key: Int) async {
        let from = key
        let to = Int(NativeAddActivityChartLogic.dayBounds(
            for: Date(timeIntervalSince1970: TimeInterval(key))
        ).end.timeIntervalSince1970)
        let buckets = await repo.hrSamples(
            from: from, to: to,
            bucketSeconds: NativeAddActivityChartLogic.bucketSeconds
        )
        let rows = await repo.workoutRows(days: 120)
        guard !Task.isCancelled else { return }
        hrSamples = buckets.map(NativeAddActivityChartLogic.Sample.init)
        storedWorkouts = rows
        hrLoadedDay = key
    }

    private func moveWindow(to proposed: Date) {
        let duration = max(end.timeIntervalSince(start), 60)
        let clamped = NativeAddActivityChartLogic.clampedWindow(
            start: proposed,
            duration: duration,
            dayStart: dayStart,
            now: Date()
        )
        start = clamped.start
        end = clamped.end
    }

    private var builtRow: WorkoutRow? {
        guard let base = WorkoutSource.buildManualRowFromSpan(
            start: start, end: end, sport: sport, avgHr: nil, energyKcal: nil
        ) else { return nil }
        return WorkoutSource.preservingCaptured(base, from: editing)
    }

    private func save() {
        guard let row = builtRow else { return }
        onSave(row, editing)
        dismiss()
    }
}

/// Presents the live workout full-screen on iOS; a large sheet on macOS.
private struct NativeLiveWorkoutPresentation: ViewModifier {
    var session: NativeActiveWorkoutState?
    @Binding var isPresented: Bool
    var onEnd: (TimeInterval) -> Void
    var onDismiss: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $isPresented) {
            if let session {
                NativeActiveWorkoutView(
                    sport: session.sport,
                    startedAt: session.startedAt,
                    onEnd: onEnd
                )
            }
        }
        #else
        content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
            if let session {
                NativeActiveWorkoutView(
                    sport: session.sport,
                    startedAt: session.startedAt,
                    onEnd: onEnd
                )
            }
        }
        #endif
    }
}

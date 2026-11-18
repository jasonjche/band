import SwiftUI
import Combine
import StrandDesign
import WhoopStore

/// Journal: inset grouped list of the day's real answers, plus an Apple Form to log them.
struct NativeJournalView: View {
    var startsLogging: Bool = false
    var onFinish: (() -> Void)? = nil
    @Environment(\.nativeNavigationPath) private var path
    @StateObject private var catalog = JournalCatalogStore()
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""
    @State private var repoHandle: Repository?
    @State private var firstDay: String?
    @State private var refreshSeq = 0
    @State private var handlesReady = false

    private var selectedDay: Date {
        get { NativeDaySelection.date(from: selectedDayKey) }
        nonmutating set { selectedDayKey = NativeDaySelection.key(from: newValue) }
    }

    @State private var entries: [JournalEntry] = []
    @State private var importedQuestions: [String] = []
    @State private var nativeAnswers: [String: Bool] = [:]
    @State private var nativeNumeric: [String: Double] = [:]
    @State private var logging: Bool
    @State private var formItems: [JournalCatalogItem] = []

    init(startsLogging: Bool = false, onFinish: (() -> Void)? = nil) {
        self.startsLogging = startsLogging
        self.onFinish = onFinish
        _logging = State(initialValue: startsLogging)
    }

    private var dayKey: String { NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }

    private var behaviorDay: Date { NativeJournalBehaviorDay.date(from: selectedDay) }

    private var answers: [HomeJournalAnswer] {
        HomeJournalAnswer.make(entries: entries, day: dayKey)
    }

    private var notes: String? {
        entries.compactMap { entry -> String? in
            guard entry.day == dayKey else { return nil }
            return NativeJournalNotes.decode(entry.notes).note
        }.first { !$0.isEmpty }
    }

    private var hasEntry: Bool { !answers.isEmpty }

    var body: some View {
        Group {
            if logging {
                NativeJournalEditor(
                    items: formItems,
                    day: behaviorDay,
                    prompt: NativeJournalBehaviorDay.caption(for: selectedDay),
                    initialAnswers: seededYes,
                    initialNumeric: seededNumeric,
                    initialTimes: seededTime,
                    catalog: catalog,
                    imported: importedQuestions,
                    onSave: { yes, numeric, times in
                        await saveDraft(yes: yes, numeric: numeric, times: times)
                    },
                    onCancel: {
                        if let onFinish {
                            onFinish()
                        } else {
                            logging = false
                        }
                    }
                )
            } else {
                journalBody
            }
        }
        .navigationTitle("Journal")
        .modifier(NativeInlineTitle())
        .nativeDateSubtitle(behaviorDay)
        .toolbar {
            if !logging {
                ToolbarItem(placement: .primaryAction) {
                    Button(hasEntry ? "Edit" : "Log") { beginEditing() }
                }
            }
        }
        .background {
            NativeJournalRepoSink(
                repoHandle: $repoHandle,
                firstDay: $firstDay,
                refreshSeq: $refreshSeq,
                handlesReady: $handlesReady
            )
        }
        .task(id: handlesReady ? "\(dayKey)-\(refreshSeq)" : "boot") {
            guard handlesReady else { return }
            await reload()
            if logging { seedDraft() }
        }
        .onChange(of: catalog.items) { _ in refreshFormItems() }
        .navigationDestination(for: NativeJournalImpactRoute.self) { _ in
            NativeJournalImpactView()
        }
    }

    @ViewBuilder private var journalBody: some View {
        NativeChrome.screen {
            HomeDateStepper(
                title: NativeJournalBehaviorDay.title(for: selectedDay),
                canGoBack: HomeDayNav.canGoBack(selectedKey: dayKey, firstDay: firstDay),
                canGoForward: HomeDayNav.canGoForward(selectedKey: dayKey),
                onBack: { shiftDay(-1) },
                onForward: { shiftDay(1) }
            )
            .frame(maxWidth: .infinity)
            NativeChrome.panel {
                Text(NativeJournalBehaviorDay.caption(for: selectedDay))
                    .font(StrandFont.subhead)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HomeJournalList(answers: answers, notes: notes)
            Button {
                path.wrappedValue.append(NativeJournalImpactRoute())
            } label: {
                NativeChrome.panel {
                    NativeCardHeader(
                        title: "Impact on Recovery",
                        symbol: "chart.bar",
                        tint: NativeChrome.recovery,
                        chevron: true
                    )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Impact on Recovery")
        }
    }

    @State private var seededYes: [String: Bool] = [:]
    @State private var seededNumeric: [String: Double] = [:]
    @State private var seededTime: [String: Date] = [:]
    @State private var persistedYes: [String: Bool] = [:]
    @State private var persistedNumeric: [String: Double] = [:]
    @State private var persistedTime: [String: Date] = [:]

    private func shiftDay(_ delta: Int) {
        guard let next = HomeDayNav.shift(from: selectedDay, delta: delta, firstDay: firstDay) else { return }
        selectedDay = next
    }

    private func beginEditing() {
        refreshFormItems()
        seedDraft()
        logging = true
    }

    private func refreshFormItems() {
        formItems = catalog.resolvedItems(imported: importedQuestions)
    }

    private func seedDraft() {
        let seed = NativeJournalDraft.seed(
            entries: entries,
            nativeAnswers: nativeAnswers,
            nativeNumeric: nativeNumeric,
            dayKey: dayKey,
            selectedDay: selectedDay
        )
        seededYes = seed.yes
        seededNumeric = seed.numeric
        seededTime = seed.times
        persistedYes = seed.persistedYes
        persistedNumeric = seed.persistedNumeric
        persistedTime = seed.persistedTimes
    }

    private func saveDraft(yes draftYes: [String: Bool], numeric draftNumeric: [String: Double], times draftTime: [String: Date]) async {
        for item in formItems {
            // Write only what the user changed, so an untouched row cannot overwrite an imported answer.
            let key = item.canonical
            if !NativeJournalDraft.shouldWrite(
                key: key,
                draftYes: draftYes,
                draftNumeric: draftNumeric,
                draftTimes: draftTime,
                persistedYes: persistedYes,
                persistedNumeric: persistedNumeric,
                persistedTimes: persistedTime
            ) { continue }
            let yes = draftYes[item.canonical] ?? false
            let follow = NativeJournalFollowUp.forItem(item)
            let notes = NativeJournalNotes.encode(
                timeMinutes: yes && follow.hasTime
                    ? draftTime[item.canonical].map { NativeJournalNotes.minutes(from: $0) }
                    : nil,
                note: nil
            )
            if yes, follow.hasQuantity {
                let value = draftNumeric[item.canonical] ?? follow.defaultQuantity
                await repoHandle?.saveJournalNumeric(day: dayKey, question: item.canonical, value: value, notes: notes)
            } else {
                await repoHandle?.saveJournalAnswer(day: dayKey, question: item.canonical, answeredYes: yes, notes: notes)
            }
        }
        logging = false
        await reload()
        onFinish?()
    }

    private func reload() async {
        guard let repo = repoHandle else { return }
        firstDay = repo.days.first?.day
        entries = await repo.journalEntries(days: 40)
        let imported = await repo.importedJournalEntries(days: 400)
        importedQuestions = Array(Set(imported.map(\.question))).sorted()
        nativeAnswers = await repo.nativeJournalAnswers(day: dayKey)
        nativeNumeric = await repo.nativeJournalNumeric(day: dayKey)
        refreshFormItems()
    }
}

/// Holds Repository so the journal list does not re-render on hydration / cycle seq.
private struct NativeJournalRepoSink: View {
    @EnvironmentObject private var repo: Repository
    @Binding var repoHandle: Repository?
    @Binding var firstDay: String?
    @Binding var refreshSeq: Int
    @Binding var handlesReady: Bool

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                repoHandle = repo
                firstDay = repo.days.first?.day
                refreshSeq = repo.refreshSeq
                handlesReady = true
            }
            .onReceive(repo.$refreshSeq.removeDuplicates()) { refreshSeq = $0 }
    }
}

/// One card per category, Yes/No capsules, progress, and a short done state.
struct NativeJournalLogForm: View {
    var items: [JournalCatalogItem]
    var answers: [String: Bool]
    var numeric: [String: Double]
    var times: [String: Date] = [:]
    var day: Date = Date()
    var prompt: String? = nil
    var showsQuestionEditor: Bool = false
    var catalog: JournalCatalogStore? = nil
    var imported: [String] = []
    var onToggle: (String, Bool) -> Void
    var onNumeric: (String, Double) -> Void
    var onTime: (String, Date) -> Void = { _, _ in }

    @Environment(\.nativeStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hapticTick = 0

    private var answeredCount: Int {
        items.reduce(0) { $0 + (answers[$1.canonical] == nil ? 0 : 1) }
    }

    private var allAnswered: Bool {
        !items.isEmpty && answeredCount == items.count
    }

    var body: some View {
        let sections = NativeJournalSections.make(items)
        NativeChrome.screen {
            if let prompt, !prompt.isEmpty {
                NativeChrome.panel {
                    Text(prompt)
                        .font(StrandFont.subhead)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if items.isEmpty {
                NativeChrome.panel {
                    NativeEmptyState(text: "No behaviours to log", symbol: "book.closed")
                }
            } else {
                progressCard
                if allAnswered { completionCard }
                ForEach(sections) { section in
                    NativeChrome.panel {
                        NativeCardHeader(
                            title: section.group.title,
                            symbol: Self.symbol(for: section.group),
                            tint: Self.tint(for: section.group, style: style)
                        )
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Divider()
                            }
                            NativeJournalLogRow(
                                item: item,
                                selected: answers[item.canonical],
                                quantity: numeric[item.canonical],
                                time: times[item.canonical],
                                day: day,
                                reduceMotion: reduceMotion,
                                onToggle: { setAnswer(item, $0) },
                                onNumeric: { onNumeric(item.canonical, $0) },
                                onTime: { onTime(item.canonical, $0) }
                            )
                            .equatable()
                        }
                    }
                }
            }
            if showsQuestionEditor, let catalog {
                NavigationLink {
                    NativeJournalQuestionsView(catalog: catalog, imported: imported)
                } label: {
                    NativeChrome.panel {
                        NativeCardHeader(
                            title: "Add behaviours",
                            symbol: "plus.circle",
                            tint: Color.secondary,
                            chevron: true
                        )
                    }
                }
                .buttonStyle(.plain)
            }
        }
        #if os(iOS)
        .sensoryFeedback(.impact(weight: .light), trigger: hapticTick)
        #endif
    }

    private var progressCard: some View {
        NativeChrome.panel {
            Text("\(answeredCount) of \(items.count) answered")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
            ProgressView(value: Double(answeredCount), total: Double(max(items.count, 1)))
                .progressViewStyle(.linear)
                .tint(NativePaint.recovery(style))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(answeredCount) of \(items.count) answered")
    }

    private var completionCard: some View {
        NativeChrome.panel {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(NativePaint.recovery(style))
                VStack(alignment: .leading, spacing: 2) {
                    Text("All logged")
                        .font(StrandFont.headline)
                    Text("Save to keep this day")
                        .font(StrandFont.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78), value: allAnswered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("All logged. Save to keep this day")
    }

    private func setAnswer(_ item: JournalCatalogItem, _ yes: Bool) {
        hapticTick += 1
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78)) {
            onToggle(item.canonical, yes)
        }
    }

    static func symbol(for group: JournalGroup) -> String {
        switch group {
        case .nutrition: return "fork.knife"
        case .sleep: return "bed.double"
        case .lifestyle: return "figure.walk"
        case .recovery: return "heart"
        case .health, .supplements: return "cross.case"
        case .mental, .behaviour: return "person"
        case .training: return "figure.walk"
        case .environment: return "sun.max"
        case .womensHealth: return "heart"
        case .other: return "square.grid.2x2"
        }
    }

    private static func tint(for group: JournalGroup, style: NativeStyle) -> Color {
        switch group {
        case .nutrition: return NativePaint.activity(style)
        case .sleep: return NativePaint.sleep(style)
        case .lifestyle: return NativePaint.strain(style)
        case .recovery: return NativePaint.recovery(style)
        case .health, .supplements: return NativePaint.heart(style)
        case .mental, .behaviour: return NativeChrome.stressMid
        case .training: return NativePaint.strain(style)
        case .environment: return NativePaint.respiratory(style)
        case .womensHealth: return NativePaint.heart(style)
        case .other: return Color.secondary
        }
    }
}

/// One behaviour row. Equatable so a Yes/No tap does not rebuild every other row.
private struct NativeJournalLogRow: View, Equatable {
    var item: JournalCatalogItem
    var selected: Bool?
    var quantity: Double?
    var time: Date?
    var day: Date
    var reduceMotion: Bool
    var onToggle: (Bool) -> Void
    var onNumeric: (Double) -> Void
    var onTime: (Date) -> Void
    @Environment(\.nativeStyle) private var style

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.selected == rhs.selected
            && lhs.quantity == rhs.quantity
            && lhs.time == rhs.time
            && lhs.day == rhs.day
            && lhs.reduceMotion == rhs.reduceMotion
    }

    var body: some View {
        let follow = NativeJournalFollowUp.forItem(item)
        let yes = selected == true
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: item.display)
                    .font(StrandFont.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                yesNo
            }
            .frame(minHeight: 44)
            if yes, follow.hasQuantity {
                Stepper(value: numericBinding(follow), in: 0...99, step: 1) {
                    LabeledContent("Amount", value: numericLabel(follow))
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            if yes, follow.hasTime {
                DatePicker(
                    "Last at",
                    selection: timeBinding,
                    displayedComponents: .hourAndMinute
                )
                #if os(macOS)
                .datePickerStyle(.compact)
                #endif
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78), value: selected)
        .accessibilityElement(children: .contain)
    }

    private var yesNo: some View {
        HStack(spacing: 8) {
            choice("No", selected: selected == false) { onToggle(false) }
            choice("Yes", selected: selected == true) { onToggle(true) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.display)
        .accessibilityValue(selected == true ? "Yes" : selected == false ? "No" : "Not answered")
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(StrandFont.body.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minWidth: 64)
                .foregroundStyle(selected ? NativePaint.page(style) : Color.primary)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected
                              ? Color.primary
                              : (style == .whoop ? NativeTokens.whoopHighlight : NativeTokens.highlight))
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func numericBinding(_ follow: NativeJournalFollowUp) -> Binding<Double> {
        Binding(
            get: { quantity ?? follow.defaultQuantity },
            set: { onNumeric($0) }
        )
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { time ?? NativeJournalNotes.defaultTime(on: day) },
            set: { onTime($0) }
        )
    }

    private func numericLabel(_ follow: NativeJournalFollowUp) -> String {
        let value = quantity ?? follow.defaultQuantity
        let number = value.rounded() == value ? String(Int(value.rounded())) : String(format: "%g", value)
        if let unit = follow.unitLabel, !unit.isEmpty {
            return "\(number) \(unit)"
        }
        return number
    }
}

struct HomeJournalAnswer: Identifiable, Equatable {
    var question: String
    var value: String
    var id: String { question }

    static func make(entries: [JournalEntry], day: String) -> [HomeJournalAnswer] {
        NativeJournalIdentity.winningEntries(entries)
            .filter { $0.day == day }
            .map { entry in
                let detail = NativeJournalNotes.decode(entry.notes)
                let value: String
                if let numeric = entry.numericValue {
                    value = Self.format(numeric)
                } else {
                    value = entry.answeredYes ? "Yes" : "No"
                }
                let title = JournalCatalogStore.shortTitle(for: entry.question)
                if entry.answeredYes, let minutes = detail.timeMinutes {
                    return HomeJournalAnswer(
                        question: title,
                        value: "\(value) · \(NativeJournalNotes.formatTime(minutes))"
                    )
                }
                return HomeJournalAnswer(question: title, value: value)
            }
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value.rounded()))
        }
        return String(format: "%g", value)
    }
}

struct HomeJournalRow: View {
    var answer: HomeJournalAnswer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(answer.question)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(answer.value)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

struct HomeJournalList: View {
    var answers: [HomeJournalAnswer]
    var notes: String?

    var body: some View {
        if answers.isEmpty {
            NativeChrome.panel {
                NativeEmptyState(text: "No journal entry", symbol: "book.closed")
            }
        } else {
            NativeChrome.panel {
                VStack(spacing: 0) {
                    ForEach(Array(answers.enumerated()), id: \.element.id) { index, answer in
                        if index > 0 {
                            Divider().padding(.leading, 0)
                        }
                        HomeJournalRow(answer: answer)
                    }
                    if let notes, !notes.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Notes")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(notes)
                                .font(.body)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
    }
}

import SwiftUI
import Combine
import StrandDesign
import WhoopStore

/// Journal: inset grouped list of the day's real answers, plus an Apple Form to log them.
struct NativeJournalView: View {
    var startsLogging: Bool = false
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
    @State private var draftYes: [String: Bool] = [:]
    @State private var draftNumeric: [String: Double] = [:]
    @State private var draftTime: [String: Date] = [:]

    init(startsLogging: Bool = false) {
        self.startsLogging = startsLogging
        _logging = State(initialValue: startsLogging)
    }

    private var dayKey: String { NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }

    private var answers: [HomeJournalAnswer] {
        HomeJournalAnswer.make(entries: entries, day: dayKey)
    }

    private var notes: String? {
        entries.compactMap { entry -> String? in
            guard entry.day == dayKey else { return nil }
            return NativeJournalNotes.decode(entry.notes).note
        }.first { !$0.isEmpty }
    }

    private var items: [JournalCatalogItem] {
        catalog.resolvedItems(imported: importedQuestions)
    }

    private var hasEntry: Bool { !answers.isEmpty }

    var body: some View {
        Group {
            if logging {
                NativeJournalEditor(
                    items: items,
                    day: selectedDay,
                    answers: $draftYes,
                    numeric: $draftNumeric,
                    times: $draftTime,
                    catalog: catalog,
                    imported: importedQuestions
                )
            } else {
                journalBody
            }
        }
        .navigationTitle("Journal")
        .modifier(NativeInlineTitle())
        .nativeDateSubtitle(selectedDay)
        .toolbar {
            if logging {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { logging = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await saveDraft() } }
                }
            } else {
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
        .navigationDestination(for: NativeJournalImpactRoute.self) { _ in
            NativeJournalImpactView()
        }
    }

    @ViewBuilder private var journalBody: some View {
        NativeChrome.screen {
            HomeDateStepper(
                title: HomeDayTitle.text(for: selectedDay),
                canGoBack: HomeDayNav.canGoBack(selectedKey: dayKey, firstDay: firstDay),
                canGoForward: HomeDayNav.canGoForward(selectedKey: dayKey),
                onBack: { shiftDay(-1) },
                onForward: { shiftDay(1) }
            )
            .frame(maxWidth: .infinity)
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

    private func shiftDay(_ delta: Int) {
        guard let next = HomeDayNav.shift(from: selectedDay, delta: delta, firstDay: firstDay) else { return }
        selectedDay = next
    }

    private func beginEditing() {
        seedDraft()
        logging = true
    }

    private func seedDraft() {
        var yes: [String: Bool] = [:]
        var qty: [String: Double] = [:]
        var time: [String: Date] = [:]
        for entry in NativeJournalIdentity.winningEntries(entries) where entry.day == dayKey {
            yes[entry.question] = entry.answeredYes
            if let value = entry.numericValue { qty[entry.question] = value }
            if let minutes = NativeJournalNotes.decode(entry.notes).timeMinutes {
                time[entry.question] = NativeJournalNotes.date(minutes: minutes, on: selectedDay)
            }
        }
        for (question, value) in nativeAnswers {
            yes[JournalCatalogStore.canonicalId(for: question)] = value
        }
        for (question, value) in nativeNumeric {
            qty[JournalCatalogStore.canonicalId(for: question)] = value
        }
        draftYes = yes
        draftNumeric = qty
        draftTime = time
        seededYes = yes
        seededNumeric = qty
        seededTime = time
    }

    private func saveDraft() async {
        for item in items {
            // Write only what the user changed, so an untouched row cannot overwrite an imported answer.
            let key = item.canonical
            if draftYes[key] == seededYes[key], draftNumeric[key] == seededNumeric[key],
               draftTime[key] == seededTime[key] { continue }
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
    }

    private func reload() async {
        guard let repo = repoHandle else { return }
        firstDay = repo.days.first?.day
        entries = await repo.journalEntries(days: 40)
        let imported = await repo.importedJournalEntries(days: 400)
        importedQuestions = Array(Set(imported.map(\.question))).sorted()
        nativeAnswers = await repo.nativeJournalAnswers(day: dayKey)
        nativeNumeric = await repo.nativeJournalNumeric(day: dayKey)
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
    var showsQuestionEditor: Bool = false
    var catalog: JournalCatalogStore? = nil
    var imported: [String] = []
    var onToggle: (String, Bool) -> Void
    var onNumeric: (String, Double) -> Void
    var onTime: (String, Date) -> Void = { _, _ in }

    @Environment(\.nativeStyle) private var style
    @State private var hapticTick = 0

    private var answeredCount: Int {
        items.reduce(0) { $0 + (answers[$1.canonical] == nil ? 0 : 1) }
    }

    private var allAnswered: Bool {
        !items.isEmpty && answeredCount == items.count
    }

    var body: some View {
        NativeChrome.screen {
            if items.isEmpty {
                NativeChrome.panel {
                    NativeEmptyState(text: "No behaviours to log", symbol: "book.closed")
                }
            } else {
                progressCard
                if allAnswered { completionCard }
                ForEach(JournalGroup.displayOrder, id: \.self) { group in
                    let groupItems = items.filter { $0.group == group }
                        .sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) }
                    if !groupItems.isEmpty {
                        NativeChrome.panel {
                            NativeCardHeader(
                                title: group.title,
                                symbol: Self.symbol(for: group),
                                tint: Self.tint(for: group, style: style)
                            )
                            ForEach(Array(groupItems.enumerated()), id: \.element.id) { index, item in
                                if index > 0 {
                                    Divider()
                                }
                                row(item)
                            }
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
                            title: "Edit Questions",
                            symbol: "list.bullet",
                            tint: Color.secondary,
                            chevron: true
                        )
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: allAnswered)
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
        .transition(.scale(scale: 0.96).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("All logged. Save to keep this day")
    }

    @ViewBuilder private func row(_ item: JournalCatalogItem) -> some View {
        let follow = NativeJournalFollowUp.forItem(item)
        let yes = answers[item.canonical] == true
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: item.display)
                    .font(StrandFont.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                yesNo(item)
            }
            .frame(minHeight: 44)
            if yes, follow.hasQuantity {
                Stepper(value: numericBinding(item), in: 0...99, step: 1) {
                    LabeledContent("Amount", value: numericLabel(item, follow: follow))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if yes, follow.hasTime {
                DatePicker(
                    "Last at",
                    selection: timeBinding(item),
                    displayedComponents: .hourAndMinute
                )
                #if os(macOS)
                .datePickerStyle(.compact)
                #endif
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: answers[item.canonical])
        .accessibilityElement(children: .contain)
    }

    private func yesNo(_ item: JournalCatalogItem) -> some View {
        let selected = answers[item.canonical]
        return HStack(spacing: 8) {
            choice("No", selected: selected == false) { setAnswer(item, false) }
            choice("Yes", selected: selected == true) { setAnswer(item, true) }
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

    private func setAnswer(_ item: JournalCatalogItem, _ yes: Bool) {
        hapticTick += 1
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            onToggle(item.canonical, yes)
        }
    }

    private func numericBinding(_ item: JournalCatalogItem) -> Binding<Double> {
        Binding(
            get: { numeric[item.canonical] ?? NativeJournalFollowUp.forItem(item).defaultQuantity },
            set: { onNumeric(item.canonical, $0) }
        )
    }

    private func timeBinding(_ item: JournalCatalogItem) -> Binding<Date> {
        Binding(
            get: { times[item.canonical] ?? NativeJournalNotes.defaultTime(on: day) },
            set: { onTime(item.canonical, $0) }
        )
    }

    private func numericLabel(_ item: JournalCatalogItem, follow: NativeJournalFollowUp) -> String {
        let value = numeric[item.canonical] ?? follow.defaultQuantity
        let number = value.rounded() == value ? String(Int(value.rounded())) : String(format: "%g", value)
        if let unit = follow.unitLabel, !unit.isEmpty {
            return "\(number) \(unit)"
        }
        return number
    }

    private static func symbol(for group: JournalGroup) -> String {
        switch group {
        case .nutrition: return "fork.knife"
        case .sleep: return "bed.double"
        case .lifestyle: return "figure.walk"
        case .recovery: return "heart"
        case .health: return "cross.case"
        case .supplements: return "pills"
        case .behaviour: return "person"
        case .other: return "square.grid.2x2"
        }
    }

    private static func tint(for group: JournalGroup, style: NativeStyle) -> Color {
        switch group {
        case .nutrition: return NativePaint.activity(style)
        case .sleep: return NativePaint.sleep(style)
        case .lifestyle: return NativePaint.strain(style)
        case .recovery: return NativePaint.recovery(style)
        case .health: return NativePaint.heart(style)
        case .supplements: return NativePaint.respiratory(style)
        case .behaviour: return NativeChrome.stressMid
        case .other: return Color.secondary
        }
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

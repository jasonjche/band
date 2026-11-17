import SwiftUI
import Combine
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
        #if os(iOS)
        List {
            Section {
                HomeDateStepper(
                    title: HomeDayTitle.text(for: selectedDay),
                    canGoBack: HomeDayNav.canGoBack(selectedKey: dayKey, firstDay: firstDay),
                    canGoForward: HomeDayNav.canGoForward(selectedKey: dayKey),
                    onBack: { shiftDay(-1) },
                    onForward: { shiftDay(1) }
                )
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            if answers.isEmpty {
                Section {
                    NativeEmptyState(text: "No journal entry", symbol: "book.closed")
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(answers) { answer in
                        HomeJournalRow(answer: answer)
                    }
                }
                if let notes, !notes.isEmpty {
                    Section("Notes") {
                        Text(notes)
                            .font(.body)
                    }
                }
            }
            Section {
                impactRow
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(NativePageFill())
        #else
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
        }
        #endif
    }

    private var impactRow: some View {
        Button {
            path.wrappedValue.append(NativeJournalImpactRoute())
        } label: {
            HStack {
                Text("Impact on Recovery")
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Impact on Recovery")
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
        for entry in entries where entry.day == dayKey {
            yes[entry.question] = entry.answeredYes
            if let value = entry.numericValue { qty[entry.question] = value }
            if let minutes = NativeJournalNotes.decode(entry.notes).timeMinutes {
                time[entry.question] = NativeJournalNotes.date(minutes: minutes, on: selectedDay)
            }
        }
        for (question, value) in nativeAnswers where yes[question] == nil {
            yes[question] = value
        }
        for (question, value) in nativeNumeric where qty[question] == nil {
            qty[question] = value
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

/// Native Form of the user's tracked behaviours. Yes/no as Toggle, quantity as Stepper.
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

    var body: some View {
        Form {
            if items.isEmpty {
                Section {
                    NativeEmptyState(text: "No behaviours to log", symbol: "book.closed")
                }
            } else {
                ForEach(JournalGroup.displayOrder, id: \.self) { group in
                    let groupItems = items.filter { $0.group == group }
                        .sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) }
                    if !groupItems.isEmpty {
                        Section(group.title) {
                            ForEach(groupItems) { item in
                                row(item)
                            }
                        }
                    }
                }
            }
            if showsQuestionEditor, let catalog {
                Section {
                    NavigationLink("Edit Questions") {
                        NativeJournalQuestionsView(catalog: catalog, imported: imported)
                    }
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(NativePageFill())
        #endif
    }

    @ViewBuilder private func row(_ item: JournalCatalogItem) -> some View {
        let follow = NativeJournalFollowUp.forItem(item)
        let yes = answers[item.canonical] ?? false
        Group {
            Toggle(isOn: boolBinding(item)) {
                Text(verbatim: item.display)
            }
            if yes, follow.hasQuantity {
                Stepper(value: numericBinding(item), in: 0...99, step: 1) {
                    LabeledContent("Amount", value: numericLabel(item, follow: follow))
                }
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
            }
        }
    }

    private func boolBinding(_ item: JournalCatalogItem) -> Binding<Bool> {
        Binding(
            get: { answers[item.canonical] ?? false },
            set: { onToggle(item.canonical, $0) }
        )
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
}

struct HomeJournalAnswer: Identifiable, Equatable {
    var question: String
    var value: String
    var id: String { question }

    static func make(entries: [JournalEntry], day: String) -> [HomeJournalAnswer] {
        entries
            .filter { $0.day == day }
            .map { entry in
                let detail = NativeJournalNotes.decode(entry.notes)
                let value: String
                if let numeric = entry.numericValue {
                    value = Self.format(numeric)
                } else {
                    value = entry.answeredYes ? "Yes" : "No"
                }
                if entry.answeredYes, let minutes = detail.timeMinutes {
                    return HomeJournalAnswer(
                        question: entry.question,
                        value: "\(value) · \(NativeJournalNotes.formatTime(minutes))"
                    )
                }
                return HomeJournalAnswer(question: entry.question, value: value)
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

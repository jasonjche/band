import SwiftUI
import WhoopStore

/// Journal: inset grouped list of the day's real answers, plus an Apple Form to log them.
struct NativeJournalView: View {
    var startsLogging: Bool = false
    @EnvironmentObject private var repo: Repository
    @StateObject private var catalog = JournalCatalogStore()
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""

    private var selectedDay: Date {
        get { NativeDaySelection.date(from: selectedDayKey) }
        nonmutating set { selectedDayKey = NativeDaySelection.key(from: newValue) }
    }

    @State private var entries: [JournalEntry] = []
    @State private var importedQuestions: [String] = []
    @State private var nativeAnswers: [String: Bool] = [:]
    @State private var nativeNumeric: [String: Double] = [:]
    @State private var logging: Bool

    init(startsLogging: Bool = false) {
        self.startsLogging = startsLogging
        _logging = State(initialValue: startsLogging)
    }

    private var dayKey: String { NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }

    private var answers: [HomeJournalAnswer] {
        HomeJournalAnswer.make(entries: entries, day: dayKey)
    }

    private var notes: String? {
        entries.first { $0.day == dayKey && $0.notes != nil && !($0.notes?.isEmpty ?? true) }?.notes
    }

    private var items: [JournalCatalogItem] {
        catalog.resolvedItems(imported: importedQuestions)
    }

    private var hasEntry: Bool { !answers.isEmpty }

    var body: some View {
        Group {
            if logging {
                NativeJournalLogForm(
                    items: items,
                    answers: nativeAnswers,
                    numeric: nativeNumeric,
                    onToggle: { question, yes in
                        Task {
                            await repo.saveJournalAnswer(day: dayKey, question: question, answeredYes: yes)
                            await reload()
                        }
                    },
                    onNumeric: { question, value in
                        Task {
                            await repo.saveJournalNumeric(day: dayKey, question: question, value: value)
                            await reload()
                        }
                    }
                )
            } else {
                journalBody
            }
        }
        .navigationTitle("Journal")
        .modifier(NativeInlineTitle())
        .nativeDateSubtitle(selectedDay)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(logging ? "Done" : (hasEntry ? "Edit" : "Log")) {
                    logging.toggle()
                }
            }
        }
        .task(id: dayKey) { await reload() }
    }

    @ViewBuilder private var journalBody: some View {
        #if os(iOS)
        List {
            Section {
                HomeDateStepper(
                    title: HomeDayTitle.text(for: selectedDay),
                    canGoBack: HomeDayNav.canGoBack(selectedKey: dayKey, firstDay: repo.days.first?.day),
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
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(NativePageFill())
        #else
        NativeChrome.screen {
            HomeDateStepper(
                title: HomeDayTitle.text(for: selectedDay),
                canGoBack: HomeDayNav.canGoBack(selectedKey: dayKey, firstDay: repo.days.first?.day),
                canGoForward: HomeDayNav.canGoForward(selectedKey: dayKey),
                onBack: { shiftDay(-1) },
                onForward: { shiftDay(1) }
            )
            .frame(maxWidth: .infinity)
            HomeJournalList(answers: answers, notes: notes)
        }
        #endif
    }

    private func shiftDay(_ delta: Int) {
        guard let next = HomeDayNav.shift(from: selectedDay, delta: delta, firstDay: repo.days.first?.day) else { return }
        selectedDay = next
    }

    private func reload() async {
        entries = await repo.journalEntries(days: 40)
        let imported = await repo.importedJournalEntries(days: 400)
        importedQuestions = Array(Set(imported.map(\.question))).sorted()
        nativeAnswers = await repo.nativeJournalAnswers(day: dayKey)
        nativeNumeric = await repo.nativeJournalNumeric(day: dayKey)
    }
}

/// Native Form of the user's tracked behaviours. Yes/no as Toggle, quantity as Stepper.
struct NativeJournalLogForm: View {
    var items: [JournalCatalogItem]
    var answers: [String: Bool]
    var numeric: [String: Double]
    var onToggle: (String, Bool) -> Void
    var onNumeric: (String, Double) -> Void

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
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(NativePageFill())
        #endif
    }

    @ViewBuilder private func row(_ item: JournalCatalogItem) -> some View {
        if item.kind.isNumeric {
            HStack {
                Text(verbatim: item.display)
                Spacer()
                Button {
                    onNumeric(item.canonical, max(0, (numeric[item.canonical] ?? 0) - 1))
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Decrease")
                Text(numericLabel(item))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
                Button {
                    onNumeric(item.canonical, (numeric[item.canonical] ?? 0) + 1)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Increase")
            }
        } else {
            Toggle(isOn: boolBinding(item)) {
                Text(verbatim: item.display)
            }
        }
    }

    private func boolBinding(_ item: JournalCatalogItem) -> Binding<Bool> {
        Binding(
            get: { answers[item.canonical] ?? false },
            set: { onToggle(item.canonical, $0) }
        )
    }

    private func numericLabel(_ item: JournalCatalogItem) -> String {
        let value = numeric[item.canonical]
        let number = value.map { $0.rounded() == $0 ? String(Int($0.rounded())) : String(format: "%g", $0) } ?? "0"
        if let unit = item.kind.unitLabel, !unit.isEmpty {
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
                let value: String
                if let numeric = entry.numericValue {
                    value = Self.format(numeric)
                } else {
                    value = entry.answeredYes ? "Yes" : "No"
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

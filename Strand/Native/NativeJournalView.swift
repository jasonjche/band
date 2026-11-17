import SwiftUI
import WhoopStore

/// Journal: inset grouped list of the day's real answers. Empty → "No journal entry".
struct NativeJournalView: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""

    private var selectedDay: Date {
        get { NativeDaySelection.date(from: selectedDayKey) }
        nonmutating set { selectedDayKey = NativeDaySelection.key(from: newValue) }
    }

    @State private var entries: [JournalEntry] = []

    private var dayKey: String { NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }

    private var answers: [HomeJournalAnswer] {
        HomeJournalAnswer.make(entries: entries, day: dayKey)
    }

    private var notes: String? {
        entries.first { $0.day == dayKey && $0.notes != nil && !($0.notes?.isEmpty ?? true) }?.notes
    }

    var body: some View {
        journalBody
            .navigationTitle("Journal")
            .modifier(NativeInlineTitle())
            .nativeDateSubtitle(selectedDay)
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

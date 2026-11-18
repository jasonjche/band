import SwiftUI

/// Journal editor chrome: category cards, Yes/No capsules, follow-ups, and Edit Questions.
/// Draft answers live here so toggling a row does not rebuild NativeJournalView's catalog.
struct NativeJournalEditor: View {
    var items: [JournalCatalogItem]
    var day: Date
    var initialAnswers: [String: Bool]
    var initialNumeric: [String: Double]
    var initialTimes: [String: Date]
    var catalog: JournalCatalogStore
    var imported: [String]
    var onSave: ([String: Bool], [String: Double], [String: Date]) async -> Void
    var onCancel: () -> Void

    @State private var answers: [String: Bool]
    @State private var numeric: [String: Double]
    @State private var times: [String: Date]
    @State private var confirmDiscard = false

    init(
        items: [JournalCatalogItem],
        day: Date,
        initialAnswers: [String: Bool],
        initialNumeric: [String: Double],
        initialTimes: [String: Date],
        catalog: JournalCatalogStore,
        imported: [String],
        onSave: @escaping ([String: Bool], [String: Double], [String: Date]) async -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.items = items
        self.day = day
        self.initialAnswers = initialAnswers
        self.initialNumeric = initialNumeric
        self.initialTimes = initialTimes
        self.catalog = catalog
        self.imported = imported
        self.onSave = onSave
        self.onCancel = onCancel
        _answers = State(initialValue: initialAnswers)
        _numeric = State(initialValue: initialNumeric)
        _times = State(initialValue: initialTimes)
    }

    private var isEdited: Bool {
        answers != initialAnswers || numeric != initialNumeric || times != initialTimes
    }

    var body: some View {
        NativeJournalLogForm(
            items: items,
            answers: answers,
            numeric: numeric,
            times: times,
            day: day,
            showsQuestionEditor: true,
            catalog: catalog,
            imported: imported,
            onToggle: { question, yes in
                answers[question] = yes
                guard yes else { return }
                let follow = NativeJournalFollowUp.forQuestion(
                    question,
                    kind: items.first(where: { $0.canonical == question })?.kind ?? .bool
                )
                if follow.hasQuantity, numeric[question] == nil {
                    numeric[question] = follow.defaultQuantity
                }
                if follow.hasTime, times[question] == nil {
                    times[question] = NativeJournalNotes.defaultTime(on: day)
                }
            },
            onNumeric: { question, value in
                numeric[question] = max(0, value)
            },
            onTime: { question, date in
                times[question] = date
            }
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if isEdited {
                        confirmDiscard = true
                    } else {
                        onCancel()
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await onSave(answers, numeric, times) }
                }
            }
        }
        .confirmationDialog("Discard this entry?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { onCancel() }
            Button("Keep editing", role: .cancel) {}
        }
        .onChange(of: initialAnswers) { new in answers = new }
        .onChange(of: initialNumeric) { new in numeric = new }
        .onChange(of: initialTimes) { new in times = new }
    }
}

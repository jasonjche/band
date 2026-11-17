import SwiftUI

/// Journal editor chrome: category cards, Yes/No capsules, follow-ups, and Edit Questions.
struct NativeJournalEditor: View {
    var items: [JournalCatalogItem]
    var day: Date
    @Binding var answers: [String: Bool]
    @Binding var numeric: [String: Double]
    @Binding var times: [String: Date]
    @ObservedObject var catalog: JournalCatalogStore
    var imported: [String]

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
    }
}

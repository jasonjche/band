import SwiftUI

/// Toggle list of journal behaviours. Hidden items stay out of the day's form; the catalog persists.
struct NativeJournalQuestionsView: View {
    @ObservedObject var catalog: JournalCatalogStore
    var imported: [String]

    var body: some View {
        Form {
            ForEach(JournalGroup.displayOrder, id: \.self) { group in
                let items = grouped(group)
                if !items.isEmpty {
                    Section(group.title) {
                        ForEach(items) { item in
                            Toggle(isOn: visibilityBinding(item)) {
                                Text(verbatim: item.display)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Edit Questions")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func grouped(_ group: JournalGroup) -> [JournalCatalogItem] {
        catalog.resolvedItems(imported: imported, includeHidden: true)
            .filter { $0.group == group }
            .sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) }
    }

    private func visibilityBinding(_ item: JournalCatalogItem) -> Binding<Bool> {
        Binding(
            get: { !item.hidden },
            set: { visible in
                if visible {
                    catalog.restore(item.canonical)
                } else {
                    catalog.remove(item.canonical)
                }
            }
        )
    }
}

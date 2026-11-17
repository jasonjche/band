import SwiftUI
import StrandDesign

/// Library browser: categories, search, and a toggle to put a behaviour on the day's form.
struct NativeJournalQuestionsView: View {
    @ObservedObject var catalog: JournalCatalogStore
    var imported: [String]
    @State private var query = ""

    var body: some View {
        NativeChrome.screen {
            ForEach(JournalGroup.displayOrder, id: \.self) { group in
                let items = grouped(group)
                if !items.isEmpty {
                    NativeChrome.panel {
                        NativeCardHeader(
                            title: group.title,
                            symbol: NativeJournalLogForm.symbol(for: group),
                            tint: NativeChrome.recovery
                        )
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            Toggle(isOn: visibilityBinding(item)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: item.display)
                                        .font(StrandFont.body)
                                    if item.display != item.canonical {
                                        Text(verbatim: item.canonical)
                                            .font(StrandFont.footnote)
                                            .foregroundStyle(Color.secondary)
                                    }
                                }
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search behaviours")
        .navigationTitle("Add behaviours")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func grouped(_ group: JournalGroup) -> [JournalCatalogItem] {
        catalog.libraryItems(imported: imported)
            .filter { $0.group == group }
            .filter { JournalCatalogStore.libraryMatches($0, query: query) }
            .sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) }
    }

    private func visibilityBinding(_ item: JournalCatalogItem) -> Binding<Bool> {
        Binding(
            get: { catalog.isOnDailyForm(item.canonical, imported: imported) },
            set: { catalog.setOnDailyForm(item.canonical, enabled: $0) }
        )
    }
}

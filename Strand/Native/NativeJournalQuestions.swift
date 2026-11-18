import SwiftUI
import StrandDesign

/// Library browser: categories, search, and a toggle to put a behaviour on the day's form.
struct NativeJournalQuestionsView: View {
    @ObservedObject var catalog: JournalCatalogStore
    var imported: [String]
    @State private var query = ""

    var body: some View {
        let sections = NativeJournalSections.make(
            catalog.libraryItems(imported: imported),
            query: query
        )
        NativeChrome.screen(lazy: true) {
            ForEach(sections) { section in
                NativeJournalLibraryGroupCard(
                    section: section,
                    onToggle: { canonical, enabled in
                        catalog.setOnDailyForm(canonical, enabled: enabled)
                    }
                )
                .equatable()
            }
        }
        .searchable(text: $query, prompt: "Search behaviours")
        .navigationTitle("Add behaviours")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// One category card. Skips its body when none of its rows changed.
private struct NativeJournalLibraryGroupCard: View, Equatable {
    var section: NativeJournalSections.Section
    var onToggle: (String, Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.section == rhs.section
    }

    var body: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: section.group.title,
                symbol: NativeJournalLogForm.symbol(for: section.group),
                tint: NativeChrome.recovery
            )
            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                NativeJournalLibraryRow(
                    item: item,
                    isOn: !item.hidden,
                    onToggle: { onToggle(item.canonical, $0) }
                )
                .equatable()
            }
        }
    }
}

private struct NativeJournalLibraryRow: View, Equatable {
    var item: JournalCatalogItem
    var isOn: Bool
    var onToggle: (Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.isOn == rhs.isOn
    }

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: onToggle)) {
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

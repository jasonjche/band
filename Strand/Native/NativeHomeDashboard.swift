import SwiftUI

/// Native sheet: toggle metrics on/off and drag to reorder. Persists enabled ids as one JSON string.
struct HomeDashboardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]
    var onSave: ([String]) -> Void

    struct Row: Identifiable, Equatable {
        var id: String
        var title: String
        var enabled: Bool
    }

    init(selectedIds: [String], onSave: @escaping ([String]) -> Void) {
        self.onSave = onSave
        var seen = Set<String>()
        var built: [Row] = []
        for id in selectedIds {
            guard let metric = HomeDashboardMetric(rawValue: id), seen.insert(id).inserted else { continue }
            built.append(Row(id: id, title: metric.title, enabled: true))
        }
        for metric in HomeDashboardMetric.allCases where seen.insert(metric.rawValue).inserted {
            built.append(Row(id: metric.rawValue, title: metric.title, enabled: false))
        }
        _rows = State(initialValue: built)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach($rows) { $row in
                    Toggle(isOn: $row.enabled) {
                        Text(row.title)
                    }
                }
                .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("My Dashboard")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(rows.filter(\.enabled).map(\.id))
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #endif
    }
}

import SwiftUI
import Combine
import WhoopStore

/// Tiny leaf that holds `Repository` so the parent does not observe `objectWillChange`.
/// Forwards only `refreshSeq` (hydration / cycle publishes stay here).
struct NativeRepoSink: View {
    @EnvironmentObject private var repo: Repository
    @Binding var refreshSeq: Int
    @Binding var ready: Bool
    var onHandle: (Repository) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                onHandle(repo)
                refreshSeq = repo.refreshSeq
                ready = true
            }
            .onReceive(repo.$refreshSeq.removeDuplicates()) { refreshSeq = $0 }
    }
}

/// Captures `IntelligenceEngine` without the parent observing it.
struct NativeIntelligenceSink: View {
    @EnvironmentObject private var intelligence: IntelligenceEngine
    var onHandle: (IntelligenceEngine) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { onHandle(intelligence) }
    }
}

/// Captures `ProfileStore` without the parent observing it.
struct NativeProfileSink: View {
    @EnvironmentObject private var profile: ProfileStore
    var onHandle: (ProfileStore) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { onHandle(profile) }
    }
}

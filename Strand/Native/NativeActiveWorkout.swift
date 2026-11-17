import SwiftUI
import Combine
import StrandDesign

// Live Start Activity. GPS is skipped: GpsWorkoutRecorder is wired through AppModel's
// existing live-workout session, not a drop-in for this Native sheet. No Live Activity
// / Dynamic Island (disabled on this build for battery).

struct NativeActiveWorkoutState: Codable, Equatable, Identifiable {
    var sport: String
    var startTs: Int

    var id: Int { startTs }
    var startedAt: Date { Date(timeIntervalSince1970: TimeInterval(startTs)) }

    static let defaultsKey = "native.activeWorkout.v1"
    static let minimumDuration: TimeInterval = 60

    static func shouldDiscard(elapsed: TimeInterval) -> Bool {
        elapsed < minimumDuration
    }

    static func elapsedClock(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func load(_ defaults: UserDefaults = .standard) -> NativeActiveWorkoutState? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(NativeActiveWorkoutState.self, from: data)
    }

    static func persist(_ state: NativeActiveWorkoutState, in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// Snapshot-friendly live workout chrome. Timer always; BPM and zone only when provided.
struct NativeActiveWorkoutScreen: View {
    var sport: String
    var startedAt: Date
    var now: Date
    var bpm: Int?
    var zone: Int?
    var onEnd: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 24)
            Text(sport)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(NativeActiveWorkoutState.elapsedClock(from: startedAt, to: now))
                .font(StrandFont.rounded(56, weight: .bold))
                .monospacedDigit()
                .accessibilityLabel("Elapsed time")
            if let bpm {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(bpm)")
                            .font(StrandFont.rounded(34, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(NativeTokens.heart)
                        Text("BPM")
                            .font(.headline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if let zone {
                        Text("Zone \(zone)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(NativeTokens.hrZone(zone))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(zone.map { "\(bpm) BPM, Zone \($0)" } ?? "\(bpm) BPM")
            }
            Spacer()
            Button("End", action: onEnd)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativePageFill().ignoresSafeArea())
        .navigationTitle(sport)
        .modifier(NativeInlineTitle())
    }
}

/// Live workout: retains realtime HR while on screen, releases on disappear or background.
struct NativeActiveWorkoutView: View {
    var sport: String
    var startedAt: Date
    var onEnd: (TimeInterval) -> Void

    @EnvironmentObject private var profile: ProfileStore
    @State private var holdingHR = false
    @State private var confirmingEnd = false
    @State private var bpm: Int?
    @State private var modelHandle: AppModel?

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            NativeActiveWorkoutScreen(
                sport: sport,
                startedAt: startedAt,
                now: context.date,
                bpm: bpm,
                zone: zone(for: bpm),
                onEnd: { confirmingEnd = true }
            )
        }
        .confirmationDialog("End Activity?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("Save") { end(at: Date()) }
            // Zero elapsed falls under the one-minute rule, so nothing is stored.
            Button("Discard", role: .destructive) { releaseHR(); onEnd(0) }
            Button("Resume", role: .cancel) {}
        }
        .nativeStyleBridge()
        .interactiveDismissDisabled()
        .background {
            WorkoutHRArm(holdingHR: $holdingHR, bpm: $bpm, modelHandle: $modelHandle)
        }
        .onDisappear { releaseHR() }
    }

    private func zone(for bpm: Int?) -> Int? {
        guard let bpm else { return nil }
        return profile.hrZoneSet.zoneNumber(forBPM: Double(bpm))
    }

    private func end(at now: Date) {
        let elapsed = now.timeIntervalSince(startedAt)
        releaseHR()
        onEnd(elapsed)
    }

    private func releaseHR() {
        guard holdingHR else { return }
        modelHandle?.stopRealtimeHR()
        holdingHR = false
    }
}

/// Holds AppModel so TimelineView does not rebuild on import/cycle/illness publishes.
/// Forwards BPM and arms realtime HR while this screen is visible.
private struct WorkoutHRArm: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Binding var holdingHR: Bool
    @Binding var bpm: Int?
    @Binding var modelHandle: AppModel?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { modelHandle = model; arm() }
            .onDisappear { release() }
            .onChangeCompat(of: scenePhase) { phase in
                if phase == .background {
                    release()
                } else if phase == .active {
                    arm()
                }
            }
            .onReceive(model.$bpm.removeDuplicates()) { bpm = $0 }
    }

    private func arm() {
        guard !holdingHR else { return }
        model.startRealtimeHR()
        holdingHR = true
    }

    private func release() {
        guard holdingHR else { return }
        model.stopRealtimeHR()
        holdingHR = false
    }
}

import SwiftUI
import StrandDesign

/// macOS entry. Unit tests keep the lightweight host so `xcodebuild test -scheme BandMac`
/// never boots BLE or background timers.
@main
struct StrandApp: App {
    init() {
        guard !NativeMacHost.isUnitTestProcess else { return }
        PersonalDefaults.apply()
        PuffinExperiment.migrateContinuousHrvOvernightDefault()
    }

    var body: some Scene {
        WindowGroup {
            if NativeMacHost.isUnitTestProcess {
                Text("Band test host")
                    .padding()
                    .frame(minWidth: 320, minHeight: 200)
            } else {
                NativeMacAppScene()
                    .frame(minWidth: NativeMacLayout.minWidth, minHeight: NativeMacLayout.minHeight)
            }
        }
        .commands { NativeMacCommands() }
        .defaultSize(
            width: NativeMacHost.isUnitTestProcess ? 320 : NativeMacLayout.windowWidth,
            height: NativeMacHost.isUnitTestProcess ? 200 : NativeMacLayout.windowHeight
        )
    }
}

/// Full Band scene. Isolated from `StrandApp` so constructing `@StateObject AppModel` cannot
/// run inside the XCTest host.
private struct NativeMacAppScene: View {
    @StateObject private var model: AppModel
    @StateObject private var router: NavRouter
    @StateObject private var liftSession: LiftSessionController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue
    @AppStorage(AccentColor.storageKey) private var accentRaw = AccentColor.mint.rawValue
    @AppStorage(AccentColor.customHexKey) private var accentCustomHex = AccentColor.defaultCustomHex

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _router = StateObject(wrappedValue: NavRouter())
        let liftSession = LiftSessionController(
            buzz: { [weak model] loops in
                model?.buzz(loops: loops, gate: HapticPrefs.liftRest)
            },
            setStrapHandler: { [weak model] handler in
                model?.strapDoubleTapOverride = handler
            },
            log: { [weak model] line in
                model?.live.append(log: AppModel.stamped(line))
            }
        )
        _liftSession = StateObject(wrappedValue: liftSession)
    }

    var body: some View {
        NativeMacRootView()
            .environmentObject(model)
            .environmentObject(model.ble)
            .environmentObject(model.live)
            .environmentObject(model.repo)
            .environmentObject(model.profile)
            .environmentObject(model.behavior)
            .environmentObject(model.intelligence)
            .environmentObject(model.coach)
            .environmentObject(router)
            .environmentObject(UpdateStore.shared)
            .environmentObject(liftSession)
            .environment(\.stressNudgeCenter, model.stressNudgeCenter)
            .preferredColorScheme(AppearanceMode.resolve(appearanceRaw).colorScheme)
            .environment(\.locale, AppLanguage.activeLocale)
            .chartStyle(chartStyleRaw)
            .noopAccent(accentRaw, customHex: accentCustomHex)
            .task {
                liftSession.resumeSaved()
                await startModel()
            }
            .onChangeCompat(of: scenePhase) { phase in
                if phase == .active {
                    Task { await startModel() }
                }
            }
    }

    @MainActor
    private func startModel() async {
        model.applySmartAlarm()
        model.ble.requestSync(.foreground)
        await model.repo.refresh()
        await model.runDeferredRescoreIfOwed()
        let repo = model.repo
        Task.detached(priority: .utility) {
            await FolderBackup.catchUpIfDue(checkpoint: { await repo.checkpointForBackup() })
        }
    }
}

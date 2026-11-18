import SwiftUI
import StrandDesign

/// Lean Notifications page. Same keys as the old Automations screen so existing prefs carry over.
struct NativeNotificationsSettings: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var behavior: BehaviorStore
    @AppStorage("notif.masterEnabled") private var wristAlertsMaster = false
    @AppStorage(HapticPrefs.breathing) private var breathingHaptic = true
    @AppStorage(HapticPrefs.intervals) private var intervalsHaptic = true
    @AppStorage(HapticPrefs.liveSession) private var liveSessionHaptic = true
    @AppStorage(HapticPrefs.workout) private var workoutHaptic = true
    @StateObject private var inactivity = InactivityPrefs()

    var body: some View {
        List {
            Section {
                Toggle("Recovery is ready", isOn: $behavior.recoveryReadyNotify)
                    .onChangeCompat(of: behavior.recoveryReadyNotify) { on in
                        if on {
                            RecoveryReadyNotifier.requestAuthorization()
                            model.evaluateDailyNotifications()
                        }
                    }
                Toggle("Health Monitor", isOn: $behavior.healthMonitorNotify)
                    .onChangeCompat(of: behavior.healthMonitorNotify) { on in
                        if on {
                            HealthMonitorNotifier.requestAuthorization()
                            model.evaluateDailyNotifications()
                        }
                    }
                Toggle("Sleep recorded", isOn: $behavior.sleepRecordedNotify)
                    .onChangeCompat(of: behavior.sleepRecordedNotify) { on in
                        if on {
                            SleepRecordedNotifier.requestAuthorization()
                            model.evaluateDailyNotifications()
                        }
                    }
                Toggle("Illness early-warning", isOn: $behavior.illnessWatch)
                    .onChangeCompat(of: behavior.illnessWatch) { _ in
                        model.reevaluateIllness()
                        if behavior.illnessWatch { IllnessNotifier.requestAuthorization() }
                    }
                Toggle("Low and full battery", isOn: $behavior.batteryAlerts)
                    .onChangeCompat(of: behavior.batteryAlerts) { on in
                        if on { BatteryNotifier.requestAuthorization() }
                    }
                if behavior.batteryAlerts {
                    Toggle("Predictive runtime warning", isOn: $behavior.batteryPredictiveAlerts)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Local notifications Band can send. Recovery and Health Monitor default on.")
            }

            Section {
                if wristAlertsMaster {
                    Toggle("Wrist alerts", isOn: $wristAlertsMaster)
                }
                Toggle("Breathing pacer", isOn: $breathingHaptic)
                Toggle("Interval timer", isOn: $intervalsHaptic)
                Toggle("Live Session cues", isOn: $liveSessionHaptic)
                Toggle("Workout start & end", isOn: $workoutHaptic)
                if behavior.zoneCoaching {
                    Toggle("HR-zone coaching", isOn: $behavior.zoneCoaching)
                }
                if behavior.stressCheckIn {
                    Toggle("Stress check-ins", isOn: $behavior.stressCheckIn)
                }
                if inactivity.enabled {
                    Toggle("Inactivity reminder", isOn: $inactivity.enabled)
                }
                if behavior.strainTargetNudge {
                    Toggle("Strain target reached", isOn: $behavior.strainTargetNudge)
                }
                if behavior.doubleTapAction != .none {
                    Picker("Double-tap", selection: $behavior.doubleTapAction) {
                        Text("Off").tag(MacActionKind.none)
                        ForEach(doubleTapOptions) { Text($0.label).tag($0) }
                    }
                }
                #if os(macOS)
                if behavior.autoLockOnWristOff {
                    Toggle("Lock Mac when strap comes off", isOn: $behavior.autoLockOnWristOff)
                }
                #endif
                if !behavior.wristOffShortcut.isEmpty {
                    LabeledContent("Taken-off Shortcut") {
                        TextField("Shortcut name", text: $behavior.wristOffShortcut)
                    }
                }
                if !behavior.wristOnShortcut.isEmpty {
                    LabeledContent("Put-on Shortcut") {
                        TextField("Shortcut name", text: $behavior.wristOnShortcut)
                    }
                }
            } header: {
                Text("Strap alerts")
            } footer: {
                Text("In-session buzzes default on. Opt-in strap automations appear here only while they are on, so they can be turned off.")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .appleSettingsChrome("Notifications")
        .onAppear {
            if behavior.recoveryReadyNotify { RecoveryReadyNotifier.requestAuthorization() }
            if behavior.healthMonitorNotify { HealthMonitorNotifier.requestAuthorization() }
        }
    }

    private var doubleTapOptions: [MacActionKind] {
        #if os(iOS)
        MacActionKind.allCases.filter { $0 != .lockScreen && $0 != .none }
        #else
        MacActionKind.allCases.filter { $0 != .none }
        #endif
    }
}

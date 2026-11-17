import SwiftUI
import UserNotifications
import StrandAnalytics
import StrandDesign
import WhoopStore
#if canImport(UIKit)
import UIKit
#endif

/// Pure planner facts. The view reads these; it does not re-derive need or the strap alarm.
enum NativeSleepPlannerLogic {

    struct Snapshot: Equatable {
        var need: SleepPlanner.Need?
        var planned: SleepPlanner.Need?
        var typical: SleepPlanner.TypicalSleep
        var strainTarget: BandStrainTarget.Result?
    }

    /// Tonight's need is one extra `BandSleepLedger` step on the same arrays
    /// `NativeBandScores` already scored. Planned strain reuses that step with the
    /// strain-target midpoint as today's load.
    static func snapshot(
        days: [DailyMetric],
        sleeps: [CachedSleepSession],
        workouts: [WorkoutRow],
        importedSleep: [String: ImportedSleepFigures],
        todayKey: String
    ) -> Snapshot {
        let typical = SleepPlanner.typicalSleep(nightSamples(days: days, sleeps: sleeps))
        let target = NativeStrainTarget.resolve(
            viewingKey: todayKey, todayKey: todayKey,
            days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        guard let params = NativeBandScores.params() else {
            return Snapshot(need: nil, planned: nil, typical: typical, strainTarget: target)
        }
        let inputs = NativeBandScores.dayInputs(
            days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        guard !inputs.isEmpty else {
            return Snapshot(need: nil, planned: nil, typical: typical, strainTarget: target)
        }
        let outputs = BandScores.evaluate(days: inputs, params: params)
        let asleep = inputs.map { BandScores.nan($0.asleep) }
        let loadForNeed = outputs.map { BandScores.nan($0.loadForNeed) }
        let napForNeed = outputs.map { BandScores.nan($0.napForNeed) }
        let todayHat = outputs.last?.strainHat ?? 0
        let todayNap = inputs.last?.napMin ?? 0
        let need = SleepPlanner.projectTonight(
            asleep: asleep, loadForNeed: loadForNeed, napForNeed: napForNeed,
            todayStrainHat: todayHat, todayNapMin: todayNap, params: params.sleepLedger
        )
        var planned: SleepPlanner.Need?
        if let target {
            let mid = (target.range.lowerBound + target.range.upperBound) / 2
            planned = SleepPlanner.projectTonight(
                asleep: asleep, loadForNeed: loadForNeed, napForNeed: napForNeed,
                todayStrainHat: mid, todayNapMin: todayNap, params: params.sleepLedger
            )
        }
        return Snapshot(need: need, planned: planned, typical: typical, strainTarget: target)
    }

    static func nightSamples(days: [DailyMetric], sleeps: [CachedSleepSession]) -> [SleepPlanner.NightSample] {
        let sleepsByDay = Dictionary(grouping: sleeps) {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs)))
        }
        return days.map { day in
            let main = (sleepsByDay[day.day] ?? []).max {
                ($0.endTs - $0.effectiveStartTs) < ($1.endTs - $1.effectiveStartTs)
            }
            return SleepPlanner.NightSample(
                efficiency: day.efficiency,
                latencyMin: SleepPlanner.onsetLatencyMinutes(stagesJSON: main?.stagesJSON)
            )
        }
    }

    /// Same gate as `SmartAlarmView.strapAlarmWillArm`: a 5/MG does not arm without Protocol probes.
    static func willArm(whoop5Detected: Bool, probesEnabled: Bool) -> Bool {
        !(whoop5Detected && !probesEnabled)
    }

    /// Single funnel for every strap-alarm readout on this screen.
    /// `AppModel.nextSmartAlarmDate` is the same resolver `applySmartAlarm` arms from.
    static func nextStrapAlarm(
        enabled: Bool,
        willArm: Bool,
        minutes: Int,
        weekdays: Set<Int>,
        overrides: [Int: Int],
        from now: Date
    ) -> Date? {
        guard enabled, willArm else { return nil }
        return AppModel.nextSmartAlarmDate(
            minutes: minutes, weekdays: weekdays, overrides: overrides, from: now
        )
    }
}

/// Optional local bedtime reminder. Default off. Own keys, not the wind-down nudge.
enum NativeBedtimeReminder {
    static let requestId = "native.sleepPlanner.bedtime"
    private static let enabledKey = "native.sleepPlanner.bedtimeReminder"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    enum EnableOutcome { case scheduled, denied, off }

    static func setEnabled(_ on: Bool, minuteOfDay: Int, completion: (@MainActor (EnableOutcome) -> Void)? = nil) {
        guard on else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [requestId])
            if let completion { Task { @MainActor in completion(.off) } }
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    UserDefaults.standard.set(true, forKey: enabledKey)
                    schedule(minuteOfDay: minuteOfDay)
                    completion?(.scheduled)
                case .notDetermined:
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        Task { @MainActor in
                            if granted {
                                UserDefaults.standard.set(true, forKey: enabledKey)
                                schedule(minuteOfDay: minuteOfDay)
                                completion?(.scheduled)
                            } else {
                                completion?(.denied)
                            }
                        }
                    }
                default:
                    completion?(.denied)
                }
            }
        }
    }

    static func reschedule(minuteOfDay: Int) {
        guard isEnabled else { return }
        schedule(minuteOfDay: minuteOfDay)
    }

    private static func schedule(minuteOfDay: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestId])
        let content = UNMutableNotificationContent()
        content.title = "Time to get in bed"
        content.body = "Your Sleep Planner bedtime is now."
        content.sound = .default
        var comps = DateComponents()
        comps.hour = minuteOfDay / 60
        comps.minute = minuteOfDay % 60
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: requestId, content: content, trigger: trigger))
    }
}

/// WHOOP-style Sleep Planner: wake, Peak/Perform/Get By, in-bed time, need breakdown,
/// optional bedtime reminder, and a confirmed strap-alarm write through the existing Alarms path.
struct NativeSleepPlanner: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var behavior: BehaviorStore

    @AppStorage("native.sleepPlanner.wakeMinutes") private var wakeMinutes = 7 * 60
    @AppStorage("native.sleepPlanner.goal") private var goalRaw = SleepPlanner.Goal.peak.rawValue

    @State private var workouts: [WorkoutRow] = []
    @State private var snapshot = NativeSleepPlannerLogic.Snapshot(
        need: nil, planned: nil, typical: SleepPlanner.typicalSleep([]), strainTarget: nil
    )
    @State private var reminderOn = NativeBedtimeReminder.isEnabled
    @State private var showNotifDeniedAlert = false
    @State private var confirmArm = false
    @State private var confirmCancel = false

    private var goal: SleepPlanner.Goal {
        SleepPlanner.Goal(rawValue: goalRaw) ?? .peak
    }

    private var inBedMinute: Int? {
        guard let need = snapshot.need, need.totalMin > 0 else { return nil }
        return SleepPlanner.inBedMinutes(
            wakeMinutes: wakeMinutes, needMin: need.totalMin, goal: goal, typical: snapshot.typical
        )
    }

    private var strapWillArm: Bool {
        NativeSleepPlannerLogic.willArm(
            whoop5Detected: model.whoop5Detected, probesEnabled: PuffinExperiment.isEnabled
        )
    }

    private func nextStrapAlarm(from now: Date = Date()) -> Date? {
        NativeSleepPlannerLogic.nextStrapAlarm(
            enabled: behavior.smartAlarmEnabled,
            willArm: strapWillArm,
            minutes: behavior.smartAlarmMinutes,
            weekdays: behavior.smartAlarmWeekdays,
            overrides: WindDownNudge.perDayWakeOverrides,
            from: now
        )
    }

    var body: some View {
        Form {
            wakeSection
            goalSection
            inBedSection
            needSection
            reminderSection
            alarmSection
        }
        .appleSettingsChrome("Sleep Planner")
        .alert("Notifications are off", isPresented: $showNotifDeniedAlert) {
            Button("Not now", role: .cancel) {}
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            #endif
        } message: {
            Text("Turn on notifications for Band in Settings to get a bedtime reminder.")
        }
        .confirmationDialog(
            "Set strap alarm?",
            isPresented: $confirmArm,
            titleVisibility: .visible
        ) {
            Button("Set alarm on strap") { armStrap() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The strap will buzz at \(NativeTonightSleep.clock(wakeMinutes)). This is a silent wrist buzz, not a loud alarm. Keep a phone alarm for anything you cannot miss.")
        }
        .confirmationDialog(
            "Cancel strap alarm?",
            isPresented: $confirmCancel,
            titleVisibility: .visible
        ) {
            Button("Cancel strap alarm", role: .destructive) { cancelStrap() }
            Button("Keep alarm", role: .cancel) {}
        }
        .task { await reload() }
        .onChangeCompat(of: wakeMinutes) { _ in
            if let inBedMinute { NativeBedtimeReminder.reschedule(minuteOfDay: inBedMinute) }
        }
        .onChangeCompat(of: goalRaw) { _ in
            if let inBedMinute { NativeBedtimeReminder.reschedule(minuteOfDay: inBedMinute) }
        }
    }

    private var wakeSection: some View {
        Section {
            DatePicker("Wake time", selection: wakeBinding, displayedComponents: .hourAndMinute)
                .accessibilityLabel("Planner wake time")
        } footer: {
            Text("This time is the plan. It does not arm the strap.")
        }
    }

    private var goalSection: some View {
        Section {
            Picker("Tomorrow's goal", selection: $goalRaw) {
                Text("Peak").tag(SleepPlanner.Goal.peak.rawValue)
                Text("Perform").tag(SleepPlanner.Goal.perform.rawValue)
                Text("Get By").tag(SleepPlanner.Goal.getBy.rawValue)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Sleep goal")
        } footer: {
            Text("Peak is 100% of tonight's need, Perform 85%, Get By 70%.")
        }
    }

    @ViewBuilder private var inBedSection: some View {
        Section {
            if let inBedMinute {
                LabeledContent("In bed by", value: NativeTonightSleep.clock(inBedMinute))
                    .font(StrandFont.rounded(17, weight: .semibold))
            } else {
                LabeledContent("In bed by", value: "No data")
            }
        } footer: {
            inBedFooter
        }
    }

    private var inBedFooter: Text {
        let typical = snapshot.typical
        var line = "Bedtime is your wake time minus tonight's sleep need, adjusted for how long you usually take to fall asleep."
        if typical.usingDefaultEfficiency || typical.usingDefaultLatency {
            line += " Until you have 7 nights, Band uses typical values."
        } else {
            let eff = Int((typical.efficiency * 100).rounded())
            let lat = Int(typical.latencyMin.rounded())
            line += " Last \(typical.efficiencyNights) nights: \(eff)% efficient, \(lat) min to fall asleep."
        }
        return Text(line)
    }

    @ViewBuilder private var needSection: some View {
        if let need = snapshot.need {
            Section {
                LabeledContent("Tonight's Need", value: NativeTonightSleep.needText(need.totalMin))
                LabeledContent("Baseline", value: NativeScoreMath.duration(need.baselineMin))
                LabeledContent("Today's Strain", value: NativeSleepNeed.signedDuration(need.strainMin))
                LabeledContent("Sleep Debt", value: NativeSleepNeed.signedDuration(need.debtMin))
                LabeledContent("Naps", value: NativeSleepNeed.signedDuration(-need.napCreditMin))
                if let planned = snapshot.planned, let target = snapshot.strainTarget {
                    let lo = String(format: "%.1f", target.range.lowerBound)
                    let hi = String(format: "%.1f", target.range.upperBound)
                    LabeledContent(
                        "Strain Target \(lo)–\(hi)",
                        value: NativeTonightSleep.needText(planned.totalMin)
                    )
                }
            } header: {
                Text("Need")
            } footer: {
                Text(needFooter(need))
            }
        }
    }

    private func needFooter(_ need: SleepPlanner.Need) -> String {
        var line = "Same Band sleep-need ledger as Hours vs. Needed: baseline + strain + debt − naps."
        if need.clipped {
            line += " Need is clipped to the Band range."
        }
        if snapshot.planned != nil {
            line += " The strain-target line is tonight's need if today's load were the target midpoint."
        }
        return line
    }

    private var reminderSection: some View {
        Section {
            Toggle("Bedtime Reminder", isOn: $reminderOn)
                .onChangeCompat(of: reminderOn) { on in
                    guard let inBedMinute else {
                        if on { reminderOn = false }
                        return
                    }
                    NativeBedtimeReminder.setEnabled(on, minuteOfDay: inBedMinute) { outcome in
                        if outcome == .denied {
                            reminderOn = false
                            showNotifDeniedAlert = true
                        }
                    }
                }
        } footer: {
            Text("A local notification at the in-bed time. Off until you turn it on. It is not an alarm.")
        }
    }

    private var alarmSection: some View {
        Section {
            if let next = nextStrapAlarm() {
                LabeledContent("Strap Alarm", value: alarmStamp(next))
                if behavior.smartAlarmMinutes != wakeMinutes {
                    Button("Update strap alarm") { confirmArm = true }
                }
                Button("Cancel strap alarm", role: .destructive) { confirmCancel = true }
            } else {
                LabeledContent("Strap Alarm", value: "Off")
                Button("Set alarm on strap") { confirmArm = true }
            }
        } header: {
            Text("Strap")
        } footer: {
            Text(alarmFooter)
        }
    }

    private var alarmFooter: String {
        if model.whoop5Detected && !PuffinExperiment.isEnabled {
            return "The strap alarm is a plain buzz at the wake time. Band has no light-sleep window. WHOOP 5/MG alarms need Protocol probes in Test Centre, so this will not arm yet."
        }
        return "The strap alarm is a plain buzz at the wake time. Band has no light-sleep window. Setting it uses the same confirmed arm path as Alarms."
    }

    private var wakeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = wakeMinutes / 60
                c.minute = wakeMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                wakeMinutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
            }
        )
    }

    private func alarmStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.activeLocale
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM jj:mm")
        return formatter.string(from: date)
    }

    private func armStrap() {
        behavior.smartAlarmMinutes = wakeMinutes
        behavior.smartAlarmEnabled = true
        model.applySmartAlarm()
    }

    private func cancelStrap() {
        behavior.smartAlarmEnabled = false
        model.applySmartAlarm()
    }

    private func reload() async {
        workouts = await repo.workoutRows(days: 40)
        snapshot = NativeSleepPlannerLogic.snapshot(
            days: repo.days,
            sleeps: repo.sleeps,
            workouts: workouts,
            importedSleep: repo.importedSleep,
            todayKey: NativeDayLogic.logicalToday()
        )
    }
}

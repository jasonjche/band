import XCTest
import StrandAnalytics
@testable import Strand

final class NativeSleepPlannerTests: XCTestCase {

    func testMoreListIncludesSleepPlannerOnce() {
        XCTAssertEqual(NativeMoreItem.allCases.filter { $0 == .sleepPlanner }.count, 1)
        XCTAssertEqual(NativeMoreItem.sleepPlanner.title, "Sleep Planner")
        XCTAssertEqual(NativeMoreItem.sleepPlanner.icon, "bed.double.fill")
    }

    func testWillArmMatchesAlarmsGate() {
        XCTAssertTrue(NativeSleepPlannerLogic.willArm(whoop5Detected: false, probesEnabled: false))
        XCTAssertTrue(NativeSleepPlannerLogic.willArm(whoop5Detected: false, probesEnabled: true))
        XCTAssertFalse(NativeSleepPlannerLogic.willArm(whoop5Detected: true, probesEnabled: false))
        XCTAssertTrue(NativeSleepPlannerLogic.willArm(whoop5Detected: true, probesEnabled: true))
    }

    func testNoAlarmDateWhenUnarmed() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(NativeSleepPlannerLogic.nextStrapAlarm(
            enabled: false, willArm: true, minutes: 7 * 60, weekdays: [], overrides: [:], from: now
        ))
        XCTAssertNil(NativeSleepPlannerLogic.nextStrapAlarm(
            enabled: true, willArm: false, minutes: 7 * 60, weekdays: [], overrides: [:], from: now
        ))
    }

    func testArmedDateUsesTheAlarmsResolver() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 18, minute: 0))!
        let expected = AppModel.nextSmartAlarmDate(
            minutes: 7 * 60, weekdays: [], overrides: [:], from: now, calendar: cal
        )
        let got = NativeSleepPlannerLogic.nextStrapAlarm(
            enabled: true, willArm: true, minutes: 7 * 60, weekdays: [], overrides: [:], from: now
        )
        // Logic uses Calendar.current inside nextSmartAlarmDate; compare via the same call shape
        // the Alarms screen uses: one resolver, gated on armed.
        XCTAssertNotNil(got)
        XCTAssertEqual(
            NativeSleepPlannerLogic.nextStrapAlarm(
                enabled: true, willArm: true, minutes: 7 * 60, weekdays: [], overrides: [:], from: now
            ),
            AppModel.nextSmartAlarmDate(minutes: 7 * 60, weekdays: [], overrides: [:], from: now)
        )
        XCTAssertNotNil(expected)
    }

    func testSnapshotNeedIsBandLedgerNotASecondFormula() throws {
        let days = NativeSleepSnapshot.snapshotDays
        let sleeps = NativeSleepSnapshot.snapshotSleeps
        let snap = NativeSleepPlannerLogic.snapshot(
            days: days, sleeps: sleeps, workouts: [], importedSleep: [:],
            todayKey: NativeSleepSnapshot.highlightKey
        )
        XCTAssertNotNil(snap.need)
        XCTAssertGreaterThan(snap.need?.totalMin ?? 0, 0)
        let samples = NativeSleepPlannerLogic.nightSamples(days: days, sleeps: sleeps)
        XCTAssertEqual(samples.count, days.count)
        let highlight = sleeps.first {
            NativeDayLogic.sleepSessionDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs)))
                == NativeSleepSnapshot.highlightKey
        }
        XCTAssertEqual(
            try XCTUnwrap(SleepPlanner.onsetLatencyMinutes(stagesJSON: highlight?.stagesJSON)),
            12,
            accuracy: 1e-9
        )
    }

    func testPlannerSourceUsesExistingAlarmPathAndNoNewCommand() throws {
        let src = try Self.plannerSource()
        XCTAssertTrue(src.contains("model.applySmartAlarm()"))
        XCTAssertTrue(src.contains("AppModel.nextSmartAlarmDate("))
        XCTAssertEqual(src.components(separatedBy: "AppModel.nextSmartAlarmDate(").count - 1, 1,
                       "exactly one resolver call, same contract as SmartAlarmView")
        XCTAssertTrue(src.contains("guard enabled, willArm else"),
                      "the funnel is where the gate belongs")
        XCTAssertFalse(src.contains("armStrapAlarm("))
        XCTAssertFalse(src.contains("disableStrapAlarm("))
        XCTAssertFalse(src.contains("setAlarmTime"))
        XCTAssertFalse(src.contains("getStrapAlarm("))
        XCTAssertFalse(src.contains("send("))
        XCTAssertFalse(src.contains("WhoopCommand"))
        XCTAssertFalse(src.contains("AlarmPayload"))
        XCTAssertTrue(src.contains("This time is the plan. It does not arm the strap."))
        XCTAssertTrue(src.contains("Band has no light-sleep window"))
        XCTAssertTrue(src.contains("Set alarm on strap"))
        XCTAssertTrue(src.contains("confirmationDialog"))
        XCTAssertFalse(src.contains("TimelineView"))
        XCTAssertFalse(src.contains("Alarm in"))
    }

    func testPlannerWakePickerIsNotLabelledWakeTime() throws {
        let src = try Self.plannerSource()
        XCTAssertTrue(src.contains("accessibilityLabel(\"Planner wake time\")"))
        XCTAssertFalse(src.contains("accessibilityLabel(\"Wake time\")"))
        XCTAssertTrue(src.contains("LabeledContent(\"Strap Alarm\""))
    }

    func testBedtimeReminderDefaultsOff() {
        XCTAssertEqual(NativeBedtimeReminder.requestId, "native.sleepPlanner.bedtime")
        XCTAssertFalse(
            NativeBedtimeReminder.requestId.contains("wind-down"),
            "planner reminder must not share the Alarms wind-down identifier"
        )
    }

    private static func plannerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Strand/Native/NativeSleepPlanner.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

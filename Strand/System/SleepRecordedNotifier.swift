import Foundation
import UserNotifications

// MARK: - Optional "Sleep recorded." notification
//
// Default OFF. Once per local day, when the day's main sleep (not a nap) is first detected as
// ended. Body is hours slept and sleep performance % — the same asleep minutes and
// NativeBandScores sleep performance the Home sleep ring uses.
//
// CLEAN-ROOM: behaviour only. Copy is NOOP's own.
//
// Gate: StrainTargetNotifier idiom — persisted day marker advances only after an authorized post.
// Status-only check at fire time; requestAuthorization when the toggle is turned on.
enum SleepRecordedNotifier {
    private static let lastDayKey = "behavior.sleepRecordedLastDay"

    /// Pure, testable policy + copy — no notification/UserDefaults runtime.
    enum SleepRecordedPolicy {
        /// Same nap ceiling as `RecoveryReadyNotifier.RecoveryReadyPolicy.napMaxMinutes`.
        static let napMaxMinutes = 90

        static func isMainSleep(durationMinutes: Double) -> Bool {
            durationMinutes > Double(napMaxMinutes)
        }

        /// Displayed sleep performance: same rounding as `NativeScoreMath.percent`.
        static func displayedPercent(_ performance: Double) -> Int {
            Int(performance.rounded())
        }

        static func hoursText(asleepMinutes: Double) -> String {
            let total = max(0, Int(asleepMinutes.rounded()))
            let hours = total / 60
            let minutes = total % 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }

        /// Fire at most once per local day, only when enabled, the main sleep has ended, both
        /// hours and sleep performance are known, and we have not already posted for `today`.
        static func shouldNotify(enabled: Bool,
                                 asleepMinutes: Double?,
                                 sleepPerformance: Double?,
                                 isMainSleep: Bool,
                                 sleepEnded: Bool,
                                 lastNotifiedDay: String?,
                                 today: String) -> Bool {
            guard enabled,
                  let asleepMinutes, asleepMinutes > 0,
                  sleepPerformance != nil,
                  isMainSleep,
                  sleepEnded else { return false }
            return lastNotifiedDay != today
        }

        static func copy(asleepMinutes: Double, performancePercent: Int) -> (title: String, body: String) {
            let hours = hoursText(asleepMinutes: asleepMinutes)
            return (String(localized: "Sleep recorded."),
                    String(localized: "\(hours) · \(performancePercent)% sleep performance"))
        }
    }

    /// Ask up front (called when the user enables the toggle) so the system dialog appears at a
    /// predictable moment. BatteryNotifier idiom.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Run the policy against today's Home sleep figures and post at most once per day.
    /// `asleepMinutes` / `sleepPerformance` must be today's own figures from the same sources
    /// the Home sleep ring reads. The persisted day marker advances only after an authorized post.
    static func onDayUpdate(day: String,
                            asleepMinutes: Double?,
                            sleepPerformance: Double?,
                            isMainSleep: Bool,
                            sleepEnded: Bool,
                            enabled: Bool) {
        let d = UserDefaults.standard
        guard SleepRecordedPolicy.shouldNotify(enabled: enabled,
                                               asleepMinutes: asleepMinutes,
                                               sleepPerformance: sleepPerformance,
                                               isMainSleep: isMainSleep,
                                               sleepEnded: sleepEnded,
                                               lastNotifiedDay: d.string(forKey: lastDayKey),
                                               today: day),
              let asleepMinutes,
              let sleepPerformance else { return }
        let copy = SleepRecordedPolicy.copy(
            asleepMinutes: asleepMinutes,
            performancePercent: SleepRecordedPolicy.displayedPercent(sleepPerformance))
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "sleep-recorded", content: content, trigger: nil))
            UserDefaults.standard.set(day, forKey: lastDayKey)
        }
    }
}

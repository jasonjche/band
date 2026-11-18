import Foundation
import UserNotifications

// MARK: - Daily "Your Recovery is ready." notification
//
// Once per local day, when today's recovery is first computed after the main sleep ends (the
// post-wake analysis pass). The percent and the green/yellow/red zone word are the SAME figures
// the Home ring shows: NativeBandScores recovery, rounded the way NativeScoreMath.percent rounds,
// then NativeChrome.recoveryBandIndex on that displayed integer. A second readout of the same
// fact must not be able to disagree.
//
// CLEAN-ROOM: behaviour only. Copy is NOOP's own.
//
// Gate: StrainTargetNotifier idiom — persisted day marker advances only after an authorized post,
// so a notifications-denied day still notifies once permission is granted while that day's
// recovery is still showing. Status-only check at fire time; requestAuthorization when the
// toggle is turned on.
enum RecoveryReadyNotifier {
    private static let lastDayKey = "behavior.recoveryReadyLastDay"

    /// Pure, testable policy + copy — no notification/UserDefaults runtime.
    enum RecoveryReadyPolicy {
        /// NapDetector's max nap is 90 minutes inclusive. A block longer than that is main sleep.
        static let napMaxMinutes = 90

        /// Home ring bands via the same `NativeChrome.recoveryBandIndex` the ring tints with,
        /// applied to the DISPLAYED integer percent so the word and the color cannot disagree.
        static func zoneWord(percent: Int) -> String {
            switch NativeChrome.recoveryBandIndex(Double(percent)) {
            case 0: return String(localized: "red")
            case 1: return String(localized: "yellow")
            default: return String(localized: "green")
            }
        }

        /// One notable driver, only when HRV is at or below −1 vs baseline. Otherwise nothing.
        static func driverLine(hrvZ: Double?) -> String? {
            guard let hrvZ, hrvZ <= -1 else { return nil }
            return String(localized: "HRV well below your baseline")
        }

        /// Displayed percent: same rounding as `NativeScoreMath.percent`.
        static func displayedPercent(_ recovery: Double) -> Int {
            Int(recovery.rounded())
        }

        static func isMainSleep(durationMinutes: Double) -> Bool {
            durationMinutes > Double(napMaxMinutes)
        }

        /// Fire at most once per local day, only when enabled, today's own recovery is known,
        /// the main sleep (not a nap) has ended, and we have not already posted for `today`.
        /// Carried / stale prior-day values are excluded by the caller passing only today's score.
        static func shouldNotify(enabled: Bool,
                                 recovery: Double?,
                                 isMainSleep: Bool,
                                 sleepEnded: Bool,
                                 lastNotifiedDay: String?,
                                 today: String) -> Bool {
            guard enabled, recovery != nil, isMainSleep, sleepEnded else { return false }
            return lastNotifiedDay != today
        }

        static func copy(percent: Int, hrvZ: Double?) -> (title: String, body: String) {
            let zone = zoneWord(percent: percent)
            var body = "\(percent)% \(zone)."
            if let driver = driverLine(hrvZ: hrvZ) {
                body += " \(driver)."
            }
            return (String(localized: "Your Recovery is ready."), body)
        }
    }

    /// Ask up front (called when the user enables the toggle) so the system dialog appears at a
    /// predictable moment, not on the first post-wake analysis pass. BatteryNotifier idiom.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Run the policy against today's NativeBandScores recovery and post at most once per day.
    /// `recovery` / `hrvZ` must be today's own figures from the same NativeBandScores snapshot the
    /// Home ring reads — never a carried prior-day row. The persisted day marker advances only
    /// after an authorized post (StrainTargetNotifier).
    static func onDayUpdate(day: String,
                            recovery: Double?,
                            hrvZ: Double?,
                            isMainSleep: Bool,
                            sleepEnded: Bool,
                            enabled: Bool) {
        let d = UserDefaults.standard
        guard RecoveryReadyPolicy.shouldNotify(enabled: enabled,
                                               recovery: recovery,
                                               isMainSleep: isMainSleep,
                                               sleepEnded: sleepEnded,
                                               lastNotifiedDay: d.string(forKey: lastDayKey),
                                               today: day),
              let recovery else { return }
        let percent = RecoveryReadyPolicy.displayedPercent(recovery)
        let copy = RecoveryReadyPolicy.copy(percent: percent, hrvZ: hrvZ)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "recovery-ready", content: content, trigger: nil))
            UserDefaults.standard.set(day, forKey: lastDayKey)
        }
    }
}

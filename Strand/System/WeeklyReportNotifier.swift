import Foundation
import UserNotifications
import StrandAnalytics

/// Default-off local notification when a newly complete weekly assessment is ready.
enum WeeklyReportNotifier {
    static let enabledKey = "behavior.weeklyReportNudge"
    static let lastEndKey = "behavior.weeklyReportLastEnd"

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func evaluate(asOfDay: String, enabled: Bool) {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: lastEndKey)
        guard let end = PerformanceAssessment.NotifyPolicy.shouldNotify(
            enabled: enabled, asOfDay: asOfDay, lastNotifiedEnd: last
        ) else { return }
        guard let window = PerformanceAssessment.lastCompleteWindow(kind: .weekly, asOfDay: asOfDay),
              window.end == end else { return }
        let copy = PerformanceAssessment.NotifyPolicy.copy(weekStart: window.start, weekEnd: window.end)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "weekly-assessment", content: content, trigger: nil))
            UserDefaults.standard.set(end, forKey: lastEndKey)
        }
    }
}

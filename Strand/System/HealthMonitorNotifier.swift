import Foundation
import UserNotifications
import StrandAnalytics

// MARK: - Daily Health Monitor out-of-range notification
//
// Once per morning, after the main sleep is scored, if NativeHealthRange flags one or more of the
// five Health Monitor metrics. Body names those metrics and the direction — the SAME flagged
// vitals the Health Monitor page and Home tile show, from NativeHealthRange.report. A second
// readout of the same fact must not be able to disagree.
//
// CLEAN-ROOM: behaviour only. Copy is NOOP's own.
//
// Funnel: this is the morning local-notification for overnight vitals on Band. IllnessNotifier is
// a separate opt-in multi-signal "take it easy" watch (in-app banner; notifications only when
// that watch is on). Overnight-load on Home is explicitly never a notification. If IllnessNotifier
// has already posted this morning, this notifier yields so the two cannot stack.
//
// Gate: StrainTargetNotifier idiom — persisted day marker advances only after an authorized post.
enum HealthMonitorNotifier {
    private static let lastDayKey = "behavior.healthMonitorLastDay"

    /// Pure, testable policy + copy — no notification/UserDefaults runtime.
    enum HealthMonitorPolicy {
        struct Flag: Equatable {
            var id: String
            var status: TypicalVitalRange.Status
        }

        /// Flagged vitals from the shared Health Monitor report, in the resolver's order.
        static func flags(from report: NativeHealthRange.Report) -> [Flag] {
            report.vitals.compactMap { vital in
                // Same rule as `NativeHealthRange.Report.summary.outside`, so the post can never
                // disagree with the Home tile or the page: any metric above or below its range.
                guard vital.status == .above || vital.status == .below else { return nil }
                return Flag(id: vital.id, status: vital.status)
            }
        }

        static func isCalibrating(nightsWorn: Int) -> Bool {
            nightsWorn < NativeHealthMonitorMath.calibrateNights
        }

        static func shouldNotify(enabled: Bool,
                                 flags: [Flag],
                                 isMainSleep: Bool,
                                 sleepEnded: Bool,
                                 nightsWorn: Int,
                                 illnessPostedToday: Bool,
                                 lastNotifiedDay: String?,
                                 today: String) -> Bool {
            guard enabled,
                  isMainSleep,
                  sleepEnded,
                  !flags.isEmpty,
                  !isCalibrating(nightsWorn: nightsWorn),
                  !illnessPostedToday else { return false }
            return lastNotifiedDay != today
        }

        /// Short names for the notification. Direction copy matches the example
        /// "Resting HR and respiratory rate are above your typical range."
        static func metricName(_ id: String) -> String {
            switch id {
            case "rhr": return "Resting HR"
            case "resp": return "respiratory rate"
            case "hrv": return "HRV"
            case "spo2": return "blood oxygen"
            case "skin": return "skin temp"
            default: return id
            }
        }

        static func body(_ flags: [Flag]) -> String? {
            guard !flags.isEmpty else { return nil }
            let above = flags.filter { $0.status == .above }.map { metricName($0.id) }
            let below = flags.filter { $0.status == .below }.map { metricName($0.id) }
            var clauses: [String] = []
            if let clause = directionClause(names: above, direction: "above") {
                clauses.append(clause)
            }
            if let clause = directionClause(names: below, direction: "below") {
                clauses.append(clause)
            }
            guard let first = clauses.first else { return nil }
            if clauses.count == 1 {
                return capitalized(first) + "."
            }
            return capitalized(first) + " and " + clauses[1] + "."
        }

        static func copy(_ flags: [Flag]) -> (title: String, body: String)? {
            guard let body = body(flags) else { return nil }
            return (String(localized: "Health Monitor"), body)
        }

        private static func directionClause(names: [String], direction: String) -> String? {
            guard !names.isEmpty else { return nil }
            let joined = joinNames(names)
            let verb = names.count == 1 ? "is" : "are"
            return "\(joined) \(verb) \(direction) your typical range"
        }

        private static func joinNames(_ names: [String]) -> String {
            switch names.count {
            case 0: return ""
            case 1: return names[0]
            case 2: return "\(names[0]) and \(names[1])"
            default:
                let head = names.dropLast().joined(separator: ", ")
                return "\(head) and \(names.last ?? "")"
            }
        }

        private static func capitalized(_ text: String) -> String {
            guard let first = text.first else { return text }
            return first.uppercased() + text.dropFirst()
        }
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `report` must be `NativeHealthRange.report` for today's key — the same call Home and the
    /// Health Monitor page make. The persisted day marker advances only after an authorized post.
    static func onDayUpdate(day: String,
                            report: NativeHealthRange.Report,
                            isMainSleep: Bool,
                            sleepEnded: Bool,
                            nightsWorn: Int,
                            illnessPostedToday: Bool,
                            enabled: Bool) {
        let flags = HealthMonitorPolicy.flags(from: report)
        let d = UserDefaults.standard
        guard HealthMonitorPolicy.shouldNotify(enabled: enabled,
                                               flags: flags,
                                               isMainSleep: isMainSleep,
                                               sleepEnded: sleepEnded,
                                               nightsWorn: nightsWorn,
                                               illnessPostedToday: illnessPostedToday,
                                               lastNotifiedDay: d.string(forKey: lastDayKey),
                                               today: day),
              let copy = HealthMonitorPolicy.copy(flags) else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "health-monitor", content: content, trigger: nil))
            UserDefaults.standard.set(day, forKey: lastDayKey)
        }
    }
}

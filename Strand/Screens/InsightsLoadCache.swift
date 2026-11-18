import Foundation
import StrandAnalytics

/// Snapshot Insights last built, parked on the long-lived Repository so a re-mount can restore it.
struct InsightsLoadCache {
    let behaviours: [String: Set<String>]
    let controls: [String: Set<String>]
    let importedQuestions: [String]
    let dayAnswers: [String: Bool]
    let journalDayOffset: Int
    let outcomeByKey: [String: [String: Double]]
    let seriesByKey: [String: [(day: String, value: Double)]]
    let activityCosts: [ActivityCost]
    let numericJournalByKey: [String: [String: Double]]
}

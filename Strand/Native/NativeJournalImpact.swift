import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// Pushed from the Journal screen via the tab stack path.
struct NativeJournalImpactRoute: Hashable {}

/// Short labels and association copy for journal impact rows.
enum NativeJournalImpactCopy {
    static func title(for behaviorId: String) -> String {
        JournalCatalogStore.shortTitle(for: behaviorId)
    }

    static func effectText(_ effect: Double) -> String {
        "\(signedPoints(effect)) recovery"
    }

    static func sleepText(_ effect: Double) -> String {
        "Sleep \(signedPoints(effect))"
    }

    static func sampleCaption(verdict: JournalImpact.Verdict?, nYes: Int, nNo: Int) -> String {
        let counts = "\(nYes) yes · \(nNo) no days"
        switch verdict {
        case .helps: return "Helps · \(counts)"
        case .hurts: return "Hurts · \(counts)"
        case .unclear: return "No clear effect yet · \(counts)"
        case nil: return counts
        }
    }

    static func needCaption(needYes: Int, needNo: Int) -> String {
        var parts: [String] = []
        if needYes > 0 {
            parts.append(needYes == 1 ? "1 more yes answer" : "\(needYes) more yes answers")
        }
        if needNo > 0 {
            parts.append(needNo == 1 ? "1 more no answer" : "\(needNo) more no answers")
        }
        return parts.joined(separator: " · ")
    }

    static func recoverySentence(title: String, effect: Double) -> String {
        let name = title.lowercased()
        let points = Int(abs(effect).rounded())
        if points == 0 {
            return "Recovery is unchanged after days with \(name)"
        }
        let word = effect < 0 ? "lower" : "higher"
        let unit = points == 1 ? "point" : "points"
        return "Recovery is \(points) \(unit) \(word) after days with \(name)"
    }

    static func signedPoints(_ effect: Double) -> String {
        let rounded = effect.rounded()
        if rounded == 0 && effect != 0 {
            return String(format: "%+.1f", effect)
        }
        let n = Int(rounded)
        return n > 0 ? "+\(n)" : "\(n)"
    }
}

struct NativeJournalImpactView: View {
    @State private var repoHandle: Repository?
    @State private var refreshSeq = 0
    @State private var handlesReady = false
    @State private var model: NativeJournalImpactModel?

    var body: some View {
        Group {
            if let model {
                impactList(model)
            } else {
                NativeChrome.screen { ProgressView() }
                    .navigationTitle("Journal Impact")
                    .modifier(NativeInlineTitle())
            }
        }
        .background {
            NativeRepoSink(refreshSeq: $refreshSeq, ready: $handlesReady) { repoHandle = $0 }
        }
        .task(id: handlesReady ? "impact" : "boot") {
            guard handlesReady else { return }
            await load()
        }
    }

    @ViewBuilder private func impactList(_ model: NativeJournalImpactModel) -> some View {
        NativeChrome.screen {
            if model.isEmpty {
                NativeChrome.panel {
                    NativeEmptyState(
                        text: "Log yes and no answers to see how recovery differs after each behaviour",
                        symbol: "book.closed"
                    )
                }
            }
            if !model.clear.isEmpty {
                NativeChrome.panel {
                    ForEach(Array(model.clear.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        NativeJournalImpactRow(row: row)
                    }
                }
            }
            if !model.unclear.isEmpty {
                NativeChrome.section("No clear effect yet")
                NativeChrome.panel {
                    ForEach(Array(model.unclear.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        NativeJournalImpactRow(row: row)
                    }
                }
            }
            if !model.insufficient.isEmpty {
                NativeChrome.section("Not enough data yet")
                NativeChrome.panel {
                    ForEach(Array(model.insufficient.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        NativeJournalImpactRow(row: row)
                    }
                }
            }
            if !model.isEmpty {
                NativeChrome.footnote("Compared with days you answered no.")
            }
        }
        .navigationTitle("Journal Impact")
        .modifier(NativeInlineTitle())
    }

    private func load() async {
        guard let repo = repoHandle else { return }
        let entries = await repo.journalEntries(days: 4000)
        let workouts = await repo.workoutRows(days: 4000)
        let days = repo.days
        let sleeps = repo.sleeps
        let importedSleep = repo.importedSleep
        let asOf = days.map(\.day).max() ?? NativeDayLogic.logicalToday()
        let scores = NativeBandScores.resolve(
            days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep
        )
        var recovery: [String: Double] = [:]
        var sleep: [String: Double] = [:]
        recovery.reserveCapacity(scores.byDay.count)
        sleep.reserveCapacity(scores.byDay.count)
        for (day, scored) in scores.byDay {
            if let value = scored.recovery { recovery[day] = value }
            if let value = scored.sleepPerformance { sleep[day] = value }
        }
        let answers = NativeJournalIdentity.winningEntries(entries).map {
            JournalImpact.Answer(day: $0.day, behaviorId: $0.question, yes: $0.answeredYes)
        }
        let insights = await Task.detached(priority: .userInitiated) {
            JournalImpact.rank(
                answers: answers,
                recoveryByDay: recovery,
                sleepByDay: sleep,
                asOfDay: asOf
            )
        }.value
        model = NativeJournalImpactModel.make(insights)
    }
}

struct NativeJournalImpactModel: Equatable {
    var clear: [NativeJournalImpactRowModel]
    var unclear: [NativeJournalImpactRowModel]
    var insufficient: [NativeJournalImpactRowModel]

    var isEmpty: Bool { clear.isEmpty && unclear.isEmpty && insufficient.isEmpty }

    static func make(_ insights: [JournalImpact.Insight]) -> NativeJournalImpactModel {
        var clear: [NativeJournalImpactRowModel] = []
        var unclear: [NativeJournalImpactRowModel] = []
        var insufficient: [NativeJournalImpactRowModel] = []
        for insight in insights {
            let row = NativeJournalImpactRowModel.make(insight)
            if insight.recovery?.verdict.isClear == true {
                clear.append(row)
            } else if insight.recovery != nil {
                unclear.append(row)
            } else {
                insufficient.append(row)
            }
        }
        return NativeJournalImpactModel(clear: clear, unclear: unclear, insufficient: insufficient)
    }
}

struct NativeJournalImpactRowModel: Identifiable, Equatable {
    var id: String { behaviorId }
    var behaviorId: String
    var title: String
    var effectText: String?
    var caption: String
    var sleepText: String?
    var sentence: String
    var tintHelps: Bool?

    static func make(_ insight: JournalImpact.Insight) -> NativeJournalImpactRowModel {
        let title = NativeJournalImpactCopy.title(for: insight.behaviorId)
        if let recovery = insight.recovery, recovery.verdict.isClear {
            let sleepLine: String?
            if let sleep = insight.sleep, sleep.verdict.isClear {
                sleepLine = NativeJournalImpactCopy.sleepText(sleep.effect)
            } else {
                sleepLine = nil
            }
            return NativeJournalImpactRowModel(
                behaviorId: insight.behaviorId,
                title: title,
                effectText: NativeJournalImpactCopy.effectText(recovery.effect),
                caption: NativeJournalImpactCopy.sampleCaption(
                    verdict: recovery.verdict, nYes: recovery.nYes, nNo: recovery.nNo
                ),
                sleepText: sleepLine,
                sentence: NativeJournalImpactCopy.recoverySentence(title: title, effect: recovery.effect),
                tintHelps: recovery.verdict == .helps
            )
        }
        if let recovery = insight.recovery {
            return NativeJournalImpactRowModel(
                behaviorId: insight.behaviorId,
                title: title,
                effectText: nil,
                caption: NativeJournalImpactCopy.sampleCaption(
                    verdict: .unclear, nYes: recovery.nYes, nNo: recovery.nNo
                ),
                sleepText: nil,
                sentence: "No clear effect yet after days with \(title.lowercased())",
                tintHelps: nil
            )
        }
        return NativeJournalImpactRowModel(
            behaviorId: insight.behaviorId,
            title: title,
            effectText: nil,
            caption: NativeJournalImpactCopy.needCaption(
                needYes: insight.neededYes, needNo: insight.neededNo
            ),
            sleepText: nil,
            sentence: NativeJournalImpactCopy.needCaption(
                needYes: insight.neededYes, needNo: insight.neededNo
            ),
            tintHelps: nil
        )
    }
}

struct NativeJournalImpactRow: View {
    var row: NativeJournalImpactRowModel
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.title)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let effectText = row.effectText {
                    Text(effectText)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(valueTint)
                        .monospacedDigit()
                }
            }
            if !row.caption.isEmpty {
                Text(row.caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let sleepText = row.sleepText {
                Text(sleepText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.sentence)
    }

    private var valueTint: Color {
        guard let helps = row.tintHelps else { return .primary }
        if style == .whoop {
            return helps ? NativeTokens.whoopPositiveDelta : NativeTokens.whoopNegativeDelta
        }
        return helps ? NativeTokens.recoveryHigh : NativeTokens.bandPoor
    }
}

import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers
import WhoopStore
import StrandImport

/// Settings → Backup → "Export (WHOOP format)": gather Band's own daily metrics, Band scores,
/// sleeps, workouts and journal via Repository/WhoopStore, then serialize WHOOP's four CSVs
/// through StrandImport.WhoopCsvExporter. Apple Health rows are excluded so a re-import cannot
/// mis-attribute them as WHOOP data. CSV writing stays pure in the package.
///
/// #458: every read goes through the repository's active∪canonical union ids
/// (`importedReadIds`/`computedReadIds`). Per-row dedup keeps the active-first copy.
enum CsvExport {
    enum ExportResult {
        case exported(URL)
        case cancelled
        case failure(String)
    }

    @MainActor
    static func run(repo: Repository) async -> ExportResult {
        guard let store = await repo.storeHandle() else {
            return .failure("Couldn't open the local store.")
        }
        let importedIds = repo.importedReadIds
        let computedIds = repo.computedReadIds
        let fromDay = "0000-01-01", toDay = "9999-12-31"
        let hi = Int(Date().timeIntervalSince1970) + 86_400

        do {
            var importedByDay: [String: DailyMetric] = [:]
            for id in importedIds {
                for d in try await store.dailyMetrics(deviceId: id, from: fromDay, to: toDay)
                where importedByDay[d.day] == nil { importedByDay[d.day] = d }
            }
            var computedByDay: [String: DailyMetric] = [:]
            for id in computedIds {
                for d in try await store.dailyMetrics(deviceId: id, from: fromDay, to: toDay)
                where computedByDay[d.day] == nil { computedByDay[d.day] = d }
            }
            let imported = importedByDay.values.sorted { $0.day < $1.day }
            let computed = computedByDay.values.sorted { $0.day < $1.day }

            var seriesRaw: [String: [MetricPoint]] = [:]
            for key in ["sleep_performance", "sleep_consistency", "sleep_need_min", "sleep_debt_min",
                        "in_bed_min", "awake_min", "energy_kcal", "avg_hr", "max_hr"] {
                var byDay: [String: MetricPoint] = [:]
                for id in importedIds + computedIds {
                    for p in try await store.metricSeries(deviceId: id, key: key, from: fromDay, to: toDay)
                    where byDay[p.day] == nil { byDay[p.day] = p }
                }
                seriesRaw[key] = byDay.values.sorted { $0.day < $1.day }
            }

            var seenSleep = Set<String>(), seenComp = Set<String>()
            var impSleep: [CachedSleepSession] = [], compSleep: [CachedSleepSession] = []
            for id in importedIds {
                for s in try await store.sleepSessions(deviceId: id, from: 0, to: hi, limit: 100_000)
                where seenSleep.insert("\(s.startTs)|\(s.endTs)").inserted { impSleep.append(s) }
            }
            for id in computedIds {
                for s in try await store.sleepSessions(deviceId: id, from: 0, to: hi, limit: 100_000)
                where seenComp.insert("\(s.startTs)|\(s.endTs)").inserted { compSleep.append(s) }
            }
            var seenImpW = Set<String>(), seenCompW = Set<String>()
            var impWorkouts: [WorkoutRow] = [], compWorkouts: [WorkoutRow] = []
            for id in importedIds {
                for w in try await store.workouts(deviceId: id, from: 0, to: hi, limit: 100_000)
                where seenImpW.insert("\(w.startTs)|\(w.sport)").inserted { impWorkouts.append(w) }
            }
            for id in computedIds {
                for w in try await store.workouts(deviceId: id, from: 0, to: hi, limit: 100_000)
                where seenCompW.insert("\(w.startTs)|\(w.sport)").inserted { compWorkouts.append(w) }
            }
            var seenJournal = Set<String>()
            var journal: [JournalEntry] = []
            for id in importedIds + computedIds {
                for j in try await store.journalEntries(deviceId: id, from: fromDay, to: toDay)
                where seenJournal.insert("\(j.day)|\(j.question)").inserted { journal.append(j) }
            }

            var endDayByStartTs: [Int: String] = [:]
            for s in impSleep + compSleep {
                endDayByStartTs[s.startTs] = Repository.localDayKey(
                    Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            }
            let name = defaultName()
            let timeZone = TimeZone.current

            let tmp = try await Task.detached(priority: .utility) {
                var byDay: [String: DailyMetric] = [:]
                for d in computed { byDay[d.day] = d }
                for d in imported { byDay[d.day] = d }
                let days = byDay.values.sorted { $0.day < $1.day }

                var series: [String: [String: Double]] = [:]
                for (key, points) in seriesRaw {
                    for p in points { series[p.day, default: [:]][key] = p.value }
                }

                let endDay: (CachedSleepSession) -> String = { endDayByStartTs[$0.startTs] ?? "" }
                let sleeps = SleepMerge.merge(imported: impSleep, computed: compSleep, endDay: endDay)

                var seenWorkouts = Set<String>()
                let workouts = (impWorkouts + compWorkouts)
                    .filter { seenWorkouts.insert("\($0.startTs)|\($0.sport)").inserted }

                var importedSleep: [String: ImportedSleepFigures] = [:]
                for (day, vals) in series {
                    var fig = ImportedSleepFigures()
                    fig.performancePct = vals["sleep_performance"]
                    fig.consistencyPct = vals["sleep_consistency"]
                    fig.needMin = vals["sleep_need_min"]
                    fig.debtMin = vals["sleep_debt_min"]
                    if fig.performancePct != nil || fig.consistencyPct != nil
                        || fig.needMin != nil || fig.debtMin != nil {
                        importedSleep[day] = fig
                    }
                }
                let scores = NativeBandScores.resolve(
                    days: days, sleeps: sleeps, workouts: workouts, importedSleep: importedSleep)

                let snapshot = assembleWhoop(
                    days: days, series: series, scores: scores,
                    sleeps: sleeps, workouts: workouts, journal: journal,
                    timeZone: timeZone)

                let out = NoopScratch.file(UUID().uuidString + ".zip")
                try WhoopCsvExporter.writeArchive(
                    cycles: snapshot.cycles, sleeps: snapshot.sleeps,
                    workouts: snapshot.workouts, journal: snapshot.journal,
                    to: out)
                return out
            }.value

            #if os(macOS)
            let panel = NSSavePanel()
            panel.title = String(localized: "Export Band data (WHOOP format)")
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = [.zip]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let dest = panel.url else {
                try? FileManager.default.removeItem(at: tmp)
                return .cancelled
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: dest)
            }
            return .exported(dest)
            #else
            let staged = NoopScratch.file(name)
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            try FileManager.default.moveItem(at: tmp, to: staged)
            guard let dest = await DocumentPicker.export(staged) else { return .cancelled }
            return .exported(dest)
            #endif
        } catch {
            return .failure("WHOOP export failed: \(error.localizedDescription)")
        }
    }

    private struct Snapshot {
        var cycles: [WhoopCycleRow]
        var sleeps: [WhoopSleepRow]
        var workouts: [WhoopWorkoutRow]
        var journal: [WhoopJournalRow]
    }

    /// Build WHOOP rows from Band values. Cycle = main-sleep onset → next main-sleep onset.
    private static func assembleWhoop(
        days: [DailyMetric],
        series: [String: [String: Double]],
        scores: NativeBandScores.Snapshot,
        sleeps: [CachedSleepSession],
        workouts: [WorkoutRow],
        journal: [JournalEntry],
        timeZone: TimeZone
    ) -> Snapshot {
        func offset(_ date: Date) -> Int {
            WhoopCsvExporter.offsetMinutes(at: date, timeZone: timeZone)
        }
        func localDay(_ ts: Int) -> String {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(ts)))
        }

        var byWakeDay: [String: [CachedSleepSession]] = [:]
        for s in sleeps {
            byWakeDay[localDay(s.endTs), default: []].append(s)
        }
        var isNap: [Int: Bool] = [:]
        var mains: [CachedSleepSession] = []
        for sessions in byWakeDay.values {
            let ranked = sessions.sorted {
                ($0.endTs - $0.effectiveStartTs) > ($1.endTs - $1.effectiveStartTs)
            }
            guard let main = ranked.first else { continue }
            isNap[main.startTs] = false
            mains.append(main)
            for nap in ranked.dropFirst() { isNap[nap.startTs] = true }
        }
        mains.sort { $0.effectiveStartTs < $1.effectiveStartTs }

        struct Cycle {
            var start: Date
            var end: Date?
            var wakeDay: String
            var tz: Int
            var main: CachedSleepSession?
        }
        var cycles: [Cycle] = []
        if mains.isEmpty {
            for (i, d) in days.enumerated() {
                let start = midnight(d.day, timeZone: timeZone) ?? Date()
                let end = i + 1 < days.count ? midnight(days[i + 1].day, timeZone: timeZone) : nil
                cycles.append(Cycle(start: start, end: end, wakeDay: d.day, tz: offset(start), main: nil))
            }
        } else {
            for (i, s) in mains.enumerated() {
                let start = Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs))
                let end: Date? = i + 1 < mains.count
                    ? Date(timeIntervalSince1970: TimeInterval(mains[i + 1].effectiveStartTs))
                    : nil
                cycles.append(Cycle(start: start, end: end, wakeDay: localDay(s.endTs),
                                    tz: offset(start), main: s))
            }
        }

        let dailyByDay = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0) })
        let windows = cycles.map { (start: $0.start, end: $0.end) }

        func cycleIndex(containing date: Date) -> Int? {
            guard let hit = WhoopCsvExporter.cycleContaining(date, windows: windows) else { return nil }
            return windows.firstIndex { $0.start == hit.start && $0.end == hit.end }
        }

        var cycleRows: [WhoopCycleRow] = []
        for c in cycles {
            let d = dailyByDay[c.wakeDay]
            let s = series[c.wakeDay] ?? [:]
            let scored = NativeBandScores.day(c.wakeDay, in: scores)
            let stages = WhoopCsvExporter.stageMinutes(c.main?.stagesJSON)
            let onset = c.main.map { Date(timeIntervalSince1970: TimeInterval($0.effectiveStartTs)) }
            let wake = c.main.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) }
            let inBed = s["in_bed_min"] ?? c.main.map { Double($0.endTs - $0.effectiveStartTs) / 60.0 }
            let skin: Double? = {
                if let abs = d?.skinTempC { return abs }
                if let v = d?.skinTempDevC, v >= 20 { return v }
                return nil
            }()
            var row = WhoopCycleRow()
            row.tzOffsetMin = c.tz
            row.cycleStart = c.start
            row.cycleEnd = c.end
            row.recoveryScore = scored?.recovery ?? d?.recovery
            row.restingHeartRate = d?.restingHr.map(Double.init)
            row.hrvMs = d?.avgHrv
            row.skinTempCelsius = skin
            row.bloodOxygenPct = d?.spo2Pct
            row.dayStrain = WhoopExportImporter.whoopDayStrainFromEffort(d?.strain)
            row.energyKcal = s["energy_kcal"] ?? d?.activeKcalEst
            row.maxHeartRate = s["max_hr"]
            row.avgHeartRate = s["avg_hr"]
            row.sleepOnset = onset
            row.wakeOnset = wake
            row.sleepPerformancePct = scored?.sleepPerformance ?? s["sleep_performance"]
            row.respiratoryRate = d?.respRateBpm
            row.asleepDurationMin = stages.asleep ?? d?.totalSleepMin
            row.inBedDurationMin = inBed
            row.lightSleepDurationMin = stages.light ?? d?.lightMin
            row.deepSleepDurationMin = stages.deep ?? d?.deepMin
            row.remDurationMin = stages.rem ?? d?.remMin
            row.awakeDurationMin = stages.awake ?? s["awake_min"]
            row.sleepNeedMin = scored?.sleepNeed ?? s["sleep_need_min"]
            row.sleepDebtMin = scored?.sleepDebt ?? s["sleep_debt_min"]
            row.sleepEfficiencyPct = WhoopExportImporter.whoopEfficiencyPctFromFraction(
                c.main?.efficiency ?? d?.efficiency)
            row.sleepConsistencyPct = scored?.sleepConsistency ?? s["sleep_consistency"]
            cycleRows.append(row)
        }

        var sleepRows: [WhoopSleepRow] = []
        for s in sleeps.sorted(by: { $0.effectiveStartTs < $1.effectiveStartTs }) {
            let onset = Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs))
            let wake = Date(timeIntervalSince1970: TimeInterval(s.endTs))
            let idx = cycleIndex(containing: onset)
            let c = idx.map { cycles[$0] }
            let tz = c?.tz ?? offset(onset)
            let nap = isNap[s.startTs] ?? false
            let stages = WhoopCsvExporter.stageMinutes(s.stagesJSON)
            let wakeDay = c?.wakeDay ?? localDay(s.endTs)
            let scored = NativeBandScores.day(wakeDay, in: scores)
            let ser = series[wakeDay] ?? [:]
            var row = WhoopSleepRow()
            row.tzOffsetMin = tz
            row.cycleStart = c?.start ?? onset
            row.cycleEnd = c?.end
            row.sleepOnset = onset
            row.wakeOnset = wake
            row.isNap = nap
            if !nap {
                row.sleepPerformancePct = scored?.sleepPerformance ?? ser["sleep_performance"]
                row.respiratoryRate = dailyByDay[wakeDay]?.respRateBpm
                row.sleepNeedMin = scored?.sleepNeed ?? ser["sleep_need_min"]
                row.sleepDebtMin = scored?.sleepDebt ?? ser["sleep_debt_min"]
                row.sleepConsistencyPct = scored?.sleepConsistency ?? ser["sleep_consistency"]
            }
            row.asleepDurationMin = stages.asleep
            row.inBedDurationMin = s.endTs > s.effectiveStartTs
                ? Double(s.endTs - s.effectiveStartTs) / 60.0 : nil
            row.lightSleepDurationMin = stages.light
            row.deepSleepDurationMin = stages.deep
            row.remDurationMin = stages.rem
            row.awakeDurationMin = stages.awake
            row.sleepEfficiencyPct = WhoopExportImporter.whoopEfficiencyPctFromFraction(s.efficiency)
            sleepRows.append(row)
        }

        var workoutRows: [WhoopWorkoutRow] = []
        for w in workouts.sorted(by: { $0.startTs < $1.startTs }) {
            let start = Date(timeIntervalSince1970: TimeInterval(w.startTs))
            let end = Date(timeIntervalSince1970: TimeInterval(w.endTs))
            let idx = cycleIndex(containing: start)
            let c = idx.map { cycles[$0] }
            let tz = c?.tz ?? offset(start)
            let zones = WhoopCsvExporter.zonePercents(w.zonesJSON)
            var row = WhoopWorkoutRow()
            row.tzOffsetMin = tz
            row.cycleStart = c?.start ?? start
            row.cycleEnd = c?.end
            row.workoutStart = start
            row.workoutEnd = end
            row.durationMin = (w.durationS ?? Double(max(0, w.endTs - w.startTs))) / 60.0
            row.activityName = w.sport
            row.activityStrain = WhoopExportImporter.whoopDayStrainFromEffort(w.strain)
            row.energyKcal = w.energyKcal
            row.maxHeartRate = w.maxHr.map(Double.init)
            row.avgHeartRate = w.avgHr.map(Double.init)
            row.hrZone1Pct = zones?[0]
            row.hrZone2Pct = zones?[1]
            row.hrZone3Pct = zones?[2]
            row.hrZone4Pct = zones?[3]
            row.hrZone5Pct = zones?[4]
            row.gpsEnabled = (w.distanceM ?? 0) > 0
            workoutRows.append(row)
        }

        var journalRows: [WhoopJournalRow] = []
        for e in journal.sorted(by: { ($0.day, $0.question) < ($1.day, $1.question) }) {
            let c = cycles.first { $0.wakeDay == e.day }
            let start = c?.start ?? midnight(e.day, timeZone: timeZone)
            let tz = c?.tz ?? (start.map(offset) ?? 0)
            var row = WhoopJournalRow()
            row.tzOffsetMin = tz
            row.cycleStart = start
            row.cycleEnd = c?.end
            row.question = e.question
            row.answer = e.answeredYes ? "true" : "false"
            row.notes = e.notes
            journalRows.append(row)
        }

        return Snapshot(cycles: cycleRows, sleeps: sleepRows, workouts: workoutRows, journal: journalRows)
    }

    private static func midnight(_ day: String, timeZone: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: day + " 00:00:00")
    }

    @MainActor
    private static func defaultName() -> String {
        "whoop-export-\(Repository.localDayKey(Date())).zip"
    }
}

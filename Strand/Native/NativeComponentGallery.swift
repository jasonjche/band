#if DEBUG
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Hard-coded Native chrome for snapshot iteration. Not shipped; Debug only.
struct NativeComponentGallery: View {
    var body: some View {
        NativeChrome.screen {
            ForEach(NativeGallerySnapshot.sections) { section in
                NativeChrome.section(section.title)
                section.view
            }
        }
        .navigationTitle("Native Gallery")
        .modifier(NativeInlineTitle())
    }
}

struct NativeGallerySnapshot {
    struct Section: Identifiable {
        var id: String { name }
        var name: String
        var title: String
        var padded: Bool = true
        var view: AnyView
    }

    static let weekKeys = [
        "2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12",
        "2026-11-13", "2026-11-14", "2026-11-15",
    ]
    static let highlightKey = "2026-11-15"

    static func points(_ values: [Double?]) -> [NativeDayPoint] {
        zip(weekKeys, values).map { NativeDayPoint(key: $0.0, value: $0.1 ?? .nan) }
    }

    /// 12:37 AM – 8:00 AM on the highlighted day. In bed 7:23; asleep (stages) 6:50.
    static var sleepStart: Date {
        localDate(year: 2026, month: 11, day: 15, hour: 0, minute: 37)
    }
    static var sleepEnd: Date {
        localDate(year: 2026, month: 11, day: 15, hour: 8, minute: 0)
    }

    private static func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func sampleDay(
        day: String,
        strain: Double? = 34,
        recovery: Double = 45,
        sleepMin: Double = 410,
        light: Double? = 250,
        deep: Double? = 70,
        rem: Double? = 90,
        efficiency: Double = 0.925,
        hrv: Double = 66,
        rhr: Int = 51,
        resp: Double = 14.7,
        steps: Int = 6545,
        kcal: Double = 512,
        spo2: Double = 98,
        skin: Double = 34.5
    ) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: sleepMin, efficiency: efficiency,
            deepMin: deep, remMin: rem, lightMin: light,
            disturbances: 2, restingHr: rhr, avgHrv: hrv, recovery: recovery, strain: strain,
            exerciseCount: 1, spo2Pct: spo2, skinTempDevC: 0.1, respRateBpm: resp,
            steps: steps, activeKcalEst: kcal, skinTempC: skin
        )
    }

    static var snapshotDays: [DailyMetric] {
        zip(weekKeys, [
            (82, 40, 8.2, 4120, 400, 58, 52, 14.5),
            (90, 55, 10.1, 8800, 430, 62, 51, 14.6),
            (87, 49, 7.1, 5100, 410, 70, 50, 14.8),
            (nil, nil, nil, nil, nil, nil, nil, nil),
            (91, 62, 12.4, 10210, 440, 64, 51, 14.4),
            (85, 44, 9.0, 7340, 390, 60, 52, 14.6),
            (87, 37, 7.1, 6545, 410, 66, 51, 14.7),
        ] as [(Double?, Double?, Double?, Int?, Double?, Double?, Int?, Double?)]).map { key, row in
            if key == "2026-11-12" {
                return DailyMetric(
                    day: key,
                    totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
                    exerciseCount: nil
                )
            }
            let whoopStrain = row.2 ?? 7.1
            return sampleDay(
                day: key,
                strain: whoopStrain / 0.21,
                recovery: row.1 ?? 45,
                sleepMin: row.4 ?? 410,
                light: key == highlightKey ? 250 : (key == "2026-11-14" ? 220 : nil),
                deep: key == highlightKey ? 70 : (key == "2026-11-14" ? 80 : nil),
                rem: key == highlightKey ? 90 : (key == "2026-11-14" ? 100 : nil),
                hrv: row.5 ?? 66,
                rhr: row.6 ?? 51,
                resp: row.7 ?? 14.7,
                steps: row.3 ?? 6545,
                kcal: key == highlightKey ? 512 : 480
            )
        }
    }

    static var snapshotSleeps: [CachedSleepSession] {
        [
            CachedSleepSession(
                startTs: Int(sleepStart.timeIntervalSince1970),
                endTs: Int(sleepEnd.timeIntervalSince1970),
                efficiency: 92.5, restingHr: 51, avgHrv: 66, stagesJSON: nil
            )
        ]
    }

    static var snapshotWorkouts: [WorkoutRow] {
        let runStart = localDate(year: 2026, month: 11, day: 15, hour: 8, minute: 27)
        let runEnd = localDate(year: 2026, month: 11, day: 15, hour: 8, minute: 55)
        let liftStart = localDate(year: 2026, month: 11, day: 13, hour: 18, minute: 0)
        let liftEnd = localDate(year: 2026, month: 11, day: 13, hour: 18, minute: 40)
        return [
            WorkoutRow(
                startTs: Int(runStart.timeIntervalSince1970),
                endTs: Int(runEnd.timeIntervalSince1970),
                sport: "Running", source: "my-whoop",
                durationS: 28 * 60, energyKcal: 312, avgHr: 168, maxHr: 182,
                strain: 26, distanceM: 5200,
                zonesJSON: #"{"zone1":8,"zone2":22,"zone3":18,"zone4":40,"zone5":12}"#,
                notes: nil, steps: 4200
            ),
            WorkoutRow(
                startTs: Int(liftStart.timeIntervalSince1970),
                endTs: Int(liftEnd.timeIntervalSince1970),
                sport: "Strength", source: "my-whoop",
                durationS: 40 * 60, energyKcal: 220, avgHr: 118, maxHr: 142,
                strain: 18, distanceM: nil,
                zonesJSON: #"{"zone1":40,"zone2":35,"zone3":20,"zone4":5,"zone5":0}"#,
                notes: nil, steps: nil
            ),
        ]
    }

    static var snapshotImported: [String: ImportedSleepFigures] {
        Dictionary(uniqueKeysWithValues: weekKeys.filter { $0 != "2026-11-12" }.map { key in
            (key, ImportedSleepFigures(performancePct: key == highlightKey ? 87 : 85,
                                       consistencyPct: key == highlightKey ? 79 : 82,
                                       needMin: 465, debtMin: 36))
        })
    }

    static var snapshotModel: NativeDay.Model {
        NativeDay.make(
            days: snapshotDays,
            sleeps: snapshotSleeps,
            workouts: snapshotWorkouts,
            todayKey: highlightKey,
            connected: true,
            effortScale: .whoop,
            now: localDate(year: 2026, month: 11, day: 15, hour: 16, minute: 0),
            importedSleep: snapshotImported
        )
    }

    static var sleepBars: [NativeDayPoint] {
        NativeWeek.points(kind: .sleep, days: snapshotDays, todayKey: highlightKey, importedSleep: snapshotImported)
    }
    static var recoveryBars: [NativeDayPoint] {
        NativeWeek.points(kind: .recovery, days: snapshotDays, todayKey: highlightKey, importedSleep: snapshotImported)
    }
    static var strainBars: [NativeDayPoint] {
        NativeWeek.points(kind: .strain, days: snapshotDays, todayKey: highlightKey)
    }
    static var hrvLine: [NativeDayPoint] {
        NativeWeek.series(snapshotDays, todayKey: highlightKey) { $0.avgHrv }
    }

    static var sleepScore: NativeScore { snapshotModel.sleep }
    static var recoveryScore: NativeScore { snapshotModel.recovery }
    static var stages: [NativeStage] { snapshotModel.sleepStages }

    static var overnightHr: [NativeHourPoint] {
        let start = sleepStart
        return stride(from: 0, through: 430, by: 20).map { minute in
            let t = Double(minute)
            let bpm = 54 + 8 * sin(t / 50) + (minute > 360 ? 10 : 0)
            return NativeHourPoint(time: start.addingTimeInterval(t * 60), value: bpm)
        }
    }

    static var sleepWeekCards: [NativeWeek.Card] {
        NativeWeek.cards(
            kind: .sleep, days: snapshotDays, todayKey: highlightKey, importedSleep: snapshotImported
        )
    }

    static var recoveryWeekCards: [NativeWeek.Card] {
        NativeWeek.cards(
            kind: .recovery, days: snapshotDays, todayKey: highlightKey, importedSleep: snapshotImported
        )
    }

    static var sections: [Section] {
        [
            Section(name: "rings", title: "Rings", view: AnyView(rings)),
            Section(name: "card-header", title: "Card Header", view: AnyView(cardHeader)),
            Section(name: "hero", title: "Hero", view: AnyView(hero)),
            Section(name: "sleep-contributors", title: "Sleep Contributors", view: AnyView(sleepContributors)),
            Section(name: "recovery-contributors", title: "Recovery Contributors", view: AnyView(recoveryContributors)),
            Section(name: "bar-chart", title: "Weekly Bar Chart", view: AnyView(barChart)),
            Section(name: "line-chart", title: "Weekly Line Chart", view: AnyView(lineChart)),
            Section(name: "dual-chart", title: "Strain & Recovery", view: AnyView(dualChart)),
            Section(name: "no-data", title: "No data", view: AnyView(noData)),
            Section(name: "inset-row", title: "Inset Row", view: AnyView(insetRow)),
            Section(name: "last-night", title: "Last Night", view: AnyView(lastNight)),
            Section(name: "sleep-week", title: "Sleep Week", view: AnyView(sleepWeek)),
            Section(name: "recovery-week", title: "Recovery Week", view: AnyView(recoveryWeek)),
            Section(name: "strain-week", title: "Strain Week", view: AnyView(strainWeek)),
            Section(name: "sleep-page", title: "Sleep Page", padded: false, view: AnyView(sleepPage)),
            Section(name: "sleep-page-empty", title: "Sleep Page Empty", padded: false, view: AnyView(sleepPageEmpty)),
            Section(name: "recovery-page", title: "Recovery Page", padded: false, view: AnyView(recoveryPage)),
            Section(name: "strain-page", title: "Strain Page", padded: false, view: AnyView(strainPage)),
            Section(name: "activity-page", title: "Activity Page", padded: false, view: AnyView(activityPage)),
        ]
    }

    static var strainScore: NativeScore { snapshotModel.strain }

    static var strainWeekCards: [NativeWeek.Card] {
        NativeWeek.cards(
            kind: .strain, days: snapshotDays, todayKey: highlightKey, workouts: snapshotWorkouts
        )
    }

    private static var strainPage: some View {
        NativeScoreView(
            score: strainScore,
            weekCards: strainWeekCards,
            kind: .strain,
            activities: snapshotModel.activities,
            dayKey: highlightKey,
            scrolls: false
        )
    }

    static var activityModel: NativeActivityPageLogic.Model {
        NativeActivityPageLogic.make(
            snapshotWorkouts[0],
            prior: snapshotWorkouts + activityPriorRuns,
            scale: .whoop,
            zoneSet: HRZones.zones(maxHR: 190),
            percents: WorkoutZones.percents(snapshotWorkouts[0].zonesJSON)
        )
    }

    private static var activityPriorRuns: [WorkoutRow] {
        (1...3).map { offset in
            WorkoutRow(
                startTs: snapshotWorkouts[0].startTs - offset * 86_400,
                endTs: snapshotWorkouts[0].endTs - offset * 86_400,
                sport: "Running", source: "my-whoop",
                durationS: 28 * 60, energyKcal: 280, avgHr: 154, maxHr: 176,
                strain: 22, distanceM: 5000,
                zonesJSON: snapshotWorkouts[0].zonesJSON,
                notes: nil, steps: 4000
            )
        }
    }

    static var activityHr: [NativeHourPoint] {
        let start = Date(timeIntervalSince1970: 1_763_297_220)
        return stride(from: 0, through: 28, by: 1).map { minute in
            let t = Double(minute)
            let bpm = 110 + 60 * (1 - exp(-t / 4)) + 6 * sin(t / 3)
            return NativeHourPoint(time: start.addingTimeInterval(t * 60), value: bpm)
        }
    }

    private static var activityPage: some View {
        NativeActivityBody(
            model: activityModel,
            hr: activityHr,
            zoneSet: HRZones.zones(maxHR: 190),
            scrolls: false
        )
    }

    private static var rings: some View {
        HStack(alignment: .top, spacing: 24) {
            NativeRing(fraction: 0.87, tint: NativeTokens.sleep, value: "87%", caption: "Sleep", diameter: 104)
            NativeRing(fraction: 0.87, tint: NativeTokens.sleep, value: "87%", caption: "Sleep Performance", diameter: 184)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private static var cardHeader: some View {
        NativeChrome.panel {
            NativeCardHeader(
                title: "Heart Rate Variability",
                symbol: "waveform.path.ecg",
                tint: NativeTokens.heart,
                trailing: "Today",
                chevron: true
            )
        }
    }

    private static var hero: some View {
        NativeChrome.panel {
            NativeHeroValue(caption: "Average", value: "66", unit: "BPM", date: "Nov 9–15, 2026")
        }
    }

    private static var sleepContributors: some View { GallerySleepContributors() }

    private static var recoveryContributors: some View { GalleryRecoveryContributors() }

    private static var barChart: some View {
        NativeChrome.panel {
            NativeCardHeader(title: "Sleep Performance", symbol: "bed.double.fill", tint: NativeTokens.sleep)
            NativeChartBlock(
                points: sleepBars, bars: true, tint: NativeTokens.sleep,
                format: { "\(Int($0.rounded()))" }, axisFormat: { "\(Int($0.rounded()))" },
                unit: "%", maxY: 100,
                highlightKey: highlightKey, plotHeight: 200,
                accessibilityName: "Sleep Performance"
            )
        }
    }

    private static var lineChart: some View {
        NativeChrome.panel {
            NativeCardHeader(title: "Heart Rate Variability", symbol: "waveform.path.ecg", tint: NativeTokens.heart)
            NativeChartBlock(
                points: hrvLine, bars: false, tint: NativeTokens.heart,
                format: { "\(Int($0.rounded()))" }, unit: "ms", maxY: 80,
                highlightKey: highlightKey, plotHeight: 200, accessibilityName: "HRV"
            )
        }
    }

    private static var dualChart: some View {
        NativeChrome.panel {
            NativeCardHeader(title: "Strain & Recovery", symbol: "chart.xyaxis.line", tint: NativeTokens.strain)
            NativeStrainRecoveryChart(
                recovery: recoveryBars, strain: strainBars,
                highlightKey: highlightKey, showsHero: true
            )
            .frame(minHeight: 240)
        }
    }

    private static var noData: some View {
        NativeChrome.panel {
            NativeHeroValue(value: "No data", date: "Nov 16, 2026")
        }
    }

    private static var insetRow: some View {
        NativeChrome.panel {
            NativeContributorRow(
                symbol: "waveform.path.ecg",
                title: "HRV",
                value: "66 ms",
                prior: "60 ms",
                delta: .up,
                tint: NativeTokens.heart
            )
        }
    }

    private static var lastNight: some View {
        NativeLastNightCard(
            asleepMinutes: snapshotModel.asleepMinutes,
            sleepHours: snapshotModel.sleepHours,
            stages: stages,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            awakeTypical: snapshotModel.awakeTypical,
            needMinutes: 465,
            debtMinutes: 36
        )
    }

    private static var sleepWeek: some View { GallerySleepWeek() }
    private static var recoveryWeek: some View { GalleryRecoveryWeek() }
    private static var strainWeek: some View { GalleryStrainWeek() }

    private static var sleepPage: some View {
        NativeScoreView(
            score: sleepScore,
            weekCards: sleepWeekCards,
            kind: .sleep,
            sleepHours: snapshotModel.sleepHours,
            asleepMinutes: snapshotModel.asleepMinutes,
            stages: stages,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            overnightHr: overnightHr,
            awakeTypical: snapshotModel.awakeTypical,
            dayKey: highlightKey,
            needMinutes: snapshotModel.sleepNeedMin,
            debtMinutes: snapshotModel.sleepDebtMin,
            scrolls: false,
            sleepDetail: NativeSleepSnapshot.pageDetail
        )
    }

    private static var emptySleepScore: NativeScore {
        NativeScore(
            name: "Sleep",
            value: "—",
            known: false,
            fraction: nil,
            tint: NativeTokens.sleep,
            rows: [],
            insight: "",
            route: .sleep
        )
    }

    private static var sleepPageEmpty: some View {
        NativeScoreView(
            score: emptySleepScore,
            weekCards: [],
            kind: .sleep,
            dayKey: highlightKey,
            scrolls: false
        )
    }

    private static var recoveryPage: some View {
        NativeScoreView(
            score: recoveryScore,
            weekCards: recoveryWeekCards,
            kind: .recovery,
            dayKey: highlightKey,
            scrolls: false
        )
    }
}

private struct GalleryRecoveryContributors: View {
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            VStack(spacing: 0) {
                ForEach(Array(NativeGallerySnapshot.recoveryScore.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 34) }
                    NativeContributorRow(
                        symbol: row.symbol,
                        title: row.title,
                        value: row.value,
                        prior: row.prior,
                        delta: row.delta,
                        tint: row.title.contains("Sleep") ? NativePaint.sleep(style) : NativePaint.heart(style),
                        valueTint: row.title.contains("Sleep")
                            ? NativePaint.sleepBand(NativeScoreMath.percentValue(row.value) ?? 0, style: style)
                            : .primary
                    )
                }
            }
        }
    }
}

private struct GallerySleepContributors: View {
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            VStack(spacing: 0) {
                ForEach(Array(NativeGallerySnapshot.sleepScore.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 34) }
                    NativeContributorRow(
                        symbol: row.symbol,
                        title: row.title,
                        value: row.value,
                        prior: NativeScoreMath.hasValue(row.prior) ? row.prior : nil,
                        delta: row.delta,
                        tint: NativePaint.sleep(style),
                        valueTint: NativePaint.sleepBand(NativeScoreMath.percentValue(row.value) ?? 0, style: style)
                    )
                }
            }
        }
    }
}

private struct GallerySleepWeek: View {
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(spacing: 10) {
            ForEach(NativeGallerySnapshot.sleepWeekCards) { card in
                NativeChrome.panel {
                    NativeCardHeader(title: card.title, symbol: "bed.double.fill", tint: NativePaint.sleep(style))
                    NativeChartBlock(
                        points: card.points, bars: card.bars, tint: NativePaint.sleep(style),
                        format: { card.format == .percent ? "\(Int($0.rounded()))%" : NativeScoreMath.duration($0) },
                        unit: card.format == .percent ? "%" : nil,
                        maxY: card.maxY,
                        color: card.band ? { NativePaint.sleepBand($0, style: style) } : nil,
                        highlightKey: NativeGallerySnapshot.highlightKey, plotHeight: 200,
                        accessibilityName: card.title,
                        clockHero: card.format == .duration
                    )
                }
            }
        }
    }
}

private struct GalleryRecoveryWeek: View {
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(spacing: 10) {
            ForEach(NativeGallerySnapshot.recoveryWeekCards) { card in
                NativeChrome.panel {
                    NativeCardHeader(
                        title: card.title,
                        symbol: card.title == "Recovery" ? "heart.fill" : "waveform.path.ecg",
                        tint: card.title == "Recovery" ? NativePaint.recovery(style) : NativePaint.heart(style)
                    )
                    NativeChartBlock(
                        points: card.points, bars: card.bars,
                        tint: card.title == "Recovery" ? NativePaint.recovery(style) : NativePaint.heart(style),
                        format: { card.format == .percent ? "\(Int($0.rounded()))%" : "\(Int($0.rounded()))" },
                        unit: card.format == .percent ? "%" : "ms",
                        maxY: card.maxY,
                        color: card.band ? { NativePaint.recoveryBand($0, style: style) } : nil,
                        highlightKey: NativeGallerySnapshot.highlightKey, plotHeight: 200,
                        accessibilityName: card.title
                    )
                }
            }
        }
    }
}

private struct GalleryStrainWeek: View {
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(spacing: 10) {
            HomeActivitiesCard(items: HomeSnapshot.activities, onSleep: {}, onActivity: { _ in })
            NativeChrome.panel {
                NativeCardHeader(title: "Strain", symbol: "bolt.fill", tint: NativePaint.strain(style))
                NativeChartBlock(
                    points: NativeGallerySnapshot.strainBars, bars: true, tint: NativePaint.strain(style),
                    format: { String(format: "%.1f", $0) }, maxY: 21,
                    highlightKey: NativeGallerySnapshot.highlightKey, plotHeight: 200, accessibilityName: "Strain",
                    yTicks: NativeDayLogic.strainYTicks(maxY: 21)
                )
            }
        }
    }
}
#endif

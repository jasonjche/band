#if DEBUG
import SwiftUI
import StrandDesign
import StrandAnalytics

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

    static var sleepBars: [NativeDayPoint] { points([82, 90, 87, nil, 91, 85, 87]) }
    static var recoveryBars: [NativeDayPoint] { points([40, 55, 49, nil, 62, 44, 37]) }
    static var strainBars: [NativeDayPoint] { points([8.2, 10.1, 7.1, nil, 12.4, 9.0, 7.1]) }
    static var hrvLine: [NativeDayPoint] { points([58, 62, 70, nil, 64, 60, 66]) }

    static var sleepScore: NativeScore {
        NativeScore(
            name: "Sleep",
            value: "87%",
            known: true,
            fraction: 0.87,
            tint: NativeTokens.sleep,
            rows: [
                NativeScore.Row(
                    title: "Hours vs. Needed", value: "89%", prior: "93%",
                    symbol: "clock", delta: .down, route: .metric("hours_vs_needed_pct")
                ),
                NativeScore.Row(
                    title: "Sleep Consistency", value: "79%", prior: "82%",
                    symbol: "calendar", delta: .down, route: .metric("sleep_consistency")
                ),
                NativeScore.Row(
                    title: "Sleep Efficiency", value: "87%", prior: "90%",
                    symbol: "bed.double", delta: .down, route: .metric("sleep_efficiency")
                ),
            ],
            insight: "",
            route: .sleep
        )
    }

    static var recoveryScore: NativeScore {
        NativeScore(
            name: "Recovery",
            value: "37%",
            known: true,
            fraction: 0.37,
            tint: NativeTokens.recoveryBand(37),
            rows: [
                NativeScore.Row(
                    title: "Heart Rate Variability", value: "66 ms", prior: "60 ms",
                    symbol: "waveform.path.ecg", delta: .up, route: .metric("hrv")
                ),
                NativeScore.Row(
                    title: "Resting Heart Rate", value: "51 BPM", prior: "52 BPM",
                    symbol: "heart", delta: .down, route: .metric("resting_hr")
                ),
                NativeScore.Row(
                    title: "Respiratory Rate", value: "14.7 rpm", prior: "14.5 rpm",
                    symbol: "lungs", delta: .flat, route: .metric("resp_rate")
                ),
                NativeScore.Row(
                    title: "Sleep Performance", value: "87%", prior: "85%",
                    symbol: "moon", delta: .up, route: .sleep
                ),
            ],
            insight: "",
            route: .metric("recovery")
        )
    }

    static var stages: [NativeStage] {
        [
            NativeStage(name: "Awake", minutes: 79, typical: 55, tint: NativeTokens.sleepAwake),
            NativeStage(name: "Light", minutes: 250, typical: 220, tint: NativeTokens.sleepCore),
            NativeStage(name: "Deep", minutes: 70, typical: 80, tint: NativeTokens.sleepDeep),
            NativeStage(name: "REM", minutes: 90, typical: 100, tint: NativeTokens.sleepREM),
        ]
    }

    static var overnightHr: [NativeHourPoint] {
        let start = Date(timeIntervalSince1970: 1_763_276_400)
        return stride(from: 0, through: 480, by: 20).map { minute in
            let t = Double(minute)
            let bpm = 54 + 8 * sin(t / 50) + (minute > 400 ? 10 : 0)
            return NativeHourPoint(time: start.addingTimeInterval(t * 60), value: bpm)
        }
    }

    static var sleepStart: Date { Date(timeIntervalSince1970: 1_763_276_400) }
    static var sleepEnd: Date { Date(timeIntervalSince1970: 1_763_307_000) }

    static var sleepWeekCards: [NativeWeek.Card] {
        [
            NativeWeek.Card(
                title: "Sleep Performance", points: sleepBars, maxY: 100, bars: true,
                tint: NativeChrome.sleep, route: nil, format: .percent, band: true
            ),
            NativeWeek.Card(
                title: "Hours of Sleep",
                points: points([400, 430, 410, nil, 440, 390, 431]),
                maxY: 480, bars: true, tint: NativeChrome.sleep,
                route: .metric("hours_vs_needed_pct"), format: .duration, band: false
            ),
        ]
    }

    static var recoveryWeekCards: [NativeWeek.Card] {
        [
            NativeWeek.Card(
                title: "Recovery", points: recoveryBars, maxY: 100, bars: true,
                tint: NativeChrome.recovery, route: nil, format: .percent, band: true
            ),
            NativeWeek.Card(
                title: "Heart Rate Variability", points: hrvLine, maxY: 80, bars: false,
                tint: NativeChrome.heart, route: .metric("hrv"), format: .number, band: false
            ),
        ]
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
            Section(name: "no-data", title: "No Data", view: AnyView(noData)),
            Section(name: "inset-row", title: "Inset Row", view: AnyView(insetRow)),
            Section(name: "last-night", title: "Last Night", view: AnyView(lastNight)),
            Section(name: "sleep-week", title: "Sleep Week", view: AnyView(sleepWeek)),
            Section(name: "recovery-week", title: "Recovery Week", view: AnyView(recoveryWeek)),
            Section(name: "strain-week", title: "Strain Week", view: AnyView(strainWeek)),
            Section(name: "sleep-page", title: "Sleep Page", padded: false, view: AnyView(sleepPage)),
            Section(name: "recovery-page", title: "Recovery Page", padded: false, view: AnyView(recoveryPage)),
            Section(name: "strain-page", title: "Strain Page", padded: false, view: AnyView(strainPage)),
            Section(name: "activity-page", title: "Activity Page", padded: false, view: AnyView(activityPage)),
        ]
    }

    static var strainScore: NativeScore {
        NativeScore(
            name: "Strain",
            value: "7.1",
            known: true,
            fraction: 7.1 / 21,
            tint: NativeTokens.strain,
            rows: [
                NativeScore.Row(
                    title: "Steps", value: "6545", prior: "5120",
                    symbol: "figure.walk", delta: .up, route: .metric("steps")
                ),
            ],
            insight: "",
            route: .metric("strain")
        )
    }

    static var strainWeekCards: [NativeWeek.Card] {
        [
            NativeWeek.Card(
                title: "Strain", points: strainBars, maxY: 21, bars: true,
                tint: NativeChrome.strain, route: nil, format: .strain, band: false
            ),
        ]
    }

    private static var strainPage: some View {
        NativeScoreView(
            score: strainScore,
            weekCards: strainWeekCards,
            kind: .strain,
            activities: [
                NativeDay.Activity(
                    startTs: 1,
                    sport: "Running",
                    strainText: "13.6",
                    timeRange: "8:27 AM – 8:55 AM",
                    startClock: "8:27 AM",
                    endClock: "8:55 AM",
                    symbol: "figure.run"
                ),
            ],
            dayKey: highlightKey,
            scrolls: false
        )
    }

    static var activityModel: NativeActivity.Model {
        NativeActivity.Model(
            sport: "Running",
            symbol: "figure.run",
            timeRange: "8:27 AM – 8:55 AM",
            strainText: "13.6",
            strainDelta: .up,
            duration: "0:28:30",
            zones: [
                NativeActivity.Zone(zone: 1, minutes: 0.1, label: "Zone 1"),
                NativeActivity.Zone(zone: 2, minutes: 1.7, label: "Zone 2"),
                NativeActivity.Zone(zone: 3, minutes: 5.0, label: "Zone 3"),
                NativeActivity.Zone(zone: 4, minutes: 20.5, label: "Zone 4"),
                NativeActivity.Zone(zone: 5, minutes: 0.02, label: "Zone 5"),
            ],
            stats: [
                NativeActivity.Stat(title: "Calories", value: "312 kcal", comparison: "vs 280", symbol: "flame"),
                NativeActivity.Stat(title: "Avg HR", value: "168 BPM", comparison: "vs 154", symbol: "heart"),
            ],
            hasRoute: false
        )
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
                color: NativeChrome.sleepBand, highlightKey: highlightKey, plotHeight: 200,
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
            NativeHeroValue(value: "No Data", date: "Nov 16, 2026")
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
            asleepMinutes: 431,
            stages: stages,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            overnightHr: overnightHr,
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
            asleepMinutes: 431,
            stages: stages,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            overnightHr: overnightHr,
            dayKey: highlightKey,
            needMinutes: 465,
            debtMinutes: 36,
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
                            : .primary,
                        showsBand: false
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
                        prior: row.prior,
                        delta: row.delta,
                        tint: NativePaint.sleep(style),
                        valueTint: NativePaint.sleepBand(NativeScoreMath.percentValue(row.value) ?? 0, style: style),
                        showsBand: NativeScoreMath.attachedPercent(row.value).hasSuffix("%")
                    )
                }
                NativeWhoopBandLegend()
                    .padding(.top, 12)
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
                        accessibilityName: card.title
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
                    highlightKey: NativeGallerySnapshot.highlightKey, plotHeight: 200, accessibilityName: "Strain"
                )
            }
        }
    }
}
#endif

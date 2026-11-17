import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

/// WHOOP Health Monitor: live HR hero, calibration banner, two-column vital tiles.
/// Home's tile reads `NativeHealthRange.summary` — the same counts as this page.
struct NativeHealthMonitorPage: View {
    @Environment(\.nativeNavigationPath) private var path
    @AppStorage(NativeDaySelection.storageKey) private var selectedDayKey = ""
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @State private var repoHandle: Repository?
    @State private var profileHandle: ProfileStore?
    @State private var refreshSeq = 0
    @State private var handlesReady = false
    @State private var report = NativeHealthRange.Report(vitals: [])
    @State private var firstDay: String?
    @State private var zoneSet: HRZoneSet?
    @State private var storedSpark: [NativeHourPoint] = []
    @State private var liveBpm: Int?
    @State private var liveSamples: [NativeHourPoint] = []

    private var temperature: TemperatureUnit {
        UnitPrefs.resolveTemperature(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: temperatureRaw
        )
    }

    private var selectedDay: Date {
        get { NativeDaySelection.date(from: selectedDayKey) }
        nonmutating set { selectedDayKey = NativeDaySelection.key(from: newValue) }
    }

    private var dayKey: String { NativeDayLogic.resolvedDayKey(stored: selectedDayKey) }

    private var viewingToday: Bool { dayKey == NativeDayLogic.logicalToday() }

    private var taskID: String {
        handlesReady ? "\(dayKey)|\(refreshSeq)|\(temperature.rawValue)" : "boot"
    }

    var body: some View {
        NativeChrome.screen {
            NativeHealthMonitorBody(
                report: report,
                selectedDay: selectedDay,
                firstDay: firstDay,
                spark: sparkPoints,
                bpm: displayBpm,
                readingTime: readingTime,
                live: liveBpm != nil && viewingToday,
                zone: displayZone,
                nightsWorn: NativeHealthMonitorMath.nightsWorn(days: repoHandle?.days ?? [], todayKey: dayKey),
                onBack: { shiftDay(-1) },
                onForward: { shiftDay(1) },
                onSelect: { path.wrappedValue.append($0) },
                onOpenHeartRate: { path.wrappedValue.append(NativeHeartRateRoute()) }
            )
        }
        .navigationTitle("Health Monitor")
        .modifier(NativeInlineTitle())
        .navigationDestination(for: NativeHeartRateRoute.self) { _ in
            NativeHeartRatePage()
        }
        .background {
            NativeRepoSink(refreshSeq: $refreshSeq, ready: $handlesReady) { repoHandle = $0 }
            NativeProfileSink { profileHandle = $0 }
            if viewingToday {
                NativeLiveHRArm(bpm: $liveBpm, samples: $liveSamples)
            }
        }
        .task(id: taskID) {
            guard handlesReady, let repo = repoHandle else { return }
            firstDay = repo.days.first?.day
            report = NativeHealthRange.report(days: repo.days, todayKey: dayKey, temperature: temperature)
            let restingHR = HRZones.medianRestingHR(repo.days.compactMap(\.restingHr))
            zoneSet = profileHandle?.displayZoneSet(restingHR: restingHR)
            await loadStoredHR(repo: repo)
        }
        .onChangeCompat(of: dayKey) { key in
            if key != NativeDayLogic.logicalToday() {
                liveBpm = nil
                liveSamples = []
            }
        }
    }

    private var sparkPoints: [NativeHourPoint] {
        if storedSpark.isEmpty, viewingToday {
            return NativeHeartRateMath.spark(
                from: liveSamples,
                now: liveSamples.last?.time ?? Date()
            )
        }
        return NativeHeartRateMath.appendLive(
            storedSpark,
            bpm: viewingToday ? liveBpm : nil,
            at: liveSamples.last?.time ?? Date()
        )
    }

    private var displayBpm: Int? {
        if viewingToday, let liveBpm { return liveBpm }
        return storedSpark.last.map { Int($0.value.rounded()) }
    }

    private var readingTime: Date? {
        if viewingToday, liveBpm != nil { return liveSamples.last?.time }
        return storedSpark.last?.time
    }

    private var displayZone: Int? {
        guard let bpm = displayBpm, let zoneSet else { return nil }
        return zoneSet.zoneNumber(forBPM: Double(bpm))
    }

    private func loadStoredHR(repo: Repository) async {
        let start = Calendar.current.startOfDay(for: selectedDay)
        let from = Int(start.timeIntervalSince1970)
        let now = Date()
        let end = min(from + 86_400, Int(now.timeIntervalSince1970))
        let buckets = await repo.hrSamples(from: from, to: end, bucketSeconds: 60)
        if Task.isCancelled { return }
        let raw = buckets.map {
            NativeHourPoint(time: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm)
        }
        let windowEnd = Date(timeIntervalSince1970: TimeInterval(end))
        storedSpark = await Task.detached(priority: .utility) {
            NativeHeartRateMath.spark(from: raw, now: windowEnd)
        }.value
    }

    private func shiftDay(_ delta: Int) {
        guard let next = HomeDayNav.shift(from: selectedDay, delta: delta, firstDay: firstDay) else { return }
        selectedDay = next
    }
}

struct NativeHealthMonitorBody: View {
    var report: NativeHealthRange.Report
    var selectedDay: Date
    var firstDay: String?
    var spark: [NativeHourPoint] = []
    var bpm: Int? = nil
    var readingTime: Date? = nil
    var live: Bool = false
    var zone: Int? = nil
    var nightsWorn: Int = 0
    var onBack: () -> Void
    var onForward: () -> Void
    var onSelect: (TabRoute) -> Void
    var onOpenHeartRate: () -> Void = {}

    private var dayKey: String { Repository.localDayKey(selectedDay) }
    private var slots: [NativeHealthMonitorMath.Slot] {
        NativeHealthMonitorMath.slots(from: report)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
            HomeDateStepper(
                title: HomeDayTitle.text(for: selectedDay),
                canGoBack: HomeDayNav.canGoBack(selectedKey: dayKey, firstDay: firstDay),
                canGoForward: HomeDayNav.canGoForward(selectedKey: dayKey),
                onBack: onBack,
                onForward: onForward
            )
            .frame(maxWidth: .infinity)
            .padding(.top, NoopMetrics.space4)

            Button(action: onOpenHeartRate) {
                NativeHealthMonitorHero(
                    bpm: bpm,
                    spark: spark,
                    zone: zone,
                    live: live,
                    readingTime: readingTime
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the day’s heart rate chart")

            if let remaining = NativeHealthMonitorMath.nightsRemaining(worn: nightsWorn) {
                NativeHealthMonitorCalibrationBanner(remaining: remaining, worn: nightsWorn)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: NoopMetrics.space3),
                    GridItem(.flexible(), spacing: NoopMetrics.space3),
                ],
                spacing: NoopMetrics.space3
            ) {
                ForEach(slots) { slot in
                    Button { onSelect(slot.route) } label: {
                        NativeHealthMonitorTile(slot: slot)
                    }
                    .buttonStyle(.plain)
                    .gridCellColumns(slot.columnSpan)
                }
            }
        }
    }
}

/// Heart-rate hero: icon, bpm, zone, spark to a now-dot. Tokens only.
private struct NativeHealthMonitorHero: View {
    var bpm: Int?
    var spark: [NativeHourPoint]
    var zone: Int?
    var live: Bool
    var readingTime: Date?
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            Text("Heart Rate")
                .font(style == .whoop ? NativeTokens.whoopCaps(11) : .caption.weight(.medium))
                .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Image(systemName: "heart.fill")
                        .font(.title3)
                        .foregroundStyle(NativePaint.heart(style))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(bpm.map { "\($0)" } ?? "—")
                            .font(NativePaint.number(style == .whoop ? 40 : 34, style: style))
                            .monospacedDigit()
                        Text("BPM")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let zone {
                        Text(NativeHealthMonitorMath.zoneLabel(zone))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(NativeTokens.hrZone(zone))
                    }
                    if !live, let readingTime {
                        Text("Last reading \(NativeScopeFormat.time(readingTime))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                NativeHealthMonitorSpark(points: spark, live: live, tint: NativePaint.heart(style))
                    .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        var parts = ["Heart Rate"]
        if let bpm { parts.append("\(bpm) BPM") }
        if let zone { parts.append(NativeHealthMonitorMath.zoneLabel(zone)) }
        if !live, let readingTime {
            parts.append("Last reading \(NativeScopeFormat.time(readingTime))")
        }
        return parts.joined(separator: ", ")
    }
}

private struct NativeHealthMonitorSpark: View {
    var points: [NativeHourPoint]
    var live: Bool
    var tint: Color

    private var xDomain: ClosedRange<Date> {
        NativeHeartRateMath.sparkXDomain(points: points)
    }

    private var yDomain: ClosedRange<Double> {
        NativeHeartRateMath.fittedDomain(points.map(\.value))
    }

    private var plot: [NativeHourPoint] {
        NativeHeartRateMath.clippedPlot(points, xDomain: xDomain, yDomain: yDomain)
    }

    var body: some View {
        Chart {
            ForEach(plot) { point in
                LineMark(x: .value("Time", point.time), y: .value("BPM", point.value))
                    .foregroundStyle(tint)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .accessibilityHidden(true)
            }
            if let last = plot.last,
               last.time >= xDomain.lowerBound, last.time <= xDomain.upperBound {
                PointMark(x: .value("Now", last.time), y: .value("BPM", last.value))
                    .foregroundStyle(tint)
                    .symbol { NativeSelectedVertex(tint: tint, size: live ? 8 : 6) }
                    .accessibilityHidden(true)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartPlotStyle { $0.clipped() }
        .accessibilityHidden(true)
    }
}

private struct NativeHealthMonitorCalibrationBanner: View {
    var remaining: Int
    var worn: Int
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            Text(NativeHealthMonitorMath.calibrationCaption(remaining: remaining))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NoopMetrics.space1) {
                ForEach(0..<NativeHealthMonitorMath.calibrateNights, id: \.self) { index in
                    Capsule()
                        .fill(index < worn ? NativeTokens.heart : NativeTokens.heart.opacity(0.22))
                        .frame(height: 4)
                }
            }
            .padding(.top, NoopMetrics.space2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NativeHealthMonitorMath.calibrationCaption(remaining: remaining))
    }
}

private struct NativeHealthMonitorTile: View {
    var slot: NativeHealthMonitorMath.Slot
    @Environment(\.nativeStyle) private var style

    var body: some View {
        NativeChrome.panel {
            HStack(spacing: 6) {
                Image(systemName: slot.symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(slot.heartFamily ? NativePaint.heart(style) : NativePaint.respiratory(style))
                Text(slot.title)
                    .font(style == .whoop ? NativeTokens.whoopCaps(11) : .caption.weight(.semibold))
                    .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(slot.valueText)
                    .font(NativePaint.number(style == .whoop ? 28 : 24, style: style))
                    .monospacedDigit()
                if let unit = slot.unit, slot.hasValue {
                    Text(unit)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            NativeHealthMonitorChip(text: slot.chip, tint: slot.chipTint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(slot.accessibility)
    }
}

private struct NativeHealthMonitorChip: View {
    var text: String
    var tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.top, NoopMetrics.space1)
    }
}

/// Layout and copy for the Health Monitor page. Pure; views never fold this in `body`.
enum NativeHealthMonitorMath {
    static let calibrateNights = 7

    struct Spec {
        var id: String
        var title: String
        var symbol: String
        var unit: String
        var heartFamily: Bool
        var route: TabRoute
        var tileUnit: String
    }

    /// WHOOP order: Respiratory Rate, SpO₂, RHR, HRV, Skin Temp.
    static let specs: [Spec] = [
        Spec(id: "resp", title: "Respiratory Rate", symbol: "lungs.fill",
             unit: "breaths/min", heartFamily: false, route: .metric("resp_rate"), tileUnit: "rpm"),
        Spec(id: "spo2", title: "Blood Oxygen (SpO₂)", symbol: "drop.fill",
             unit: "%", heartFamily: true, route: .metric("spo2"), tileUnit: "%"),
        Spec(id: "rhr", title: "RHR", symbol: "heart.fill",
             unit: "BPM", heartFamily: true, route: .metric("rhr"), tileUnit: "bpm"),
        Spec(id: "hrv", title: "HRV", symbol: "waveform.path.ecg",
             unit: "ms", heartFamily: true, route: .metric("hrv"), tileUnit: "ms"),
        Spec(id: "skin", title: "Skin temp", symbol: "thermometer.medium",
             unit: "°C", heartFamily: true, route: .metric("skin_temp"), tileUnit: "°C"),
    ]

    struct Slot: Identifiable, Equatable {
        var id: String
        var title: String
        var symbol: String
        var valueText: String
        var unit: String?
        var hasValue: Bool
        var chip: String
        var chipTintName: String
        var heartFamily: Bool
        var route: TabRoute
        var accessibility: String
        var columnSpan: Int

        var chipTint: Color {
            switch chipTintName {
            case "low": return NativeTokens.recoveryLow
            case "high": return NativeTokens.recoveryHigh
            case "heart": return NativeTokens.heart
            default: return Color.secondary
            }
        }
    }

    static func slots(from report: NativeHealthRange.Report) -> [Slot] {
        specs.map { spec in
            let vital = report.vitals.first { $0.id == spec.id }
            return slot(spec: spec, vital: vital)
        }
    }

    static func slot(spec: Spec, vital: NativeHealthRange.Vital?) -> Slot {
        let hasValue = vital != nil
        let chip = chipText(status: vital?.status, hasValue: hasValue)
        let title = skinTitle(spec: spec, vital: vital)
        let valueText: String
        let unit: String?
        if let vital {
            valueText = numberText(vital)
            unit = spec.id == "spo2" ? nil : (spec.id == "skin" ? vital.unit : spec.tileUnit)
        } else {
            valueText = "—"
            unit = nil
        }
        return Slot(
            id: spec.id,
            title: title,
            symbol: spec.symbol,
            valueText: valueText,
            unit: unit,
            hasValue: hasValue,
            chip: chip,
            chipTintName: chipTintName(status: vital?.status),
            heartFamily: spec.heartFamily,
            route: spec.route,
            accessibility: NativeHealthMonitorFormat.accessibilityLabel(
                title: title,
                valueText: hasValue ? (vital?.valueText ?? valueText) : "unavailable",
                chip: chip
            ),
            columnSpan: spec.id == "skin" ? 2 : 1
        )
    }

    /// Range logic in `NativeHealthRange` evaluates absolute °C when the stored
    /// value is ≥ 20 °C (`VitalBands.isAbsoluteSkinTemp`), otherwise a signed deviation.
    static func skinTitle(spec: Spec, vital: NativeHealthRange.Vital?) -> String {
        guard spec.id == "skin" else { return spec.title }
        guard let vital else { return spec.title }
        return VitalBands.isAbsoluteSkinTemp(vital.value) ? "Skin temp" : "Skin temp vs baseline"
    }

    static func numberText(_ vital: NativeHealthRange.Vital) -> String {
        if vital.id == "spo2" { return vital.valueText }
        if vital.unit == "breaths/min" {
            return String(format: "%.1f", vital.value)
        }
        if vital.unit == "°C" || vital.unit == "°F" {
            let signed = !VitalBands.isAbsoluteSkinTemp(vital.value)
            return String(format: signed ? "%+.1f" : "%.1f", vital.value)
        }
        return String(Int(vital.value.rounded()))
    }

    static func chipText(status: TypicalVitalRange.Status?, hasValue: Bool) -> String {
        guard hasValue, let status else { return "Calibrating range" }
        switch status {
        case .building: return "Calibrating range"
        case .inRange: return "Within range"
        case .above: return "Higher"
        case .below: return "Lower"
        }
    }

    static func chipTintName(status: TypicalVitalRange.Status?) -> String {
        guard let status else { return "secondary" }
        switch status {
        case .building: return "secondary"
        case .inRange: return "high"
        case .above, .below: return "low"
        }
    }

    static func zoneLabel(_ zone: Int) -> String {
        "Zone \(max(0, zone))"
    }

    static func nightsWorn(days: [DailyMetric], todayKey: String) -> Int {
        days.filter {
            $0.day <= todayKey && ($0.avgHrv != nil || $0.restingHr != nil)
        }.count
    }

    static func nightsRemaining(worn: Int) -> Int? {
        let left = calibrateNights - worn
        return left > 0 ? left : nil
    }

    static func calibrationCaption(remaining: Int) -> String {
        let nights = remaining == 1 ? "1 more night" : "\(remaining) more nights"
        return "Wear your strap to sleep \(nights) to calibrate"
    }
}

enum NativeHealthMonitorFormat {
    /// Compact trailing so "Respiratory Rate" stays the same title size as the other rows.
    /// `NativeContributorRow` rewrites `rpm` → `breaths/min`, so the page draws its own value.
    static func trailingValue(_ vital: NativeHealthRange.Vital) -> String {
        guard vital.id == "resp" else { return vital.valueText }
        return vital.valueText.replacingOccurrences(of: "breaths/min", with: "rpm")
    }

    static func accessibilityLabel(_ vital: NativeHealthRange.Vital) -> String {
        accessibilityLabel(
            title: vital.title,
            valueText: vital.valueText,
            chip: NativeHealthMonitorMath.chipText(status: vital.status, hasValue: true)
        )
    }

    static func accessibilityLabel(title: String, valueText: String, chip: String) -> String {
        "\(title), \(valueText), \(chip)"
    }
}

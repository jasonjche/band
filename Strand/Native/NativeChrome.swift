import SwiftUI
import Charts
import StrandDesign

// Shared chrome for the WHOOP-shaped presentation.
//
// The information architecture comes from the WHOOP screenshots in
// docs/whoop-ia.md. The controls are Apple's: Gauge, List, Picker, and
// NavigationStack. On iOS 26 the bars are Liquid Glass because the system
// draws them. Cards use a continuous rounded rectangle on the grouped
// background so they read as content, not as another glass control.

enum NativeChrome {
    static let recovery = NativeTokens.recoveryHigh
    static let strain = NativeTokens.strain
    static let sleep = NativeTokens.sleep
    static let heart = NativeTokens.heart
    static let respiratory = NativeTokens.respiratory
    static let activity = NativeTokens.activity
    static let stressLow = NativeTokens.stressLow
    static let stressMid = NativeTokens.stressMid
    static let stressHigh = NativeTokens.stressHigh
    static let stress = stressHigh
    static let cardRadius: CGFloat = 26
    static let gridStroke = StrokeStyle(lineWidth: 0.5, dash: [2, 2])

    /// 0 red / 1 yellow / 2 green. 37% is the middle WHOOP band (34–66).
    static func recoveryBandIndex(_ value: Double) -> Int {
        if value < 34 { return 0 }
        if value < 67 { return 1 }
        return 2
    }

    static func recoveryBand(_ value: Double) -> Color {
        NativeTokens.recoveryBand(value)
    }

    static let poor = NativeTokens.bandPoor
    static let sufficient = NativeTokens.bandSufficient
    static let optimal = NativeTokens.bandOptimal

    static func sleepBand(_ percent: Double) -> Color {
        NativeTokens.sleepBand(percent)
    }

    /// Poor / Sufficient / Optimal tick from WHOOP sleep rows (9428).
    static func bandTick(percent: Double) -> some View {
        HStack(spacing: 2) {
            Capsule().fill(percent < 70 ? poor : poor.opacity(0.25)).frame(width: 16, height: 5)
            Capsule().fill(percent >= 70 && percent < 85 ? sufficient : sufficient.opacity(0.25)).frame(width: 16, height: 5)
            Capsule().fill(percent >= 85 ? optimal : optimal.opacity(0.25)).frame(width: 16, height: 5)
        }
        .accessibilityHidden(true)
    }

    static func stressBandColor(_ value: Double) -> Color {
        if value < 1 { return stressLow }
        if value < 2 { return stressMid }
        return stressHigh
    }

    /// Tokens, not `systemGroupedBackground`, so macOS snapshots match iOS light #F2F2F7 / dark #000000.
    static let page = NativeTokens.page
    static let cardFill = NativeTokens.card
    static let hairline = NativeTokens.separator

    static func stack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NativeStack(content: content)
    }

    static func screen<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NativeScreen(content: content)
    }

    static func panel<Content: View>(expands: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        NativePanel(expands: expands, content: content)
    }

    static func card<Content: View>(header: NativeCardHeader, @ViewBuilder content: () -> Content) -> some View {
        panel {
            header
            content()
        }
    }

    static func section(_ title: String) -> some View {
        NativeSectionTitle(title: title)
    }

    static func footnote(_ text: String) -> some View {
        NativeFootnote(text: text)
    }
}

private struct NativeStack<Content: View>: View {
    @Environment(\.nativeStyle) private var style
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: style == .whoop ? 12 : 10) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativePageFill())
    }
}

private struct NativeScreen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            NativeStack(content: { content })
                .padding(.bottom, 136)
        }
        .background(NativePageFill().ignoresSafeArea())
    }
}

private struct NativePanel<Content: View>: View {
    var expands: Bool = false
    @Environment(\.nativeStyle) private var style
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: style == .whoop ? 12 : 10) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: expands ? .infinity : nil, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: NativePaint.cardRadius(style), style: .continuous)
                .fill(NativePaint.card(style))
        )
    }
}

private struct NativeSectionTitle: View {
    var title: String
    @Environment(\.nativeStyle) private var style

    var body: some View {
        Text(title)
            .font(style == .whoop ? .title2.bold() : .title2.bold())
            .padding(.top, 18)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NativeFootnote: View {
    var text: String
    @Environment(\.nativeStyle) private var style

    var body: some View {
        Text(text)
            .font(style == .whoop ? NativeTokens.whoopCaps(11) : .footnote)
            .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Health card header: tinted symbol + title, optional trailing value, optional chevron.
struct NativeCardHeader: View {
    var title: String
    var symbol: String?
    var tint: Color
    var trailing: String? = nil
    var chevron: Bool = false
    @Environment(\.nativeStyle) private var style

    var body: some View {
        if style == .whoop {
            whoop
        } else {
            apple
        }
    }

    private var apple: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                }
                Text(title)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if chevron {
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var whoop: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(NativeTokens.whoopCaps(12))
                .tracking(NativeTokens.whoopCapsTracking)
                .foregroundStyle(NativeTokens.whoopLabel)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing.uppercased())
                    .font(NativeTokens.whoopCaps(11))
                    .tracking(NativeTokens.whoopCapsTracking)
                    .foregroundStyle(NativeTokens.whoopLabel)
                    .monospacedDigit()
            }
            if chevron {
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(NativeTokens.whoopLabel)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// Rounded bold value with an optional baseline-aligned unit.
struct NativeValueText: View {
    var value: String
    var unit: String?
    var size: CGFloat = 34
    @Environment(\.nativeStyle) private var style

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: unit == "%" ? 1 : 4) {
            Text(value)
                .font(NativePaint.number(size, style: style))
                .monospacedDigit()
            if let unit, !unit.isEmpty {
                Text(style == .whoop && unit == "%" ? "%" : unit)
                    .font(NativePaint.number(unit == "%" ? size * 0.42 : (style == .whoop ? size * 0.42 : 17),
                                             weight: unit == "%" ? .bold : .medium,
                                             style: style))
                    .foregroundStyle(unit == "%" ? Color.primary : Color.secondary)
                    .baselineOffset(unit == "%" ? size * 0.055 : 0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Caption + hero value + unit + date, matching Apple Health's value block.
struct NativeHeroValue: View {
    var caption: String? = nil
    var value: String
    var unit: String? = nil
    var date: String? = nil
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(style == .whoop ? NativeTokens.whoopCaps(11) : .caption.weight(.medium))
                    .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                    .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
                    .textCase(.uppercase)
            }
            NativeValueText(value: value, unit: unit, size: style == .whoop ? 40 : 34)
            if let date, !date.isEmpty {
                Text(date)
                    .font(style == .whoop ? NativeTokens.whoopCaps(11) : .subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Inset-list metric row: tinted symbol, title, bold value with unit, prior underneath, delta.
/// One layout for Sleep / Recovery / Strain contributors, Home dashboard rows, and Health Monitor.
/// Band colour may tint the value text; the three-dash ticks and Poor/Sufficient/Optimal legend
/// are not part of this row.
struct NativeContributorRow: View {
    var symbol: String
    var title: String
    var value: String
    var prior: String? = nil
    var delta: NativeScore.Delta = .none
    var tint: Color
    var valueTint: Color = .primary
    @Environment(\.nativeStyle) private var style

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(style == .whoop ? title.uppercased() : title)
                .font(style == .whoop ? NativeTokens.whoopCaps(13) : .body)
                .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 4) {
                    Text(displayValue)
                        .font(style == .whoop
                              ? NativeTokens.whoopNumber(17, weight: .semibold)
                              : StrandFont.rounded(17, weight: .semibold))
                        .foregroundStyle(style == .whoop ? Color.primary : valueTint)
                        .lineLimit(1)
                        .monospacedDigit()
                    NativeDelta(delta: delta)
                }
                if let prior, NativeScoreMath.hasValue(prior) {
                    Text(displayPrior)
                        .font(style == .whoop ? NativeTokens.whoopNumber(12, weight: .regular) : .footnote)
                        .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }
            .layoutPriority(1)
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }

    private var displayValue: String {
        appleUnit(NativeScoreMath.attachedPercent(value))
    }

    private var displayPrior: String {
        appleUnit(NativeScoreMath.attachedPercent(prior ?? ""))
    }

    /// Apple style spells respiratory as breaths/min; the model may still say rpm.
    private func appleUnit(_ text: String) -> String {
        text.replacingOccurrences(of: "rpm", with: "breaths/min")
    }
}

/// Activity list row: tinted pill (symbol + value), uppercase name, two-line time, trailing tint bar.
struct NativeActivityRow: View {
    var symbol: String
    var tint: Color
    var title: String
    var trailing: String
    var startClock: String
    var endClock: String
    @Environment(\.nativeStyle) private var style

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                Text(trailing)
                    .font(style == .whoop
                          ? NativeTokens.whoopNumber(17, weight: .bold)
                          : StrandFont.rounded(17, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint)
            )

            Text(title.uppercased())
                .font(style == .whoop ? NativeTokens.whoopCaps(12) : .subheadline.weight(.semibold))
                .tracking(style == .whoop ? NativeTokens.whoopCapsTracking : 0)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 6)

            if !startClock.isEmpty || !endClock.isEmpty {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(startClock)
                    Text(endClock)
                }
                .font(style == .whoop ? NativeTokens.whoopCaps(10) : .caption2)
                .foregroundStyle(style == .whoop ? NativeTokens.whoopLabel : Color.secondary)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
            }

            Capsule()
                .fill(tint)
                .frame(width: 3, height: 28)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(trailing), \(startClock) \(endClock)")
    }
}

/// Capsule overlay under a chart page ("Latest: Oct 26" + "11 ms").
struct NativeLatestCapsule: View {
    var label: String
    var value: String
    @Environment(\.nativeStyle) private var style

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(NativePaint.card(style)))
        .accessibilityElement(children: .combine)
    }
}

/// Centred placeholder for an empty chart or list card.
struct NativeEmptyState: View {
    var text: String
    var symbol: String = "chart.bar"

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
            Text(text)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .accessibilityElement(children: .combine)
    }
}

/// Subtle opacity pulse for loading placeholders. Reduce Motion leaves the view still.
struct NativeShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || !pulse ? 1 : 0.62)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

extension View {
    func nativeShimmer() -> some View {
        modifier(NativeShimmer())
    }
}

struct NativeRing: View {
    var fraction: Double?
    var tint: Color
    var value: String
    var caption: String
    var diameter: CGFloat = 168
    /// Fractions around the ring, 0...1. Strain used these for the light / moderate / high marks.
    /// Deprecated: ticks are no longer drawn. Kept so existing call sites compile.
    var ticks: [Double] = []

    @Environment(\.nativeStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: Double = 0

    var body: some View {
        // Stroke is centered on the path, so it is inset by half the line width
        // or the caption under the ring sits on the paint.
        let whoop = style == .whoop
        let line = max(5, diameter * (whoop ? 0.135 : 0.11))
        let numberSize = max(17, diameter * (whoop ? 0.28 : 0.25))
        let percentSize = numberSize * (whoop ? 0.40 : 0.45)
        let _ = ticks
        VStack(spacing: caption.isEmpty || (whoop && diameter >= 160) ? 0 : 8) {
            ZStack {
                Circle()
                    .stroke(
                        whoop ? NativeTokens.whoopTrack : tint.opacity(NativeTokens.trackOpacity),
                        lineWidth: line
                    )
                Circle()
                    .trim(from: 0, to: drawn)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: whoop ? 6 : 0) {
                    HStack(alignment: .firstTextBaseline, spacing: whoop ? 1 : 0) {
                        Text(numericText)
                            .font(NativePaint.number(numberSize, style: style))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        if showsPercent {
                            Text("%")
                                .font(NativePaint.number(percentSize, weight: .bold, style: style))
                                .baselineOffset(numberSize * 0.055)
                        }
                    }
                    if whoop, diameter >= 160, !caption.isEmpty {
                        whoopInnerCaption
                    }
                }
                .padding(line + 8)
            }
            .padding(line / 2)
            .frame(width: diameter, height: diameter)
            if !caption.isEmpty, !(whoop && diameter >= 160) {
                Text(whoop ? caption.uppercased() : caption)
                    .font(whoop ? NativeTokens.whoopCaps(11) : .subheadline.weight(.semibold))
                    .tracking(whoop ? NativeTokens.whoopCapsTracking : 0)
                    .foregroundStyle(whoop ? NativeTokens.whoopLabel : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
        }
        .onAppear { reveal(fraction) }
        .onChangeCompat(of: fraction) { reveal($0) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption.isEmpty ? "Score" : caption), \(value)")
    }

    @ViewBuilder private var whoopInnerCaption: some View {
        let parts = caption.split(separator: " ").map(String.init)
        VStack(spacing: 1) {
            ForEach(parts, id: \.self) { part in
                Text(part.uppercased())
                    .font(NativeTokens.whoopCaps(9))
                    .tracking(0.35)
                    .foregroundStyle(NativeTokens.whoopLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var showsPercent: Bool { NativeScoreMath.attachedPercent(value).hasSuffix("%") }
    private var numericText: String {
        let attached = NativeScoreMath.attachedPercent(value)
        return showsPercent ? String(attached.dropLast()) : attached
    }

    private func reveal(_ fraction: Double?) {
        let target = fraction.map { min(1, max(0, $0)) } ?? 0
        if reduceMotion {
            var transaction = Transaction(animation: nil)
            withTransaction(transaction) { drawn = target }
            return
        }
        withAnimation(.spring(response: 0.8, dampingFraction: 0.86)) {
            drawn = target
        }
    }
}

struct NativeDelta: View {
    var delta: NativeScore.Delta
    @Environment(\.nativeStyle) private var style

    var body: some View {
        if delta == .none || delta == .flat {
            EmptyView()
        } else {
            Image(systemName: triangle)
                .font(style == .whoop ? NativeTokens.whoopCaps(10) : .caption2.weight(.bold))
                .foregroundStyle(deltaTint)
                .frame(width: 12)
                .accessibilityLabel(delta.name)
        }
    }

    private var triangle: String {
        if delta == .up { return "arrowtriangle.up.fill" }
        if delta == .down { return "arrowtriangle.down.fill" }
        return "minus"
    }

    private var deltaTint: Color {
        if style == .whoop {
            if delta == .up { return NativeTokens.whoopPositiveDelta }
            if delta == .down { return NativeTokens.whoopNegativeDelta }
            return NativeTokens.whoopLabel
        }
        if delta == .up { return NativeTokens.positiveDelta }
        if delta == .down { return NativeTokens.negativeDelta }
        return .secondary
    }
}

private struct NativeNavigationPathKey: EnvironmentKey {
    static let defaultValue = Binding<NavigationPath>(
        get: { NavigationPath() },
        set: { _ in }
    )
}

private struct NativeSelectedDayKey: EnvironmentKey {
    static let defaultValue = Date()
}

/// Home stepper and pushed score pages must share one day. Navigation destinations
/// do not inherit NativeHomeView's environment, so the key is AppStorage.
enum NativeDaySelection {
    static let storageKey = "noop.nativeSelectedDayKey"

    static func key(from date: Date) -> String {
        NativeDayLogic.persistSteppedDay(date)
    }

    static func date(from key: String) -> Date {
        NativeDayLogic.date(forStored: key)
    }
}

extension EnvironmentValues {
    /// The tab stack's path. Home buttons append to it because a value-link tap was not pushing.
    var nativeNavigationPath: Binding<NavigationPath> {
        get { self[NativeNavigationPathKey.self] }
        set { self[NativeNavigationPathKey.self] = newValue }
    }

    /// The day Home is showing. Score pages read this so a ring tap matches the stepper.
    var nativeSelectedDay: Date {
        get { self[NativeSelectedDayKey.self] }
        set { self[NativeSelectedDayKey.self] = newValue }
    }
}

struct NativeDayPoint: Identifiable {
    /// Calendar day `yyyy-MM-dd`. Chart x value and identity — never a weekday letter.
    var key: String
    /// Short unique axis label (day of month). Not used as Chart identity.
    var day: String
    var value: Double
    var id: String { key }

    init(key: String, value: Double, day: String? = nil) {
        self.key = key
        self.value = value
        if let day {
            self.day = day
        } else {
            let tail = String(key.suffix(2)).drop { $0 == "0" }
            self.day = tail.isEmpty ? key : String(tail)
        }
    }
}

/// Weekday "Thu". The page's selected day is primary semibold.
/// WHOOP style stacks weekday over the date ("Fri" / "6").
private struct NativeChartAxisLabel: View {
    var key: String
    var highlighted: Bool
    @Environment(\.nativeStyle) private var style

    var body: some View {
        VStack(spacing: 1) {
            Text(NativeChartDay.weekday(key))
            Text(NativeChartDay.dayOfMonth(key))
        }
        .font(style == .whoop ? NativeTokens.whoopCaps(10) : .caption2.weight(highlighted ? .semibold : .regular))
        .foregroundStyle(highlighted ? Color.primary : (style == .whoop ? NativeTokens.whoopLabel : Color.secondary))
    }
}

enum NativeChartDay {
    static func date(from key: String) -> Date? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: key)
    }

    static func weekday(_ key: String) -> String {
        guard let date = date(from: key) else { return key }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(secondsFromGMT: 0)
        out.dateFormat = "EEE"
        return out.string(from: date)
    }

    static func dayOfMonth(_ key: String) -> String {
        guard let date = date(from: key) else {
            let tail = String(key.suffix(2)).drop { $0 == "0" }
            return tail.isEmpty ? key : String(tail)
        }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(secondsFromGMT: 0)
        out.dateFormat = "d"
        return out.string(from: date)
    }

    /// "Thu, Nov 12"
    static func longLabel(_ key: String) -> String {
        guard let date = date(from: key) else { return key }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(secondsFromGMT: 0)
        out.dateFormat = "EEE, MMM d"
        return out.string(from: date)
    }

    /// "Nov 12, 2026"
    static func mediumDate(_ key: String) -> String {
        guard let date = date(from: key) else { return key }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(secondsFromGMT: 0)
        out.dateFormat = "MMM d, yyyy"
        return out.string(from: date)
    }

    /// "Nov 10–16, 2026"
    static func rangeLabel(from startKey: String, to endKey: String) -> String {
        guard let start = date(from: startKey), let end = date(from: endKey) else {
            return "\(startKey) – \(endKey)"
        }
        let monthDay = DateFormatter()
        monthDay.locale = Locale(identifier: "en_US_POSIX")
        monthDay.timeZone = TimeZone(secondsFromGMT: 0)
        monthDay.dateFormat = "MMM d"
        let year = DateFormatter()
        year.locale = Locale(identifier: "en_US_POSIX")
        year.timeZone = TimeZone(secondsFromGMT: 0)
        year.dateFormat = "yyyy"
        let startYear = Calendar(identifier: .gregorian).component(.year, from: start)
        let endYear = Calendar(identifier: .gregorian).component(.year, from: end)
        if startYear == endYear {
            let startMonth = Calendar(identifier: .gregorian).component(.month, from: start)
            let endMonth = Calendar(identifier: .gregorian).component(.month, from: end)
            if startMonth == endMonth {
                let dayOnly = DateFormatter()
                dayOnly.locale = Locale(identifier: "en_US_POSIX")
                dayOnly.timeZone = TimeZone(secondsFromGMT: 0)
                dayOnly.dateFormat = "d"
                return "\(monthDay.string(from: start))–\(dayOnly.string(from: end)), \(year.string(from: end))"
            }
            return "\(monthDay.string(from: start))–\(monthDay.string(from: end)), \(year.string(from: end))"
        }
        return "\(monthDay.string(from: start)), \(startYear)–\(monthDay.string(from: end)), \(endYear)"
    }

    /// Consecutive finite points share a segment id; a NaN/missing day starts a new segment
    /// so LineMark does not draw across the gap.
    struct LinePoint: Identifiable {
        var key: String
        var value: Double
        var segment: Int
        var id: String { "\(segment)-\(key)" }
    }

    static func linePoints(_ points: [NativeDayPoint]) -> [LinePoint] {
        var segment = 0
        var lastFinite = false
        var result: [LinePoint] = []
        for point in points {
            if point.value.isFinite {
                if !lastFinite, !result.isEmpty { segment += 1 }
                result.append(LinePoint(key: point.key, value: point.value, segment: segment))
                lastFinite = true
            } else {
                lastFinite = false
            }
        }
        return result
    }

    static func fittedDomain(_ values: [Double], fallback: ClosedRange<Double>) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        guard let lo0 = finite.min(), let hi0 = finite.max() else { return fallback }
        if lo0 == hi0 {
            let pad = max(abs(lo0) * 0.15, 1)
            return (lo0 - pad)...(hi0 + pad)
        }
        let mean = finite.reduce(0, +) / Double(finite.count)
        let range = hi0 - lo0
        let pad = max(range * 0.25, abs(mean) * 0.05, 1e-6)
        return (lo0 - pad)...(hi0 + pad)
    }
}

private struct NativeHollowVertex: View {
    var tint: Color
    var size: CGFloat = 8
    @Environment(\.nativeStyle) private var style

    var body: some View {
        ZStack {
            Circle().fill(NativePaint.card(style))
            Circle().strokeBorder(tint, lineWidth: 2)
        }
        .frame(width: size, height: size)
    }
}

/// Average hero plus a weekly plot. Scrubbing (iOS) swaps the hero to that day.
struct NativeChartBlock: View {
    var points: [NativeDayPoint]
    var bars: Bool
    var tint: Color
    var format: (Double) -> String
    var axisFormat: ((Double) -> String)? = nil
    var unit: String? = nil
    var maxY: Double
    var color: ((Double) -> Color)? = nil
    var highlightKey: String? = nil
    var plotHeight: CGFloat = 200
    var accessibilityName: String = "Week"
    var clockHero: Bool = false
    var yTicks: [Double]? = nil
    var stacks: [NativeWeek.Card.Stack] = []
    var showsValueLabels: Bool = true

    @State private var selectedDay: String?

    private var known: [NativeDayPoint] { points.filter { $0.value.isFinite } }
    private var selectedPoint: NativeDayPoint? {
        guard let selectedDay else { return nil }
        return points.first { $0.key == selectedDay || $0.day == selectedDay }.flatMap {
            $0.value.isFinite ? $0 : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            hero
            plot
                .frame(height: plotHeight)
        }
    }

    @ViewBuilder private var hero: some View {
        if clockHero {
            clockHeroBlock
        } else if let selectedPoint {
            NativeHeroValue(
                caption: nil,
                value: format(selectedPoint.value),
                unit: unit,
                date: NativeChartDay.mediumDate(selectedPoint.key)
            )
        } else if let average = NativeScoreMath.mean(known.map(\.value)), let range = rangeDate {
            NativeHeroValue(caption: "Average", value: format(average), unit: unit, date: range)
        } else if let range = rangeDate {
            NativeHeroValue(value: "No Data", date: range)
        }
    }

    @ViewBuilder private var clockHeroBlock: some View {
        if let selectedPoint {
            NativeClockHero(minutes: selectedPoint.value)
            Text(NativeChartDay.mediumDate(selectedPoint.key))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let average = NativeScoreMath.mean(known.map(\.value)), let range = rangeDate {
            NativeClockHero(caption: "Average", minutes: average)
            Text(range)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let range = rangeDate {
            NativeHeroValue(value: "No Data", date: range)
        }
    }

    private var rangeDate: String? {
        guard let first = points.first?.key, let last = points.last?.key else { return nil }
        return NativeChartDay.rangeLabel(from: first, to: last)
    }

    @ViewBuilder private var plot: some View {
        if known.isEmpty && stacks.allSatisfy({ !$0.points.contains { $0.value.isFinite } }) {
            NativeEmptyState(text: "No Data")
        } else if !stacks.isEmpty {
            NativeStackedWeekBars(
                stacks: stacks,
                format: format,
                axisFormat: axisFormat ?? format,
                maxY: maxY,
                highlightKey: highlightKey,
                selectedDay: $selectedDay,
                showsValueLabels: showsValueLabels,
                yTicks: yTicks
            )
        } else if bars {
            NativeScoreWeekBars(
                points: points, tint: tint, format: format,
                axisFormat: axisFormat ?? format, maxY: maxY,
                color: color, highlightKey: highlightKey, selectedDay: $selectedDay,
                showsValueLabels: showsValueLabels,
                yTicks: yTicks
            )
        } else {
            NativeLabeledLine(
                points: points, tint: tint, domain: 0...max(maxY, 1), format: format,
                axisFormat: axisFormat ?? format,
                accessibilityName: accessibilityName, highlightKey: highlightKey,
                selectedDay: $selectedDay
            )
        }
    }
}

/// One series, straight segments, hollow vertices, no area fill.
struct NativeLabeledLine: View {
    var points: [NativeDayPoint]
    var tint: Color
    var domain: ClosedRange<Double>
    var format: (Double) -> String
    var axisFormat: ((Double) -> String)? = nil
    var accessibilityName: String
    var highlightKey: String? = nil
    var selectedDay: Binding<String?>? = nil
    var compactYAxis: Bool = false
    @Environment(\.nativeStyle) private var style

    private var known: [NativeDayPoint] { points.filter { $0.value.isFinite } }
    private var whoop: Bool { style == .whoop }
    private var segments: [NativeChartDay.LinePoint] { NativeChartDay.linePoints(points) }

    private var yDomain: ClosedRange<Double> {
        NativeChartDay.fittedDomain(known.map(\.value), fallback: domain)
    }

    var body: some View {
        if known.isEmpty {
            NativeEmptyState(text: "No Data")
        } else {
            Chart {
                ForEach(points) { point in
                    BarMark(x: .value("Day", point.key), y: .value("Slot", 0))
                        .foregroundStyle(Color.clear)
                        .accessibilityHidden(true)
                }
                ForEach(segments) { point in
                    LineMark(
                        x: .value("Day", point.key),
                        y: .value("Value", point.value),
                        series: .value("Segment", point.segment)
                    )
                    .foregroundStyle(tint)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(
                        x: .value("Day", point.key),
                        y: .value("Value", point.value),
                        series: .value("Segment", point.segment)
                    )
                    .foregroundStyle(tint)
                    .symbol { NativeHollowVertex(tint: tint) }
                    .annotation(position: .top, spacing: 4) {
                        Text(format(point.value))
                            .font(whoop ? NativeTokens.whoopNumber(11, weight: .semibold) : .caption2.weight(.semibold))
                            .foregroundStyle(whoop ? NativeTokens.whoopLabel : Color.secondary)
                    }
                }
                if !whoop, let selected = selectedDay?.wrappedValue,
                   known.contains(where: { $0.key == selected || $0.day == selected }) {
                    RuleMark(x: .value("Day", selected))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartYScale(domain: yDomain)
            .modifier(NativeChartChrome(
                keys: points.map(\.key),
                highlightKey: highlightKey,
                yFormat: axisFormat ?? format,
                hideYAxis: whoop,
                yTicks: NativeChartTicks.values(in: yDomain, maxCount: compactYAxis ? 2 : 3)
            ))
            .modifier(NativeOptionalDaySelect(selected: selectedDay))
            .accessibilityLabel("\(accessibilityName), \(known.map { format($0.value) }.joined(separator: ", "))")
        }
    }
}

/// Two lines on one 0…1 plot. Strain 0–21 and Recovery 0–100 share a normalised y.
/// Series names live in the card header, not a legend. Y-axis is on the right.
struct NativeStrainRecoveryChart: View {
    var recovery: [NativeDayPoint]
    var strain: [NativeDayPoint]
    var highlightKey: String? = nil
    var showsHero: Bool = false

    private struct Line: Identifiable {
        var day: String
        var value: Double
        var series: String
        var tint: Color
        var segment: Int
        var id: String { "\(series)-\(segment)-\(day)" }
    }

    private var axisKeys: [String] {
        let keys = strain.map(\.key) + recovery.map(\.key)
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @Environment(\.nativeStyle) private var style

    private var strainCeiling: Double {
        NativeDayLogic.strainMaxY(UnitPrefs.resolveEffortScale(effortScaleRaw))
    }

    private var lines: [Line] {
        func mapped(_ points: [NativeDayPoint], series: String, scale: Double, tint: Color) -> [Line] {
            NativeChartDay.linePoints(points).map {
                Line(day: $0.key, value: $0.value / scale, series: series, tint: tint, segment: $0.segment)
            }
        }
        return mapped(strain, series: "Strain", scale: strainCeiling, tint: NativePaint.strain(style))
            + mapped(recovery, series: "Recovery", scale: 100, tint: NativePaint.recovery(style))
    }

    @State private var selectedDay: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsHero {
                dualHero
            } else if let selectedDay, let caption = inspectCaption(selectedDay) {
                Text(caption)
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
            }
            Chart {
                ForEach(axisKeys, id: \.self) { key in
                    BarMark(x: .value("Day", key), y: .value("Slot", 0))
                        .foregroundStyle(Color.clear)
                        .accessibilityHidden(true)
                }
                ForEach(lines) { point in
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Value", point.value),
                        series: .value("Metric", "\(point.series)-\(point.segment)")
                    )
                    .foregroundStyle(by: .value("Metric", point.series))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(
                        x: .value("Day", point.day),
                        y: .value("Value", point.value),
                        series: .value("Metric", "\(point.series)-\(point.segment)")
                    )
                    .foregroundStyle(by: .value("Metric", point.series))
                    .symbol { NativeHollowVertex(tint: point.tint) }
                }
                if let selectedDay {
                    RuleMark(x: .value("Day", selectedDay))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale([
                "Strain": NativePaint.strain(style),
                "Recovery": NativePaint.recovery(style),
            ])
            .chartLegend(.hidden)
            .chartYScale(domain: 0...1.05)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 1.0 / 3, 2.0 / 3, 1]) { value in
                    AxisGridLine(stroke: NativeChrome.gridStroke)
                        .foregroundStyle(NativeChrome.hairline)
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text("\(Int((raw * strainCeiling).rounded()))")
                                .font(.caption2)
                                .foregroundStyle(NativePaint.strain(style))
                                .monospacedDigit()
                        }
                    }
                }
                AxisMarks(position: .trailing, values: [0, 1.0 / 3, 2.0 / 3, 1]) { value in
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text("\(Int((raw * 100).rounded()))")
                                .font(.caption2)
                                .foregroundStyle(NativePaint.recovery(style))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: axisKeys) { value in
                    AxisGridLine(stroke: NativeChrome.gridStroke)
                        .foregroundStyle(NativeChrome.hairline)
                    AxisValueLabel {
                        if let key = value.as(String.self) {
                            NativeChartAxisLabel(key: key, highlighted: key == highlightKey)
                        }
                    }
                }
            }
            .modifier(NativeDaySelect(selected: $selectedDay))
            .accessibilityLabel("Strain and Recovery, last 7 days")
        }
    }

    @ViewBuilder private var dualHero: some View {
        if let selectedDay, let caption = inspectCaption(selectedDay) {
            NativeHeroValue(value: caption, date: NativeChartDay.mediumDate(selectedDay))
        } else {
            let strainAvg = NativeScoreMath.mean(strain.filter { $0.value.isFinite }.map(\.value))
            let recoveryAvg = NativeScoreMath.mean(recovery.filter { $0.value.isFinite }.map(\.value))
            let range: String? = {
                guard let first = axisKeys.first, let last = axisKeys.last else { return nil }
                return NativeChartDay.rangeLabel(from: first, to: last)
            }()
            if strainAvg != nil || recoveryAvg != nil {
                NativeHeroValue(
                    caption: "Average",
                    value: [
                        strainAvg.map { String(format: "%.1f", $0) },
                        recoveryAvg.map { "\(Int($0.rounded()))%" },
                    ].compactMap { $0 }.joined(separator: "   "),
                    date: range
                )
            } else {
                NativeHeroValue(value: "No Data", date: range)
            }
        }
    }

    private func inspectCaption(_ day: String) -> String? {
        let s = strain.first { $0.key == day || $0.day == day }
        let r = recovery.first { $0.key == day || $0.day == day }
        guard (s?.value.isFinite ?? false) || (r?.value.isFinite ?? false) else { return nil }
        var parts: [String] = []
        if let s, s.value.isFinite { parts.append(String(format: "%.1f", s.value)) }
        if let r, r.value.isFinite { parts.append("\(Int(r.value.rounded()))%") }
        return parts.joined(separator: "  ")
    }
}

struct NativeScoreWeekBars: View {
    var points: [NativeDayPoint]
    var tint: Color
    var format: (Double) -> String
    var axisFormat: ((Double) -> String)? = nil
    var maxY: Double
    var color: ((Double) -> Color)? = nil
    var highlightKey: String? = nil
    var selectedDay: Binding<String?>? = nil
    var compactYAxis: Bool = false
    var showsValueLabels: Bool = true
    var yTicks: [Double]? = nil
    @Environment(\.nativeStyle) private var style

    private var known: [NativeDayPoint] { points.filter { $0.value.isFinite } }
    private var ceiling: Double { max(maxY, 1) }
    private var whoop: Bool { style == .whoop }
    private var plotCeiling: Double { ceiling * 1.22 }

    var body: some View {
        if known.isEmpty {
            NativeEmptyState(text: "No Data")
        } else {
            Chart {
                ForEach(points) { point in
                    if point.key == highlightKey {
                        RectangleMark(
                            x: .value("Day", point.key),
                            yStart: .value("Low", 0),
                            yEnd: .value("High", plotCeiling)
                        )
                        .foregroundStyle(whoop ? NativeTokens.whoopHighlight : NativeTokens.highlight)
                        .cornerRadius(8)
                        .accessibilityHidden(true)
                    }
                    if point.value.isFinite {
                        BarMark(
                            x: .value("Day", point.key),
                            y: .value("Value", point.value),
                            width: .ratio(whoop ? 0.42 : 0.5)
                        )
                        .foregroundStyle(barColor(point.value))
                        .cornerRadius(whoop ? 3 : 4)
                        .annotation(position: .top, spacing: 4) {
                            if showsValueLabels {
                                Text(format(point.value))
                                    .font(whoop ? NativeTokens.whoopNumber(11, weight: .semibold) : .caption2.weight(.semibold))
                                    .foregroundStyle(point.key == highlightKey ? Color.primary : (whoop ? NativeTokens.whoopLabel : Color.secondary))
                                    .monospacedDigit()
                            }
                        }
                    } else {
                        BarMark(
                            x: .value("Day", point.key),
                            y: .value("Value", 0),
                            width: .ratio(whoop ? 0.42 : 0.5)
                        )
                        .foregroundStyle(Color.clear)
                        .accessibilityHidden(true)
                    }
                }
                if !whoop, let selected = selectedDay?.wrappedValue,
                   known.contains(where: { $0.key == selected || $0.day == selected }) {
                    RuleMark(x: .value("Day", selected))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartYScale(domain: 0...plotCeiling)
            .modifier(NativeChartChrome(
                keys: points.map(\.key),
                highlightKey: highlightKey,
                yFormat: axisFormat ?? format,
                hideYAxis: whoop,
                yTicks: yTicks ?? NativeChartTicks.values(in: 0...ceiling, maxCount: compactYAxis ? 2 : 3)
            ))
            .modifier(NativeOptionalDaySelect(selected: selectedDay))
        }
    }

    private func barColor(_ value: Double) -> Color {
        color?(value) ?? tint
    }
}

/// Stacked weekly bars (HR zones 1–3 / 4–5). No legend; colours are the zone tokens.
struct NativeStackedWeekBars: View {
    var stacks: [NativeWeek.Card.Stack]
    var format: (Double) -> String
    var axisFormat: ((Double) -> String)? = nil
    var maxY: Double
    var highlightKey: String? = nil
    var selectedDay: Binding<String?>? = nil
    var showsValueLabels: Bool = true
    var yTicks: [Double]? = nil
    @Environment(\.nativeStyle) private var style

    private struct Slice: Identifiable {
        var key: String
        var value: Double
        var series: String
        var tint: Color
        var id: String { series + key }
    }

    private var keys: [String] {
        var seen = Set<String>()
        return stacks.flatMap(\.points).map(\.key).filter { seen.insert($0).inserted }
    }

    private var slices: [Slice] {
        stacks.flatMap { stack in
            stack.points.compactMap { point in
                guard point.value.isFinite, point.value > 0 else { return nil }
                return Slice(key: point.key, value: point.value, series: stack.title, tint: stack.tint)
            }
        }
    }

    private var ceiling: Double { max(maxY, 1) }
    private var whoop: Bool { style == .whoop }
    private var plotCeiling: Double { ceiling * 1.22 }
    private var scale: [String: Color] {
        Dictionary(uniqueKeysWithValues: stacks.map { ($0.title, $0.tint) })
    }

    var body: some View {
        if slices.isEmpty {
            NativeEmptyState(text: "No Data")
        } else {
            Chart {
                ForEach(keys, id: \.self) { key in
                    if key == highlightKey {
                        RectangleMark(
                            x: .value("Day", key),
                            yStart: .value("Low", 0),
                            yEnd: .value("High", plotCeiling)
                        )
                        .foregroundStyle(whoop ? NativeTokens.whoopHighlight : NativeTokens.highlight)
                        .cornerRadius(8)
                        .accessibilityHidden(true)
                    }
                }
                ForEach(slices) { slice in
                    BarMark(
                        x: .value("Day", slice.key),
                        y: .value("Value", slice.value),
                        width: .ratio(whoop ? 0.42 : 0.5)
                    )
                    .foregroundStyle(by: .value("Zone", slice.series))
                    .cornerRadius(whoop ? 3 : 4)
                }
            }
            .chartForegroundStyleScale(scale)
            .chartLegend(.hidden)
            .chartYScale(domain: 0...plotCeiling)
            .modifier(NativeChartChrome(
                keys: keys,
                highlightKey: highlightKey,
                yFormat: axisFormat ?? format,
                hideYAxis: whoop,
                yTicks: yTicks ?? NativeChartTicks.values(in: 0...ceiling, maxCount: 3)
            ))
            .modifier(NativeOptionalDaySelect(selected: selectedDay))
        }
    }
}

enum NativeChartTicks {
    /// 2–3 fitted ticks. `minSpacing` is a fraction of the domain; ticks closer than that collapse to 2.
    static func values(in domain: ClosedRange<Double>, maxCount: Int = 3, minSpacing: Double? = nil) -> [Double] {
        let lo = domain.lowerBound
        let hi = domain.upperBound
        let span = hi - lo
        guard span > 0, maxCount >= 2 else { return [lo] }
        let floor = minSpacing ?? max(span * 0.28, abs(hi) * 0.04, 1)
        if maxCount == 2 || span < floor * 1.6 {
            return [lo, hi]
        }
        return [lo, lo + span / 2, hi]
    }
}

private struct NativeChartChrome: ViewModifier {
    var keys: [String]
    var highlightKey: String?
    var yFormat: (Double) -> String
    var hideYAxis: Bool = false
    var yTicks: [Double]? = nil
    @Environment(\.nativeStyle) private var style

    @ViewBuilder
    func body(content: Content) -> some View {
        let plotted = content
            .chartXAxis {
                AxisMarks(values: keys) { value in
                    AxisGridLine(stroke: style == .whoop ? StrokeStyle(lineWidth: 0) : NativeChrome.gridStroke)
                        .foregroundStyle(NativePaint.separator(style))
                    AxisValueLabel {
                        if let key = value.as(String.self) {
                            NativeChartAxisLabel(key: key, highlighted: key == highlightKey)
                        }
                    }
                }
            }
        if hideYAxis {
            plotted.chartYAxis(.hidden)
        } else if let yTicks {
            plotted
                .chartYAxis {
                    AxisMarks(position: .trailing, values: yTicks) { value in
                        AxisGridLine(stroke: NativeChrome.gridStroke)
                            .foregroundStyle(NativePaint.separator(style))
                        AxisValueLabel {
                            if let raw = value.as(Double.self) {
                                Text(yFormat(raw))
                                    .font(.caption2)
                                    .foregroundStyle(Color.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
        } else {
            plotted
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine(stroke: NativeChrome.gridStroke)
                            .foregroundStyle(NativePaint.separator(style))
                        AxisValueLabel {
                            if let raw = value.as(Double.self) {
                                Text(yFormat(raw))
                                    .font(.caption2)
                                    .foregroundStyle(Color.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
        }
    }
}

private struct NativeOptionalDaySelect: ViewModifier {
    var selected: Binding<String?>?
    func body(content: Content) -> some View {
        Group {
            if let selected {
                content.modifier(NativeDaySelect(selected: selected))
            } else {
                content
            }
        }
    }
}

/// Overnight heart-rate polyline. Dense samples: line only, y-axis on the right.
struct NativeOvernightLine: View {
    var points: [NativeHourPoint]
    var tint: Color = NativeTokens.heart

    private var yDomain: ClosedRange<Double> {
        NativeChartDay.fittedDomain(points.map(\.value), fallback: 40...90)
    }

    var body: some View {
        if points.isEmpty {
            NativeEmptyState(text: "No Data")
        } else {
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Time", point.time), y: .value("HR", point.value))
                        .foregroundStyle(tint)
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartYScale(domain: yDomain)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: NativeChrome.gridStroke)
                        .foregroundStyle(NativeChrome.hairline)
                    AxisValueLabel()
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: NativeChrome.gridStroke)
                        .foregroundStyle(NativeChrome.hairline)
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.hour().minute())
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct NativeHourPoint: Identifiable {
    var time: Date
    var value: Double
    var id: Date { time }
}

/// 24-hour stress from sleep bounds, workouts, and the day's 0–3 score. Night is shaded.
/// Shot 9420 / 9464.
struct NativeStressMonitor: View {
    var score: Double
    var sleepStart: Date?
    var sleepEnd: Date?
    var workouts: [(start: Date, end: Date)]
    var dayStart: Date
    var now: Date
    var sampleHours: [NativeHourPoint] = []
    @Environment(\.nativeStyle) private var style

    private var hours: [NativeHourPoint] {
        if !sampleHours.isEmpty { return sampleHours }
        return NativeHomeCharts.stressHours(
            dayStart: dayStart, now: now, sleepStart: sleepStart, sleepEnd: sleepEnd,
            workouts: workouts, daily: score
        )
    }

    @Binding var scrubValue: Double
    @Binding var scrubTime: Date?
    @State private var selectedTime: Date?

    var body: some View {
        Chart {
            if let sleepStart, let sleepEnd {
                RectangleMark(
                    xStart: .value("Sleep start", sleepStart),
                    xEnd: .value("Sleep end", sleepEnd),
                    yStart: .value("Low", 0),
                    yEnd: .value("High", 3)
                )
                .foregroundStyle(Color.primary.opacity(0.10))
            }
            ForEach(Array(workouts.enumerated()), id: \.offset) { _, bout in
                RectangleMark(
                    xStart: .value("W start", bout.start),
                    xEnd: .value("W end", bout.end),
                    yStart: .value("Low", 0),
                    yEnd: .value("High", 3)
                )
                .foregroundStyle(NativeChrome.strain.opacity(0.22))
            }
            ForEach(hours) { point in
                if style == .whoop {
                    AreaMark(x: .value("Time", point.time), y: .value("Stress", point.value))
                        .foregroundStyle(stressGradient.opacity(0.22))
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("Time", point.time), y: .value("Stress", point.value))
                    .foregroundStyle(stressGradient)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            }
            if let sleepStart {
                PointMark(x: .value("Moon", sleepStart), y: .value("Top", 2.85))
                    .symbolSize(0)
                    .annotation(position: .bottom, spacing: 0) {
                        Image(systemName: "moon.fill").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let bout = workouts.first {
                PointMark(x: .value("Work", bout.start), y: .value("Top", 2.85))
                    .symbolSize(0)
                    .annotation(position: .bottom, spacing: 0) {
                        Image(systemName: "figure.run").font(.caption2).foregroundStyle(NativeChrome.strain)
                    }
            }
            if let selectedTime, let point = nearest(to: selectedTime) {
                RuleMark(x: .value("Scrub", point.time))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                PointMark(x: .value("Scrub", point.time), y: .value("Stress", point.value))
                    .foregroundStyle(NativeChrome.stressBandColor(point.value))
                    .symbolSize(70)
                    .annotation(position: .top, spacing: 4) {
                        Text(String(format: "%.1f", point.value))
                            .font(.headline.monospacedDigit())
                    }
            }
        }
        .chartYScale(domain: 0...3)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 1, 2, 3]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                AxisValueLabel().font(.caption2)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute()).font(.caption2)
            }
        }
        .modifier(NativeTimeSelect(selected: $selectedTime, onChange: { time in
            guard let time, let point = nearest(to: time) else { return }
            scrubTime = point.time
            scrubValue = point.value
        }))
        .accessibilityLabel("Stress monitor \(String(format: "%.1f", score))")
    }

    private func nearest(to time: Date) -> NativeHourPoint? {
        hours.min(by: { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) })
    }

    private var stressGradient: LinearGradient {
        LinearGradient(
            colors: [NativeChrome.stressLow, NativeChrome.stressMid, NativeChrome.stressHigh],
            startPoint: .bottom,
            endPoint: .top
        )
    }
}

private struct NativeDaySelect: ViewModifier {
    @Binding var selected: String?
    func body(content: Content) -> some View {
        #if os(iOS)
        content.chartXSelection(value: $selected)
        #else
        content
        #endif
    }
}

struct NativeTimeSelect: ViewModifier {
    @Binding var selected: Date?
    var onChange: (Date?) -> Void
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .chartXSelection(value: $selected)
            .onChange(of: selected) { _, time in onChange(time) }
        #else
        content
        #endif
    }
}

struct NativeInlineTitle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }
}

private struct NativeDateSubtitle: ViewModifier {
    var date: Date

    private var formatted: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.navigationSubtitle(formatted)
        } else {
            content
        }
        #elseif os(macOS)
        content.navigationSubtitle(formatted)
        #else
        content
        #endif
    }
}

extension View {
    /// Pushed-page date under the navigation title. iOS 26+ / macOS uses
    /// `navigationSubtitle`; earlier iOS falls back to a principal toolbar stack.
    func nativeDateSubtitle(_ date: Date) -> some View {
        modifier(NativeDateSubtitle(date: date))
    }
}

/// One score page's facts. Shared by Home rings and the three detail pages.
struct NativeScore: Equatable {
    struct Delta: Equatable {
        var symbol: String
        var tint: Color
        var name: String
        static let flat = Delta(symbol: "minus", tint: .secondary, name: "in line with the last 30 days")
        static let up = Delta(symbol: "arrow.up", tint: NativeTokens.positiveDelta, name: "above the last 30 days")
        static let down = Delta(symbol: "arrow.down", tint: NativeTokens.negativeDelta, name: "below the last 30 days")
        static let none = Delta(symbol: "circle", tint: .clear, name: "no comparison")
    }

    struct Row: Equatable, Identifiable {
        var id: String { title }
        var title: String
        var value: String
        var prior: String
        var symbol: String
        var delta: Delta
        var route: TabRoute
    }

    var name: String
    var value: String
    var known: Bool
    var fraction: Double?
    var tint: Color
    var rows: [Row]
    var insight: String
    var route: TabRoute
}

enum NativeScoreMath {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    static func strainText(_ stored: Double?, scale: EffortScale) -> String {
        NativeDayLogic.strainText(stored, scale: scale)
    }

    static func labeled(_ value: Double?, unit: String, decimals: Int = 0, grouped: Bool = false) -> String {
        guard let value else { return "—" }
        let shown: String
        if grouped {
            shown = count(value) ?? "—"
        } else if decimals == 0 {
            shown = String(Int(value.rounded()))
        } else {
            shown = String(format: "%.\(decimals)f", value)
        }
        if unit.isEmpty { return shown }
        if unit == "%" { return "\(shown)%" }
        return "\(shown)\u{00A0}\(unit)"
    }

    /// Grouped integer. Home steps hero and Strain steps row both call this.
    static func count(_ value: Double?) -> String? {
        guard let value else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = AppLanguage.activeLocale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value.rounded()))
    }

    static func count(_ value: Double) -> String {
        count(Optional(value)) ?? "\(Int(value.rounded()))"
    }

    /// "89 %" / "89\u{00A0}%" → "89%". Leaves non-percent values alone.
    static func attachedPercent(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}%", with: "%")
            .replacingOccurrences(of: " %", with: "%")
    }

    static func hasValue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "—" && trimmed != "-" && trimmed != "–"
    }

    static func percentValue(_ text: String) -> Double? {
        let stripped = attachedPercent(text)
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard stripped.contains(where: \.isLetter) == false else { return nil }
        return Double(stripped)
    }

    static func priorText(_ values: [Double], unit: String, decimals: Int = 0, grouped: Bool = false) -> String {
        labeled(mean(values), unit: unit, decimals: decimals, grouped: grouped)
    }

    static func delta(_ value: Double?, _ prior: [Double]) -> NativeScore.Delta {
        guard let value, let mean = mean(prior), mean != 0 else { return .none }
        let change = (value - mean) / abs(mean)
        if change > 0.03 { return .up }
        if change < -0.03 { return .down }
        return .flat
    }

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func duration(_ minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// WHOOP time-in-zone: h:mm:ss.
    static func durationHMS(_ minutes: Double) -> String {
        let total = max(0, Int((minutes * 60).rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func clockParts(_ minutes: Double) -> (hours: Int, minutes: Int) {
        let total = max(0, Int(minutes.rounded()))
        return (total / 60, total % 60)
    }
}

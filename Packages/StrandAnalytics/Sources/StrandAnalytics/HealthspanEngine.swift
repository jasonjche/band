import Foundation

// HealthspanEngine.swift — Band Age + Pace of Aging from published all-cause-mortality
// hazard ratios (NOT medical advice; a wellness comparison, never a clinical biological age).
//
// Independent of WHOOP's closed model. Same *method family* as WHOOP Healthspan / patent
// WO2026161891A1: map each wearable metric to a published all-cause-mortality hazard ratio
// versus a health-optimized referent, convert with Years = ln(HR) / 0.1 (a 10.5% hazard is
// about +1 year), and sum the years. Band Age uses a 6-month average; Pace of Aging uses
// 30 days projected over six months. HRV is deliberately excluded (WHOOP Healthspan /
// WHOOP Age guide). Lean body mass is optional and dropped from the sum when missing.
//
// FitnessAgeEngine is a different claim (7-day Nes 2011 VO₂max inversion). This engine does
// not call it. Callers may pass an Apple Health or Nes-estimated VO₂max as `vo2max`.

public enum HealthspanEngine {

    /// Patent WO2026161891A1 / Gompertz approximation: mortality rises ~10% per year of adult age,
    /// so Δyears = ln(HR) / 0.1. Equiv. a hazard ratio of 1.105 is about +1 year.
    public static let lnHazardPerYear = 0.1
    public static let ageWindowDays = 180
    public static let paceWindowDays = 30
    /// About six months of nights before Band Age is treated as calibrated.
    public static let minDaysForAge = 150
    /// WHOOP unlocks Healthspan after ~21 recoveries; Pace can show at this floor.
    public static let minDaysForPace = 21
    public static let minContributors = 3
    public static let minBandAge = 18.0
    public static let maxBandAge = 80.0
    public static let minPace = -1.0
    public static let maxPace = 3.0

    public enum Section: String, Equatable, Sendable {
        case sleep, strain, fitness
    }

    public enum Readiness: Equatable, Sendable {
        case notReady
        case calibrating
        case ready
    }

    /// One calendar day of inputs. All fields optional; the engine uses whatever is present.
    public struct Day: Equatable, Sendable {
        public var day: String                 // yyyy-MM-dd
        public var sleepHours: Double?
        public var sleepOnsetMin: Int?         // minutes from local midnight
        public var sleepWakeMin: Int?
        public var sleepConsistency: Double?   // 0…100, if already scored
        public var steps: Double?
        public var restingHR: Double?
        public var vo2max: Double?
        public var zone13Min: Double?          // that day's minutes in HR zones 1–3
        public var zone45Min: Double?
        public var strengthMin: Double?
        public var leanMassPct: Double?        // 0…100
        public init(day: String, sleepHours: Double? = nil, sleepOnsetMin: Int? = nil,
                    sleepWakeMin: Int? = nil, sleepConsistency: Double? = nil,
                    steps: Double? = nil, restingHR: Double? = nil, vo2max: Double? = nil,
                    zone13Min: Double? = nil, zone45Min: Double? = nil,
                    strengthMin: Double? = nil, leanMassPct: Double? = nil) {
            self.day = day; self.sleepHours = sleepHours
            self.sleepOnsetMin = sleepOnsetMin; self.sleepWakeMin = sleepWakeMin
            self.sleepConsistency = sleepConsistency; self.steps = steps
            self.restingHR = restingHR; self.vo2max = vo2max
            self.zone13Min = zone13Min; self.zone45Min = zone45Min
            self.strengthMin = strengthMin; self.leanMassPct = leanMassPct
        }
    }

    public struct Profile: Equatable, Sendable {
        public var chronoAge: Double
        public var sex: String                 // "male" | "female" | other
        public init(chronoAge: Double, sex: String) {
            self.chronoAge = chronoAge; self.sex = sex
        }
    }

    /// Aggregated lifestyle snapshot over a window (6-month or 30-day).
    public struct Window: Equatable, Sendable {
        public var sleepHours: Double?
        public var sleepConsistency: Double?   // 0…100
        public var weeklyZone13Min: Double?
        public var weeklyZone45Min: Double?
        public var weeklyStrengthMin: Double?
        public var dailySteps: Double?
        public var restingHR: Double?
        public var vo2max: Double?
        public var leanMassPct: Double?
        public var daysWithData: Int
        public init(sleepHours: Double? = nil, sleepConsistency: Double? = nil,
                    weeklyZone13Min: Double? = nil, weeklyZone45Min: Double? = nil,
                    weeklyStrengthMin: Double? = nil, dailySteps: Double? = nil,
                    restingHR: Double? = nil, vo2max: Double? = nil,
                    leanMassPct: Double? = nil, daysWithData: Int = 0) {
            self.sleepHours = sleepHours; self.sleepConsistency = sleepConsistency
            self.weeklyZone13Min = weeklyZone13Min; self.weeklyZone45Min = weeklyZone45Min
            self.weeklyStrengthMin = weeklyStrengthMin; self.dailySteps = dailySteps
            self.restingHR = restingHR; self.vo2max = vo2max
            self.leanMassPct = leanMassPct; self.daysWithData = daysWithData
        }
    }

    public struct Contributor: Equatable, Sendable {
        public var key: String
        public var label: String
        public var section: Section
        public var value: Double?
        public var value30: Double?
        public var unit: String
        public var target: Double
        public var targetLabel: String
        public var years: Double?
        public var years30: Double?
        public var scaleMin: Double
        public var scaleMax: Double
        public var higherIsBetter: Bool
        public var available: Bool
        public var citation: String
        public init(key: String, label: String, section: Section, value: Double?,
                    value30: Double?, unit: String, target: Double, targetLabel: String,
                    years: Double?, years30: Double?, scaleMin: Double, scaleMax: Double,
                    higherIsBetter: Bool, available: Bool, citation: String) {
            self.key = key; self.label = label; self.section = section
            self.value = value; self.value30 = value30; self.unit = unit
            self.target = target; self.targetLabel = targetLabel
            self.years = years; self.years30 = years30
            self.scaleMin = scaleMin; self.scaleMax = scaleMax
            self.higherIsBetter = higherIsBetter; self.available = available
            self.citation = citation
        }
    }

    public struct TrendPoint: Equatable, Sendable {
        public var day: String
        public var bandAge: Double
        public var chronoAge: Double
        public var pace: Double?
        public init(day: String, bandAge: Double, chronoAge: Double, pace: Double?) {
            self.day = day; self.bandAge = bandAge; self.chronoAge = chronoAge; self.pace = pace
        }
    }

    public struct Result: Equatable, Sendable {
        public var bandAge: Double?
        public var chronoAge: Double
        public var deltaYears: Double?          // chrono − bandAge; positive = younger
        public var pace: Double?
        public var readiness: Readiness
        public var missing: [String]
        public var contributors: [Contributor]
        public var trend: [TrendPoint]
        public var coverageDays: Int
        public var factorsUsed: Int
        public init(bandAge: Double?, chronoAge: Double, deltaYears: Double?, pace: Double?,
                    readiness: Readiness, missing: [String], contributors: [Contributor],
                    trend: [TrendPoint], coverageDays: Int, factorsUsed: Int) {
            self.bandAge = bandAge; self.chronoAge = chronoAge; self.deltaYears = deltaYears
            self.pace = pace; self.readiness = readiness; self.missing = missing
            self.contributors = contributors; self.trend = trend
            self.coverageDays = coverageDays; self.factorsUsed = factorsUsed
        }
    }

    // MARK: - Years conversion (patent)

    /// Years of age equivalent for an all-cause-mortality hazard ratio.
    /// WO2026161891A1: Years = ln(HR) / 0.1.
    public static func years(fromHazard hr: Double) -> Double {
        guard hr > 0 else { return 0 }
        return log(hr) / lnHazardPerYear
    }

    public static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, v))
    }

    public static func isFemale(_ sex: String) -> Bool { sex.lowercased() == "female" }

    // MARK: - Targets (health-optimized referents, not population means)

    /// Paluch 2022 Lancet Public Health: mortality benefit plateaus near 8,000–10,000 steps/day
    /// under age 60 and 6,000–8,000 at ≥60. The 8,000 / 6,000 floors are the 0-year referents.
    public static func stepsTarget(age: Double) -> Double { age >= 60 ? 6_000 : 8_000 }

    /// WHOOP Age guide / FRIEND-like cardiorespiratory-fitness target (ml/kg/min).
    /// About 44 (men) / 38 (women) at age 30, declining 0.4 ml/kg/min per year.
    public static func vo2Target(age: Double, sex: String) -> Double {
        let at30 = isFemale(sex) ? 38.0 : 44.0
        return max(18, at30 - 0.4 * (age - 30))
    }

    /// WHOOP Age guide: below 60 bpm (men) / 64 bpm (women).
    public static func rhrTarget(sex: String) -> Double { isFemale(sex) ? 64 : 60 }

    /// Momma 2022 BJSM nadir ~40 min/week of muscle-strengthening.
    public static let strengthTargetMin = 40.0
    /// WHO 2020 / WHOOP Age guide: ≥100 min/week zones 1–3 for younger adults.
    public static func zone13Target(age: Double) -> Double { age >= 60 ? 70 : 100 }
    /// WHOOP Age guide: ≥10 min/week zones 4–5.
    public static let zone45TargetMin = 10.0
    /// Cappuccio 2010 referent 7–8 h; WHOOP treats 7–9 h as the healthy band.
    public static let sleepHoursTarget = 7.5
    /// Windred 2024 / WHOOP Age guide: ≥70% sleep regularity.
    public static let consistencyTarget = 70.0
    /// WHOOP Age guide: ~80% men / 67% women lean mass in younger adults.
    public static func leanMassTarget(sex: String) -> Double { isFemale(sex) ? 67 : 80 }

    // MARK: - Per-metric hazard curves
    //
    // Each function returns an all-cause-mortality HR versus the health-optimized referent
    // (HR 1.0 at the target). Doc comments cite the source of the knots.

    /// Cappuccio FP et al. Sleep 2010;33:585–592. Pooled RR vs 7–8 h: short sleep 1.12
    /// (95% CI 1.06–1.18), long sleep 1.30 (1.22–1.38). U-shape; 7–8 h is the nadir.
    public static func sleepHoursHazard(_ hours: Double) -> Double {
        hazard(hours, knots: [
            (4.0, 1.28), (5.0, 1.12), (6.0, 1.06), (7.0, 1.00),
            (8.0, 1.00), (9.0, 1.15), (10.0, 1.30), (12.0, 1.30)
        ])
    }

    /// Windred DP et al. Sleep 2024;47:zsad253. UK Biobank accelerometer SRI. Fully adjusted
    /// all-cause HR for most-regular vs least-regular quintile ≈ 0.70. WHOOP's 70% target is
    /// the 0-year referent; 40% maps to the inverse (1/0.70 ≈ 1.43) and 100% to 0.70.
    public static func sleepConsistencyHazard(_ percent: Double) -> Double {
        hazard(clamp(percent, 0, 100), knots: [
            (40, 1.43), (70, 1.00), (100, 0.70)
        ])
    }

    /// Paluch AE et al. Lancet Public Health 2022;7:e219–e228. Device-measured steps,
    /// 15 cohorts. Quartile medians 3,553 / 5,801 / 7,842 / 10,901; HRs vs Q1: 0.60 / 0.55 /
    /// 0.47. Knots are those HRs re-based so Q3 (~8,000, the under-60 plateau) is HR 1.0.
    public static func stepsHazard(_ steps: Double, age: Double) -> Double {
        let target = stepsTarget(age: age)
        let scale = target / 8_000
        let x = steps / scale
        return hazard(x, knots: [
            (0, 2.20), (3_553, 1.82), (5_801, 1.09), (7_842, 1.00),
            (10_901, 0.85), (14_000, 0.85)
        ])
    }

    /// Arem H et al. JAMA Intern Med 2015;175:959–967. Leisure-time MVPA vs none:
    /// 0.1–7.4 MET-h/wk HR 0.80; meeting guidelines (7.5–14.9) HR 0.69; 2–3× HR 0.63;
    /// ≥3× HR 0.61. Re-based so 100 min/week (WHOOP young-adult zones 1–3 target / WHO
    /// moderate activity) is HR 1.0.
    public static func zone13Hazard(_ weeklyMin: Double) -> Double {
        hazard(weeklyMin, knots: [
            (0, 1.45), (100, 1.00), (150, 0.93), (300, 0.91), (600, 0.88)
        ])
    }

    /// WHO 2020 guidelines (75 min vigorous/week) plus Arem 2015 / WHOOP Age guide
    /// (≥10 min/week zones 4–5). 15–20 min vigorous/week is linked to ~18–24% lower
    /// mortality in accelerometer cohorts; 10 min is the 0-year referent.
    public static func zone45Hazard(_ weeklyMin: Double) -> Double {
        hazard(weeklyMin, knots: [
            (0, 1.22), (10, 1.00), (75, 0.85), (150, 0.80)
        ])
    }

    /// Momma H et al. Br J Sports Med 2022;56:755–763. Muscle-strengthening vs none
    /// RR 0.85; spline nadir ~40 min/week RR 0.83 (J-shaped; RR rises again past ~140 min).
    /// 40 min/week is the 0-year referent.
    public static func strengthHazard(_ weeklyMin: Double) -> Double {
        hazard(weeklyMin, knots: [
            (0, 1.205), (40, 1.00), (60, 0.95), (140, 1.00), (200, 1.08)
        ])
    }

    /// Zhang D et al. CMAJ 2016;188:E53–E63. 46 cohorts; RR 1.09 (1.07–1.12) per 10 bpm
    /// increment in resting heart rate. Applied versus the sex-specific target.
    public static func restingHRHazard(_ bpm: Double, sex: String) -> Double {
        let delta = (bpm - rhrTarget(sex: sex)) / 10.0
        return pow(1.09, delta)
    }

    /// Kodama S et al. JAMA 2009;301:2024–2035. 1 MET (3.5 ml/kg/min) higher CRF →
    /// RR 0.87 all-cause mortality. Mandsager W et al. JAMA Netw Open 2018;1:e183605
    /// confirms CRF as a steep graded predictor (elite vs low). Slope is Kodama;
    /// the age/sex target is the 0-year referent.
    public static func vo2Hazard(_ vo2: Double, age: Double, sex: String) -> Double {
        let mets = (vo2 - vo2Target(age: age, sex: sex)) / 3.5
        return pow(0.87, mets)
    }

    /// Srikanthan P, Karlamangla AS. Am J Med 2014;127:547–555. Low muscle mass vs
    /// higher quartiles, all-cause HR ≈ 1.23. Linear to the WHOOP Age guide target
    /// (80% men / 67% women); no extra credit above the target (matching WHOOP's 0.0
    /// years at 86.5% lean mass).
    public static func leanMassHazard(_ percent: Double, sex: String) -> Double {
        let target = leanMassTarget(sex: sex)
        let floor = isFemale(sex) ? 50.0 : 60.0
        if percent >= target { return 1.0 }
        return hazard(percent, knots: [(floor, 1.23), (target, 1.00)])
    }

    /// Piecewise-linear interpolation of (x, HR) knots; clamps to the end knots.
    public static func hazard(_ x: Double, knots: [(Double, Double)]) -> Double {
        guard let first = knots.first, let last = knots.last else { return 1 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for i in 1..<knots.count {
            let (x0, h0) = knots[i - 1]
            let (x1, h1) = knots[i]
            if x <= x1 {
                let t = (x - x0) / (x1 - x0)
                return h0 + (h1 - h0) * t
            }
        }
        return last.1
    }

    // MARK: - Sports / zones helpers (DB-free)

    /// WHOOP Healthspan strength list: strength, weightlifting, pilates, yoga, HIIT,
    /// functional fitness, rucking — plus powerlifting / cross-fit aliases.
    public static func isStrengthSport(_ name: String) -> Bool {
        let s = name.lowercased()
        let keys = ["strength", "weight", "lift", "pilates", "yoga", "hiit",
                    "functional", "ruck", "crossfit", "cross-fit", "powerlift"]
        return keys.contains { s.contains($0) }
    }

    /// Parse imported zone percentages. Accepts `z1`…`z5` and `zone1`…`zone5`.
    public static func zonePercents(fromJSON json: String?) -> [Double]? {
        guard let json, let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let p = (1...5).map { i -> Double in
            let v = (obj["z\(i)"] ?? obj["zone\(i)"]) as? NSNumber
            return min(max(v?.doubleValue ?? 0, 0), 100)
        }
        return p.contains(where: { $0 > 0 }) ? p : nil
    }

    public static func zoneMinutes(percents: [Double], durationMin: Double) -> (z13: Double, z45: Double) {
        let p = percents + Array(repeating: 0, count: max(0, 5 - percents.count))
        let z13 = durationMin * (p[0] + p[1] + p[2]) / 100
        let z45 = durationMin * (p[3] + p[4]) / 100
        return (z13, z45)
    }

    /// `lean_mass` in Band is often kilograms. Values in (0, 1] are fractions;
    /// values below body mass are kg; otherwise a percentage.
    public static func leanMassPercent(stored: Double, weightKg: Double?) -> Double? {
        if stored <= 0 { return nil }
        if stored <= 1 { return stored * 100 }
        if let w = weightKg, w > 0, stored < w { return 100 * stored / w }
        if stored <= 100 { return stored }
        return nil
    }

    // MARK: - Sleep consistency from bed/wake clocks

    /// SRI-style last-vs-each over 5 nights (today + prior 4), matching WHOOP's
    /// "last 24 hours vs the prior 4 days". Uses BandConsistency; identity affine
    /// so 100 = identical sleep-wake masks.
    public static func sleepConsistency(nights: [(onsetMin: Int, wakeMin: Int)]) -> [Double] {
        let masks = nights.map {
            BandConsistency.mask(onsetMin: $0.onsetMin, wakeMin: $0.wakeMin, naps: [])
        }
        let params = BandConsistency.Params(
            nNights: 5, mode: "last_vs_each", recency: 0.7,
            intercept: 0, slope: 1, clipLo: 0, clipHi: 100
        )
        return BandConsistency.run(masks: masks, params: params).mapped
    }

    // MARK: - Window summary

    public static func summarize(_ days: [Day], ending: String, windowDays: Int) -> Window {
        guard windowDays > 0, let endEpoch = isoEpochDay(ending) else { return Window() }
        let startEpoch = endEpoch - (windowDays - 1)
        let slice = days.filter { day in
            guard let e = isoEpochDay(day.day) else { return false }
            return e >= startEpoch && e <= endEpoch
        }
        let weeks = Double(windowDays) / 7.0
        let sleepHours = mean(slice.compactMap(\.sleepHours))
        let consistency: Double?
        let precomputed = slice.compactMap(\.sleepConsistency)
        if precomputed.count >= 3 {
            consistency = mean(precomputed)
        } else {
            let clocks: [(Int, Int)] = slice.compactMap {
                guard let a = $0.sleepOnsetMin, let b = $0.sleepWakeMin else { return nil }
                return (a, b)
            }
            let mapped = sleepConsistency(nights: clocks).filter { $0.isFinite }
            consistency = mapped.count >= 3 ? mean(mapped) : nil
        }
        let z13 = sum(slice.compactMap(\.zone13Min))
        let z45 = sum(slice.compactMap(\.zone45Min))
        let strength = sum(slice.compactMap(\.strengthMin))
        let used = Set(slice.compactMap { d -> String? in
            if d.sleepHours != nil || d.restingHR != nil || d.steps != nil
                || d.zone13Min != nil || d.vo2max != nil { return d.day }
            return nil
        })
        return Window(
            sleepHours: sleepHours,
            sleepConsistency: consistency,
            weeklyZone13Min: z13 > 0 ? z13 / weeks : nil,
            weeklyZone45Min: z45 > 0 ? z45 / weeks : nil,
            weeklyStrengthMin: strength > 0 ? strength / weeks : nil,
            dailySteps: mean(slice.compactMap(\.steps)),
            restingHR: mean(slice.compactMap(\.restingHR)),
            vo2max: mean(slice.compactMap(\.vo2max)),
            leanMassPct: mean(slice.compactMap(\.leanMassPct)),
            daysWithData: used.count
        )
    }

    // MARK: - Contributors + score

    public static func compute(profile: Profile, sixMonth: Window, thirtyDay: Window,
                               coverageDays: Int, asOfDay: String? = nil,
                               days: [Day] = []) -> Result {
        let age = profile.chronoAge
        let sex = profile.sex
        let six = contributors(window: sixMonth, profile: profile)
        let thirty = contributors(window: thirtyDay, profile: profile)
        let merged: [Contributor] = six.enumerated().map { idx, c in
            let t = thirty[idx]
            var out = c
            out.value30 = t.value
            out.years30 = t.years
            return out
        }
        let used = six.filter { $0.available && $0.years != nil }
        let delta180 = used.reduce(0.0) { $0 + ($1.years ?? 0) }
        let used30 = thirty.filter { $0.available && $0.years != nil }
        let delta30 = used30.reduce(0.0) { $0 + ($1.years ?? 0) }

        var missing: [String] = []
        if age <= 0 { missing.append("Your age in Profile") }
        if sixMonth.sleepHours == nil { missing.append("Sleep hours") }
        if sixMonth.sleepConsistency == nil { missing.append("Sleep consistency (bed and wake times)") }
        if sixMonth.weeklyZone13Min == nil { missing.append("Time in HR zones 1–3 from workouts") }
        if sixMonth.weeklyZone45Min == nil { missing.append("Time in HR zones 4–5 from workouts") }
        if sixMonth.weeklyStrengthMin == nil { missing.append("Strength activity time") }
        if sixMonth.dailySteps == nil { missing.append("Daily steps") }
        if sixMonth.restingHR == nil { missing.append("Resting heart rate") }
        if sixMonth.vo2max == nil { missing.append("VO₂ max from Apple Health") }
        if sixMonth.leanMassPct == nil {
            missing.append("Lean body mass (not on this device — left out of Band Age)")
        }
        if coverageDays < minDaysForAge {
            missing.append("About \(minDaysForAge - coverageDays) more days of wear for a 6-month Band Age")
        }

        let factors = used.count
        let canScore = age > 0 && factors >= minContributors
        let readiness: Readiness
        if !canScore || coverageDays < minDaysForPace {
            readiness = .notReady
        } else if coverageDays < minDaysForAge {
            readiness = .calibrating
        } else {
            readiness = .ready
        }

        var bandAge: Double? = nil
        var deltaYears: Double? = nil
        if canScore {
            let raw = clamp(age + delta180, minBandAge, maxBandAge)
            bandAge = raw
            deltaYears = age - raw
        }

        var pace: Double? = nil
        if canScore, thirtyDay.daysWithData >= minDaysForPace, used30.count >= minContributors {
            // Project 30-day habits over 6 months and compare to current Band Age.
            // pace = 1 + (Δ30 − Δ180) / 0.5 so matched windows read 1.0×.
            pace = clamp(1 + (delta30 - delta180) / 0.5, minPace, maxPace)
        }

        let trend: [TrendPoint]
        if let asOfDay, !days.isEmpty, canScore {
            trend = trendPoints(days: days, profile: profile, asOfDay: asOfDay)
        } else {
            trend = []
        }

        return Result(bandAge: bandAge, chronoAge: age, deltaYears: deltaYears, pace: pace,
                      readiness: readiness, missing: missing, contributors: merged,
                      trend: trend, coverageDays: coverageDays, factorsUsed: factors)
    }

    public static func compute(days: [Day], profile: Profile, asOfDay: String) -> Result {
        let filled = fillingConsistency(days)
        let six = summarize(filled, ending: asOfDay, windowDays: ageWindowDays)
        let thirty = summarize(filled, ending: asOfDay, windowDays: paceWindowDays)
        return compute(profile: profile, sixMonth: six, thirtyDay: thirty,
                       coverageDays: six.daysWithData, asOfDay: asOfDay, days: filled)
    }

    /// Score each night's SRI once so 6-month / 30-day / trend windows reuse it.
    public static func fillingConsistency(_ days: [Day]) -> [Day] {
        let sorted = days.sorted { $0.day < $1.day }
        let nights = sorted.map { d -> (onsetMin: Int, wakeMin: Int) in
            (d.sleepOnsetMin ?? 0, d.sleepWakeMin ?? 0)
        }
        let mapped = sleepConsistency(nights: nights)
        return zip(sorted, mapped).map { day, value in
            var out = day
            if out.sleepConsistency == nil, value.isFinite { out.sleepConsistency = value }
            return out
        }
    }

    public static func contributors(window: Window, profile: Profile) -> [Contributor] {
        let age = profile.chronoAge
        let sex = profile.sex
        func row(key: String, label: String, section: Section, value: Double?,
                 unit: String, target: Double, targetLabel: String,
                 years: Double?, scaleMin: Double, scaleMax: Double,
                 higherIsBetter: Bool, available: Bool, citation: String) -> Contributor {
            Contributor(key: key, label: label, section: section, value: value, value30: nil,
                        unit: unit, target: target, targetLabel: targetLabel,
                        years: years, years30: nil, scaleMin: scaleMin, scaleMax: scaleMax,
                        higherIsBetter: higherIsBetter, available: available, citation: citation)
        }
        let sleepY = window.sleepHours.map { years(fromHazard: sleepHoursHazard($0)) }
        let consY = window.sleepConsistency.map { years(fromHazard: sleepConsistencyHazard($0)) }
        let z13Y = window.weeklyZone13Min.map { years(fromHazard: zone13Hazard($0)) }
        let z45Y = window.weeklyZone45Min.map { years(fromHazard: zone45Hazard($0)) }
        let strY = window.weeklyStrengthMin.map { years(fromHazard: strengthHazard($0)) }
        let stepY = window.dailySteps.map { years(fromHazard: stepsHazard($0, age: age)) }
        let rhrY = window.restingHR.map { years(fromHazard: restingHRHazard($0, sex: sex)) }
        let vo2Y = window.vo2max.map { years(fromHazard: vo2Hazard($0, age: age, sex: sex)) }
        let lbmY = window.leanMassPct.map { years(fromHazard: leanMassHazard($0, sex: sex)) }
        return [
            row(key: "consistency", label: "Sleep Consistency", section: .sleep,
                value: window.sleepConsistency, unit: "%", target: consistencyTarget,
                targetLabel: "≥ 70%", years: consY, scaleMin: 40, scaleMax: 100,
                higherIsBetter: true, available: window.sleepConsistency != nil,
                citation: "Windred 2024 Sleep; UK Biobank SRI, most- vs least-regular HR ≈ 0.70."),
            row(key: "sleep", label: "Hours of Sleep", section: .sleep,
                value: window.sleepHours, unit: "h", target: sleepHoursTarget,
                targetLabel: "7–9 h", years: sleepY, scaleMin: 5, scaleMax: 9,
                higherIsBetter: true, available: window.sleepHours != nil,
                citation: "Cappuccio 2010 Sleep; U-shape vs 7–8 h, short RR 1.12, long RR 1.30."),
            row(key: "zone13", label: "Time in HR Zones 1–3 (Weekly)", section: .strain,
                value: window.weeklyZone13Min, unit: "min", target: zone13Target(age: age),
                targetLabel: "≥ \(Int(zone13Target(age: age))) min", years: z13Y,
                scaleMin: 0, scaleMax: 360, higherIsBetter: true,
                available: window.weeklyZone13Min != nil,
                citation: "Arem 2015 JAMA Intern Med; WHO 2020 150 min moderate / WHOOP ≥100 min Z1–3."),
            row(key: "zone45", label: "Time in HR Zones 4–5 (Weekly)", section: .strain,
                value: window.weeklyZone45Min, unit: "min", target: zone45TargetMin,
                targetLabel: "≥ 10 min", years: z45Y, scaleMin: 0, scaleMax: 60,
                higherIsBetter: true, available: window.weeklyZone45Min != nil,
                citation: "WHO 2020 75 min vigorous; WHOOP Age guide ≥10 min Z4–5."),
            row(key: "strength", label: "Strength Activity Time (Weekly)", section: .strain,
                value: window.weeklyStrengthMin, unit: "min", target: strengthTargetMin,
                targetLabel: "≥ 40 min", years: strY, scaleMin: 0, scaleMax: 120,
                higherIsBetter: true, available: window.weeklyStrengthMin != nil,
                citation: "Momma 2022 Br J Sports Med; nadir ~40 min/week, RR 0.83 vs none."),
            row(key: "steps", label: "Steps", section: .strain,
                value: window.dailySteps, unit: "", target: stepsTarget(age: age),
                targetLabel: "≥ \(Int(stepsTarget(age: age)))", years: stepY,
                scaleMin: 0, scaleMax: 16_000, higherIsBetter: true,
                available: window.dailySteps != nil,
                citation: "Paluch 2022 Lancet Public Health; plateau ~8k steps/day under 60."),
            row(key: "vo2max", label: "VO₂ Max", section: .fitness,
                value: window.vo2max, unit: "ml/kg/min", target: vo2Target(age: age, sex: sex),
                targetLabel: "≥ \(Int(vo2Target(age: age, sex: sex).rounded()))", years: vo2Y,
                scaleMin: 15, scaleMax: 70, higherIsBetter: true,
                available: window.vo2max != nil,
                citation: "Kodama 2009 JAMA, RR 0.87 per MET; Mandsager 2018 JAMA Netw Open."),
            row(key: "rhr", label: "RHR", section: .fitness,
                value: window.restingHR, unit: "bpm", target: rhrTarget(sex: sex),
                targetLabel: "< \(Int(rhrTarget(sex: sex))) bpm", years: rhrY,
                scaleMin: 40, scaleMax: 80, higherIsBetter: false,
                available: window.restingHR != nil,
                citation: "Zhang 2016 CMAJ meta-analysis; RR 1.09 per 10 bpm."),
            row(key: "lean", label: "Lean Body Mass", section: .fitness,
                value: window.leanMassPct, unit: "%", target: leanMassTarget(sex: sex),
                targetLabel: "≥ \(Int(leanMassTarget(sex: sex)))%", years: lbmY,
                scaleMin: 50, scaleMax: 90, higherIsBetter: true,
                available: window.leanMassPct != nil,
                citation: "Srikanthan 2014 Am J Med; low muscle mass all-cause HR ≈ 1.23."),
        ]
    }

    // MARK: - Trend (weekly lookbacks)

    public static func trendPoints(days: [Day], profile: Profile, asOfDay: String) -> [TrendPoint] {
        guard let end = isoEpochDay(asOfDay) else { return [] }
        var points: [TrendPoint] = []
        var cursor = end
        let oldest = days.compactMap { isoEpochDay($0.day) }.min() ?? end
        let start = max(oldest + 21, end - 180)
        while cursor >= start {
            guard let key = isoString(cursor) else { break }
            let six = summarize(days, ending: key, windowDays: ageWindowDays)
            let thirty = summarize(days, ending: key, windowDays: paceWindowDays)
            let ageThen = profile.chronoAge - Double(end - cursor) / 365.25
            let r = compute(profile: Profile(chronoAge: ageThen, sex: profile.sex),
                            sixMonth: six, thirtyDay: thirty,
                            coverageDays: six.daysWithData)
            if let band = r.bandAge {
                points.append(TrendPoint(day: key, bandAge: band, chronoAge: ageThen, pace: r.pace))
            }
            cursor -= 7
        }
        return points.reversed()
    }

    // MARK: - Internals

    private static func mean(_ xs: [Double]) -> Double? {
        let ys = xs.filter { $0.isFinite }
        guard !ys.isEmpty else { return nil }
        return ys.reduce(0, +) / Double(ys.count)
    }

    private static func sum(_ xs: [Double]) -> Double {
        xs.filter(\.isFinite).reduce(0, +)
    }

    /// Civil epoch day for `yyyy-MM-dd` (Howard Hinnant, TZ-free).
    public static func isoEpochDay(_ iso: String) -> Int? {
        let p = iso.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              m >= 1, m <= 12 else { return nil }
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public static func isoString(_ epochDay: Int) -> String? {
        var z = epochDay + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        y += (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}

import Foundation
import StrandAnalytics
import StrandImport
import WhoopProtocol

// bandcheck — agreement with WHOOP + self-invariants on a real wearer DB.
//
// USAGE:
//   swift run --package-path Tools/BandCheck bandcheck \
//     --db /tmp/band-pull/O4/whoop.sqlite \
//     --export ~/band/whoop-export
//
// Paths may also come from BANDCHECK_DB / BANDCHECK_EXPORT / BANDCHECK_THRESHOLDS.
// The database is never written to and never lives in this repository. Pass a COPY.

struct Args {
    var db = ""
    var export = ""
    var thresholds = ""
    var streamDevice = "my-whoop"
    var importedDevice = "my-whoop"
    var computedDevice = "my-whoop-noop"
    var tz = TimeZone.current.identifier
    var age: Double?
    var hrMax: Double?
    var weightKg: Double?
    var heightCm: Double?
    var sex: String?
    var verbose = false
    var json: String?
    var labels: String?
}

func parseArgs() -> Args {
    var a = Args()
    let env = ProcessInfo.processInfo.environment
    a.db = env["BANDCHECK_DB"] ?? a.db
    a.export = env["BANDCHECK_EXPORT"] ?? a.export
    a.thresholds = env["BANDCHECK_THRESHOLDS"] ?? a.thresholds
    a.labels = env["BANDCHECK_LABELS"] ?? a.labels
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let k = it.next() {
        switch k {
        case "--db": a.db = it.next() ?? a.db
        case "--export": a.export = it.next() ?? a.export
        case "--thresholds": a.thresholds = it.next() ?? a.thresholds
        case "--device", "--stream-device": a.streamDevice = it.next() ?? a.streamDevice
        case "--imported-device": a.importedDevice = it.next() ?? a.importedDevice
        case "--computed-device": a.computedDevice = it.next() ?? a.computedDevice
        case "--tz": a.tz = it.next() ?? a.tz
        case "--age": a.age = Double(it.next() ?? "")
        case "--hr-max": a.hrMax = Double(it.next() ?? "")
        case "--weight-kg": a.weightKg = Double(it.next() ?? "")
        case "--height-cm": a.heightCm = Double(it.next() ?? "")
        case "--sex": a.sex = it.next() ?? a.sex
        case "--verbose": a.verbose = true
        case "--json": a.json = it.next()
        case "--labels": a.labels = it.next()
        case "-h", "--help": a.db = ""
        default:
            FileHandle.standardError.write(Data("unknown argument \(k)\n".utf8))
            exit(2)
        }
    }
    return a
}

let usage = """
usage: bandcheck --db <sqlite> --export <whoop-csv-dir> [--thresholds <json>]
                 [--stream-device <id>] [--imported-device <id>] [--computed-device <id>]
                 [--tz <iana>] [--age <y>] [--hr-max <bpm>]
                 [--weight-kg <kg>] [--height-cm <cm>] [--sex male|female|nonbinary]
                 [--verbose] [--json <path>] [--labels <json>]

  One command that, before every install, says whether Band still agrees with WHOOP
  and with itself on this wearer's real data. Paths are arguments or env vars
  (BANDCHECK_DB, BANDCHECK_EXPORT, BANDCHECK_THRESHOLDS). Output is aggregates only;
  --verbose prints per-day pairs to stdout and must never be written into the repo.

  NativeBandScores (Strand/Native) is app-target only and is not imported; the replay
  uses BandScores.evaluate, which is what NativeBandScores wraps. WorkoutZones is
  likewise skipped; zone minutes come from the WHOOP export columns.
"""

var args = parseArgs()
if args.thresholds.isEmpty {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    args.thresholds = here.appendingPathComponent("thresholds.json").path
}
guard !args.db.isEmpty, !args.export.isEmpty else {
    print(usage)
    exit(2)
}
guard FileManager.default.fileExists(atPath: args.db) else {
    fputs("db not found: \(args.db)\n", stderr); exit(2)
}
guard FileManager.default.fileExists(atPath: args.export) else {
    fputs("export not found: \(args.export)\n", stderr); exit(2)
}

let tz = TimeZone(identifier: args.tz) ?? TimeZone.current
let calendar = DayKey.calendar(tz: tz)

let db = try ReadOnlyDB(path: args.db)
let (whoopDays, whoopWorkouts, whoopSleeps, whoopQuestions) = try Perf.measure("load_export") {
    try loadWhoopExport(path: args.export)
}
let daily = try Perf.measure("load_daily") { try db.dailyMetrics() }
let sleeps = try Perf.measure("load_sleeps") { try db.sleepSessions() }
let workouts = try Perf.measure("load_workouts") { try db.workouts() }
let apple = try db.appleDaily()
let journal = try db.journal()
let series = try db.metricSeries(keys: ["vo2max", "vo2max_est", "steps", "sleep_performance", "energy_kcal"])
let hrSpan = try db.hrSpan()

var hrByDay: [String: [HRSample]] = [:]
var gravByDay: [String: [GravitySample]] = [:]
var stepsByDay: [String: [StepSample]] = [:]
var rrByDay: [String: [RRInterval]] = [:]
var skinByDay: [String: [SkinTempSample]] = [:]
if let span = hrSpan {
    let hr = try Perf.measure("load_hr") {
        try db.coalescedHR(device: args.streamDevice, from: span.from, to: span.to)
    }
    let grav = try Perf.measure("load_gravity") {
        try db.gravity(device: args.streamDevice, from: span.from, to: span.to)
    }
    let steps = try Perf.measure("load_steps") {
        try db.steps(device: args.streamDevice, from: span.from, to: span.to)
    }
    Perf.measure("bucket_by_day", days: 0) {
        var cursor = DayKey.LogicalCursor(calendar: calendar)
        for s in hr {
            hrByDay[cursor.logical(s.ts), default: []].append(s)
        }
        cursor = DayKey.LogicalCursor(calendar: calendar)
        for g in grav {
            gravByDay[cursor.logical(g.ts), default: []].append(g)
        }
        cursor = DayKey.LogicalCursor(calendar: calendar)
        for s in steps {
            stepsByDay[cursor.logical(s.ts), default: []].append(s)
        }
    }
    if Perf.analysisReplay {
        let rr = try Perf.measure("load_rr") {
            try db.rrIntervals(device: args.streamDevice, from: span.from, to: span.to)
        }
        let skin = try Perf.measure("load_skin") {
            try db.skinTemp(device: args.streamDevice, from: span.from, to: span.to)
        }
        Perf.measure("bucket_rr_skin") {
            var cursor = DayKey.LogicalCursor(calendar: calendar)
            for r in rr {
                rrByDay[cursor.logical(r.ts), default: []].append(r)
            }
            cursor = DayKey.LogicalCursor(calendar: calendar)
            for s in skin {
                skinByDay[cursor.logical(s.ts), default: []].append(s)
            }
        }
    }
}

let allBpm = hrByDay.values.flatMap { $0.map { Double($0.bpm) } }
// p99.5 of every sample (sleep included) sits near resting HR. Floor with Tanaka when
// the caller did not pass --hr-max, same as StrainScorer.estimateHRmax with an age.
let age = args.age ?? (args.hrMax == nil ? 35 : nil)
let (estMax, maxSrc) = StrainScorer.estimateHRmax(allBpm, age: age)
let hrMax = args.hrMax ?? (estMax > 0 ? estMax : StrainScorer.tanakaHRmax(age: age ?? 35))

guard let strainParams = BandStrain.bundledParams() else {
    fputs("BandStrain params missing from StrandAnalytics bundle\n", stderr); exit(2)
}
let scoreParams = try BandScores.Params.bundled()

let profile = UserProfile(
    weightKg: args.weightKg ?? 70,
    heightCm: args.heightCm ?? 170,
    age: args.age ?? 30,
    sex: args.sex ?? "nonbinary")

let cfg = CheckConfig(
    verbose: args.verbose, calendar: calendar,
    streamDevice: args.streamDevice, importedDevice: args.importedDevice,
    computedDevice: args.computedDevice, hrMax: hrMax,
    strainParams: strainParams, scoreParams: scoreParams, profile: profile)

let (agreements, _) = Perf.measure("agreementChecks") {
    agreementChecks(
        whoopDays: whoopDays, whoopWorkouts: whoopWorkouts, whoopSleeps: whoopSleeps,
        daily: daily, sleeps: sleeps, workouts: workouts, hrByDay: hrByDay,
        energySeries: series, cfg: cfg)
}

var rhrByDay: [String: Double] = [:]
for d in whoopDays { if let v = d.rhr { rhrByDay[d.day] = v } }
for r in daily where r.deviceId == args.computedDevice || r.deviceId == args.importedDevice {
    if let v = r.restingHr { rhrByDay[r.day] = v }
}
let labels = try args.labels.map { try WorkoutLabels.load(path: $0) } ?? WorkoutLabels()
let detection = Perf.measure("detectionChecks") {
    detectionChecks(
        whoopWorkouts: whoopWorkouts, dbWorkouts: workouts,
        hrByDay: hrByDay, gravByDay: gravByDay, rhrByDay: rhrByDay, labels: labels, cfg: cfg)
}

var invariants = try Perf.measure("invariantChecks") {
    try invariantChecks(
        daily: daily, apple: apple, workouts: workouts, journal: journal, series: series,
        whoopQuestions: whoopQuestions, hrSpan: hrSpan, db: db,
        appleHRDir: URL(fileURLWithPath: args.db).deletingLastPathComponent()
            .appendingPathComponent("apple-workout-hr"),
        cfg: cfg)
}
let stressGate = Perf.measure("stressGateCheck") {
    stressGateCheck(
        hrByDay: hrByDay, gravByDay: gravByDay, stepsByDay: stepsByDay,
        workouts: workouts, rhrByDay: rhrByDay, cfg: cfg)
}
invariants.append(stressGate.result)

let rhrDef = Perf.measure("rhrDefinitionCheck") {
    rhrDefinitionCheck(whoopDays: whoopDays, sleeps: sleeps,
                       hrByDay: hrByDay, cfg: cfg)
}
let illnessRates = Perf.measure("illnessRate") {
    illnessRateReports(daily: daily, whoopDays: whoopDays,
                       importedDevice: args.importedDevice,
                       computedDevice: args.computedDevice)
}

let thresholds: Thresholds
if FileManager.default.fileExists(atPath: args.thresholds) {
    thresholds = try Thresholds.load(path: args.thresholds)
} else {
    fputs("thresholds file missing (\(args.thresholds)); using defaults that fail any invariant\n", stderr)
    thresholds = .defaults
}
let fails = evaluateGates(agreements: agreements, detection: detection,
                          invariants: invariants, thresholds: thresholds)

let overlapImported = Set(whoopDays.map(\.day)).intersection(daily.filter { $0.deviceId == args.importedDevice }.map(\.day))
let overlapComputed = Set(whoopDays.map(\.day)).intersection(daily.filter { $0.deviceId == args.computedDevice }.map(\.day))

print("""

================================================================================
BANDCHECK
================================================================================
db            \(args.db)
export        \(args.export)
tz            \(tz.identifier)  (4h logical-day rollover)
hrmax         \(String(format: "%.1f", hrMax)) (\(args.hrMax != nil ? "flag" : maxSrc))
whoop days    \(whoopDays.count)   workouts \(whoopWorkouts.count)   sleeps \(whoopSleeps.count)
overlap       imported \(overlapImported.count) days   computed \(overlapComputed.count) days
hr window     \(hrByDay.count) logical days, \(hrByDay.values.reduce(0) { $0 + $1.count }) samples
""")

print("""
A. AGREEMENT WITH WHOOP
--------------------------------------------------------------------------------
check                              n      MAE     bias   within tol          worst-day
""")
for a in agreements {
    let worst = a.worstDay.map { "\($0) Δ\(fmt(a.worstAbsErr ?? .nan, 5, 2).trimmingCharacters(in: .whitespaces))" } ?? ""
    let name = a.name.padding(toLength: 32, withPad: " ", startingAt: 0)
    print("\(name) \(String(format: "%4d", a.n)) \(fmt(a.mae)) \(fmt(a.bias)) \(pct(a.withinTol))  ±\(String(format: "%.2g", a.tolerance))  \(worst)")
}

print("""

B. WORKOUT DETECTION  (AutoWorkoutDetector, \(AutoWorkoutDetector.minSustainedMin) min, motion confirm)
--------------------------------------------------------------------------------
against                    pred   ref    TP   precision   recall   F1
""")
for name in ["whoop", "phone_apple_manual", "union"] {
    guard let m = detection[name] else { continue }
    let label = name.padding(toLength: 22, withPad: " ", startingAt: 0)
    print("\(label) \(String(format: "%5d %5d %5d", m.predicted, m.reference, m.truePositives))   \(pct(m.precision))   \(pct(m.recall))  \(fmt(m.f1, 6, 3))")
    if !m.falsePositives.isEmpty {
        print("  false positives (start + duration only):")
        let fmtISO = ISO8601DateFormatter()
        fmtISO.timeZone = tz
        for fp in m.falsePositives.prefix(20) {
            let start = fmtISO.string(from: Date(timeIntervalSince1970: TimeInterval(fp.start)))
            print("    \(start)  \(fp.durationSec / 60) min")
        }
        if m.falsePositives.count > 20 {
            print("    … \(m.falsePositives.count - 20) more")
        }
    }
}

print("""

C. INVARIANTS ON THE PHONE DB
--------------------------------------------------------------------------------
""")
for r in invariants {
    let mark = r.pass ? "PASS" : "FAIL"
    let label = r.name.padding(toLength: 28, withPad: " ", startingAt: 0)
    print("  \(mark)  \(label)  fail \(r.failCount) / checked \(r.checked)  \(r.note)")
}
print("  stress gate  \(stressGate.latest)")

print("""

D. RHR DEFINITION A/B  (export RHR vs replayed sleep-window HR; not a gate)
--------------------------------------------------------------------------------
check                              n      MAE     bias   within tol
""")
for a in [rhrDef.floorAll, rhrDef.meanAll, rhrDef.floorHoldout, rhrDef.meanHoldout] {
    let name = a.name.padding(toLength: 32, withPad: " ", startingAt: 0)
    print("\(name) \(String(format: "%4d", a.n)) \(fmt(a.mae)) \(fmt(a.bias)) \(pct(a.withinTol))")
}
print("  ship mean−2.2  \(rhrDef.shipMeanMinus ? "yes (holdout MAE lower)" : "no (floor wins or n<5)")")

print("""

E. ILLNESS SIGNAL  (BandIllnessSignal lagged median baseline; episodes / 60 days)
--------------------------------------------------------------------------------
""")
for r in illnessRates {
    let src = r.source.padding(toLength: 14, withPad: " ", startingAt: 0)
    print("  \(src)  nights \(r.nights)  span \(r.spanDays)  episodes \(r.episodes)  watch-nights \(r.watchNights)  per-60-days \(String(format: "%.3f", r.per60))")
}

print("""

SKIPPED (app-target only; not moved)
  NativeBandScores          Strand/Native/NativeBandScores.swift  — replay uses BandScores.evaluate
  WorkoutZones              Strand/Data/WorkoutZones.swift        — zone % from the WHOOP export
  JournalCatalog.canonical  Strand/Data/JournalCatalog.swift      — title-key fold only, no alias table
  WorkoutSource.classify    Strand/Data/WorkoutSource.swift       — suffix/source string checks instead
""")

if !fails.isEmpty {
    print("\nTHRESHOLD REGRESSIONS (\(fails.count))")
    for f in fails { print("  \(f.check): \(f.detail)") }
}

let worst = agreements.filter { $0.n > 0 }.sorted { $0.mae > $1.mae }
if let top = worst.first {
    print("\nWORST AGREEMENT  \(top.name)  MAE \(fmt(top.mae))  n=\(top.n)  worst-day \(top.worstDay ?? "—")")
}
let failInv = invariants.filter { !$0.pass }
if !failInv.isEmpty {
    print("FAILING INVARIANTS  " + failInv.map { "\($0.name)=\($0.failCount)" }.joined(separator: ", "))
}

if let path = args.json {
    let payload = reportJSON(agreements: agreements, detection: detection,
                             invariants: invariants, fails: fails)
    try payload.write(toFile: path, atomically: true, encoding: .utf8)
}

if Perf.analysisReplay {
    replayAnalysisPass(hrByDay: hrByDay, gravByDay: gravByDay, stepsByDay: stepsByDay,
                       rrByDay: rrByDay, skinByDay: skinByDay, cfg: cfg)
}
print(Perf.report())

exit(fails.isEmpty ? 0 : 1)

func reportJSON(agreements: [SeriesAgreement], detection: [String: MatchStats],
                invariants: [InvariantResult], fails: [GateFail]) -> String {
    func num(_ v: Double) -> Any { v.isFinite ? v : NSNull() }
    var agr: [[String: Any]] = []
    for a in agreements {
        agr.append([
            "name": a.name, "n": a.n, "mae": num(a.mae), "bias": num(a.bias),
            "within_tol": num(a.withinTol), "tolerance": a.tolerance,
            "worst_day": a.worstDay as Any,
        ])
    }
    var det: [String: Any] = [:]
    for (k, m) in detection {
        det[k] = [
            "predicted": m.predicted, "reference": m.reference, "tp": m.truePositives,
            "precision": num(m.precision), "recall": num(m.recall),
            "false_positives": m.falsePositives.map { ["start": $0.start, "duration_sec": $0.durationSec] },
        ]
    }
    let inv = invariants.map {
        ["name": $0.name, "pass": $0.pass, "fail_count": $0.failCount, "checked": $0.checked]
    }
    let obj: [String: Any] = [
        "agreements": agr, "detection": det, "invariants": inv,
        "regressions": fails.map { ["check": $0.check, "detail": $0.detail] },
    ]
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
}

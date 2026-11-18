import XCTest
@testable import StrandImport

/// Round-trip contract: serialize with WhoopCsvExporter, re-parse with WhoopExportImporter,
/// assert field-level equality. Synthetic data only — never reads a real WHOOP export folder.
final class WhoopCsvExporterTests: XCTestCase {

    private let tzNeg5 = -300  // UTC-05:00
    private let tzPos1 = 60    // UTC+01:00

    // MARK: - Headers

    func testHeadersMatchWhoopExactly() {
        XCTAssertEqual(
            WhoopCsvExporter.cyclesHeader,
            "Cycle start time,Cycle end time,Cycle timezone,Recovery score %,"
            + "Resting heart rate (bpm),Heart rate variability (ms),Skin temp (celsius),"
            + "Blood oxygen %,Day Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),"
            + "Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),"
            + "Asleep duration (min),In bed duration (min),Light sleep duration (min),"
            + "Deep (SWS) duration (min),REM duration (min),Awake duration (min),"
            + "Sleep need (min),Sleep debt (min),Sleep efficiency %,Sleep consistency %"
        )
        XCTAssertEqual(
            WhoopCsvExporter.sleepsHeader,
            "Cycle start time,Cycle end time,Cycle timezone,Sleep onset,Wake onset,"
            + "Sleep performance %,Respiratory rate (rpm),Asleep duration (min),"
            + "In bed duration (min),Light sleep duration (min),Deep (SWS) duration (min),"
            + "REM duration (min),Awake duration (min),Sleep need (min),Sleep debt (min),"
            + "Sleep efficiency %,Sleep consistency %,Nap"
        )
        XCTAssertEqual(
            WhoopCsvExporter.workoutsHeader,
            "Cycle start time,Cycle end time,Cycle timezone,Workout start time,Workout end time,"
            + "Duration (min),Activity name,Activity Strain,Energy burned (cal),Max HR (bpm),"
            + "Average HR (bpm),HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,HR Zone 5 %,"
            + "GPS enabled"
        )
        XCTAssertEqual(
            WhoopCsvExporter.journalHeader,
            "Cycle start time,Cycle end time,Cycle timezone,Question text,Answered yes,Notes"
        )
        XCTAssertEqual(WhoopCsvExporter.cyclesCSV([]).components(separatedBy: "\r\n").first,
                       WhoopCsvExporter.cyclesHeader)
        XCTAssertEqual(WhoopCsvExporter.sleepsCSV([]).components(separatedBy: "\r\n").first,
                       WhoopCsvExporter.sleepsHeader)
        XCTAssertEqual(WhoopCsvExporter.workoutsCSV([]).components(separatedBy: "\r\n").first,
                       WhoopCsvExporter.workoutsHeader)
        XCTAssertEqual(WhoopCsvExporter.journalCSV([]).components(separatedBy: "\r\n").first,
                       WhoopCsvExporter.journalHeader)
    }

    func testTimezoneLabelIsWhoopStyle() {
        XCTAssertEqual(WhoopCsvExporter.timezoneLabel(offsetMinutes: -300), "UTC-05:00")
        XCTAssertEqual(WhoopCsvExporter.timezoneLabel(offsetMinutes: 60), "UTC+01:00")
        XCTAssertEqual(WhoopCsvExporter.timezoneLabel(offsetMinutes: 0), "UTC+00:00")
        XCTAssertEqual(WhoopCsvExporter.timezoneLabel(offsetMinutes: 330), "UTC+05:30")
    }

    func testTimestampIsLocalWallClock() {
        // 2024-01-02 06:30:00 at UTC-05:00 == 11:30 UTC.
        let utc = Fixtures.utc(2024, 1, 2, 11, 30, 0)
        XCTAssertEqual(WhoopCsvExporter.timestamp(utc, offsetMinutes: -300), "2024-01-02 06:30:00")
        XCTAssertEqual(WhoopCsvExporter.timestamp(nil, offsetMinutes: -300), "")
    }

    func testNumbersAreLocaleProofAndEmptyWhenMissing() {
        XCTAssertEqual(WhoopCsvExporter.num(72.0), "72")
        XCTAssertEqual(WhoopCsvExporter.num(68.4), "68.4")
        XCTAssertEqual(WhoopCsvExporter.num(nil as Double?), "")
        XCTAssertFalse(WhoopCsvExporter.num(12345.678).contains(","))
        XCTAssertEqual(WhoopCsvExporter.bool(true), "true")
        XCTAssertEqual(WhoopCsvExporter.bool(false), "false")
        XCTAssertEqual(WhoopCsvExporter.bool(nil), "")
    }

    func testCycleWindowsLastEndIsEmpty() {
        let a = Fixtures.utc(2024, 1, 2, 4, 15, 0)
        let b = Fixtures.utc(2024, 1, 3, 4, 10, 0)
        let windows = WhoopCsvExporter.cycleWindows(mainOnsets: [b, a])
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].start, a)
        XCTAssertEqual(windows[0].end, b)
        XCTAssertEqual(windows[1].start, b)
        XCTAssertNil(windows[1].end)
        XCTAssertEqual(WhoopCsvExporter.cycleContaining(a, windows: windows)?.start, a)
        XCTAssertEqual(WhoopCsvExporter.cycleContaining(b.addingTimeInterval(-1), windows: windows)?.start, a)
        XCTAssertEqual(WhoopCsvExporter.cycleContaining(b, windows: windows)?.start, b)
    }

    // MARK: - Round-trip through the real importer

    func testCyclesRoundTripThroughRealImporter() throws {
        var row = WhoopCycleRow()
        row.tzOffsetMin = tzNeg5
        row.cycleStart = Fixtures.utc(2024, 1, 2, 4, 15, 0)   // 2024-01-01 23:15 local
        row.cycleEnd = Fixtures.utc(2024, 1, 3, 4, 10, 0)
        row.recoveryScore = 72
        row.restingHeartRate = 52
        row.hrvMs = 68.4
        row.skinTempCelsius = 33.1
        row.bloodOxygenPct = 96.0
        row.dayStrain = 12.5
        row.energyKcal = 2450
        row.maxHeartRate = 165
        row.avgHeartRate = 68
        row.sleepOnset = Fixtures.utc(2024, 1, 2, 4, 15, 0)
        row.wakeOnset = Fixtures.utc(2024, 1, 2, 11, 30, 0)    // 2024-01-02 06:30 local
        row.sleepPerformancePct = 85
        row.respiratoryRate = 14.2
        row.asleepDurationMin = 420
        row.inBedDurationMin = 455
        row.lightSleepDurationMin = 210
        row.deepSleepDurationMin = 95
        row.remDurationMin = 115
        row.awakeDurationMin = 35
        row.sleepNeedMin = 480
        row.sleepDebtMin = 60
        row.sleepEfficiencyPct = 92.3
        row.sleepConsistencyPct = 88

        var open = WhoopCycleRow()
        open.tzOffsetMin = tzNeg5
        open.cycleStart = Fixtures.utc(2024, 1, 3, 4, 10, 0)
        open.cycleEnd = nil
        open.recoveryScore = 55

        let csv = WhoopCsvExporter.cyclesCSV([row, open])
        XCTAssertTrue(csv.contains("UTC-05:00"))
        XCTAssertTrue(csv.contains("2024-01-01 23:15:00"))
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines[0], WhoopCsvExporter.cyclesHeader)
        // Open cycle: empty cycle-end cell between start and timezone.
        XCTAssertTrue(lines[2].contains("2024-01-02 23:10:00,,UTC-05:00"))

        let back = WhoopExportImporter().parseCycles(CSVTable(text: csv))
        XCTAssertEqual(back.count, 2)
        let r = back[0]
        XCTAssertEqual(r.cycleStart, row.cycleStart)
        XCTAssertEqual(r.cycleEnd, row.cycleEnd)
        XCTAssertEqual(r.tzOffsetMin, tzNeg5)
        XCTAssertEqual(r.recoveryScore, 72)
        XCTAssertEqual(r.restingHeartRate, 52)
        XCTAssertEqual(r.hrvMs, 68.4)
        XCTAssertEqual(r.skinTempCelsius, 33.1)
        XCTAssertEqual(r.bloodOxygenPct, 96.0)
        XCTAssertEqual(r.dayStrain, 12.5)
        XCTAssertEqual(r.energyKcal, 2450)
        XCTAssertEqual(r.maxHeartRate, 165)
        XCTAssertEqual(r.avgHeartRate, 68)
        XCTAssertEqual(r.sleepOnset, row.sleepOnset)
        XCTAssertEqual(r.wakeOnset, row.wakeOnset)
        XCTAssertEqual(r.sleepPerformancePct, 85)
        XCTAssertEqual(r.respiratoryRate, 14.2)
        XCTAssertEqual(r.asleepDurationMin, 420)
        XCTAssertEqual(r.inBedDurationMin, 455)
        XCTAssertEqual(r.lightSleepDurationMin, 210)
        XCTAssertEqual(r.deepSleepDurationMin, 95)
        XCTAssertEqual(r.remDurationMin, 115)
        XCTAssertEqual(r.awakeDurationMin, 35)
        XCTAssertEqual(r.sleepNeedMin, 480)
        XCTAssertEqual(r.sleepDebtMin, 60)
        XCTAssertEqual(r.sleepEfficiencyPct, 92.3)
        XCTAssertEqual(r.sleepConsistencyPct, 88)
        XCTAssertNil(back[1].cycleEnd)
        XCTAssertEqual(back[1].recoveryScore, 55)
    }

    func testSleepsRoundTripIncludingNapAndStageShapes() {
        var main = WhoopSleepRow()
        main.tzOffsetMin = tzPos1
        main.cycleStart = Fixtures.utc(2024, 1, 2, 5, 30, 0)
        main.cycleEnd = Fixtures.utc(2024, 1, 3, 5, 29, 0)
        main.sleepOnset = Fixtures.utc(2024, 1, 1, 22, 15, 0)
        main.wakeOnset = Fixtures.utc(2024, 1, 2, 5, 30, 0)
        main.isNap = false
        main.sleepPerformancePct = 85
        main.respiratoryRate = 14.2
        main.asleepDurationMin = 420
        main.inBedDurationMin = 455
        main.lightSleepDurationMin = 210
        main.deepSleepDurationMin = 95
        main.remDurationMin = 115
        main.awakeDurationMin = 35
        main.sleepNeedMin = 480
        main.sleepDebtMin = 60
        main.sleepEfficiencyPct = 92.3
        main.sleepConsistencyPct = 88

        var nap = WhoopSleepRow()
        nap.tzOffsetMin = tzPos1
        nap.cycleStart = main.cycleStart
        nap.cycleEnd = main.cycleEnd
        nap.sleepOnset = Fixtures.utc(2024, 1, 2, 13, 0, 0)
        nap.wakeOnset = Fixtures.utc(2024, 1, 2, 13, 25, 0)
        nap.isNap = true
        nap.asleepDurationMin = 25
        nap.inBedDurationMin = 25
        nap.lightSleepDurationMin = 20
        nap.deepSleepDurationMin = 5
        nap.remDurationMin = 0
        nap.awakeDurationMin = 0

        let csv = WhoopCsvExporter.sleepsCSV([main, nap])
        XCTAssertTrue(csv.contains(",false\r\n") || csv.hasSuffix(",false\r\n"))
        XCTAssertTrue(csv.contains(",true\r\n") || csv.contains(",true"))
        let back = WhoopExportImporter().parseSleeps(CSVTable(text: csv))
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].cycleStart, main.cycleStart)
        XCTAssertEqual(back[0].cycleEnd, main.cycleEnd)
        XCTAssertEqual(back[0].sleepOnset, main.sleepOnset)
        XCTAssertEqual(back[0].wakeOnset, main.wakeOnset)
        XCTAssertEqual(back[0].isNap, false)
        XCTAssertEqual(back[0].lightSleepDurationMin, 210)
        XCTAssertEqual(back[0].deepSleepDurationMin, 95)
        XCTAssertEqual(back[0].remDurationMin, 115)
        XCTAssertEqual(back[0].awakeDurationMin, 35)
        XCTAssertEqual(back[0].asleepDurationMin, 420)
        XCTAssertEqual(back[0].sleepNeedMin, 480)
        XCTAssertEqual(back[1].isNap, true)
        XCTAssertEqual(back[1].asleepDurationMin, 25)
        XCTAssertNil(back[1].sleepPerformancePct)
    }

    func testStageMinutesFromAllPersistedShapes() {
        let dict = WhoopCsvExporter.stageMinutes(#"{"light":210,"deep":95,"rem":115,"awake":35}"#)
        XCTAssertEqual(dict.light, 210)
        XCTAssertEqual(dict.deep, 95)
        XCTAssertEqual(dict.rem, 115)
        XCTAssertEqual(dict.awake, 35)
        XCTAssertEqual(dict.asleep, 420)

        let array = WhoopCsvExporter.stageMinutes(#"[{"stage":"light","min":200.0},{"stage":"deep","min":80.0}]"#)
        XCTAssertEqual(array.light, 200)
        XCTAssertEqual(array.deep, 80)

        let segs = WhoopCsvExporter.stageMinutes(
            #"[{"start":2000000000,"end":2000003600,"stage":"light"},{"start":2000003600,"end":2000007200,"stage":"deep"}]"#
        )
        XCTAssertEqual(segs.light, 60)
        XCTAssertEqual(segs.deep, 60)
    }

    func testWorkoutsRoundTripIncludingCommaInNameAndGps() {
        var w = WhoopWorkoutRow()
        w.tzOffsetMin = tzNeg5
        w.cycleStart = Fixtures.utc(2024, 1, 2, 4, 15, 0)
        w.cycleEnd = Fixtures.utc(2024, 1, 3, 4, 10, 0)
        w.workoutStart = Fixtures.utc(2024, 1, 2, 22, 0, 0)
        w.workoutEnd = Fixtures.utc(2024, 1, 2, 22, 45, 0)
        w.durationMin = 45
        w.activityName = "Run, \"tempo\"\nintervals"
        w.activityStrain = 11.2
        w.energyKcal = 540
        w.maxHeartRate = 182
        w.avgHeartRate = 158
        w.hrZone1Pct = 5
        w.hrZone2Pct = 20
        w.hrZone3Pct = 40
        w.hrZone4Pct = 30
        w.hrZone5Pct = 5
        w.gpsEnabled = true

        let csv = WhoopCsvExporter.workoutsCSV([w])
        XCTAssertTrue(csv.contains("GPS enabled"))
        XCTAssertTrue(csv.contains("true"))
        let back = WhoopExportImporter().parseWorkouts(CSVTable(text: csv))
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].activityName, "Run, \"tempo\"\nintervals")
        XCTAssertEqual(try XCTUnwrap(back[0].activityStrain), 11.2, accuracy: 1e-6)
        XCTAssertEqual(back[0].energyKcal, 540)
        XCTAssertEqual(back[0].avgHeartRate, 158)
        XCTAssertEqual(back[0].maxHeartRate, 182)
        XCTAssertEqual(back[0].hrZone3Pct, 40)
        XCTAssertEqual(back[0].durationMin, 45)
        XCTAssertEqual(back[0].gpsEnabled, true)
        XCTAssertEqual(back[0].workoutStart, w.workoutStart)
        XCTAssertEqual(back[0].workoutEnd, w.workoutEnd)
        XCTAssertEqual(back[0].cycleStart, w.cycleStart)
        XCTAssertEqual(back[0].cycleEnd, w.cycleEnd)
    }

    func testJournalRoundTripIncludingFalseAnswers() {
        var no = WhoopJournalRow()
        no.tzOffsetMin = tzPos1
        no.cycleStart = Fixtures.utc(2024, 1, 2, 5, 30, 0)
        no.cycleEnd = Fixtures.utc(2024, 1, 3, 5, 29, 0)
        no.question = "Any alcohol?"
        no.answer = "false"

        var yes = WhoopJournalRow()
        yes.tzOffsetMin = tzPos1
        yes.cycleStart = no.cycleStart
        yes.cycleEnd = no.cycleEnd
        yes.question = "Caffeine, after 4pm?"
        yes.answer = "true"
        yes.notes = "one, big \"mug\""

        let csv = WhoopCsvExporter.journalCSV([no, yes])
        XCTAssertTrue(csv.hasPrefix(WhoopCsvExporter.journalHeader))
        XCTAssertTrue(csv.contains("Answered yes"))
        XCTAssertFalse(csv.contains("Answered yes/no"))
        let back = WhoopExportImporter().parseJournal(CSVTable(text: csv)).sorted {
            ($0.question ?? "") < ($1.question ?? "")
        }
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].question, "Any alcohol?")
        XCTAssertEqual(back[0].answer, "false")
        XCTAssertEqual(back[0].cycleEnd, no.cycleEnd)
        XCTAssertEqual(back[1].question, "Caffeine, after 4pm?")
        XCTAssertEqual(back[1].answer, "true")
        XCTAssertEqual(back[1].notes, "one, big \"mug\"")
    }

    func testMissingValuesExportAsEmptyCells() {
        var row = WhoopCycleRow()
        row.tzOffsetMin = 0
        row.cycleStart = Fixtures.utc(2024, 6, 1, 0, 0, 0)
        let csv = WhoopCsvExporter.cyclesCSV([row])
        let dataLine = csv.components(separatedBy: "\r\n").dropFirst().first ?? ""
        // Recovery through consistency are all empty; strain/HR/sleep cells blank.
        XCTAssertTrue(dataLine.contains(",,UTC+00:00,"))
        let back = WhoopExportImporter().parseCycles(CSVTable(text: csv))
        XCTAssertEqual(back.count, 1)
        XCTAssertNil(back[0].recoveryScore)
        XCTAssertNil(back[0].dayStrain)
        XCTAssertNil(back[0].sleepOnset)
    }

    func testZipArchiveRoundTripsThroughFullImporter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whoop-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zipURL = dir.appendingPathComponent("whoop-export.zip")

        var cycle = WhoopCycleRow()
        cycle.tzOffsetMin = tzNeg5
        cycle.cycleStart = Fixtures.utc(2024, 1, 2, 4, 15, 0)
        cycle.recoveryScore = 72
        cycle.dayStrain = 12.5
        cycle.sleepOnset = cycle.cycleStart
        cycle.wakeOnset = Fixtures.utc(2024, 1, 2, 11, 30, 0)
        cycle.asleepDurationMin = 420

        var sleep = WhoopSleepRow()
        sleep.tzOffsetMin = tzNeg5
        sleep.cycleStart = cycle.cycleStart
        sleep.sleepOnset = cycle.sleepOnset
        sleep.wakeOnset = cycle.wakeOnset
        sleep.isNap = false
        sleep.asleepDurationMin = 420
        sleep.lightSleepDurationMin = 210
        sleep.deepSleepDurationMin = 95
        sleep.remDurationMin = 115

        var workout = WhoopWorkoutRow()
        workout.tzOffsetMin = tzNeg5
        workout.cycleStart = cycle.cycleStart
        workout.workoutStart = Fixtures.utc(2024, 1, 2, 22, 0, 0)
        workout.workoutEnd = Fixtures.utc(2024, 1, 2, 22, 45, 0)
        workout.activityName = "Running"
        workout.activityStrain = 11.2
        workout.gpsEnabled = false

        var journal = WhoopJournalRow()
        journal.tzOffsetMin = tzNeg5
        journal.cycleStart = cycle.cycleStart
        journal.question = "Did you drink any alcohol?"
        journal.answer = "false"

        try WhoopCsvExporter.writeArchive(
            cycles: [cycle], sleeps: [sleep], workouts: [workout], journal: [journal],
            to: zipURL
        )

        let result = try WhoopExportImporter().`import`(from: zipURL)
        XCTAssertEqual(result.cycles.count, 1)
        XCTAssertEqual(result.cycles[0].recoveryScore, 72)
        XCTAssertEqual(result.cycles[0].dayStrain, 12.5)
        XCTAssertEqual(result.sleeps.count, 1)
        XCTAssertEqual(result.sleeps[0].asleepDurationMin, 420)
        XCTAssertEqual(result.sleeps[0].isNap, false)
        XCTAssertEqual(result.workouts.count, 1)
        XCTAssertEqual(result.workouts[0].activityName, "Running")
        XCTAssertEqual(result.workouts[0].gpsEnabled, false)
        XCTAssertEqual(result.journal.count, 1)
        XCTAssertEqual(result.journal[0].answer, "false")
    }

    func testEfficiencyPctFractionPairIsLosslessAndNilSafe() {
        XCTAssertEqual(WhoopExportImporter.whoopEfficiencyPctFromFraction(0.923) ?? -1, 92.3, accuracy: 1e-9)
        XCTAssertEqual(WhoopExportImporter.fractionFromImportedEfficiencyPct(92.3) ?? -1, 0.923, accuracy: 1e-9)
        let roundTripped = WhoopExportImporter.fractionFromImportedEfficiencyPct(
            WhoopExportImporter.whoopEfficiencyPctFromFraction(0.6569))
        XCTAssertEqual(roundTripped ?? -1, 0.6569, accuracy: 1e-9)
        XCTAssertNil(WhoopExportImporter.whoopEfficiencyPctFromFraction(nil))
        XCTAssertNil(WhoopExportImporter.fractionFromImportedEfficiencyPct(nil))
    }
}

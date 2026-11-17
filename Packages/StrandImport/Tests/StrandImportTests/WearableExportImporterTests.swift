import XCTest
import Foundation
@testable import StrandImport

/// Pins the offline file-import of a user's OWN Oura / Fitbit / Garmin data export onto NOOP's daily
/// metrics + sleep sessions. Tiny inline fixtures per brand (no real account data). HONEST DATA:
/// only fields the export carries are written; a brand's OWN score is reference-only, never Charge.
final class WearableExportImporterTests: XCTestCase {

    private func bytes(_ s: String) -> Data { s.data(using: .utf8)! }

    func testSemicolonDelimiterDetection() {
        // The CSV reader sniffs the delimiter per file: a `;`-delimited header splits into real columns,
        // a `,`-delimited one stays comma (so the WHOOP path is unchanged).
        XCTAssertEqual(CSVTable.detectDelimiter("a;b;c\n1;2;3"), ";")
        XCTAssertEqual(CSVTable.detectDelimiter("a,b,c\n1,2,3"), ",")
        // A quoted value containing the other separator must not flip the detection.
        XCTAssertEqual(CSVTable.detectDelimiter("\"x,y\";b;c\n1;2;3"), ";")
        let t = CSVTable(text: "day;score\n2026-06-01;81")
        XCTAssertEqual(t.normalizedHeaders, ["day", "score"])
        XCTAssertEqual(t.rows.first?["score"], "81")
    }

    func testImportErrorIsHonestNotOpaqueErreur4() {
        // The honest-message fix (#857): ImportError now conforms to LocalizedError, so the surfaced
        // localizedDescription is a real sentence, not the positional NSError "…ImportError erreur 4".
        let err = ImportError.emptyExport("That file is Oura's raw heart-rate log")
        XCTAssertEqual(err.errorDescription, err.description)
        XCTAssertTrue(err.localizedDescription.contains("heart-rate log"))
        XCTAssertFalse(err.localizedDescription.lowercased().contains("erreur"))
    }

    // MARK: - Fitbit

    func testFitbitSleepRestingHrSteps() {
        let sleep = """
        [ { "dateOfSleep": "2026-06-01", "startTime": "2026-05-31T23:00:00.000",
            "endTime": "2026-06-01T06:00:00.000", "minutesAsleep": 400, "minutesAwake": 20,
            "efficiency": 94,
            "levels": { "summary": {
              "deep": { "minutes": 80 }, "light": { "minutes": 220 },
              "rem": { "minutes": 100 }, "wake": { "minutes": 20 } } } } ]
        """
        let rhr = """
        [ { "dateTime": "2026-06-01T00:00:00.000", "value": { "date": "2026-06-01", "value": 51.5, "error": 5.0 } } ]
        """
        let steps = """
        [ { "dateTime": "2026-06-01 08:00:00", "value": "1200" },
          { "dateTime": "2026-06-01 09:00:00", "value": "800" } ]
        """
        let files = [
            "sleep-2026-06-01.json": bytes(sleep),
            "resting_heart_rate-2026-06-01.json": bytes(rhr),
            "steps-2026-06-01.json": bytes(steps),
        ]
        XCTAssertEqual(WearableExportImporter.detectBrand(files), .fitbit)
        let r = WearableExportImporter.parse(brand: .fitbit, files: files)

        XCTAssertEqual(r.summary.sourceKind, .fitbitImport)
        XCTAssertEqual(r.sleeps.count, 1)
        let s = r.sleeps[0]
        XCTAssertEqual(s.totalSleepMin!, 400, accuracy: 1e-6)
        XCTAssertEqual(s.deepMin!, 80, accuracy: 1e-6)
        XCTAssertEqual(s.remMin!, 100, accuracy: 1e-6)
        XCTAssertEqual(s.efficiencyPct!, 94, accuracy: 1e-6)

        XCTAssertEqual(r.days.count, 1)
        let d = r.days[0]
        XCTAssertEqual(d.day, "2026-06-01")
        XCTAssertEqual(d.restingHr, 51)                          // nested value.value, rounded
        XCTAssertEqual(d.steps, 2000)                            // intraday steps summed
        XCTAssertEqual(d.totalSleepMin!, 400, accuracy: 1e-6)
    }

    // MARK: - Garmin

    func testGarminWellnessSleepAndDaily() {
        // sleepData: epoch-MILLIS GMT timestamps + *SleepSeconds + an overall score (reference).
        // 2026-06-01 00:00:00Z = 1780272000000 ms; +7h end.
        let sleepStartMs = 1_780_272_000_000.0
        let sleepEndMs = sleepStartMs + 7 * 3600 * 1000
        let sleepData = """
        [ { "calendarDate": "2026-06-01", "sleepStartTimestampGMT": \(Int(sleepStartMs)),
            "sleepEndTimestampGMT": \(Int(sleepEndMs)),
            "deepSleepSeconds": 4800, "lightSleepSeconds": 14400, "remSleepSeconds": 5400,
            "awakeSleepSeconds": 600, "unmeasurableSeconds": 0, "overallSleepScore": 78 } ]
        """
        let daily = """
        [ { "calendarDate": "2026-06-01", "restingHeartRate": 47, "totalSteps": 9100,
            "totalDistanceMeters": 7300.5, "averageStressLevel": 31 } ]
        """
        let files = [
            "di_connect/di_connect_wellness/2026_sleepdata.json": bytes(sleepData),
            "di_connect/di_connect_wellness/2026_dailysummary.json": bytes(daily),
        ]
        XCTAssertEqual(WearableExportImporter.detectBrand(files), .garmin)
        let r = WearableExportImporter.parse(brand: .garmin, files: files)

        XCTAssertEqual(r.summary.sourceKind, .garminImport)
        XCTAssertEqual(r.sleeps.count, 1)
        let s = r.sleeps[0]
        XCTAssertEqual(s.deepMin!, 80, accuracy: 1e-6)           // 4800s
        XCTAssertEqual(s.lightMin!, 240, accuracy: 1e-6)         // 14400s
        XCTAssertEqual(s.remMin!, 90, accuracy: 1e-6)            // 5400s
        XCTAssertEqual(s.totalSleepMin!, 410, accuracy: 1e-6)    // 80+240+90
        XCTAssertEqual(s.sleepScore, 78)                          // reference, never Charge

        XCTAssertEqual(r.days.count, 1)
        let d = r.days[0]
        XCTAssertEqual(d.day, "2026-06-01")
        XCTAssertEqual(d.restingHr, 47)
        XCTAssertEqual(d.steps, 9100)
        XCTAssertEqual(d.distanceM!, 7300.5, accuracy: 1e-6)
        XCTAssertEqual(d.avgStress, 31)
    }

    // MARK: - Safety / honesty

    func testJunkAndZeroValuesAreRejectedSafely() {
        // Not a wearable export at all → no brand.
        XCTAssertNil(WearableExportImporter.detectBrand(["random.json": bytes("{\"foo\":1}")]))

        // Zero / missing HR and a malformed sleep period must not produce fabricated rows or crash.
        let json = """
        { "sleep": [
            { "day": "2026-06-03", "bedtime_start": "bad", "bedtime_end": "also-bad",
              "total_sleep_duration": 0, "average_heart_rate": 0 } ],
          "daily_readiness": [
            { "day": "2026-06-03", "score": 0, "contributors": { "resting_heart_rate": 0 } } ] }
        """
        let r = WearableExportImporter.parse(brand: .oura, files: ["oura.json": bytes(json)])
        XCTAssertEqual(r.sleeps.count, 0)                        // unparseable times → dropped
        // The readiness day still exists but carries no fabricated values (0 RHR/score → nil).
        if let d = r.days.first(where: { $0.day == "2026-06-03" }) {
            XCTAssertNil(d.restingHr)
            XCTAssertNil(d.readinessScore)
        }
    }

    func testHugeOutOfRangeNumberDoesNotTrap() {
        // A finite-but-out-of-Int-range number (1e19 > 9e18) must be dropped by the safeInt guard, never
        // trap the Int(Double) conversion. The valid sibling field still imports.
        let json = """
        { "daily_activity": [ { "day": "2026-06-04", "steps": 1e19, "active_calories": 500 } ] }
        """
        let r = WearableExportImporter.parse(brand: .oura, files: ["oura.json": bytes(json)])
        XCTAssertTrue(r.days.isEmpty)
        XCTAssertTrue(r.sleeps.isEmpty)
    }
}

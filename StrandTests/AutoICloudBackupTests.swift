import XCTest
@testable import Strand

final class AutoICloudBackupTests: XCTestCase {

    func testFileNameIsDatedZip() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = cal.date(from: DateComponents(year: 2026, month: 3, day: 4))!
        XCTAssertEqual(AutoICloudBackup.fileName(on: date, timeZone: cal.timeZone),
                       "Band-backup-2026-03-04.zip")
        XCTAssertEqual(AutoICloudBackup.dayStamp(date, timeZone: cal.timeZone), "2026-03-04")
    }

    func testIsBackupFileAcceptsOnlyCanonicalNames() {
        XCTAssertTrue(AutoICloudBackup.isBackupFile("Band-backup-2026-03-04.zip"))
        XCTAssertFalse(AutoICloudBackup.isBackupFile("Band-backup-2026-3-4.zip"))
        XCTAssertFalse(AutoICloudBackup.isBackupFile("Band-backup-2026-03-04.noopbak"))
        XCTAssertFalse(AutoICloudBackup.isBackupFile("noop-backup-2026-03-04.zip"))
        XCTAssertFalse(AutoICloudBackup.isBackupFile("notes.txt"))
        XCTAssertFalse(AutoICloudBackup.isBackupFile("Band-backup-not-a-date.zip"))
    }

    func testPruneKeepsNewestSevenAndIgnoresOtherFiles() {
        let backups = (1...10).map { String(format: "Band-backup-2026-01-%02d.zip", $0) }
        let names = backups + ["notes.txt", "noop-backup-2026-01-01.noopbak", "photo.jpg"]
        let pruned = AutoICloudBackup.filesToPrune(names, keep: 7)
        XCTAssertEqual(Set(pruned), Set([
            "Band-backup-2026-01-01.zip",
            "Band-backup-2026-01-02.zip",
            "Band-backup-2026-01-03.zip",
        ]))
        XCTAssertFalse(pruned.contains("notes.txt"))
        XCTAssertFalse(pruned.contains("noop-backup-2026-01-01.noopbak"))
    }

    func testPruneNoOpWithinBudget() {
        XCTAssertTrue(AutoICloudBackup.filesToPrune(["Band-backup-2026-01-01.zip"], keep: 7).isEmpty)
    }

    func testIsDueWhenLastBackupIsAnotherDay() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: AutoICloudBackup.lastDateKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AutoICloudBackup.lastDateKey)
            } else {
                defaults.removeObject(forKey: AutoICloudBackup.lastDateKey)
            }
        }
        AutoICloudBackup.lastBackupDay = nil
        XCTAssertTrue(AutoICloudBackup.isDue())
        AutoICloudBackup.lastBackupDay = AutoICloudBackup.dayStamp()
        XCTAssertFalse(AutoICloudBackup.isDue())
        AutoICloudBackup.lastBackupDay = "2000-01-01"
        XCTAssertTrue(AutoICloudBackup.isDue())
    }

    func testKeysMatchRequestedDefaults() {
        XCTAssertEqual(AutoICloudBackup.enabledKey, "band.autoBackup.enabled")
        XCTAssertEqual(AutoICloudBackup.bookmarkKey, "band.autoBackup.folderBookmark")
    }
}

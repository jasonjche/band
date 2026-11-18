import XCTest
@testable import Strand

final class MacICloudSyncTests: XCTestCase {

    func testRecognizesBandZipNoopbakAndICloudPlaceholders() {
        XCTAssertTrue(MacICloudSync.isSupportedBackupName("Band-backup-2026-11-18.zip"))
        XCTAssertTrue(MacICloudSync.isSupportedBackupName(".Band-backup-2026-11-18.zip.icloud"))
        XCTAssertTrue(MacICloudSync.isSupportedBackupName("noop-backup-2026-11-18.noopbak"))
        XCTAssertTrue(MacICloudSync.isSupportedBackupName(".noop-backup-2026-11-18.noopbak.icloud"))
        XCTAssertFalse(MacICloudSync.isSupportedBackupName("notes.txt"))
        XCTAssertFalse(MacICloudSync.isSupportedBackupName("whoop-export.zip"))
    }

    func testNewestCandidatePrefersLatestDayStampThenModificationTime() {
        let older = MacICloudSync.Entry(
            name: "Band-backup-2026-11-17.zip",
            modifiedAt: 1_763_500_000,
            size: 1000,
            isPlaceholder: false
        )
        let newer = MacICloudSync.Entry(
            name: "Band-backup-2026-11-18.zip",
            modifiedAt: 1_763_400_000,
            size: 1200,
            isPlaceholder: false
        )
        let unrelated = MacICloudSync.Entry(
            name: "random.zip",
            modifiedAt: 1_763_999_999,
            size: 500,
            isPlaceholder: false
        )
        XCTAssertEqual(MacICloudSync.newestCandidate(in: [older, unrelated, newer]), newer)
    }

    func testShouldSyncSkipsIdenticalSignatureUnlessForced() {
        let entry = MacICloudSync.Entry(
            name: "Band-backup-2026-11-18.zip",
            modifiedAt: 1_763_450_000,
            size: 2048,
            isPlaceholder: false
        )
        XCTAssertTrue(MacICloudSync.shouldSync(candidate: entry, lastSignature: nil))
        XCTAssertFalse(MacICloudSync.shouldSync(candidate: entry, lastSignature: entry.signature))
        XCTAssertTrue(MacICloudSync.shouldSync(candidate: entry, lastSignature: entry.signature, force: true))

        var updated = entry
        updated.size = 4096
        XCTAssertTrue(MacICloudSync.shouldSync(candidate: updated, lastSignature: entry.signature))
    }
}

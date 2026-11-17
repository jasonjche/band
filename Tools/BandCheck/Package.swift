// swift-tools-version:5.9
import PackageDescription

// BandCheck — one command that, before every install, says whether Band's numbers still agree
// with WHOOP and with themselves on the wearer's real data.
//
// Replays the same package scorers the app uses (BandStrain, BandScores, RecoveryScorer,
// AutoWorkoutDetector, FusionResolver, SleepStageTotals) over a WHOOP CSV export and a
// read-only copy of the phone SQLite. The database and export paths are ALWAYS arguments
// or env vars — no health data lives in this repository, and none is ever written back.
// Opened `SQLITE_OPEN_READONLY` + `immutable=1`. Output is aggregates only.
let package = Package(
    name: "bandcheck",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/StrandAnalytics"),
        .package(path: "../../Packages/WhoopProtocol"),
        .package(path: "../../Packages/StrandImport"),
    ],
    targets: [
        .executableTarget(
            name: "bandcheck",
            dependencies: ["StrandAnalytics", "WhoopProtocol", "StrandImport"]
        ),
        .testTarget(name: "bandcheckTests", dependencies: ["bandcheck"]),
    ]
)

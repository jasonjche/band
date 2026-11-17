# Band

Band is a personal, offline iPhone companion for the WHOOP 5.0 strap. It pairs over Bluetooth,
keeps every reading in an on-device SQLite store, and computes sleep, recovery, strain, stress and
the rest locally. There is no account, no server and no telemetry.

The aim is WHOOP's experience, built the Apple way: the same scores and screens, using WHOOP's
published methods where they exist, checked against a real WHOOP export.

Band is a fork of [NOOP](https://github.com/ryanbr/noop) and is not affiliated with WHOOP.

## What it does

- **Scores:**
  - Sleep, Recovery and Strain rings, with a personal strain target.
  - Stress Monitor (0–3, per minute).
  - Health Monitor: typical ranges for RHR, HRV, respiratory rate, SpO₂ and skin temperature.
- **Sleep:**
  - A learned four-stage sleep stager.
  - Sleep need, sleep debt and consistency.
  - A Sleep Planner with a bedtime recommendation, tied to the strap alarm.
- **Activities:**
  - Automatic workout detection.
  - WHOOP heart-rate-reserve zones.
  - Muscular load for logged strength sets.
  - Recovery activities (sauna, cold plunge and similar).
  - Steps per workout.
  - Apple Health import and write-back, so workouts can reach Strava through Health.
- **Insights:**
  - Healthspan: Band Age and Pace of Aging.
  - Weekly and monthly assessments.
  - A 100-behaviour journal, with an impact ranking for each behaviour.
  - HRV trend.
  - A two-night illness signal.
- **Notifications:** Recovery is ready, Health Monitor out of range, sleep recorded, and strap
  battery (low at 20%, full).

## Layout

| Path | Contents |
|---|---|
| `Packages/WhoopProtocol` | BLE frame parsing, CRC, command and event decoding. Pure Swift, no CoreBluetooth. |
| `Packages/WhoopStore` | GRDB / SQLite persistence and migrations. |
| `Packages/StrandAnalytics` | All scoring maths: HRV, recovery, strain, sleep, stress, calories and more. Database-free. |
| `Packages/StrandImport` | WHOOP CSV and Apple Health importers. |
| `Packages/StrandDesign` | Design tokens and shared SwiftUI components. |
| `Strand/` | App code: BLE, collection, repository, and the native UI in `Strand/Native`. |
| `StrandiOS/` | The iOS app entry point and tab shell. |
| `Tools/BandCheck` | Replay harness that scores Band against a WHOOP export and fails on regressions. |
| `Tools/SleepPSG`, `Tools/SleepBench` | Sleep-staging benchmarks against public sleep-lab data. |

## Build

You need Xcode with the iOS 26 SDK and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
`project.yml` is the source of truth; the Xcode project is generated from it and never committed.

```bash
xcodegen generate
# iPhone
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' build
# Tests (the app tests run on the macOS host)
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test
# Analytics and storage packages
(cd Packages/StrandAnalytics && swift test)
```

Signing uses your own team and bundle ID: see `Config/BundleIdSecrets.example.xcconfig`. A free
Apple ID signs for 7 days.

## Checking the numbers

`BandCheck` replays Band's algorithms over a WHOOP CSV export and a copy of the phone's database.
It reports agreement per score and checks invariants. It exits non-zero if a change makes any
gated score worse.

```bash
swift run --package-path Tools/BandCheck bandcheck \
  --db <copy of whoop.sqlite> --export <WHOOP export dir> --labels <labels.json>
```

The thresholds live in `Tools/BandCheck/thresholds.json`. An algorithm change ships only when it
improves agreement on held-out days.

## Strap safety

Band only sends the strap commands NOOP already curated, and every one of them can be undone. It
never sends firmware, ship-mode, factory-reset or other destructive commands. See `AGENTS.md`.

## Licence and credits

Band is a fork of NOOP and keeps NOOP's licence: [PolyForm Noncommercial 1.0.0](LICENSE).
Third-party components and ported work, including the learned sleep stager from
[reNOOP](https://github.com/denismanulov/reNOOP), are credited in [NOTICE](NOTICE) and
[ATTRIBUTION.md](ATTRIBUTION.md).

WHOOP is a trademark of WHOOP, Inc. Band is an independent, clean-room interoperability project
for hardware you own. It contains no WHOOP firmware, app code or assets. Band is not a medical
device; see [DISCLAIMER.md](DISCLAIMER.md).

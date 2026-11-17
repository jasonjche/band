# BandCheck

One command that, before every install, says whether Band’s numbers still agree with WHOOP and with themselves on this wearer’s real data.

Tests in the app use synthetic fixtures. This tool replays the same package scorers the app uses (`BandStrain`, `BandScores`, `AutoWorkoutDetector`, `FusionResolver`, `SleepStageTotals`) over:

- a WHOOP CSV export (directory or zip)
- a **read-only copy** of the phone SQLite

The database is opened `immutable=1`. Paths are arguments or env vars. Output is aggregates (counts, MAE, bias, percent agreement, worst-day **dates**). Per-day values print only with `--verbose`, and that output must never be committed.

## Command

From the repo root:

```bash
swift run --package-path Tools/BandCheck bandcheck \
  --db /tmp/band-pull/O4/whoop.sqlite \
  --export "$HOME/band/whoop-export"
```

Env vars `BANDCHECK_DB`, `BANDCHECK_EXPORT`, `BANDCHECK_THRESHOLDS` work in place of the flags.

```bash
# optional
--thresholds Tools/BandCheck/thresholds.json   # default: this package’s thresholds.json
--stream-device my-whoop
--imported-device my-whoop
--computed-device my-whoop-noop
--tz America/New_York
--age 35
--hr-max 190
--verbose          # per-day pairs to stdout; do not write into the repo
--json /tmp/bandcheck.json
```

Exit `0` if every check is inside `thresholds.json`. Exit `1` on a regression. Exit `2` on usage / missing files.

`swift test --package-path Tools/BandCheck` is the unit suite (no health data).

## What it checks

**A. Agreement with WHOOP** — MAE, bias, share within a tolerance, N, worst-day date.

- Stored imported `dailyMetric` (`my-whoop`) vs the export (import fidelity).
- Stored computed `dailyMetric` (`my-whoop-noop`) vs the export on overlapping days.
- Replay of `BandScores.evaluate` over export-period inputs (the package path `NativeBandScores` wraps).
- Replay of `BandStrain` over 1 Hz HR on days the phone DB actually has, and over WHOOP zone minutes for workout strain.

**B. Workout detection** — `AutoWorkoutDetector` over the phone HR/gravity history vs WHOOP `workouts.csv` (overlapping dates) and vs apple-health/manual rows. Precision/recall by 50% shorter-span overlap. False positives: start time + duration only.

**C. Invariants** on the phone DB, each pass/fail with a count:

- one resolved steps value per day (`FusionResolver`); strap steps &lt; 10% of Apple Health
- duplicate `dailyMetric` rows per `(deviceId, day)`
- auto-saved workouts overlapping another workout
- workouts in the HR window (or auto/manual) with no HR samples
- journal question ids that fold to the same title key
- `vo2max` / `vo2max_est` in `metricSeries` with no `appleDaily.vo2max`

## Skipped (app-target only)

| Code | Where | What BandCheck does instead |
|---|---|---|
| `NativeBandScores` | `Strand/Native/NativeBandScores.swift` | `BandScores.evaluate` |
| `WorkoutZones` | `Strand/Data/WorkoutZones.swift` | zone % from the WHOOP export |
| `JournalCatalog.canonicalId` | `Strand/Data/JournalCatalog.swift` | punctuation-insensitive title fold; no alias table |
| `WorkoutSource.classify` | `Strand/Data/WorkoutSource.swift` | `source` suffix / apple-health / manual string checks |

Do not move that code into a package from this tool.

## Private data

Never commit raw rows, fixtures derived from them, or per-day values. `thresholds.json` holds caps only.

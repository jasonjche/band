# LearnedWorkoutDetector fit

Private-data fitting script for `Packages/StrandAnalytics/.../LearnedWorkoutDetector.swift`.

```
python3 Tools/LearnedWorkout/fit.py
```

Reads (never writes):

- `BAND_DB` default `/tmp/band-pull/O4/whoop.sqlite`
- `BAND_WHOOP_WORKOUTS` default `~/band/whoop-export/workouts.csv`

Writes aggregates only to `/tmp/band-learned-workout/fit_report.json`. Do not commit rows, windows, or derived fixtures.

Two local days of 1 Hz strap HR are not enough to replace `AutoWorkoutDetector`. Re-run after more strap days accumulate.

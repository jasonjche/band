# WHOOP screenshot map

Source: `~/Downloads/IMG_9417.PNG` through `IMG_9454.PNG` (38 shots, one session, 1:01–1:03).
This is the information architecture the native presentation follows. Membership, gifts, and the Galleri ad are WHOOP commerce. They are not screens we build.

Paired WHOOP ↔ NOOP captures live in [`Tools/whoop-parity/`](../Tools/whoop-parity/). The screen list is `screens.json`. Generate a side-by-side gallery with `python3 Tools/whoop-parity/capture.py --whoop-dir ~/iphone-agent/whoop-tour --out Tools/whoop-parity/out`.

## Tabs

Home, Health, Humans, More, plus a floating coach button. Humans and the coach are community and chat. We keep More as the existing index and do not invent a social graph.

## Home

`9417` top, `9418` middle, `9419`–`9420` bottom. One scroll.

- Date stepper, battery.
- Three rings: Sleep, Recovery, Strain. Each opens that score page.
- My Day: sleep block and activities. Plus adds an activity. A row opens activity detail.
- Journal week strip, then Behavior Insights.
- My Dashboard: pinned metrics, each with the prior value and an up or down mark. Customize edits the pin list.
- Stress Monitor chart. Opens stress.
- Strain and Recovery week chart.

## Score pages

Same chrome on all three: back, date, battery, one ring, four contributor rows with a 30-day comparison, a legend, then the rest of the day.

- Recovery `9438`–`9441`. Rows: HRV, resting heart rate, respiratory rate, sleep performance. Weekly charts under that.
- Sleep `9428`–`9437`. Rows: hours vs needed, consistency, efficiency, high sleep stress. Then last night: hours, HR chart, stage bars vs typical, restorative. Weekly charts: performance, hours vs needed, restorative, consistency, time in bed, efficiency, debt, sleep stress.
- Strain `9442`–`9445`. Rows: HR zones 1–3, zones 4–5, strength time, steps. Then today's activities. Weekly charts: strain, zone stacks, steps, calories, strength time.

Contributor rows and chart cards push a metric detail. Activity rows push activity detail.

## Activity

`9446`–`9449` weightlifting, `9450`–`9454` run.

- Title, time range, strain vs 30-day average.
- Heart-rate chart, duration, zone bars.
- Key stats vs 30-day average: calories, average HR, max HR, duration. A run also shows distance, pace, elevation, steps, moving time.
- Map only when the workout has a route. We do not invent one.

## Healthspan

`9421` Health tab, `9422`–`9426` the Healthspan push.

- Age, years younger or older, pace of aging.
- Sleep, Strain, and Fitness sections. Each behavior is a range bar against a 6-month and 30-day mark, with a years impact.
- Trend view: age vs chronological age, pace of aging.

We show this only when the store already has a fitness-age or vitality series. We do not invent an age.

## Settings

`9427`. Account, device, app, privacy, support. Gift / membership / trial rows are commerce. They are not screens we build. The native shell's Settings is a system grouped list of our real controls (units, strap, notifications). It does not copy membership commerce.

## Verification contract

Each shot is a pass/fail for the matching screen. Do not invent chrome the store cannot fill. Dash a row when the series is missing.

| Shot | Screen | Must match | Store has it |
| --- | --- | --- | --- |
| 9417 | Home top | Date stepper, three rings Sleep / Recovery / Strain with uppercase labels and chevrons, gap under the rings before My Day, sleep + activity rows, journal peek. Taps on rings open those score pages. Tab bar is Home / Health / Humans / More. We do not add a Sleep tab. We do not add Humans. Health is WHOOP Age, which we do not invent, so native tabs are Home + More. | Rings, sleep duration, workouts |
| 9418 | Home mid | Sticky mini rings when scrolled. Journal week checks. Behavior Insights. Dashboard rows: current value, prior under it, delta. Customize. | Journal checks, HRV, RHR, steps. Zone minutes often missing |
| 9419 | Home dashboard rest | More dashboard rows, then Stress Monitor | Same |
| 9420 | Home bottom | Stress Monitor is **intraday** 0–3 with a night shade, not a 7-day line. Strain & Recovery is **one** dual-axis week: Strain 0–21 left, Recovery 0–100 right, labels on points, today highlighted. Sticky mini rings. | Daily strain/recovery. Intraday stress only if HR samples exist |
| 9421–9426 | Health tab | WHOOP Age / Healthspan. Skip Galleri. | Do not build unless a fitness-age series exists |
| 9427 | Settings index | Grouped rows. Skip gift/trial. | Our Settings list |
| 9428 | Sleep score | Large ring “Sleep Performance”, four contributor rows with a small range bar, Poor/Sufficient/Optimal legend, then Last Night's Sleep | Hours vs typical, efficiency. Consistency and sleep stress often dash |
| 9429 | Last night | Hours, overnight HR, stage bars vs typical (Awake, Light, SWS, REM), restorative | deep/rem/light minutes. No awake % or HR chart unless samples exist |
| 9430–9437 | Sleep rest | Weekly cards: performance, hours, restorative, consistency, time in bed, efficiency, debt, sleep stress | Plot only series we store |
| 9438 | Recovery score | Ring, HRV, RHR, respiratory, sleep performance, 30-day compare | Yes |
| 9439–9441 | Recovery week | Recovery as **bars** (color by band), then HRV / RHR / respiratory **lines**, labels on points | Yes |
| 9442 | Strain score | Ring 0–21, zones 1–3, zones 4–5, strength time, steps | Steps yes. Zones/strength often dash |
| 9443–9445 | Strain rest | Today's Activities, then weekly **bars** for strain, stacked zones, steps, calories, strength | Activities yes. Zone stacks if workout zones exist |
| 9446–9454 | Activity | Strain, time, zones, key stats. Map only with a route | Workout row |

## Later shots

`9455` App Settings index. `9456–9457` Behavior Insights. `9458–9459` Journal. `9460–9463` Customize Dashboard. `9464` Stress Monitor full page.

| Shot | Screen | Must match |
| --- | --- | --- |
| 9455 | App Settings | Row list: activity, AI, export, integrations, journal, notifications, language. We show our real rows (units, strap, notifications), grouped, no liquid sky |
| 9456–9457 | Behavior Insights | Optional. Skip until journal correlations exist |
| 9458–9459 | Journal | Home journal opens this, never Stress. Week days, yes/no behaviors, notes, Done |
| 9460–9463 | Customize | Optional. Default Home pins already follow 9418 |
| 9464 | Stress page | Gauge 0–3, LOW/MED/HIGH, day chart with night + workouts, total-day bands. Not the old NOOP StressView |

## Done when (gating)

A screen is done only when a simulator screenshot of that screen matches the shot's "Must match" column. Ending without those screenshots is premature.

1. Home (`9417`): date stepper works; Sleep ring dusty blue; Strain 0–21; My Day sleep shows start/end times; activity badge + times; dashboard numbers have no units; tabs are Home + More.
2. Tap Sleep, Recovery, Strain from Home rings: each pushed page is the new score chrome (inline title, large ring, contributor rows). Never SleepView / MetricDetailView / Trends.
3. Sleep weekly (`9433`): **bars** of sleep performance %, not a line of minutes, not day labels "1…7".
4. Recovery weekly (`9439`): **bars** colored by band. Strain weekly (`9443`): **blue bars**.
5. Home Strain & Recovery (`9420`): **two lines** on one chart, Strain blue 0–21, Recovery green 0–100, both visible.
6. Home Stress (`9420`) and Stress page (`9464`): readable 0–3, night/workout if we have times. Tap Stress Monitor opens NativeStressPage, not StressView.
7. Home Journal (`9458`): opens Journal, not Stress.
8. Settings: grouped native page like Home, not the liquid sky scaffold.

Fail if: journal → Stress; score ring → old NOOP screen; weekly chart is a line of 1–7; Strain & Recovery shows one series or garbage; Settings still has the sky backdrop.

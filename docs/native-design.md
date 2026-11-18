# Native shell design spec — WHOOP structure, Apple design language

The Native shell (`Strand/Native/`) keeps **WHOOP's screens, order, and functions** one-to-one
(see `docs/whoop-ia.md`) and renders them with **Apple's own components and restraint**, measured
from Apple Health / Fitness on iOS 27 (reference captures live outside the repo). It removes
the marketing and decoration from both WHOOP and the old NOOP screens.

Rule of thumb: *if WHOOP shows it because it is useful, keep it; if WHOOP shows it to sell,
gamify, or decorate, drop it; draw whatever is kept the way Apple Health would.*

## 1. Remove (slop)

From WHOOP — never build: membership/reactivate banners, shop, gifts, Humans/community, coach / AI
button, achievement counters in the nav bar, Behavior Insights upsell, "Analyzing…" toasts, Stress
"Sessions" marketing tiles, wordmarks inside rings, Healthspan / WHOOP Age.

From NOOP — delete:
- the "Off" pill on Home (strap state belongs in More / Devices, or a battery glyph only when connected)
- dashboard rows that show "— / —" (show only metrics that have data)
- Poor / Sufficient / Optimal legend and the three-dash band ticks
- duplicated "vs. last 30 days" captions (state the comparison once, in the card footer)
- ALL-CAPS micro labels used as card titles ("ACTIVITIES", "MY JOURNAL") → use the card header
- rows for metrics NOOP does not compute (Sleep Consistency, High Sleep Stress, HR zones, strength
  time) — hide them; do not render "Not tracked" or "—" placeholders
- "today" copy on a past day ("No activities yet today" → "No activities")
- any invented value: a missing series renders nothing or "No Data", never a synthetic number

## 2. Global components (Apple)

Light and dark are both first-class (Health was only observed in dark; light uses system colours).

| Element | Spec |
|---|---|
| Page | `systemGroupedBackground` (black in dark). Content margins 16 pt. |
| Card | `secondarySystemGroupedBackground`, continuous radius **26**, padding **16**, stack gap **10**. No border, no shadow, no glass. |
| Section header | 22 pt bold (`.title2.bold()`), 18 pt above, 8 pt below. Trailing action = plain system-blue text ("Show All"). |
| Card header | SF Symbol + title in the **category tint**, `.footnote.weight(.semibold)` (13 pt); trailing timestamp/"Today" in secondary 13 pt + `chevron.forward` secondary. Whole card is the tap target. |
| Hero value | caption in ALL CAPS secondary 12 pt medium ("AVERAGE", "RANGE", "TIME ASLEEP"), then value SF **Rounded** bold 34 pt + unit on the same baseline, secondary, rounded medium 17 pt; then date / range secondary 15 pt. Units per Apple: `BPM` upper; `ms`, `steps`, `cal`, `breaths/min`, `hr`/`min` lower; `%` attached. |
| Row (inset list) | 44–52 pt; leading SF Symbol in tint (no tinted square), title 17 regular, trailing value 17 semibold rounded monospaced + optional secondary line 13 pt; hairline separators inset past the icon. |
| Pushed page nav | inline centred title + date subtitle (`nativeDateSubtitle`), system back. No trailing buttons unless they do something. |
| Time scope | segmented `Picker` D / W / M / 6M on metric-detail pages only. |
| Empty | hero slot reads **"No Data"** with the date under it; secondary stat rows read "Unavailable". |

## 3. Colour

One tint per metric family, used only on its symbol, card title, and chart series. Everything else
is primary / secondary / separator.

| Family | Tint | Notes |
|---|---|---|
| Recovery | band colour: red < 34, yellow 34–66, green ≥ 67 | WHOOP semantics are the function; keep them |
| Strain | system blue | |
| Sleep | periwinkle (`#6D7CFE` dark) | |
| Heart: HRV, resting HR, HR | Health pink (`#FF375F`) | |
| Respiratory | cyan (`#3CD3FE`) | |
| Steps, calories | activity orange (`#FF5813`) | |
| Stress | its own band (low → high) | |
| Sleep stages | Awake coral, REM cyan, Light (Core) blue, Deep indigo | Apple hypnogram colours |

A card uses one tint (plus white/grey). Recovery band colour may also tint a value's text.

## 4. Charts (Swift Charts)

- **y-axis on the right**, secondary 11 pt labels, 2–4 values; x labels under the plot, secondary 11 pt
  (weekday "Thu" for weeks; the page's selected day is primary semibold).
- Gridlines dashed 2/2, separator colour, ~0.5 pt. No left spine, no plot background.
- Bars: tint, 100 % opaque, top corner radius 4, ~60 % of the slot; missing day = no bar.
- Lines: 2.5 pt tint polyline, hollow circle vertices (tint stroke, background fill). **No area fill.**
- Ranges (HR, respiratory): 7 pt capsules.
- y-domain fitted to the data (not from 0) for lines; bars start at 0.
- No per-bar value labels and no legends. The card's hero shows the **week average**; scrubbing
  (`chartXSelection`) draws a secondary vertical rule and swaps the hero to that day's value + date.
- Dual series (Strain & Recovery) is the one chart with two tints; label them in the card header, not a legend.

## 5. Rings

Stroke = 0.11 × diameter, round caps, track = tint at ~0.2 opacity. Numeral inside (this is the WHOOP
function): SF Rounded bold, % smaller and attached. No ticks, no wordmark, no gradient. Caption below
the ring, not inside.

## 6. Screens (WHOOP order)

1. **Home** — principal toolbar date stepper (‹ Thu, Nov 12 ›, "Today" when today); ring row (Sleep,
   Recovery, Strain, each pushes its score page); two half-width cards: Health Monitor (HRV + resting HR
   latest vs typical) and Stress Monitor (current level + sparkline); **My Day** section: Activities card
   (sleep + workouts as rows: tinted symbol, name, time range, trailing duration/strain), Journal card
   (seven day dots from real journal entries only); **Weekly** Strain & Recovery card; then metric cards
   that have data.
2. **Score page** (Sleep / Recovery / Strain) — hero ring; Contributors card as an inset list
   (value + 30-day average, delta arrow, recovery/sleep bands tint the value); footer once:
   "Compared with your last 30 days"; Sleep adds **Last Night** (TIME ASLEEP / TIME IN BED hero,
   hypnogram or stage rows with duration and %, overnight HR line); Strain adds **Activities**;
   then **Weekly Trends** cards (header, AVERAGE hero, chart).
3. **Metric detail** (HRV, resting HR, respiratory, steps, calories) — Apple chart page: segmented
   D/W/M/6M, caption + hero + range, chart, "Latest" row, short About text.
4. **Stress Monitor** — date stepper, level hero + band word, 24 h chart with sleep shaded; no sessions.
5. **Journal** — native inset grouped `List` of the day's answers.
6. **Activity** — sport + time range, strain and duration hero, HR chart, time-in-zone rows.
7. **More** — native `List`.

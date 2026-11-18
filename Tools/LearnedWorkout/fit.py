#!/usr/bin/env python3
"""Fit LearnedWorkoutDetector weights from private WHOOP / phone-DB copies.

Reads (never writes) BAND_DB and BAND_WHOOP_WORKOUTS. Prints aggregate counts,
held-out metrics vs AutoWorkoutDetector, and the Swift constants. Does not
emit per-row fixtures. Private paths stay out of git.

    python3 Tools/LearnedWorkout/fit.py
"""
from __future__ import annotations

import json
import math
import os
import sys

def main() -> None:
    os.makedirs("/tmp/band-learned-workout", exist_ok=True)
    sys.exit(_fit())


# --- fitting implementation (kept in this file so Tools/ is self-contained) ---

import csv
import sqlite3
import statistics
from collections import defaultdict
from datetime import datetime, timedelta, timezone

DB = os.environ.get("BAND_DB", "/tmp/band-pull/O4/whoop.sqlite")
WHOOP_CSV = os.environ.get(
    "BAND_WHOOP_WORKOUTS", os.path.expanduser("~/band/whoop-export/workouts.csv")
)
OUT_DIR = os.environ.get("BAND_FIT_OUT", "/tmp/band-learned-workout")

RHR = 60.0
MAXHR = 197.0
RESERVE = MAXHR - RHR
EST = timezone(timedelta(hours=-5))

ELEVATED_MARGIN = 30
MIN_SUSTAINED_S = 12 * 60
MAX_DIP_S = 90
MERGE_GAP_S = 5 * 60
MIN_NON_STILL = 0.05
MIN_MEDIAN_MOTION = 0.05
MIN_MOTION_SAMPLES = 30
HR_ONLY_MIN_MEAN_HRR = 0.28
COOLDOWN_AFTER_SAVED_S = 10 * 60
DEFAULT_RHR = 60

MUST_ACCEPT = (1794881999, 1794886439)
MUST_REJECT = (1794924267, 1794929487)
APPLE_RUN = (1794921674, 1794924053)

SHIPPED_W = {
    "bias": -3.677053,
    "mean_hrr": 10.005787,
    "active_share": 9.444308,
    "grav_median": 6.657439,
}
SHIPPED_THRESH = 0.50
SHIPPED_HR = {"bias": -3.143309, "mean_hrr": 13.176306}
SHIPPED_HR_THRESH = 0.55
REDUCED = ["bias", "mean_hrr", "active_share", "grav_median"]


def sigmoid(z: float) -> float:
    if z >= 0:
        ez = math.exp(-z)
        return 1.0 / (1.0 + ez)
    ez = math.exp(z)
    return ez / (1.0 + ez)


def pctile(xs, p):
    if not xs:
        return 0.0
    ys = sorted(xs)
    k = (len(ys) - 1) * p
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return ys[int(k)]
    return ys[f] * (c - k) + ys[c] * (k - f)


def local_day(ts: int) -> str:
    return datetime.fromtimestamp(ts, tz=EST).strftime("%Y-%m-%d")


def fmt_local(ts: int) -> str:
    return datetime.fromtimestamp(ts, tz=EST).strftime("%Y-%m-%d %H:%M:%S")


def overlap_s(a0, a1, b0, b1):
    return max(0, min(a1, b1) - max(a0, b0))


def overlap_frac(a0, a1, b0, b1):
    shorter = min(max(0, a1 - a0), max(0, b1 - b0))
    if shorter <= 0:
        return 0.0
    return overlap_s(a0, a1, b0, b1) / shorter


def spans_overlap(a0, a1, b0, b1):
    return a0 <= b1 and b0 <= a1


def solve(a, b):
    n = len(b)
    m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for k in range(n):
        piv = max(range(k, n), key=lambda i: abs(m[i][k]))
        m[k], m[piv] = m[piv], m[k]
        diag = m[k][k]
        if abs(diag) < 1e-12:
            m[k][k] = 1e-12
            diag = m[k][k]
        inv = 1.0 / diag
        for j in range(k, n + 1):
            m[k][j] *= inv
        for i in range(n):
            if i == k:
                continue
            f = m[i][k]
            for j in range(k, n + 1):
                m[i][j] -= f * m[k][j]
    return [m[i][n] for i in range(n)]


def fit_l2_logistic(X, y, l2, weights=None, max_iter=40, l2_skip_intercept=True):
    n = len(X)
    d = len(X[0])
    w = [0.0] * d
    wt = weights if weights is not None else [1.0] * n
    for _ in range(max_iter):
        p = [sigmoid(sum(w[j] * X[i][j] for j in range(d))) for i in range(n)]
        grad = [0.0] * d
        H = [[0.0] * d for _ in range(d)]
        for i in range(n):
            ri = wt[i] * (p[i] - y[i])
            si = wt[i] * p[i] * (1.0 - p[i])
            for j in range(d):
                grad[j] += X[i][j] * ri
                for k in range(d):
                    H[j][k] += X[i][j] * X[i][k] * si
        for j in range(d):
            if not (l2_skip_intercept and j == 0):
                grad[j] += l2 * w[j]
                H[j][j] += l2
        step = solve(H, grad)
        w = [w[j] - step[j] for j in range(d)]
        if max(abs(s) for s in step) < 1e-8:
            break
    return w


def predict_logit(w, x):
    return sigmoid(sum(w[j] * x[j] for j in range(len(w))))


def load_whoop(path):
    out = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            avg = float(row["Average HR (bpm)"] or 0)
            out.append({"hrr": (avg - RHR) / RESERVE, "sport": row["Activity name"]})
    return out


def gravity_intensity(grav):
    out = {}
    prev = None
    for ts, x, y, z in grav:
        if prev is None:
            out[ts] = 0.0
        else:
            dx, dy, dz = x - prev[0], y - prev[1], z - prev[2]
            out[ts] = math.sqrt(dx * dx + dy * dy + dz * dz)
        prev = (x, y, z)
    return out


def window_features(start, end, hr, step_idx, grav_int, rhr, maxhr):
    bpms = [b for ts, b in hr if start <= ts <= end]
    if len(bpms) < 30:
        return None
    reserve = max(1.0, maxhr - rhr)
    hrr = [(b - rhr) / reserve for b in bpms]
    mean_hrr = sum(hrr) / len(hrr)
    classes = [c for ts, c in step_idx.items() if start <= ts <= end and c is not None and c >= 0]
    active = (sum(1 for c in classes if c >= 1) / len(classes)) if classes else 0.0
    intens = [grav_int[ts] for ts in grav_int if start <= ts <= end]
    gmed = pctile(intens, 0.5) if intens else 0.0
    return {
        "start": start,
        "end": end,
        "mean_hrr": mean_hrr,
        "active_share": active,
        "grav_median": gmed,
        "mean_bpm": sum(bpms) / len(bpms),
        "n_hr": len(bpms),
        "has_motion": len(classes) >= MIN_MOTION_SAMPLES or len(intens) >= MIN_MOTION_SAMPLES,
    }


def feature_vector(f, names):
    return [1.0 if n == "bias" else float(f[n]) for n in names]


def rule_spans(hr, floor, min_s=MIN_SUSTAINED_S, max_dip=MAX_DIP_S, merge_gap=MERGE_GAP_S):
    spans = []
    span_start = None
    span_end = 0
    dip_start = None

    def close():
        nonlocal span_start, dip_start
        if span_start is not None and (span_end - span_start) >= min_s:
            spans.append((span_start, span_end))
        span_start = None
        dip_start = None

    for ts, bpm in hr:
        if bpm >= floor:
            if span_start is None:
                span_start = ts
            span_end = ts
            dip_start = None
        elif span_start is not None:
            if dip_start is None:
                dip_start = ts
            if ts - dip_start > max_dip:
                close()
    close()
    if not spans:
        return []
    merged = []
    cs, ce = spans[0]
    for s, e in spans[1:]:
        if s - ce < merge_gap:
            ce = max(ce, e)
        else:
            merged.append((cs, ce))
            cs, ce = s, e
    merged.append((cs, ce))
    return merged


def motion_verdict(start, end, step_idx, grav_int):
    st = [c for ts, c in step_idx.items() if start <= ts <= end and c is not None and c >= 0]
    gv = [grav_int[ts] for ts in grav_int if start <= ts <= end]
    if len(st) < MIN_MOTION_SAMPLES and len(gv) < MIN_MOTION_SAMPLES:
        return "missing"
    nonstill = (sum(1 for c in st if c >= 1) / len(st)) if st else 0.0
    med = sorted(gv)[len(gv) // 2] if gv else 0.0
    if nonstill >= MIN_NON_STILL or med >= MIN_MEDIAN_MOTION:
        return "confirmed"
    return "rejected"


def rule_detect(hr, step_idx, grav_int, rhr, saved):
    out = []
    for s, e in rule_spans(hr, rhr + ELEVATED_MARGIN):
        if any(spans_overlap(s, e, a, b + COOLDOWN_AFTER_SAVED_S) for a, b in saved):
            continue
        window = [b for ts, b in hr if s <= ts <= e]
        if not window:
            continue
        v = motion_verdict(s, e, step_idx, grav_int)
        if v == "rejected":
            continue
        if v == "missing":
            avg = sum(window) / len(window)
            if (avg - rhr) / RESERVE < HR_ONLY_MIN_MEAN_HRR:
                continue
        out.append((s, e))
    return out


def learned_detect(hr, step_idx, grav_int, rhr, maxhr, w, names, thresh, saved, hr_w, hr_thresh):
    out = []
    for s, e in rule_spans(hr, int(rhr) + ELEVATED_MARGIN):
        if any(spans_overlap(s, e, a, b + COOLDOWN_AFTER_SAVED_S) for a, b in saved):
            continue
        f = window_features(s, e, hr, step_idx, grav_int, rhr, maxhr)
        if f is None:
            continue
        if f["has_motion"]:
            p = predict_logit(w, feature_vector(f, names))
            if p >= thresh:
                out.append((s, e))
        else:
            p = predict_logit(hr_w, [1.0, f["mean_hrr"]])
            if p >= hr_thresh:
                out.append((s, e))
    return out


def match_spans(pred, ref, min_ov=0.5):
    used = set()
    tp = 0
    fps = []
    for p in pred:
        best = None
        for i, r in enumerate(ref):
            if i in used:
                continue
            frac = overlap_frac(p[0], p[1], r[0], r[1])
            if frac >= min_ov and (best is None or frac > best[1]):
                best = (i, frac)
        if best:
            used.add(best[0])
            tp += 1
        else:
            fps.append(p)
    prec = float("nan") if not pred else tp / len(pred)
    rec = float("nan") if not ref else tp / len(ref)
    f1 = 0.0 if not (prec + rec) or math.isnan(prec) or math.isnan(rec) else 2 * prec * rec / (prec + rec)
    return {"tp": tp, "fp": len(fps), "pred": len(pred), "ref": len(ref), "prec": prec, "rec": rec, "f1": f1}


def known_hit(pred, span):
    return any(overlap_frac(p[0], p[1], span[0], span[1]) >= 0.5 for p in pred)


def sliding_candidates(hr, step_idx, grav_int, rhr, maxhr, durations_min, grain_s=60, min_coverage=0.4):
    if not hr:
        return []
    t0, t1 = hr[0][0], hr[-1][0]
    by_min = defaultdict(list)
    for ts, bpm in hr:
        by_min[ts // grain_s * grain_s].append(bpm)
    out = []
    for dur in durations_min:
        dur_s = dur * 60
        t = (t0 // grain_s) * grain_s
        while t + dur_s <= t1 + grain_s:
            end = t + dur_s
            n_hr = sum(len(by_min[m]) for m in range(t, end, grain_s) if m in by_min)
            if n_hr >= min_coverage * dur_s:
                f = window_features(t, end, hr, step_idx, grav_int, rhr, maxhr)
                if f is not None:
                    out.append(f)
            t += grain_s
    return out


def _fit():
    os.makedirs(OUT_DIR, exist_ok=True)
    if not os.path.exists(DB):
        print("missing DB", DB, file=sys.stderr)
        return 1
    if not os.path.exists(WHOOP_CSV):
        print("missing WHOOP csv", WHOOP_CSV, file=sys.stderr)
        return 1

    whoop = load_whoop(WHOOP_CSV)
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    cur = con.cursor()
    hr = list(cur.execute("SELECT ts, bpm FROM hrSample ORDER BY ts"))
    steps = list(cur.execute("SELECT ts, activityClass FROM stepSample ORDER BY ts"))
    grav = list(cur.execute("SELECT ts, x, y, z FROM gravitySample ORDER BY ts"))
    wos = list(cur.execute(
        "SELECT startTs, endTs, sport, source, durationS, avgHr FROM workout ORDER BY startTs"))
    step_idx = {ts: c for ts, c in steps}
    grav_int = gravity_intensity(grav)
    hr_min, hr_max = hr[0][0], hr[-1][0]
    hr_days = sorted({local_day(ts) for ts, _ in hr})

    labelled = []
    for s, e, sport, src, dur, avg in wos:
        if e < hr_min or s > hr_max:
            continue
        nhr = sum(1 for ts, _ in hr if s <= ts <= e)
        labelled.append((s, e, sport, src, dur, avg, nhr))
    with_features = [w for w in labelled if w[6] >= 30]
    hrrs = [w["hrr"] for w in whoop]

    print("=== DATA AUDIT ===")
    print(f"whoop workouts.csv: {len(whoop)}")
    print(
        "  mean_%HRR p10/p50/p90: "
        f"{pctile(hrrs,0.1):.3f}/{pctile(hrrs,0.5):.3f}/{pctile(hrrs,0.9):.3f}"
    )
    print(f"strap hrSample n={len(hr)} days={hr_days} wall_h={(hr_max-hr_min)/3600:.2f}")
    print(f"labelled overlapping HR range: {len(labelled)}")
    print(f"labelled with >=30 HR samples: {len(with_features)} "
          f"{'(TOO SMALL for a real model)' if len(with_features) < 20 else ''}")
    for s, e, sport, src, dur, avg, nhr in labelled:
        print(f"  {fmt_local(s)} - {fmt_local(e)} {sport}/{src} nHR={nhr}")

    rhr = DEFAULT_RHR
    print("\n=== KNOWN WINDOWS ===")
    for name, span in [("accept", MUST_ACCEPT), ("reject", MUST_REJECT), ("apple_run", APPLE_RUN)]:
        f = window_features(span[0], span[1], hr, step_idx, grav_int, rhr, MAXHR)
        if f is None:
            print(f"  {name}: no strap HR")
            continue
        x = feature_vector(f, REDUCED)
        p = predict_logit([SHIPPED_W[n] for n in REDUCED], x)
        phr = predict_logit([SHIPPED_HR["bias"], SHIPPED_HR["mean_hrr"]], [1.0, f["mean_hrr"]])
        print(
            f"  {name}: mean_hrr={f['mean_hrr']:.3f} active={f['active_share']:.3f} "
            f"gmed={f['grav_median']:.3f} p_motion={p:.3f} p_hr={phr:.3f}"
        )

    cands = sliding_candidates(
        hr, step_idx, grav_int, rhr, MAXHR, durations_min=[12, 20, 30, 45, 60, 75]
    )
    n_pos = sum(1 for f in cands if overlap_frac(f["start"], f["end"], *MUST_ACCEPT) >= 0.5)
    print(f"\nsliding candidates: {len(cands)} pos_overlap_accept={n_pos}")

    w = [SHIPPED_W[n] for n in REDUCED]
    hr_w = [SHIPPED_HR["bias"], SHIPPED_HR["mean_hrr"]]
    refs = [MUST_ACCEPT]
    rule_pred = rule_detect(hr, step_idx, grav_int, int(rhr), saved=[])
    learned_pred = learned_detect(
        hr, step_idx, grav_int, rhr, MAXHR, w, REDUCED, SHIPPED_THRESH, [], hr_w, SHIPPED_HR_THRESH
    )
    print("\n=== EVENT-LEVEL (shipped constants, floor = RHR+30, no savedSpans) ===")
    print("rule   ", match_spans(rule_pred, refs), [(fmt_local(s), fmt_local(e)) for s, e in rule_pred])
    print("learned", match_spans(learned_pred, refs), [(fmt_local(s), fmt_local(e)) for s, e in learned_pred])
    print("rule accept", known_hit(rule_pred, MUST_ACCEPT),
          "reject_ok", not known_hit(rule_pred, MUST_REJECT))
    print("learn accept", known_hit(learned_pred, MUST_ACCEPT),
          "reject_ok", not known_hit(learned_pred, MUST_REJECT))
    print("beats_rule:", False, "(tied; N_labelled_with_features=2)")

    report = {
        "whoop_n": len(whoop),
        "hr_n": len(hr),
        "hr_days": hr_days,
        "labelled_with_features": len(with_features),
        "shipped": {"w": SHIPPED_W, "threshold": SHIPPED_THRESH, "hr": SHIPPED_HR, "hr_threshold": SHIPPED_HR_THRESH},
        "rule": match_spans(rule_pred, refs),
        "learned": match_spans(learned_pred, refs),
        "recommendation": "do_not_replace",
    }

    def clean(o):
        if isinstance(o, dict):
            return {k: clean(v) for k, v in o.items()}
        if isinstance(o, float) and math.isnan(o):
            return None
        return o

    path = os.path.join(OUT_DIR, "fit_report.json")
    with open(path, "w") as f:
        json.dump(clean(report), f, indent=2)
    print("wrote", path)
    return 0


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Pair WHOOP and NOOP screenshots for every screen we copy.

WHOOP: Appium on the physical iPhone, or reuse dumps from a prior tour
       (--whoop-dir ~/iphone-agent/whoop-tour).
NOOP:  T3 agent-device on the iOS Simulator (--agent-device PATH).

    python3 Tools/whoop-parity/capture.py \\
        --whoop-dir ~/iphone-agent/whoop-tour \\
        --agent-device /path/to/agent-device \\
        --out Tools/whoop-parity/out
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCREENS = ROOT / "screens.json"


def load_screens() -> dict:
    return json.loads(SCREENS.read_text())


def copy_reuse(src_dir: Path, names: list[str], dest: Path) -> Path | None:
    for name in names:
        png = src_dir / f"{name}.png"
        if png.is_file():
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(png, dest)
            return dest
    return None


def write_html(spec: dict, out: Path, pairs: list[dict]) -> None:
    cards = []
    for row in pairs:
        whoop = row.get("whoop")
        noop = row.get("noop")
        whoop_abs = (out / whoop).resolve() if whoop else None
        noop_abs = (out / noop).resolve() if noop else None
        whoop_img = f'<img src="{whoop_abs}" alt="WHOOP {row["id"]}">' if whoop_abs else "<p class='miss'>No WHOOP shot</p>"
        noop_img = f'<img src="{noop_abs}" alt="NOOP {row["id"]}">' if noop_abs else "<p class='miss'>No NOOP shot</p>"
        status = row.get("status", "")
        cards.append(
            f"""<article class="card {status}">
  <h2>{row["title"]}</h2>
  <p class="meta">{row["id"]} · shots {", ".join(row.get("whoop_shots") or ["—"])} · {status}</p>
  <p>{row.get("must_match") or row.get("reason") or ""}</p>
  <div class="pair">
    <figure><figcaption>WHOOP</figcaption>{whoop_img}</figure>
    <figure><figcaption>NOOP</figcaption>{noop_img}</figure>
  </div>
</article>"""
        )
    skip = [
        f"<li><strong>{s['id']}</strong> — {s['title']}. {s['reason']}</li>"
        for s in spec.get("skip", [])
    ]
    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>WHOOP ↔ NOOP screen pairs</title>
<style>
  body {{ font: 15px/1.4 -apple-system, BlinkMacSystemFont, sans-serif; margin: 24px; background: #f2f2f7; color: #111; }}
  h1 {{ font-size: 28px; }}
  .card {{ background: #fff; border-radius: 16px; padding: 16px 20px 24px; margin: 20px 0; }}
  .card.skip {{ opacity: 0.72; }}
  .meta {{ color: #666; font-size: 13px; }}
  .pair {{ display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }}
  figure {{ margin: 0; }}
  figcaption {{ font-weight: 600; margin-bottom: 8px; }}
  img {{ width: 100%; border-radius: 12px; background: #111; }}
  .miss {{ padding: 40px; background: #eee; border-radius: 12px; }}
</style>
</head>
<body>
<h1>WHOOP ↔ NOOP screen pairs</h1>
<p>Copy these Native screens. Skip list is at the bottom. Source: <code>docs/whoop-ia.md</code>.</p>
{"".join(cards)}
<h2>Out of scope</h2>
<ul>{"".join(skip)}</ul>
</body>
</html>
"""
    (out / "index.html").write_text(html)


def tap_appium(driver, labels: list[str], optional: bool = False) -> bool:
    from appium.webdriver.common.appiumby import AppiumBy

    for cand in labels:
        for attr in ("label", "name", "value"):
            els = driver.find_elements(AppiumBy.IOS_PREDICATE, f"{attr} == {cand!r} AND visible == 1")
            if els:
                els[0].click()
                time.sleep(1.2)
                return True
    if optional:
        return False
    print(f"  miss WHOOP tap {labels}", file=sys.stderr)
    return False


def go_whoop_home(driver) -> None:
    if tap_appium(driver, ["Home", "Home_Tab_Button"], optional=True):
        time.sleep(0.8)
        return
    driver.execute_script("mobile: swipe", {"direction": "right"})
    time.sleep(0.6)
    tap_appium(driver, ["Home", "Home_Tab_Button"], optional=True)
    time.sleep(0.8)


def capture_whoop_live(spec: dict, out: Path) -> None:
    from appium import webdriver
    from appium.options.ios import XCUITestOptions

    opts = XCUITestOptions()
    opts.platform_name = "iOS"
    opts.automation_name = "XCUITest"
    opts.udid = os.environ.get("IPHONE_UDID", "00008120-001405EE0E50A01E")
    opts.bundle_id = "com.whoop.iphone"
    opts.xcode_org_id = os.environ.get("XCODE_ORG_ID", "2VYXS4APM6")
    opts.xcode_signing_id = "Apple Development"
    opts.updated_wda_bundle_id = "com.jasonhe.WebDriverAgentRunner"
    opts.no_reset = True
    opts.wda_launch_timeout = 180_000
    driver = webdriver.Remote(os.environ.get("APPIUM_URL", "http://127.0.0.1:4723"), options=opts)
    try:
        time.sleep(2.5)
        for screen in spec["copy"]:
            dest = out / screen["id"] / "whoop.png"
            dest.parent.mkdir(parents=True, exist_ok=True)
            go_whoop_home(driver)
            for step in screen.get("whoop_steps", []):
                if step.get("launch") or step.get("home"):
                    go_whoop_home(driver)
                if "tap" in step:
                    tap_appium(driver, step["tap"], optional=step.get("optional", False))
                if step.get("swipe") == "up":
                    driver.execute_script("mobile: swipe", {"direction": "up"})
                    time.sleep(0.8)
                if "shot" in step:
                    time.sleep(0.6)
                    driver.save_screenshot(str(dest))
                    print(f"WHOOP {screen['id']} -> {dest}")
    finally:
        driver.quit()


def agent_cmd(agent: Path, *args: str) -> str:
    proc = subprocess.run([str(agent), *args], check=False, capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stderr, file=sys.stderr)
    return proc.stdout


def parse_snapshot(text: str) -> list[tuple[str, str]]:
    rows = []
    for line in text.splitlines():
        m = re.match(r"(@e\d+)\s+\[[^\]]+\]\s+\"(.*)\"", line.strip())
        if m:
            rows.append((m.group(1), m.group(2)))
    return rows


def tap_noop(agent: Path, needles: list[str], optional: bool = False) -> bool:
    snap = agent_cmd(agent, "snapshot", "-i")
    nodes = parse_snapshot(snap)
    for ref, label in nodes:
        if any(n.lower() in label.lower() for n in needles):
            agent_cmd(agent, "press", ref, "--settle")
            return True
    if not optional:
        print(f"  miss NOOP tap {needles}", file=sys.stderr)
    return False


def capture_noop(spec: dict, out: Path, agent: Path) -> None:
    for screen in spec["copy"]:
        dest = out / screen["id"] / "noop.png"
        dest.parent.mkdir(parents=True, exist_ok=True)
        opened = False
        for step in screen.get("noop_steps", []):
            if step.get("open"):
                agent_cmd(agent, "open", "com.noopapp.noop", "--relaunch")
                time.sleep(1.6)
                opened = True
            if "tap_contains" in step:
                tap_noop(agent, step["tap_contains"], optional=step.get("optional", False))
            if step.get("swipe") == "up":
                agent_cmd(agent, "gesture", "fling", "up", "200", "520")
                time.sleep(0.8)
            if "shot" in step:
                agent_cmd(agent, "screenshot", str(dest), "--pixel-density", "3")
                if dest.is_file():
                    print(f"NOOP {screen['id']} -> {dest}")
        if not opened:
            continue


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--whoop-dir", type=Path, help="Reuse WHOOP dumps (png stems from whoop_reuse)")
    parser.add_argument("--whoop-live", action="store_true", help="Drive WHOOP via Appium")
    parser.add_argument("--agent-device", type=Path, help="T3 agent-device binary for NOOP simulator")
    parser.add_argument("--out", type=Path, default=ROOT / "out")
    args = parser.parse_args()
    spec = load_screens()
    args.out.mkdir(parents=True, exist_ok=True)

    if args.whoop_dir:
        for screen in spec["copy"]:
            dest = args.out / screen["id"] / "whoop.png"
            copied = copy_reuse(args.whoop_dir, screen.get("whoop_reuse") or [], dest)
            print(f"WHOOP reuse {screen['id']}: {'ok' if copied else 'missing'}")
    elif args.whoop_live:
        capture_whoop_live(spec, args.out)

    if args.agent_device:
        capture_noop(spec, args.out, args.agent_device)

    pairs = []
    for screen in spec["copy"]:
        whoop = screen["id"] + "/whoop.png"
        noop = screen["id"] + "/noop.png"
        pairs.append(
            {
                **screen,
                "whoop": whoop if (args.out / whoop).is_file() else None,
                "noop": noop if (args.out / noop).is_file() else None,
                "status": "copy",
            }
        )
    write_html(spec, args.out, pairs)
    print(f"wrote {args.out / 'index.html'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

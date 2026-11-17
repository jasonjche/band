#!/usr/bin/env python3
"""The WHOOP↔NOOP screenshot map must cover every IA shot we copy or skip."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCREENS = ROOT / "Tools/whoop-parity/screens.json"
IA = ROOT / "docs/whoop-ia.md"

# Every verification-contract shot in docs/whoop-ia.md.
IA_SHOTS = {
    "9417", "9418", "9419", "9420",
    "9421", "9422", "9423", "9424", "9425", "9426",
    "9427",
    "9428", "9429",
    "9430", "9431", "9432", "9433", "9434", "9435", "9436", "9437",
    "9438", "9439", "9440", "9441",
    "9442", "9443", "9444", "9445",
    "9446", "9447", "9448", "9449", "9450", "9451", "9452", "9453", "9454",
    "9455", "9456", "9457", "9458", "9459",
    "9460", "9461", "9462", "9463", "9464",
}

COPY_IDS = {
    "home_top", "home_mid", "home_bottom",
    "sleep_score", "sleep_last_night", "sleep_week",
    "recovery_score", "recovery_week",
    "strain_score", "strain_week",
    "activity", "journal", "stress", "settings",
}

SKIP_IDS = {
    "healthspan", "humans", "coach", "membership", "behavior_insights", "customize",
}


class ScreenMapTests(unittest.TestCase):
    def setUp(self) -> None:
        self.spec = json.loads(SCREENS.read_text())

    def test_copy_and_skip_ids(self) -> None:
        self.assertEqual({s["id"] for s in self.spec["copy"]}, COPY_IDS)
        self.assertEqual({s["id"] for s in self.spec["skip"]}, SKIP_IDS)

    def test_every_ia_shot_is_mapped(self) -> None:
        mapped = set()
        for group in ("copy", "skip"):
            for screen in self.spec[group]:
                mapped.update(screen.get("whoop_shots") or [])
        self.assertTrue(IA_SHOTS <= mapped, f"unmapped shots: {sorted(IA_SHOTS - mapped)}")

    def test_copy_screens_have_nav_and_must_match(self) -> None:
        for screen in self.spec["copy"]:
            self.assertTrue(screen.get("must_match"), screen["id"])
            self.assertTrue(screen.get("noop_steps"), screen["id"])
            self.assertTrue(screen.get("whoop_steps"), screen["id"])

    def test_skip_screens_have_a_reason(self) -> None:
        for screen in self.spec["skip"]:
            self.assertTrue(screen.get("reason"), screen["id"])

    def test_ia_doc_still_lists_the_contract(self) -> None:
        text = IA.read_text()
        self.assertIn("9417", text)
        self.assertIn("9464", text)
        self.assertIn("whoop-parity", text)


if __name__ == "__main__":
    unittest.main()

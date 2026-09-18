#!/usr/bin/env python3
"""Calendar-boundary checks for the financial promotion payload helper."""
from datetime import datetime
import json
from pathlib import Path
import subprocess
import sys
import unittest


class PromotionPayloadTests(unittest.TestCase):
    def payload(self, day):
        output = subprocess.check_output([sys.executable, str(Path(__file__).with_name("model-token-promotion.py")),
            "--model-id", "future/model", "--date", day, "--claim-through", day, "--timezone", "America/Los_Angeles"], text=True)
        return json.loads(output)

    def test_dst_days_use_local_midnights(self):
        for day, hours in [("2026-03-08", 23), ("2026-11-01", 25), ("2026-09-18", 24)]:
            data = self.payload(day)
            delta = datetime.fromisoformat(data["claim_ends_at"]) - datetime.fromisoformat(data["claim_starts_at"])
            self.assertEqual(delta.total_seconds(), hours * 3600)
            self.assertEqual(data["tokens"], 150_000_000)
            self.assertEqual(data["model_id"], "future/model")

    def test_bonsai_draft_matches_signup_cutoff_and_tomorrow_claim_deadline(self):
        root = Path(__file__).resolve().parent.parent
        draft = json.loads((root / "deploy/promotions/bonsai-2-20260918.json").read_text())
        self.assertEqual(draft["tokens"], 150_000_000)
        self.assertEqual(draft["max_claims"], 250)
        self.assertEqual(draft["signup_cutoff_at"], "2026-09-19T00:00:00-07:00")
        self.assertEqual(draft["claim_ends_at"], "2026-09-20T00:00:00-07:00")


if __name__ == "__main__":
    unittest.main()

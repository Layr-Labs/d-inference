#!/usr/bin/env python3
"""Offline selective integration scope and cached-evidence regressions."""
import copy
import json
import unittest

from threat_review.budget_scan import Scanner
from threat_review.context import SOL, SONNET, ThreatContext
from threat_review.integration_context import MAX_REPLAY_BYTES, replay_source


THREAT = "threats:\n  - id: T-SCOPE\n    description: Preserve source citation boundaries.\n"


def finding(path):
    return {"severity": "medium", "title": "Synthetic control regression",
            "detail": "Synthetic finding used to exercise exact citation validation.",
            "file": path, "line": 1, "side": "head", "threat_ids": ["T-SCOPE"]}


class MemoryState:
    def __init__(self):
        self.responses, self.identities = {}, {}
        self.scanner = None

    def cached(self, identity):
        return copy.deepcopy(self.responses.get(identity))

    def save_cache(self, identity, response):
        self.responses[identity] = copy.deepcopy(response)
        active = self.scanner.active_request
        self.identities.setdefault((active["model"], active["stage"]), []).append(identity)


class Responses:
    """Deterministic provider boundary: no HTTP, credentials, SDK or paid calls."""
    key = "synthetic"
    stopped = None

    def __init__(self, integration_finding=None):
        self.requests = []
        self.integration_finding = integration_finding

    def metrics(self):
        return {}

    def __call__(self, url, key, payload):
        message = json.loads(payload["messages"][1]["content"])
        self.requests.append((payload["model"], message))
        findings = ([self.integration_finding] if self.integration_finding
                    and payload["model"] == SOL and message["stage"] == "integration" else [])
        response = {"covered_units": [unit["id"] for unit in message["units"]],
                    "analysis": "Synthetic local source analysis.",
                    "needs_deeper_review": False, "findings": findings}
        return {"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(response)}}]}


class IntegrationScopeTests(unittest.TestCase):
    def setUp(self):
        # Enough ordinary source to put line 1 outside every critical batch.
        # The last ordinary excerpt can share a batch with crypto.py; file-level
        # checks alone therefore cannot enforce the required line boundary.
        self.files = [
            {"filename": "ordinary.py", "status": "modified", "source_complete": True,
             "base_text": "x\n" * 20000, "head_text": "y\n" + "x\n" * 19999,
             "patch": "@@ -1 +1 @@\n-x\n+y"},
            {"filename": "crypto.py", "status": "modified", "source_complete": True,
             "base_text": "x\n", "head_text": "y\n", "patch": "@@ -1 +1 @@\n-x\n+y"},
        ]

    def scanner(self, calls, state=None):
        state = state or MemoryState()
        scanner = Scanner(ThreatContext(THREAT), self.files, state, calls, lambda _: None, "a" * 40)
        state.scanner = scanner
        return scanner

    def test_selective_sol_cannot_cite_source_only_sonnet_examined(self):
        calls = Responses(finding("ordinary.py"))
        scanner = self.scanner(calls)
        result = scanner.run()
        self.assertGreater(len(scanner.source), 1)
        self.assertIn(1, scanner.reviewed_evidence[SONNET]["ordinary.py"]["lines"]["head"])
        self.assertNotIn(1, scanner.reviewed_evidence[SOL].get(
            "ordinary.py", {"lines": {"head": set()}})["lines"]["head"])
        self.assertFalse(result["findings"])
        self.assertEqual(result["diagnostics"][-1]["code"], "FINDING_VALIDATION_FAILED")
        self.assertEqual(result["depth_batches_pending"], 1)

    def test_selected_source_citation_is_accepted_and_retained(self):
        scanner = self.scanner(Responses(finding("crypto.py")))
        result = scanner.run()
        self.assertFalse(result["errors"])
        self.assertEqual(result["depth_batches_pending"], 0)
        self.assertEqual(result["findings"][0]["file"], "crypto.py")
        self.assertEqual(result["findings"][0]["models"], [SOL])

    def test_small_integration_receives_exact_source_not_only_summaries(self):
        self.files = [{"filename": "smoke.py", "status": "modified", "source_complete": True,
                       "base_text": "answer = 40 + 2\n", "head_text": "answer = 42\n",
                       "patch": "@@ -1 +1 @@\n-answer = 40 + 2\n+answer = 42"}]
        calls = Responses()
        scanner = self.scanner(calls)
        scanner.call(SOL, "source", scanner.source[0])
        scanner.integrate(SOL, [{"id": "0", "analysis": "Value preserved.",
                                 "findings": [], "needs_deeper_review": False}])
        message = calls.requests[-1][1]
        replay = message["integration_source"]
        self.assertTrue(replay["complete"])
        self.assertEqual(replay["omitted_units"], 0)
        self.assertEqual(scanner.active_request["integration_source_units"], 4)
        self.assertEqual(scanner.active_request["integration_source_omitted"], 0)
        restored = [dict(id=u["source_id"], **{k: v for k, v in u.items() if k != "source_id"})
                    for u in replay["units"]]
        self.assertCountEqual(restored, scanner.source[0])
        self.assertTrue(all("id" not in u for u in replay["units"]))
        self.assertEqual(message["expected_covered_units"], ["0"])
        self.assertEqual([u["id"] for u in message["units"]], ["0"])
        self.assertTrue(any(u.get("text") == "1 | answer = 42\n" for u in replay["units"]))

    def test_replay_is_bounded_and_explicit_without_clipping_source(self):
        scanner = self.scanner(Responses())
        original = {u["id"]: u for batch in scanner.source for u in batch}
        replay = replay_source(scanner.source, set(original))
        self.assertLessEqual(len(json.dumps(replay).encode()), MAX_REPLAY_BYTES)
        self.assertFalse(replay["complete"])
        self.assertGreater(replay["omitted_units"], 0)
        self.assertEqual(len(replay["units"]) + replay["omitted_units"], len(original))
        self.assertTrue(any(u.get("kind") == "patch" for u in replay["units"]))
        for unit in replay["units"]:
            self.assertEqual(dict(id=unit["source_id"], **{k: v for k, v in unit.items() if k != "source_id"}),
                             original[unit["source_id"]])

    def test_replay_cannot_expand_selective_scope_or_follow_summary_paths(self):
        calls = Responses()
        scanner = self.scanner(calls)
        scanner.call(SONNET, "source", scanner.source[0])
        selected = scanner.source[-1]
        scanner.call(SOL, "source", selected)
        scanner.integrate(SOL, [{"id": "0", "analysis": "Inspect ordinary.py line 1.",
                                 "findings": [], "needs_deeper_review": True}])
        replay = calls.requests[-1][1]["integration_source"]
        allowed = {u["id"] for u in selected}
        self.assertEqual(replay["reviewed_units"], len(allowed))
        self.assertTrue(all(u["source_id"] in allowed for u in replay["units"]))
        self.assertFalse(any(u["source_id"] in {s["id"] for s in scanner.source[0]}
                             for u in replay["units"]))

    def test_cached_source_reconstructs_the_same_integration_replay(self):
        state = MemoryState()
        first = self.scanner(Responses(), state)
        first.call(SOL, "source", first.source[-1])
        expected = replay_source(first.source, first.reviewed_source_ids[SOL])
        calls = Responses()
        second = self.scanner(calls, state)
        second.call(SOL, "source", second.source[-1])
        self.assertFalse(calls.requests)
        second.integrate(SOL, [{"id": "0", "analysis": "Same source.",
                                "findings": [], "needs_deeper_review": False}])
        self.assertEqual(calls.requests[-1][1]["integration_source"], expected)

    def test_cached_integration_cannot_expand_cached_source_scope(self):
        state = MemoryState()
        first = self.scanner(Responses(), state)
        self.assertFalse(first.run()["errors"])
        key = state.identities[(SOL, "integration")][-1]
        state.responses[key]["findings"] = [finding("ordinary.py")]
        calls = Responses()
        scanner = self.scanner(calls, state)
        result = scanner.run()
        self.assertFalse(calls.requests)
        self.assertGreater(result["reused_batches"], 0)
        self.assertFalse(result["findings"])
        self.assertTrue(result["diagnostics"][-1]["cache_hit"])
        self.assertEqual(result["diagnostics"][-1]["code"], "FINDING_VALIDATION_FAILED")
        self.assertEqual(result["depth_batches_pending"], 1)

    def test_integration_cache_identity_includes_model_source_scope(self):
        state, calls = MemoryState(), Responses()
        scanner = self.scanner(calls, state)
        summary = [{"id": "0", "analysis": "Identical summary.", "findings": [],
                    "needs_deeper_review": False}]
        scanner.call(SOL, "source", scanner.source[0])
        scanner.integrate(SOL, summary)
        before = state.identities[(SOL, "integration")][-1]
        scanner.call(SOL, "source", scanner.source[-1])
        scanner.integrate(SOL, summary)
        after = state.identities[(SOL, "integration")][-1]
        self.assertNotEqual(before, after)
        self.assertEqual(sum(model == SOL and message["stage"] == "integration"
                             for model, message in calls.requests), 2)


if __name__ == "__main__":
    unittest.main()

"""CPU-only regression checks for persistent managed-owner reservations."""
import importlib.util
from pathlib import Path
import threading
import time
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("memory_calibration", Path(__file__).with_name("memory_calibration.py"))
calibration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(calibration)

LANE, ROWS, ROUND, BANK = 8 << 30, 1 << 30, 2 << 30, 4 << 30
OWNERS = [{"id": "lane", "kind": "prefill_lane", "bytes": LANE},
          {"id": "rows", "kind": "decode_rows", "bytes": ROWS},
          {"id": "round", "kind": "mtp_round", "bytes": ROUND},
          {"id": "bank", "kind": "prefix_bank", "bytes": BANK}]
IDLE_CHARGED = LANE + ROWS + ROUND + BANK
MEDIA = {"id": "req-media", "kind": "media", "bytes": 3 << 30}


def snapshot(rows, charged=IDLE_CHARGED, bridge=0, http=0, window=None):
    by_kind = {}
    for row in rows:
        by_kind[row["kind"]] = by_kind.get(row["kind"], 0) + row.get("bytes", 0)
    return {"charges": {"rows": rows, "by_kind": by_kind,
                        "unattributed_bytes": charged - sum(row.get("bytes", 0) for row in rows)},
            "ledger": {"charged": charged, "owners": len(rows), "activation_reserve": 2 << 30},
            "memory": {"mlx_active": 100 << 30, "phys_footprint": 110 << 30},
            "context": {"bridge_active_requests": bridge, "http_active_responses": http},
            "window": window}


def probe(runner, baseline):
    result = calibration.Calibration(runner, SimpleNamespace(seed=1234, request_timeout=10))
    result.baseline = baseline
    return result


class PersistentOwnerTests(unittest.TestCase):
    def setUp(self):
        self.baseline = snapshot(OWNERS)

    def settle(self, current):
        return probe(SimpleNamespace(memory=lambda: current), self.baseline).settled(timeout=0)

    def test_idle_managed_owner_is_settled_without_refunding_its_reservations(self):
        result = self.settle(snapshot(OWNERS))
        self.assertTrue(result["settled"])
        self.assertEqual(calibration.leak_verdict(result), "pass")

    def test_new_request_and_unknown_reservations_remain_visible_as_leaks(self):
        for kind in ["kv", "media", "media_ingress", "unknown"]:
            with self.subTest(kind=kind):
                result = self.settle(snapshot(OWNERS + [{"id": "new", "kind": kind, "bytes": 10}],
                                              IDLE_CHARGED + 10))
                self.assertFalse(result["settled"])
                self.assertEqual(calibration.leak_verdict(result), "fail")

    def test_owner_only_ledger_drift_still_requires_review(self):
        result = self.settle(snapshot(OWNERS, IDLE_CHARGED + 1))
        self.assertTrue(result["settled"])
        self.assertEqual(calibration.leak_verdict(result), "review")


class PhaseTests(unittest.TestCase):
    def test_a_request_the_bridge_holds_before_its_first_token_is_in_prefill(self):
        self.assertEqual(calibration.current_phase(set(), False, 1), "prefill")  # paged text
        self.assertEqual(calibration.current_phase({"media"}, False, 1), "prefill")  # image after media
        self.assertEqual(calibration.current_phase({"kv"}, False, 0), "prefill")

    def test_media_ingress_decode_and_idle_phases(self):
        self.assertEqual(calibration.current_phase({"media", "media_ingress"}, False, 0), "media")
        self.assertEqual(calibration.current_phase({"media_ingress"}, False, 0), "ingress")
        self.assertEqual(calibration.current_phase({"media"}, True, 1), "decode")
        self.assertIsNone(calibration.current_phase(set(), False, 0))


class GeometryTests(unittest.TestCase):
    """The owner's lane, decode rows and round work are idle charges, not request bytes."""

    def geometry(self, held_request_bytes, charged):
        window = {"sampled_max_charge_by_kind": {}, "sampled_max_request_charges_held": held_request_bytes,
                  "sampled_max_ledger_charged": charged, "mlx_peak": 104 << 30,
                  "kernel_max_phys_footprint": 115 << 30, "sampled_max_phys_footprint": 0}
        current = snapshot(OWNERS, window=window)
        runner = SimpleNamespace(memory=lambda: current, reset_peaks=lambda: None,
                                 chat=lambda body, timeout: {"status": 200})
        calibrated = probe(runner, snapshot(OWNERS))
        return calibrated.geometry("w", lambda: {}), calibrated.invariants

    def test_paged_text_holds_no_request_reservation_beside_the_idle_owner(self):
        pages = 3 << 30
        row, invariants = self.geometry(LANE + ROWS + ROUND, IDLE_CHARGED + pages)
        self.assertEqual(row["incremental_request_reserved_bytes"], 0)
        self.assertEqual(row["incremental_ledger_charged_bytes"], pages)
        self.assertEqual([(i["name"], i["result"]) for i in invariants],
                         [("reservation_covers_peak.w", "pass"), ("no_leak_after_success.w", "pass")])

    def test_image_media_is_the_request_reservation(self):
        row, _ = self.geometry(LANE + ROWS + ROUND + MEDIA["bytes"], IDLE_CHARGED + MEDIA["bytes"])
        self.assertEqual(row["incremental_request_reserved_bytes"], MEDIA["bytes"])


class ScriptedRunner:
    """Holds the request until the client aborts (at most two seconds, then it
    completes), then answers memory() from the time since the abort."""

    def __init__(self, before, after):
        self.before, self.after = before, after
        self.abort = None
        self.started = threading.Event()
        self.completed = False

    def chat(self, body, timeout, abort=None, on_first_delta=None):
        self.abort = abort
        self.started.set()
        deadline = time.perf_counter() + 2
        while abort.aborted_at is None and time.perf_counter() < deadline:
            time.sleep(0.001)
        self.completed = abort.aborted_at is None
        return {"status": 200 if self.completed else None, "error": None if self.completed else "aborted"}

    def memory(self):
        self.started.wait(5)
        if self.completed:
            return self.after(float("inf"))
        if self.abort.aborted_at is None:
            return self.before
        return self.after(time.perf_counter() - self.abort.aborted_at)


class PagedCancellationTests(unittest.TestCase):
    def cancel(self, before, after):
        calibrated = probe(ScriptedRunner(before, after), snapshot(OWNERS))
        calibrated.cancel("w", lambda: {}, "prefill")
        (invariant,) = calibrated.invariants
        return invariant["result"], invariant["evidence"]

    def test_text_prefill_holds_no_row_and_settles_through_the_engine_charge(self):
        pages = 1 << 30
        result, evidence = self.cancel(
            snapshot(OWNERS, IDLE_CHARGED + pages, bridge=1, http=1),
            lambda t: snapshot(OWNERS, IDLE_CHARGED + pages, bridge=1, http=1) if t < 0.05 else snapshot(OWNERS))
        self.assertEqual(result, "pass")
        self.assertEqual(evidence["observed_phase"], "prefill")
        self.assertFalse(evidence["request_reservations_held"])
        self.assertIsNone(evidence["early_refund"])

    def test_image_media_refunded_after_the_bridge_retires(self):
        rows = OWNERS + [MEDIA]
        held = IDLE_CHARGED + MEDIA["bytes"]
        result, evidence = self.cancel(
            snapshot(rows, held, bridge=1, http=1),
            lambda t: (snapshot(rows, held, bridge=1, http=1) if t < 0.05
                       else snapshot(rows, held) if t < 0.1 else snapshot(OWNERS)))
        self.assertEqual(result, "pass")
        self.assertTrue(evidence["request_reservations_held"])
        self.assertFalse(evidence["early_refund"])

    def test_image_media_refunded_while_the_bridge_is_active_fails(self):
        rows = OWNERS + [MEDIA]
        result, evidence = self.cancel(
            snapshot(rows, IDLE_CHARGED + MEDIA["bytes"], bridge=1, http=1),
            lambda t: snapshot(OWNERS, bridge=1, http=1) if t < 0.1 else snapshot(OWNERS))
        self.assertEqual(result, "fail")
        self.assertTrue(evidence["early_refund"])


if __name__ == '__main__':
    unittest.main()

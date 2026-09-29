"""Execute the real SQL against disposable local PostgreSQL, never production."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


QUERY = Path(__file__).with_name("release_comparison.sql")


def sampled(identifier, rate):
    """Independent reference for Go hash/fnv.New32a and profiler.sampled."""
    value = 2166136261
    for byte in identifier.encode("utf-8"):
        value = ((value ^ byte) * 16777619) & 0xFFFFFFFF
    return identifier == "" or value / 2**32 < rate


@unittest.skipUnless(all(shutil.which(x) for x in ("initdb", "pg_ctl", "psql"))
                     and os.geteuid() != 0, "local PostgreSQL binaries and non-root user required")
class ReleaseComparisonTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="fc-monitor-", dir="/tmp")
        cls.data = Path(cls.temp.name) / "data"
        subprocess.run(["initdb", "-D", str(cls.data), "-A", "trust", "-U", "postgres",
                        "--no-locale", "--encoding=UTF8"], check=True, capture_output=True)
        subprocess.run(["pg_ctl", "-D", str(cls.data), "-l", str(Path(cls.temp.name) / "server.log"),
                        "-o", f"-F -h '' -k {cls.temp.name} -p 55432", "-w", "start"],
                       check=True, capture_output=True)
        cls.client = ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-h", cls.temp.name,
                      "-p", "55432", "-U", "postgres", "-d", "postgres"]

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["pg_ctl", "-D", str(cls.data), "-m", "immediate", "-w", "stop"],
                       check=True, capture_output=True)
        cls.temp.cleanup()

    def execute(self, sql, *args):
        return subprocess.run(self.client + list(args), input=sql, text=True,
                              check=True, capture_output=True).stdout

    def setUp(self):
        self.execute("""
          DROP TABLE IF EXISTS request_profiles, request_outcomes;
          CREATE TABLE request_outcomes(coord_request_id text PRIMARY KEY,
            received_at timestamptz, evidence_conflict boolean, record jsonb);
          CREATE TABLE request_profiles(coord_request_id text, winning boolean,
            final_status text, first_content_us bigint, first_content_budget_ms int,
            provider_profile_valid boolean, provider_profile_consistent boolean,
            provider_profile jsonb, provider_version text, chip_family text,
            kv_backend text, has_tools boolean, requires_vision boolean,
            requested_max_tokens int, timing_anomaly boolean);
        """)

    def outcome(self, identifier, period="before", **changes):
        record = dict(model="fixture-model", endpoint="/v1/chat/completions", stream=True,
                      http_status=200, termination="completed", evidence_conflict=False,
                      handler_finished_at="2026-09-28T21:00:01Z", attempts_complete=True,
                      attempts_truncated=False, attempts_total=1, attempts=[],
                      public_demand={"consumer_hash": "CUSTOMER_SENTINEL"})
        record.update(changes)
        when = "2026-09-28T20:30:00Z" if period == "before" else "2026-09-28T21:30:00Z"
        payload = json.dumps(record).replace("'", "''")
        self.execute(f"INSERT INTO request_outcomes VALUES ('{identifier}', '{when}', false, '{payload}');")

    def profile(self, identifier, milliseconds=100, tokens=8192, **changes):
        values = dict(coord_request_id=identifier, winning=True, final_status="success",
                      first_content_us=milliseconds * 1000, first_content_budget_ms=20000,
                      provider_profile_valid=True, provider_profile_consistent=True,
                      provider_profile=json.dumps(dict(prompt_tokens=tokens, mtp_active=True)),
                      provider_version="fixture-version", chip_family="M5 Max", kv_backend="contiguous",
                      has_tools=False, requires_vision=False, requested_max_tokens=128, timing_anomaly=False)
        values.update(changes)
        encoded = ["NULL" if v is None else "'" + str(v).replace("'", "''") + "'" for v in values.values()]
        self.execute(f"INSERT INTO request_profiles ({','.join(values)}) VALUES ({','.join(encoded)});")

    def compare(self, **changes):
        parameters = dict(before_start="2026-09-28T20:00:00Z", before_end="2026-09-28T21:00:00Z",
                          after_start="2026-09-28T21:00:00Z", after_end="2026-09-28T22:00:00Z",
                          before_sample_rate=1, after_sample_rate=1, model="fixture-model")
        parameters.update(changes)
        args = [arg for key, value in parameters.items() for arg in ("-v", f"{key}={value}")]
        # This also proves no table/function creation is needed on the replica.
        output = self.execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\n"
                              + QUERY.read_text() + "\nCOMMIT;", *args)
        self.assertNotIn("CUSTOMER_SENTINEL", output)
        self.assertNotIn("REQUEST_SENTINEL", output)
        return json.loads(output)

    def test_logical_denominators_distinguish_coordinator_timeouts_deadline_refusal_and_hedges(self):
        self.outcome("REQUEST_SENTINEL-success", attempts_total=3,
                     attempts=[dict(raw_reason="first_chunk_timeout", final_status="timeout"),
                               dict(backup_of="hidden-primary"), {}])
        self.profile("REQUEST_SENTINEL-success")
        self.profile("REQUEST_SENTINEL-success", winning=False, final_status="error")
        self.outcome("predictive", http_status=429, termination="rejected", raw_reason="deadline_unreachable")
        self.outcome("timeout", http_status=429, termination="rejected", normalized_code="ext_first_content_timeout")
        self.outcome("unfinished", http_status=0, termination="in_progress", handler_finished_at=None,
                     attempts_complete=False)
        result = self.compare()
        outcomes = result["logical_outcomes"][0]
        self.assertEqual(outcomes["logical_requests"], 4)
        self.assertEqual(outcomes["http_429_requests"], 2)
        self.assertEqual(outcomes["final_actual_first_content_timeouts"], 1)
        self.assertEqual(outcomes["deadline_unreachable_rejections"], 1)
        self.assertEqual(outcomes["requests_with_recorded_timeout_attempt"], 1)
        self.assertEqual(outcomes["retry_denominator_requests"], 3)
        self.assertEqual(outcomes["additional_attempts"], 2)
        self.assertEqual(outcomes["hedge_attempts"], 1)
        self.assertAlmostEqual(outcomes["additional_attempts_per_request"], 2 / 3)
        self.assertAlmostEqual(outcomes["additional_non_hedge_attempts_per_request"], 1 / 3)
        self.assertEqual(result["successful_first_content"][0]["successful_requests"], 1)

    def test_shared_deadline_reason_includes_provider_expiry_without_claiming_prediction(self):
        # These distinct provider decisions produce the same logical raw reason.
        # Even with diagnostic profiles present, this aggregate does not claim
        # a complete predictive/elapsed split from sampled provider evidence.
        for identifier, decision in [
            ("predicted-refusal", dict(verdict="deadline_unreachable", projection="bounded",
                                       remaining_us=1000, projected_service_us=2000)),
            ("provider-expired", dict(verdict="expired_before_submit", remaining_us=0)),
        ]:
            self.outcome(identifier, http_status=429, termination="rejected", raw_reason="deadline_unreachable")
            self.profile(identifier, winning=False, final_status="error", first_content_us=None,
                         provider_profile=json.dumps(dict(deadline_decision=decision)))
        self.outcome("coordinator-expired", http_status=429, termination="rejected",
                     normalized_code="ext_first_content_timeout")
        result = self.compare()
        outcomes = result["logical_outcomes"][0]
        self.assertEqual(outcomes["deadline_unreachable_rejections"], 2)
        self.assertEqual(outcomes["final_actual_first_content_timeouts"], 1)
        self.assertEqual(outcomes["http_429_requests"], 3)
        self.assertNotIn("predictive_deadline_rejections", outcomes)
        self.assertEqual(result["successful_first_content"], [])

    def test_reconstructs_fnv_sample_and_excludes_enriched_slow_successes(self):
        identifiers = [f"REQUEST_SENTINEL-{i}" for i in range(10000)]
        selected = next(x for x in identifiers if sampled(x, .1))
        enriched_only = next(x for x in identifiers if sampled(x, .5) and not sampled(x, .1))
        self.outcome(selected)
        self.profile(selected, milliseconds=100)
        self.outcome(enriched_only)
        self.profile(enriched_only, milliseconds=30000)
        result = self.compare(before_sample_rate=.5, after_sample_rate=.1)
        self.assertEqual(result["common_profile_sample_rate"], .1)
        self.assertEqual(result["logical_outcomes"][0]["logical_requests"], 2)
        self.assertEqual(result["profile_sample_coverage"][0]["sampled_logical_requests"], 1)
        self.assertEqual(result["successful_first_content"][0]["first_content_p95_ms"], 100)

    def test_sampler_uses_strict_32_bit_fnv_boundary(self):
        # Standard FNV-1a vector: UTF-8 "hello" -> 0x4f9f2cab.
        threshold = 0x4F9F2CAB / 2**32
        self.outcome("hello")
        self.profile("hello")
        self.assertFalse(sampled("hello", threshold))
        at_boundary = self.compare(before_sample_rate=threshold, after_sample_rate=threshold)
        self.assertEqual(at_boundary["profile_sample_coverage"], [])
        above = threshold + 1 / 2**32
        self.assertTrue(sampled("hello", above))
        self.assertEqual(self.compare(before_sample_rate=above, after_sample_rate=above)
                         ["profile_sample_coverage"][0]["sampled_logical_requests"], 1)

    def test_prompt_band_percentiles_match_only_equivalent_success_strata(self):
        for identifier, period, latency, tokens in [
            ("b1", "before", 100, 4096), ("b2", "before", 300, 16383),
            ("a1", "after", 200, 8192), ("a2", "after", 400, 32768)]:
            self.outcome(identifier, period)
            self.profile(identifier, milliseconds=latency, tokens=tokens)
        rows = self.compare()["successful_first_content"]
        before = next(r for r in rows if r["cohort"] == "before")
        self.assertTrue(before["matched_in_both_periods"])
        self.assertEqual(before["first_content_p50_ms"], 200)
        self.assertEqual(before["first_content_p95_ms"], 290)
        self.assertFalse(next(r for r in rows if r["stratum"]["actual_prompt_band"] == "32768+")["matched_in_both_periods"])

    def test_missing_profiles_ambiguous_winners_and_invalid_actual_counts_are_visible(self):
        for identifier in ("missing", "duplicate", "unknown-count", "late"):
            self.outcome(identifier)
        self.profile("duplicate")
        self.profile("duplicate")
        self.profile("unknown-count", provider_profile_valid=False)
        self.profile("late", milliseconds=21000)
        result = self.compare()
        coverage = result["profile_sample_coverage"][0]
        self.assertEqual(coverage["sampled_completed_requests"], 4)
        self.assertEqual(coverage["ambiguous_winner_requests"], 1)
        self.assertEqual(coverage["timed_completed_requests"], 2)
        self.assertEqual(coverage["coordinator_on_time_completed_requests"], 1)
        self.assertEqual(coverage["prompt_banded_completed_requests"], 1)
        self.assertEqual(result["provider_decode_token_gaps"]["status"], "not_recorded_in_production_profiles")

    def test_conflict_column_and_late_cohort_boundary_are_not_silently_accepted(self):
        self.outcome("conflict", http_status=429, termination="rejected", normalized_code="ext_first_content_timeout")
        self.execute("UPDATE request_outcomes SET evidence_conflict=true;")
        self.outcome("boundary", "after")
        self.execute("UPDATE request_outcomes SET received_at='2026-09-28T22:00:00Z' WHERE coord_request_id='boundary';")
        result = self.compare()
        self.assertEqual(len(result["logical_outcomes"]), 1)
        self.assertEqual(result["logical_outcomes"][0]["evidence_conflict_requests"], 1)
        self.assertEqual(result["logical_outcomes"][0]["final_actual_first_content_timeouts"], 0)

    def test_invalid_windows_and_disabled_sampling_fail_closed(self):
        self.outcome("request")
        for invalid in [dict(before_sample_rate=0), dict(after_sample_rate=1.1),
                        dict(after_start="2026-09-28T20:30:00Z"),
                        dict(before_start="2026-09-26T20:00:00Z")]:
            result = self.compare(**invalid)
            self.assertFalse(result["parameters_valid"])
            self.assertEqual(result["logical_outcomes"], [])


if __name__ == "__main__":
    unittest.main()

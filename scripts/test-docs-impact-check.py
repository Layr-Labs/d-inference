#!/usr/bin/env python3

import json
import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts" / "docs-impact-check.py"


class DocsImpactCheckTests(unittest.TestCase):
    def run_check(self, *paths: str, labels: list[str] | None = None) -> subprocess.CompletedProcess[str]:
        command = ["python3", str(CHECK)]
        for path in paths:
            command.extend(["--changed-file", path])
        env = os.environ.copy()
        env["DOCS_IMPACT_LABELS"] = json.dumps(labels or [])
        return subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)

    def test_unrelated_source_change_passes(self) -> None:
        result = self.run_check("coordinator/api/example_telemetry_test.go")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_telemetry_change_requires_canonical_docs(self) -> None:
        result = self.run_check("coordinator/api/warm_pool_telemetry.go")
        self.assertEqual(result.returncode, 1)
        self.assertIn("telemetry source changed", result.stderr)
        self.assertIn("warm-pool and scheduling source changed", result.stderr)

    def test_each_matching_rule_must_be_satisfied(self) -> None:
        result = self.run_check(
            "coordinator/api/warm_pool_telemetry.go",
            "docs/reference/telemetry-inventory.md",
        )
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("telemetry source changed", result.stderr)
        self.assertIn("warm-pool and scheduling source changed", result.stderr)

    def test_all_matching_docs_pass(self) -> None:
        result = self.run_check(
            "coordinator/api/warm_pool_telemetry.go",
            "docs/reference/telemetry-inventory.md",
            "docs/architecture/scheduling.md",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_maintainer_override_passes(self) -> None:
        result = self.run_check(
            "coordinator/api/warm_pool_telemetry.go",
            labels=["docs-not-needed"],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bypassed", result.stdout)

    def test_sqlc_changes_require_canonical_docs(self) -> None:
        sources = (
            "coordinator/store/postgres/sqlc.yaml",
            "coordinator/store/postgres/queries/api_keys.sql",
            "coordinator/store/postgres/storedb/models.go",
        )
        documents = ("docs/developer/sqlc.md", "docs/reference/sqlc-type-mapping.md")
        for source in sources:
            with self.subTest(source=source):
                related = ("docs/reference/soft-delete.md",) if source.endswith("queries/api_keys.sql") else ()
                for unrelated in ((), ("docs/architecture/storage.md",)):
                    missing = self.run_check(source, *related, *unrelated)
                    self.assertEqual(missing.returncode, 1, missing.stdout + missing.stderr)
                    self.assertIn("sqlc queries and type mappings source changed", missing.stderr)
                for document in documents:
                    covered = self.run_check(source, *related, document)
                    self.assertEqual(covered.returncode, 0, covered.stdout + covered.stderr)
                overridden = self.run_check(source, labels=["docs-not-needed"])
                self.assertEqual(overridden.returncode, 0, overridden.stdout + overridden.stderr)

        ignored = self.run_check(
            "coordinator/tests/store/postgres/storedb/models_test.go",
            "coordinator/store/postgres/storedb/models_test.go",
        )
        self.assertEqual(ignored.returncode, 0, ignored.stdout + ignored.stderr)

    def test_soft_delete_reads_and_writes_require_canonical_docs(self) -> None:
        sources = (
            "coordinator/store/memory/small_models_interest.go",
            "coordinator/store/memory/legacy_mdm_cohort.go",
            "coordinator/store/postgres/small_models_interest.go",
            "coordinator/store/postgres/legacy_mdm_cohort.go",
            "coordinator/store/memory/users.go",
            "coordinator/store/postgres/users.go",
            "coordinator/store/memory/device_auth.go",
            "coordinator/store/postgres/device_auth.go",
            "coordinator/store/memory/providers.go",
            "coordinator/store/postgres/provider_read.go",
            "coordinator/store/postgres/provider_record_write.go",
            "coordinator/store/memory/apikey.go",
            "coordinator/store/postgres/queries/api_keys.sql",
            "coordinator/store/postgres/storedb/api_keys.sql.go",
        )
        for source in sources:
            with self.subTest(source=source):
                related = ("docs/reference/sqlc-type-mapping.md", "docs/architecture/storage.md",
                           "docs/architecture/security/enrollment.md")
                missing = self.run_check(source, *related)
                self.assertEqual(missing.returncode, 1, missing.stdout + missing.stderr)
                self.assertIn("soft-delete reads and writes source changed", missing.stderr)
                covered = self.run_check(source, *related, "docs/reference/soft-delete.md")
                self.assertEqual(covered.returncode, 0, covered.stdout + covered.stderr)
        overridden = self.run_check(*sources, labels=["docs-not-needed"])
        self.assertEqual(overridden.returncode, 0, overridden.stdout + overridden.stderr)
        ignored = self.run_check(
            "coordinator/tests/store/postgres/soft_delete_reads_test.go",
            "coordinator/store/postgres/users_test.go",
            "coordinator/store/postgres/usage.go",
            "coordinator/store/memory/ledger.go",
        )
        self.assertEqual(ignored.returncode, 0, ignored.stdout + ignored.stderr)

    def test_reorganized_owners_keep_canonical_documentation_gates(self) -> None:
        cases = (
            ("coordinator/api/routes.go", "docs/reference/api-contracts.md"),
            ("coordinator/api/observation/events.go", "docs/architecture/telemetry.md"),
            ("coordinator/registry/admission/budget.go", "docs/architecture/routing.md"),
            ("coordinator/registry/selection/affinity.go", "docs/architecture/routing.md"),
            ("coordinator/app/startup_config.go", "docs/reference/configuration.md"),
            ("coordinator/store/postgres/migrations.go", "docs/architecture/storage.md"),
            ("coordinator/store/postgres/migration_indexes.go", "docs/architecture/storage.md"),
            ("coordinator/store/postgres/schema/migrations/00010_example.sql", "docs/architecture/storage.md"),
            ("coordinator/store/postgres/schema/schema.sql", "docs/architecture/storage.md"),
            ("coordinator/store/postgres/example_schema.go", "docs/architecture/storage.md"),
            ("coordinator/store/postgres/startup.go", "docs/architecture/storage.md"),
            ("coordinator/store/postgres/retired_backfills.go", "docs/architecture/storage.md"),
            ("coordinator/store/postgres/provider_earnings_index.go", "docs/architecture/storage.md"),
            ("coordinator/store/postgres/earnings_window_index.go", "docs/architecture/storage.md"),
            ("coordinator/api/releases/policy.go", "docs/operations/provider-release.md"),
            ("coordinator/store/memory/memory.go", "docs/developer/navigation.md"),
            ("coordinator/app/app.go", "docs/developer/navigation.md"),
        )
        for source, document in cases:
            with self.subTest(source=source):
                missing = self.run_check(source)
                self.assertEqual(missing.returncode, 1, missing.stdout + missing.stderr)
                covered = self.run_check(source, document)
                self.assertEqual(covered.returncode, 0, covered.stdout + covered.stderr)

    def test_reorganized_private_tests_remain_excluded(self) -> None:
        result = self.run_check("coordinator/api/observation/owner_test.go",
                                "coordinator/store/postgres/migrations_test.go")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_relocated_endpoints_require_api_contracts(self) -> None:
        sources = (
            "coordinator/api/billing/pricing.go",
            "coordinator/api/billing/account.go",
            "coordinator/api/billing/checkout.go",
            "coordinator/api/billing/payouts/connect_status.go",
            "coordinator/api/billing/payouts/global_payouts_withdraw.go",
            "coordinator/api/catalog/models_endpoints.go",
            "coordinator/api/catalog/openrouter_endpoint.go",
            "coordinator/api/catalog/capacity.go",
            "coordinator/api/accounts/summary.go",
            "coordinator/api/access/otp.go",
            "coordinator/api/access/keys/request.go",
            "coordinator/api/access/device/handlers.go",
            "coordinator/api/inference/consumer.go",
            "coordinator/api/inference/request/body.go",
            "coordinator/api/inference/response/responses_stream.go",
            "coordinator/api/inference/exact_cache_status.go",
            "coordinator/api/inference/sender_encryption.go",
            "coordinator/api/inference/model_token_promotions.go",
            "coordinator/api/operations/health.go",
            "coordinator/api/operations/drain.go",
            "coordinator/api/reporting/network_series.go",
            "coordinator/api/reporting/model_demand.go",
            "coordinator/api/provider/provider.go",
            "coordinator/api/provider/trust/enroll.go",
            "coordinator/api/provider/trust/status.go",
            "coordinator/api/provider/trust/settings.go",
            "coordinator/api/provider/trust/app_attest_revocation.go",
            "coordinator/api/observation/admin_telemetry.go",
            "coordinator/api/observation/profiler_admin.go",
            "coordinator/api/observation/request_outcome_admin.go",
            "coordinator/api/releases/download.go",
            "coordinator/api/releases/app_attest_builds.go",
            "coordinator/api/releases/read_handlers.go",
        )
        other_docs = ("docs/architecture/telemetry.md", "docs/operations/provider-release.md",
                       "docs/architecture/security/attestation.md",
                       "docs/architecture/security/encryption.md", "docs/architecture/billing.md")
        for source in sources:
            with self.subTest(source=source):
                # Other domains' docs must not satisfy the API contract gate.
                self.assertTrue((ROOT / source).is_file(), source)
                missing = self.run_check(source, *other_docs)
                self.assertEqual(missing.returncode, 1, missing.stdout + missing.stderr)
                self.assertIn("HTTP and API contracts source changed", missing.stderr)
                covered = self.run_check(source, *other_docs, "docs/reference/api-contracts.md")
                self.assertEqual(covered.returncode, 0, covered.stdout + covered.stderr)
                test_source = source.removesuffix(".go") + "_test.go"
                ignored = self.run_check(test_source)
                self.assertEqual(ignored.returncode, 0, ignored.stdout + ignored.stderr)

    def test_internal_helpers_do_not_require_api_contracts(self) -> None:
        result = self.run_check(
            "coordinator/api/readcache/cache.go",
            "coordinator/api/inference/chunk_key_cache.go",
            "coordinator/api/provider/trust/challenge_policy.go",
            "docs/architecture/security/attestation.md",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_extracted_components_retain_behavior_and_ownership_gates(self) -> None:
        cases = (
            ("coordinator/internal/api/middleware/middleware.go", "HTTP and API contracts"),
            ("coordinator/internal/api/accounts/fleetview/me_authorization.go", "HTTP and API contracts"),
            ("coordinator/internal/inference/relay/consumer_stream.go", "HTTP and API contracts"),
            ("coordinator/internal/inference/media/media_resolve.go", "HTTP and API contracts"),
            ("coordinator/internal/promptcontract/endpoint/endpoint_lower_messages.go", "HTTP and API contracts"),
            ("coordinator/internal/observation/profile/profiler_sink.go", "telemetry"),
            ("coordinator/internal/observation/routes/telemetry_sink.go", "telemetry"),
            ("coordinator/internal/wire/type_scan.go", "protocol messages"),
            ("coordinator/internal/registry/kvbudget/pool.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/residency/fit.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/queuedrain/coalescer.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/identitygate/directory.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/identitygate/gate_lock.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/providerdrain/authority.go", "warm-pool and scheduling"),
            ("coordinator/registry/model_load_preparation.go", "warm-pool and scheduling"),
            ("coordinator/registry/model_load_planner.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/deadline/catalog.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/deadline/catalog_data.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/deadline/profile.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/deadline/posture.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/forecast/forecast.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/ttftforecast/forecast.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/ttftcalibration/calibrator.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/ttftcalibration/pending.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/shortlist/order.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/eviction/grace.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/modelindex/counts.go", "warm-pool and scheduling"),
            ("coordinator/registry/provider_directory.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/connectiontime/origin.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/capacityquote/tracker.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/performance/calibration.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/warmplan/planner.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/swapplan/controller.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/pendingload/ledger.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/reservation/commit_mode.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/serviceretirement/ledger.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/queuewait/clock.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/providerwrite/writer.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/writertransport/transport.go", "warm-pool and scheduling"),
            ("coordinator/internal/registry/writedeadline/watchdog.go", "warm-pool and scheduling"),
            ("coordinator/registry/connection_lifecycle.go", "warm-pool and scheduling"),
            ("coordinator/registry/connection_disconnect.go", "warm-pool and scheduling"),
            ("coordinator/registry/connection_origin.go", "warm-pool and scheduling"),
            ("coordinator/registry/connection_trust.go", "warm-pool and scheduling"),
            ("coordinator/registry/provider_lifecycle.go", "warm-pool and scheduling"),
            ("coordinator/registry/service_reservations.go", "warm-pool and scheduling"),
            ("coordinator/registry/provider_persistence.go", "storage schema"),
            ("coordinator/registry/persistence.go", "storage schema"),
            ("coordinator/registry/connection_lifecycle.go", "trust and attestation"),
            ("coordinator/registry/connection_trust.go", "trust and attestation"),
            ("coordinator/registry/persistence.go", "trust and attestation"),
            ("coordinator/api/inference/first_wait_failure.go", "warm-pool and scheduling"),
            ("coordinator/api/inference/first_wait_failure.go", "billing and accounting"),
            ("coordinator/api/inference/first_wait_failure.go", "telemetry"),
            ("coordinator/internal/startup/startup_config.go", "configuration"),
            ("coordinator/internal/registry/ttftcalibration/calibrator.go", "configuration"),
            ("coordinator/internal/mediafetch/policy/config.go", "configuration"),
            ("coordinator/internal/provider/journal/trust_reuse_journal.go", "trust and attestation"),
            ("coordinator/internal/provider/identity/code_attest_throttle.go", "trust and attestation"),
            ("coordinator/internal/appattest/transcript/binding.go", "trust and attestation"),
            ("coordinator/internal/appattest/authorization/controller.go", "trust and attestation"),
            ("coordinator/internal/appattest/recovery/driver.go", "trust and attestation"),
            ("coordinator/internal/inference/cacheusage/cache_usage.go", "billing and accounting"),
            ("coordinator/internal/inference/promotions/model_token_admission.go", "billing and accounting"),
            ("coordinator/internal/inference/promotions/model_token_pricing.go", "billing and accounting"),
            ("coordinator/internal/inference/reservations/admission.go", "billing and accounting"),
            ("coordinator/internal/inference/chunkkeys/chunk_key_cache.go", "request privacy"),
            ("coordinator/internal/registry/cacheactivation/gate.go", "cache routing"),
            ("coordinator/internal/registry/cachequeue/queue.go", "cache routing"),
            ("coordinator/internal/registry/cachetracker/tracker.go", "cache routing"),
            ("coordinator/internal/registry/cacheindex/order.go", "cache routing"),
            ("coordinator/internal/registry/cacheplan/plan.go", "cache routing"),
            ("coordinator/internal/registry/cachepeer/revision.go", "cache routing"),
            ("coordinator/internal/registry/cachehistory/index.go", "cache routing"),
            ("coordinator/internal/registry/cachedemand/tracker.go", "cache routing"),
            ("coordinator/internal/registry/cacheattempt/owner.go", "cache routing"),
            ("coordinator/internal/registry/cachepolicy/limits.go", "cache routing"),
            ("coordinator/registry/cache_restoration.go", "cache routing"),
            ("coordinator/registry/cache_maintenance.go", "cache routing"),
            ("coordinator/registry/cache_snapshot_result.go", "cache routing"),
            ("coordinator/registry/cache_snapshot.go", "cache routing"),
            ("coordinator/internal/registry/autopilotstate/state.go", "model autopilot"),
            ("coordinator/internal/registry/autopilotcontrol/controller.go", "model autopilot"),
            ("coordinator/internal/registry/autopilotledger/events.go", "model autopilot"),
            ("coordinator/internal/registry/demandwindow/window.go", "model autopilot"),
        )
        canonical = {
            "HTTP and API contracts": "docs/reference/api-contracts.md",
            "telemetry": "docs/architecture/telemetry.md",
            "protocol messages": "docs/reference/protocol-messages.md",
            "warm-pool and scheduling": "docs/architecture/routing.md",
            "configuration": "docs/reference/configuration.md",
            "storage schema": "docs/architecture/storage.md",
            "trust and attestation": "docs/architecture/security/attestation.md",
            "billing and accounting": "docs/architecture/billing.md",
            "request privacy": "docs/architecture/security/encryption.md",
            "cache routing": "docs/architecture/cache-aware-routing.md",
            "model autopilot": "docs/architecture/model-autopilot.md",
        }
        ownership = "docs/architecture/components/coordinator.md"
        for source, rule in cases:
            with self.subTest(source=source, rule=rule):
                self.assertTrue((ROOT / source).is_file(), source)
                missing = self.run_check(source, ownership, "docs/developer/navigation.md")
                self.assertEqual(missing.returncode, 1, missing.stdout + missing.stderr)
                self.assertIn(f"{rule} source changed", missing.stderr)
                behavior_only = self.run_check(source, *canonical.values())
                self.assertEqual(behavior_only.returncode, 1,
                                 behavior_only.stdout + behavior_only.stderr)
                self.assertIn("coordinator ownership source changed", behavior_only.stderr)
                unrelated = [doc for name, doc in canonical.items() if name != rule]
                still_missing = self.run_check(source, ownership, *unrelated)
                self.assertEqual(still_missing.returncode, 1,
                                 still_missing.stdout + still_missing.stderr)
                self.assertIn(f"{rule} source changed", still_missing.stderr)
                covered = self.run_check(source, ownership, *canonical.values())
                self.assertEqual(covered.returncode, 0, covered.stdout + covered.stderr)

    def test_relocated_domain_owners_require_behavior_documentation(self) -> None:
        cases = {
            "trust and attestation": (
                "coordinator/store/memory/legacy_mdm_cohort.go",
                "coordinator/store/postgres/legacy_mdm_cohort.go",
            ),
            "HTTP and API contracts": (
                "coordinator/api/releases/artifact_metadata.go",
            ),
            "billing and accounting": (
                "coordinator/api/billing/pricing.go",
                "coordinator/api/billing/payouts/global_payouts_withdraw.go",
                "coordinator/api/inference/provider_inference.go",
                "coordinator/api/inference/completion_accounting.go",
                "coordinator/api/inference/consumer.go",
                "coordinator/api/inference/dispatch.go",
                "coordinator/api/inference/reservations.go",
                "coordinator/api/inference/settlement.go",
                "coordinator/api/inference/inference_balance.go",
            ),
            "model autopilot": (
                "coordinator/api/inference/autopilot_demand.go",
                "coordinator/internal/inference/demand/request.go",
            ),
            "telemetry": (
                "coordinator/internal/inference/metrics/attempt_outcomes.go",
                "coordinator/internal/inference/metrics/backend.go",
                "coordinator/internal/provider/verification/metrics.go",
            ),
            "protocol messages": (
                "coordinator/tests/protocol/testdata/process_memory_wire.json",
                "coordinator/tests/protocol/testdata/performance_capacity_wire_fixture.json",
            ),
            "warm-pool and scheduling": (
                "coordinator/registry/provider_eligibility.go",
                "coordinator/registry/provider_eligibility_admit.go",
                "coordinator/registry/provider_eligibility_vision.go",
                "coordinator/registry/routing_eligibility.go",
                "coordinator/registry/gate_evaluation.go",
                "coordinator/registry/gate_preparation.go",
                "coordinator/registry/queue_assignment.go",
                "coordinator/registry/queue_drain.go",
                "coordinator/registry/reservation_candidates.go",
                "coordinator/registry/candidate_selection.go",
                "coordinator/registry/candidate_binding.go",
                "coordinator/registry/quote_plan_evidence.go",
                "coordinator/registry/dispatch_plan.go",
                "coordinator/registry/dispatch_plan_quotes.go",
                "coordinator/registry/capacity_quotes.go",
            ),
        }
        config = json.loads((ROOT / "scripts/docs-impact-rules.json").read_text())
        all_docs = {doc for rule in config["rules"] for doc in rule["docs_any_of"]}
        for domain, sources in cases.items():
            rule = next(rule for rule in config["rules"] if rule["name"] == domain)
            unrelated_docs = sorted(all_docs - set(rule["docs_any_of"]))
            for source in sources:
                with self.subTest(source=source, domain=domain):
                    self.assertTrue((ROOT / source).is_file(), source)
                    missing = self.run_check(source, *unrelated_docs)
                    self.assertEqual(missing.returncode, 1, missing.stdout + missing.stderr)
                    self.assertIn(f"{domain} source changed", missing.stderr)
                    for document in rule["docs_any_of"]:
                        covered = self.run_check(source, *unrelated_docs, document)
                        self.assertEqual(covered.returncode, 0, covered.stdout + covered.stderr)
                    if source.endswith(".go"):
                        ignored = self.run_check(source.removesuffix(".go") + "_test.go")
                        self.assertEqual(ignored.returncode, 0, ignored.stdout + ignored.stderr)

    def test_mirrored_tests_do_not_become_production_impact_sources(self) -> None:
        result = self.run_check(
            "coordinator/tests/api/inference/media/media_resolve_test.go",
            "coordinator/tests/api/provider/trust/verification/reconnect_test.go",
            "coordinator/tests/protocol/type_scan_test.go",
            "coordinator/tests/internal/testdb/main_test.go",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_test_runner_and_shared_fixtures_require_test_documentation(self) -> None:
        for source in ("scripts/coordinator_tests/runner.py", "scripts/verify-prompt-parity.sh",
                       "scripts/docs-impact-rules.json", "coordinator/tests/internal/testkit/server.go"):
            with self.subTest(source=source):
                self.assertTrue((ROOT / source).is_file(), source)
                missing = self.run_check(source, "docs/architecture/components/coordinator.md")
                self.assertEqual(missing.returncode, 1, missing.stdout + missing.stderr)
                self.assertIn("coordinator test tooling source changed", missing.stderr)
                covered = self.run_check(source, "docs/developer/test.md")
                self.assertEqual(covered.returncode, 0, covered.stdout + covered.stderr)


if __name__ == "__main__":
    unittest.main()

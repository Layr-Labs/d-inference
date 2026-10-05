"""The design artifact never enables retirement through an archive command."""

import json
from pathlib import Path

from telemetry_archive.model import TABLES


def test_retirement_policy_targets_all_captured_detail_but_remains_disabled():
    path = Path(__file__).parents[1] / "retention-policy.proposed.json"
    policy = json.loads(path.read_text())
    assert policy["status"] == "proposed_not_runtime_configuration"
    assert policy["deletion_enabled"] is False
    retirement = policy["retirement"]
    assert retirement["target_hot_detail_days"] == 14
    assert set(retirement["table_allowlist"]) == set(TABLES)
    assert retirement["archive_expiration"] is None
    assert {
        "durable_incremental_capture_with_commit_boundary",
        "financial_idempotency_survives_removal_of_detail",
        "transactional_monthly_and_lifetime_key_spend_counters_migrated",
        "private_history_and_direct_admin_sql_readers_migrated",
        "specific_production_enablement_approval",
    } <= set(retirement["required_gates"])

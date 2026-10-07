import hashlib
import json

import pytest

from telemetry_archive.accounting import query_aggregates
from telemetry_archive.artifact import json_bytes, read_artifact
from telemetry_archive.backfill import Runner
from telemetry_archive.backfill_plan import identity, make_plan
from telemetry_archive.codec import encode, verify_parquet
from telemetry_archive.journal import Journal
from telemetry_archive.model import ArchiveError, stamp, utc
from telemetry_archive.publish import reader_sql
from telemetry_archive.queries import verify_query
from telemetry_archive.tables import ACCOUNTING_FIELDS
from telemetry_archive.windows import IDWindow

from .fake_storage import Bucket
from .test_queries import Client as QueryClient

BONUS = "autopilot_bonus_micro_usd"
BASE_FIELDS = ("amount_micro_usd", "floor_micro_usd", "earned_micro_usd")


def test_receipt_fields_cannot_expand_sql_aggregate_allowlist():
    unexpected = "unexpected_field') AS BIGNUMERIC)), 0) AS STRING); SELECT 1; --"
    assert query_aggregates("request_profiles", {unexpected: "0"}) == []
    assert query_aggregates("provider_floor_draws", {unexpected: "0"}) == []


def floor_artifact(tmp_path, monkeypatch, *, legacy=False, bonus=100):
    window = IDWindow("provider_floor_draws", 1, 2)
    at = utc("2026-10-07T00:00:00Z")
    row = {
        "id": 1,
        "created_at": stamp(at),
        "amount_micro_usd": 1009,
        "floor_micro_usd": 2000,
        "earned_micro_usd": 0,
    }
    if bonus is not None:
        row[BONUS] = bonus
    # Reproduce the old writer's frozen three-field receipt without changing
    # the current reader under test. Complete row JSON is preserved in both.
    with monkeypatch.context() as old_writer:
        if legacy:
            old_writer.setitem(ACCOUNTING_FIELDS, window.table, BASE_FIELDS)
        stats = encode([[(1, at, json.dumps(row))]], tmp_path / "data.parquet", window, 1)
    receipt = {
        "format_version": 2,
        "copy_only": True,
        "retention_eligible": False,
        **identity(window),
        "source": {"accounting_totals": stats["accounting_totals"]},
        "stats": stats,
    }
    receipt["artifact_id"] = hashlib.sha256(json_bytes(receipt)).hexdigest()
    (tmp_path / "receipt.json").write_bytes(json_bytes(receipt))
    return receipt, window


def test_bonus_is_reconciled_separately_and_exposed_in_reader(tmp_path, monkeypatch):
    receipt, window = floor_artifact(tmp_path, monkeypatch)
    assert receipt["stats"]["accounting_totals"] == {
        "amount_micro_usd": "1009",
        "floor_micro_usd": "2000",
        "earned_micro_usd": "0",
        BONUS: "100",
    }
    read_artifact(tmp_path)
    bad = {
        **receipt["stats"],
        "accounting_totals": {
            **receipt["stats"]["accounting_totals"],
            BONUS: "99",
        },
    }
    with pytest.raises(ArchiveError, match="source snapshot receipt"):
        verify_parquet(tmp_path / "data.parquet", window, bad)
    sql = reader_sql("archive-project", "accounting_history", window.table, "a" * 16)
    assert f"COALESCE(CAST(JSON_VALUE(r.row_json, '$.{BONUS}') AS INT64), 0) AS {BONUS}" in sql
    client = QueryClient(receipt)
    client.result.update(
        {f"accounting_{k}": v for k, v in receipt["stats"]["accounting_totals"].items()}
    )
    published = {
        "snapshot": receipt,
        "location": "us-east4",
        "bucket": "archive-test",
        "data": {"name": "data.parquet"},
    }
    assert verify_query(client, published)["verified"]
    client.result[f"accounting_{BONUS}"] = "99"
    with pytest.raises(ArchiveError, match="BigQuery results differ"):
        verify_query(client, published)


@pytest.mark.parametrize("bonus", [None, 100])
def test_legacy_receipts_keep_their_original_reconciliation(tmp_path, monkeypatch, bonus):
    receipt, _ = floor_artifact(tmp_path, monkeypatch, legacy=True, bonus=bonus)
    assert BONUS not in receipt["stats"]["accounting_totals"]
    actual, _ = read_artifact(tmp_path)
    assert actual == receipt  # No receipt or artifact-ID rewrite on upgrade.
    client = QueryClient(receipt)
    client.result.update(
        {f"accounting_{k}": v for k, v in receipt["stats"]["accounting_totals"].items()}
    )
    original = client.query

    def query(sql, **kwargs):
        assert f"AS accounting_{BONUS}" not in sql
        return original(sql, **kwargs)

    client.query = query
    assert verify_query(
        client,
        {
            "snapshot": receipt,
            "location": "us-east4",
            "bucket": "archive-test",
            "data": {"name": "data.parquet"},
        },
    )["verified"]


@pytest.mark.parametrize("legacy_first", [True, False])
def test_mixed_receipt_summary_certifies_only_shared_fields(legacy_first):
    plan = make_plan([{"table": "provider_floor_draws", "id_start": 1, "id_end": 100002}])
    journal = Journal(Bucket(), plan["plan_id"])

    def process(window):
        totals = {"amount_micro_usd": "1009", "floor_micro_usd": "2000", "earned_micro_usd": "0"}
        if (window.start == 1) != legacy_first:
            totals[BONUS] = "100"
        return {
            "verified": True,
            "rows": 1,
            "parquet_bytes": 100,
            "accounting_totals": totals,
            "objects": {"data": {"name": str(window.start), "generation": 1}},
        }

    summary = Runner(plan, journal, process, saved_check=lambda r: None).run()
    expected = {"amount_micro_usd": "2018", "floor_micro_usd": "4000", "earned_micro_usd": "0"}
    assert summary["complete"] and summary["windows"] == 2
    assert summary["tables"]["provider_floor_draws"]["accounting_totals"] == expected
    assert journal.get("catalogs/provider_floor_draws")["accounting_totals"] == expected
    assert (
        Runner(
            plan, journal, lambda w: pytest.fail("already copied"), saved_check=lambda r: None
        ).run()
        == summary
    )

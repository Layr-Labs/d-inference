import hashlib
import json
from dataclasses import replace
from datetime import timedelta

import pytest

from telemetry_archive.artifact import json_bytes, read_artifact, validate_receipt
from telemetry_archive.backfill import BackfillIncomplete, Runner
from telemetry_archive.backfill_plan import children, identity, make_plan, windows
from telemetry_archive.codec import encode, verify_parquet
from telemetry_archive.journal import Journal
from telemetry_archive.model import ArchiveError, stamp, utc
from telemetry_archive.objects import load_remote, upload
from telemetry_archive.publish import reader_sql
from telemetry_archive.queries import verify_query
from telemetry_archive.tables import ACCOUNTING_FIELDS
from telemetry_archive.windows import IDWindow

from .fake_storage import Bucket, Client
from .test_queries import Client as QueryClient


@pytest.fixture(params=ACCOUNTING_FIELDS)
def accounting_artifact(request, tmp_path):
    table = request.param
    window = IDWindow(table, 1, 10)
    when = utc("2026-09-01T00:00:00Z")
    # Backdated events, holes, negative amounts and >2^53 must survive unchanged.
    rows = []
    for source_id, offset, amount in ((1, 20, 2**63 - 1), (3, -20, -(2**63)), (9, 1, 2**63 - 1)):
        at = when + timedelta(days=offset)
        record = {
            "id": source_id,
            "created_at": stamp(at),
            "account_id": "test-account",
            "future_detail": {"unicode": "☃", "values": [None, source_id]},
            **dict.fromkeys(ACCOUNTING_FIELDS[table], amount),
        }
        rows.append((source_id, at, json.dumps(record, ensure_ascii=False)))
    directory = tmp_path / table
    directory.mkdir()
    stats = encode([rows], directory / "data.parquet", window, len(rows))
    receipt = {
        "format_version": 2,
        "copy_only": True,
        "retention_eligible": False,
        **identity(window),
        "source": {
            "in_recovery": True,
            "read_only": "on",
            "observed_at": stamp(when),
            "columns": [],
            "accounting_totals": stats["accounting_totals"],
        },
        "stats": stats,
    }
    receipt["artifact_id"] = hashlib.sha256(json_bytes(receipt)).hexdigest()
    (directory / "receipt.json").write_bytes(json_bytes(receipt))
    return directory, receipt, window


def test_accounting_exact_totals_and_backdated_bounds(accounting_artifact):
    directory, receipt, window = accounting_artifact
    read_artifact(directory)
    stats = receipt["stats"]
    assert set(stats["accounting_totals"].values()) == {str(2**63 - 2)}
    assert stats["first_time"] == "2026-08-12T00:00:00.000000Z"
    assert stats["last_time"] == "2026-09-21T00:00:00.000000Z"
    bad = {**stats, "accounting_totals": dict.fromkeys(ACCOUNTING_FIELDS[window.table], "0")}
    with pytest.raises(ArchiveError):
        verify_parquet(directory / "data.parquet", window, bad)


def test_accounting_cannot_enter_telemetry_bucket(accounting_artifact):
    directory, receipt, window = accounting_artifact
    client = Client()
    with pytest.raises(ArchiveError, match="dedicated bucket"):
        upload(directory, client, "archive-test", "us-east4")
    assert not client.bucket.objects
    client.bucket.labels = {"archive-scope": "accounting"}
    published = upload(directory, client, "archive-test", "us-east4")
    remote, _ = load_remote(client, published["receipt_uri"], "us-east4")
    assert remote["snapshot"] == receipt
    assert f"{window.table}/id_range=1_10/" in published["data"]["name"]


def test_accounting_totals_required_in_receipts(accounting_artifact):
    _, receipt, _ = accounting_artifact
    del receipt["stats"]["accounting_totals"]
    receipt["artifact_id"] = hashlib.sha256(
        json_bytes({k: v for k, v in receipt.items() if k != "artifact_id"})
    ).hexdigest()
    with pytest.raises(ArchiveError, match="reconciliation"):
        validate_receipt(receipt)


def test_bigquery_verifies_money_without_float_conversion(accounting_artifact):
    _, receipt, _ = accounting_artifact
    client = QueryClient(receipt)
    sums = {"accounting_" + k: v for k, v in receipt["stats"]["accounting_totals"].items()}
    client.result.update(sums)
    published = {
        "snapshot": receipt,
        "location": "us-east4",
        "bucket": "archive-test",
        "data": {"name": "data.parquet"},
    }
    original = client.query

    def query(sql, **kwargs):
        assert "AS BIGNUMERIC" in sql and "@id_start" in sql and "@start" not in sql
        assert {p.name for p in kwargs["job_config"].query_parameters} == {"id_start", "id_end"}
        return original(sql, **kwargs)

    client.query = query
    assert verify_query(client, published)["verified"]
    client.result[next(iter(sums))] = "0"
    with pytest.raises(ArchiveError, match="BigQuery results differ"):
        verify_query(client, published)


def test_id_plan_split_resume_and_financial_summary():
    plan = make_plan([{"table": "ledger_entries", "id_start": 1, "id_end": 200002}])
    chunks = list(windows(plan))
    assert [(w.start, w.end) for w in chunks] == [(1, 100001), (100001, 200001), (200001, 200002)]
    left, right = children(chunks[-2])
    assert left.end == right.start and left.start == chunks[-2].start
    journal = Journal(Bucket(), plan["plan_id"])

    def process(window):
        return {
            "verified": True,
            "rows": 1,
            "parquet_bytes": 100,
            "accounting_totals": {"amount_micro_usd": "-9007199254740993", "balance_after": "42"},
            "objects": {"data": {"name": str(window.start), "generation": 1}},
        }

    with pytest.raises(BackfillIncomplete):
        Runner(plan, journal, process, saved_check=lambda r: None, max_new_windows=1).run()
    summary = Runner(plan, journal, process, saved_check=lambda r: None).run()
    assert summary["tables"]["ledger_entries"]["accounting_totals"] == {
        "amount_micro_usd": "-27021597764222979",
        "balance_after": "126",
    }
    assert (
        Runner(
            plan, journal, lambda w: pytest.fail("already copied"), saved_check=lambda r: None
        ).run()
        == summary
    )


@pytest.mark.parametrize("value", [None, True, 1.0, "1", 2**63])
def test_money_must_be_an_exact_signed_integer(value, tmp_path):
    w = IDWindow("ledger_entries", 1, 3)
    at = utc("2026-09-01T00:00:00Z")
    raw = json.dumps(
        {"id": 1, "created_at": stamp(at), "amount_micro_usd": value, "balance_after": 0}
    )
    with pytest.raises(ArchiveError, match="exact signed integer"):
        encode([[(1, at, raw)]], tmp_path / "invalid.parquet", w, 1)


def test_id_window_limits_and_scope(window):
    for start, end in ((True, 2), (1, 1), (2, 1), (1, 2**63), (1, 1000002)):
        with pytest.raises(ValueError):
            IDWindow("usage", start, end)
    with pytest.raises(ValueError):
        IDWindow("request_profiles", 1, 2)
    with pytest.raises(ValueError):
        replace(IDWindow("usage", 1, 2), max_rows=0)
    with pytest.raises(ArchiveError):
        make_plan([identity(window), {"table": "usage", "id_start": 1, "id_end": 10}])
    for table in ACCOUNTING_FIELDS:
        sql = reader_sql("archive-project", "accounting_history", table, "a" * 16)
        assert "AS INT64" in sql and "PARTITION BY r.source_id" in sql
        with pytest.raises(ArchiveError):
            reader_sql("archive-project", "telemetry_history", table, "a" * 16)

import re
from decimal import Decimal
from types import SimpleNamespace

import pytest

from telemetry_archive import analytics_preview
from telemetry_archive.analytics_sql import parameters, query_sql, source_tables
from telemetry_archive.cli import parser
from telemetry_archive.model import ArchiveError, utc

CATALOG = "a" * 16


def arguments(*extra):
    return parser().parse_args(
        [
            "analytics-preview",
            "--project",
            "archive-test",
            "--dataset",
            "accounting_history",
            "--catalog",
            CATALOG,
            "--query",
            "leaderboard",
            "--as-of",
            "2026-09-26T12:00:00Z",
            *extra,
        ]
    )


def test_compile_requires_no_credentials_and_never_certifies_retention(monkeypatch):
    monkeypatch.setattr(
        analytics_preview.cloud, "bigquery_client", lambda *_: pytest.fail("cloud call")
    )
    report = analytics_preview.preview(arguments())
    assert report["serving_eligible"] is False and report["retention_eligible"] is False
    assert report["source_completeness"] == "not_certified"
    assert report["parameters"]["since"] == "2026-09-25T12:00:00.000000Z"
    assert "PARTITION BY r.source_id" in report["sql"]  # Overlapping snapshots deduplicated.
    assert f"provider_earnings_files_{CATALOG}" in report["sql"]  # Catalog pinned, no view race.


@pytest.mark.parametrize(
    "args",
    [
        ("--dataset", "telemetry_history"),
        ("--catalog", "a;DROP TABLE x"),
        ("--maximum-bytes-billed", "0"),
        ("--maximum-bytes-billed", str(11 * 1024**3)),
        ("--limit", "201"),
    ],
)
def test_invalid_scope_and_budgets_fail_before_cloud(args, monkeypatch):
    monkeypatch.setattr(
        analytics_preview.cloud, "bigquery_client", lambda *_: pytest.fail("cloud call")
    )
    with pytest.raises(ArchiveError):
        analytics_preview.preview(arguments(*args))


def test_rolling_window_has_exclusive_upper_bound():
    at = utc("2026-09-26T12:00:00Z")
    assert parameters("7d", at, 50)["since"] == utc("2026-09-19T12:00:00Z")
    assert parameters("all", at, 50)["since"] is None
    for query in ("leaderboard", "network-totals", "usage-timeseries"):
        sql = query_sql("archive-test", "accounting_history", CATALOG, query)
        assert "source_time < @as_of" in sql and "source_time >= @since" in sql


class Job:
    job_id = "test-job"
    total_bytes_processed = 100

    def __init__(self, rows):
        self.rows = rows

    def result(self, timeout):
        return self.rows


class Client:
    def __init__(self, tables=("provider_earnings", "ledger_entries"), description=None):
        self.tables = tables
        self.description = description or "Verified archive catalog sha256=" + "a" * 64
        self.calls = []

    def get_dataset(self, _):
        return SimpleNamespace(location="us-east4")

    def get_table(self, _):
        return SimpleNamespace(description=self.description)

    def query(self, sql, job_config):
        self.calls.append((sql, job_config.to_api_repr()))
        if sql.startswith("SELECT DISTINCT table_name"):
            return Job([{"table_name": t} for t in self.tables])
        return Job([{"earnings_micro_usd": Decimal(2**63 + 1), "jobs": 2}])


def test_execute_keeps_large_sums_exact_and_caps_both_queries(monkeypatch):
    client = Client()
    monkeypatch.setattr(analytics_preview.cloud, "bigquery_client", lambda *_: client)
    report = analytics_preview.preview(arguments("--execute", "--maximum-bytes-billed", "10000000"))
    assert report["rows"][0]["earnings_micro_usd"] == str(2**63 + 1)
    assert report["serving_eligible"] is False
    assert len(client.calls) == 2
    assert all(c["query"]["maximumBytesBilled"] == "10000000" for _, c in client.calls)
    assert {p["name"] for p in client.calls[-1][1]["query"]["queryParameters"]} == {
        "since",
        "as_of",
        "limit",
    }


@pytest.mark.parametrize(
    "client", [Client(tables=("provider_earnings",)), Client(description="other")]
)
def test_missing_or_mismatched_catalog_cannot_run_analytics(client, monkeypatch):
    monkeypatch.setattr(analytics_preview.cloud, "bigquery_client", lambda *_: client)
    with pytest.raises(ArchiveError):
        analytics_preview.preview(arguments("--execute"))
    assert len(client.calls) <= 1


def test_unbounded_usage_execution_is_rejected_before_cloud(monkeypatch):
    monkeypatch.setattr(
        analytics_preview.cloud, "bigquery_client", lambda *_: pytest.fail("cloud call")
    )
    with pytest.raises(ArchiveError, match="bounded"):
        analytics_preview.preview(
            arguments("--query", "usage-timeseries", "--window", "all", "--execute")
        )


@pytest.mark.parametrize("query", ["leaderboard", "network-totals", "usage-timeseries"])
def test_execute_ignores_mixed_generation_stable_aliases(query, monkeypatch):
    class MixedAliases(Client):
        def get_table(self, name):
            assert name == f"archive-test.accounting_history.catalog_{CATALOG}"
            return super().get_table(name)

        def query(self, sql, job_config):
            # Simulate publication selecting a new earnings alias before ledger.
            # Any use of these aliases would mix cuts; the immutable inputs stay A.
            aliases = {
                "archive-test.accounting_history.provider_earnings": "b" * 16,
                "archive-test.accounting_history.ledger_entries": CATALOG,
                "archive-test.accounting_history.usage": "b" * 16,
            }
            referenced = set(re.findall(r"`([^`]+)`", sql))
            assert not referenced.intersection(aliases)
            expected = {f"archive-test.accounting_history.catalog_{CATALOG}"}
            if not sql.startswith("SELECT DISTINCT table_name"):
                expected.update(
                    f"archive-test.accounting_history.{table}_files_{CATALOG}"
                    for table in self.tables
                )
            assert referenced == expected
            return super().query(sql, job_config)

    client = MixedAliases(tables=source_tables(query))
    monkeypatch.setattr(analytics_preview.cloud, "bigquery_client", lambda *_: client)
    report = analytics_preview.preview(arguments("--query", query, "--execute"))
    assert report["catalog_version"] == CATALOG
    assert report["serving_eligible"] is False
    assert len(client.calls) == 2

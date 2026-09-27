"""Optional SELECT-only BigQuery semantic tests; no datasets or tables are created."""

import os
from decimal import Decimal

import pytest
from google.cloud import bigquery

from telemetry_archive import cloud
from telemetry_archive.analytics_sql import aggregation_sql, parameters
from telemetry_archive.model import utc

FIXTURE = """WITH provider_earnings AS (
 SELECT account_id, model, amount_micro_usd, prompt_tokens, completion_tokens,
   TIMESTAMP(event_at) AS source_time FROM UNNEST([
 STRUCT('a' AS account_id, 'work' AS model, 1000 AS amount_micro_usd,
   10 AS prompt_tokens, 20 AS completion_tokens, '2026-09-25 12:00:00+00' AS event_at),
 ('a', 'work', -100, -1, -2, '2026-09-25 13:00:00+00'),
 ('a', 'base_reward', 200, 999, 999, '2026-09-26 00:00:00+00'),
 ('b', 'base_reward', 300, 999, 999, '2026-09-25 14:00:00+00'),
 ('c', 'work', 500, 7, 8, '2026-09-25 10:00:00+00'),
 ('d', 'work', 1150, 5, 15, '2026-09-25 13:00:00+00'),
 ('e', 'work', 1150, 5, 15, '2026-09-25 13:00:00+00'),
 ('', 'work', 50, 1, 2, '2026-09-25 13:00:00+00'),
 ('future', 'work', 999999, 9, 9, '2026-09-26 12:00:00+00')
 ])
), ledger_entries AS (
 SELECT account_id, entry_type, amount_micro_usd, TIMESTAMP(event_at) AS source_time FROM UNNEST([
 STRUCT('a' AS account_id, 'referral_reward' AS entry_type, 100 AS amount_micro_usd,
   '2026-09-25 16:00:00+00' AS event_at),
 ('b', 'admin_reward', -50, '2026-09-25 16:00:00+00'),
 ('consumer-only', 'referral_reward', 9000, '2026-09-25 16:00:00+00'),
 ('c', 'admin_reward', 500, '2026-09-25 16:00:00+00'),
 ('', 'admin_reward', 99999, '2026-09-25 16:00:00+00'),
 ('d', 'deposit', 9999, '2026-09-25 16:00:00+00')
 ])
), usage AS (
 SELECT TIMESTAMP(event_at) AS source_time, prompt_tokens, completion_tokens, cost_micro_usd
 FROM UNNEST([
 STRUCT('2026-09-25 12:00:00+00' AS event_at, 10 AS prompt_tokens, 20 AS completion_tokens,
   9223372036854775807 AS cost_micro_usd),
 ('2026-09-25 12:30:00+00', 5, 6, 1),
 ('2026-09-25 11:59:59+00', 9, 9, 99),
 ('2026-09-26 12:00:00+00', 9, 9, 99)
 ])
)"""


@pytest.fixture
def bq():
    project = os.environ.get("TEST_ARCHIVE_BIGQUERY_PROJECT")
    if not project:
        pytest.skip("set TEST_ARCHIVE_BIGQUERY_PROJECT for explicit SELECT-only cloud checks")
    return cloud.bigquery_client(project, "us-east4")


def run(bq, query, window="24h", metric="earnings", limit=50, as_of="2026-09-26T12:00:00Z"):
    values = parameters(window, utc(as_of), limit)
    config = bigquery.QueryJobConfig(
        maximum_bytes_billed=10 * 1024**2,
        query_parameters=[
            bigquery.ScalarQueryParameter(k, "INT64" if k == "limit" else "TIMESTAMP", v)
            for k, v in values.items()
        ],
    )
    return [
        dict(row.items())
        for row in bq.query(FIXTURE + aggregation_sql(query, metric), job_config=config).result(
            timeout=120
        )
    ]


def test_leaderboard_preserves_reward_cohorts_and_signed_corrections(bq):
    rows = run(bq, "leaderboard")
    assert [r["account_id"] for r in rows] == ["a", "d", "e", "b"]
    assert rows[0] == {
        "account_id": "a",
        "earnings_micro_usd": Decimal(1200),
        "work_micro_usd": Decimal(900),
        "reward_micro_usd": Decimal(300),
        "tokens": Decimal(27),
        "jobs": 2,
    }
    assert rows[3]["jobs"] == rows[3]["tokens"] == 0
    assert rows[3]["reward_micro_usd"] == 250


@pytest.mark.parametrize("metric", ["tokens", "jobs"])
def test_metric_order_limit_and_tie_break(bq, metric):
    rows = run(bq, "leaderboard", metric=metric, limit=2)
    assert [r["account_id"] for r in rows] == ["a", "d"]


@pytest.mark.parametrize(
    "window,earnings,tokens,jobs,accounts",
    [
        ("24h", 3800, 70, 5, 4),
        ("7d", 4800, 85, 6, 5),
    ],
)
def test_network_totals_include_anonymous_work_without_anonymous_rewards(
    bq,
    window,
    earnings,
    tokens,
    jobs,
    accounts,
):
    (row,) = run(bq, "network-totals", window=window)
    assert row["earnings_micro_usd"] == earnings
    assert row["tokens"] == tokens and row["jobs"] == jobs and row["active_accounts"] == accounts
    assert row["work_micro_usd"] + row["reward_micro_usd"] == earnings


def test_usage_boundary_buckets_and_exact_amount_above_int64(bq):
    (row,) = run(bq, "usage-timeseries")
    assert row == {
        "bucket_start": utc("2026-09-25T12:00:00Z"),
        "requests": 2,
        "prompt_tokens": Decimal(15),
        "completion_tokens": Decimal(26),
        "cost_micro_usd": Decimal(2**63),
    }


def test_empty_window_is_distinct_from_query_failure(bq):
    assert run(bq, "leaderboard", as_of="2026-01-01T00:00:00Z") == []
    (row,) = run(bq, "network-totals", as_of="2026-01-01T00:00:00Z")
    assert set(row.values()) == {0}

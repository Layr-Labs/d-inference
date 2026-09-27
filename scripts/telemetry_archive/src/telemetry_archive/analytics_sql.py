"""Bounded shadow queries against one immutable accounting catalog generation."""

from datetime import timedelta

from .model import ArchiveError
from .publish import reader_sql

QUERIES = ("leaderboard", "network-totals", "usage-timeseries")
WINDOWS = {"24h": 1, "7d": 7, "30d": 30, "all": None}
METRICS = {"earnings": "earnings_micro_usd", "tokens": "tokens", "jobs": "jobs"}


def parameters(window, as_of, limit):
    if window not in WINDOWS or as_of.tzinfo is None:
        raise ArchiveError("choose an explicit UTC cutoff and a supported analytics window")
    if type(limit) is not int or not 1 <= limit <= 200:
        raise ArchiveError("analytics limit must be between 1 and 200")
    days = WINDOWS[window]
    return {"since": as_of - timedelta(days=days) if days else None, "as_of": as_of, "limit": limit}


def source_tables(query):
    if query not in QUERIES:
        raise ArchiveError("unsupported analytics query")
    return ["usage"] if query == "usage-timeseries" else ["provider_earnings", "ledger_entries"]


def query_sql(project, dataset, catalog, query, metric="earnings"):
    sources = [
        f"{table} AS ({reader_sql(project, dataset, table, catalog)})"
        for table in source_tables(query)
    ]
    return "WITH " + ",\n".join(sources) + aggregation_sql(query, metric)


def aggregation_sql(query, metric="earnings"):
    """Append aggregate CTEs to typed inputs, shared with SELECT-only SQL parity tests."""
    source_tables(query)
    if metric not in METRICS:
        raise ArchiveError("unsupported leaderboard metric")
    bounds = "(@since IS NULL OR source_time >= @since) AND source_time < @as_of"
    if query == "usage-timeseries":
        body = f"""SELECT TIMESTAMP_TRUNC(source_time, HOUR, 'UTC') AS bucket_start,
  COUNT(*) AS requests,
  COALESCE(SUM(CAST(prompt_tokens AS BIGNUMERIC)), 0) AS prompt_tokens,
  COALESCE(SUM(CAST(completion_tokens AS BIGNUMERIC)), 0) AS completion_tokens,
  COALESCE(SUM(CAST(cost_micro_usd AS BIGNUMERIC)), 0) AS cost_micro_usd
FROM usage WHERE {bounds}
GROUP BY bucket_start ORDER BY bucket_start"""
        return "\n" + body
    sources = [
        f"earnings AS (SELECT * FROM provider_earnings WHERE {bounds})",
        f"ledger AS (SELECT * FROM ledger_entries WHERE {bounds})",
        """accounts AS (
  SELECT account_id,
    SUM(IF(model <> 'base_reward', CAST(amount_micro_usd AS BIGNUMERIC), 0)) AS work_micro,
    SUM(IF(model = 'base_reward', CAST(amount_micro_usd AS BIGNUMERIC), 0)) AS base_micro,
    SUM(IF(model <> 'base_reward', CAST(prompt_tokens AS BIGNUMERIC)
      + CAST(completion_tokens AS BIGNUMERIC), 0)) AS tokens,
    COUNTIF(model <> 'base_reward') AS jobs
  FROM earnings WHERE account_id != '' GROUP BY account_id
)""",
        """rewards AS (
  SELECT account_id, SUM(CAST(amount_micro_usd AS BIGNUMERIC)) AS reward_micro
  FROM ledger WHERE entry_type IN ('referral_reward', 'admin_reward')
  GROUP BY account_id
)""",
    ]
    if query == "leaderboard":
        # Ledger-only accounts do not join the provider cohort. Base rewards
        # contribute money, but never inference job/token counts.
        body = f"""SELECT a.account_id,
  a.work_micro + a.base_micro + COALESCE(r.reward_micro, 0) AS earnings_micro_usd,
  a.work_micro AS work_micro_usd,
  a.base_micro + COALESCE(r.reward_micro, 0) AS reward_micro_usd,
  a.tokens, a.jobs
FROM accounts a LEFT JOIN rewards r USING (account_id)
ORDER BY {METRICS[metric]} DESC, account_id ASC LIMIT @limit"""
    else:
        # Match NetworkTotals: anonymous earnings count in network work/base
        # totals, but cannot qualify an account for ledger rewards or active count.
        sources.append("""totals AS (
  SELECT
    COALESCE(SUM(IF(model <> 'base_reward', CAST(amount_micro_usd AS BIGNUMERIC), 0)), 0)
      AS work_micro,
    COALESCE(SUM(IF(model = 'base_reward', CAST(amount_micro_usd AS BIGNUMERIC), 0)), 0)
      AS base_micro,
    COALESCE(SUM(IF(model <> 'base_reward', CAST(prompt_tokens AS BIGNUMERIC)
      + CAST(completion_tokens AS BIGNUMERIC), 0)), 0) AS tokens,
    COUNTIF(model <> 'base_reward') AS jobs FROM earnings
)""")
        sources.append("""provider_rewards AS (
  SELECT COALESCE(SUM(r.reward_micro), 0) AS reward_micro
  FROM rewards r JOIN accounts a USING (account_id)
)""")
        body = """SELECT t.work_micro + t.base_micro + r.reward_micro AS earnings_micro_usd,
  t.work_micro AS work_micro_usd, t.base_micro + r.reward_micro AS reward_micro_usd,
  t.tokens, t.jobs, (SELECT COUNT(*) FROM accounts) AS active_accounts
FROM totals t CROSS JOIN provider_rewards r"""
    return ",\n" + ",\n".join(sources) + "\n" + body

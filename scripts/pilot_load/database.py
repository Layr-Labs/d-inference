from __future__ import annotations

import json
import subprocess
import time
from typing import Any

from .processes import isolated_environment


COMMON_QUERIES = {
    "balances": """
        SELECT account_id, balance_micro_usd, withdrawable_micro_usd
        FROM public.balances
        WHERE balance_micro_usd <> 0 OR withdrawable_micro_usd <> 0
        ORDER BY account_id
    """,
    "provider_earnings": """
        SELECT account_id, model, count(*) AS entries,
               sum(amount_micro_usd) AS amount_micro_usd,
               sum(prompt_tokens) AS prompt_tokens,
               sum(completion_tokens) AS completion_tokens
        FROM public.provider_earnings
        GROUP BY account_id, model
        ORDER BY account_id, model
    """,
    "usage": """
        SELECT public_model, model, count(*) AS requests,
               sum(prompt_tokens) AS prompt_tokens,
               sum(completion_tokens) AS completion_tokens,
               sum(cost_micro_usd) AS cost_micro_usd
        FROM public.usage
        GROUP BY public_model, model
        ORDER BY public_model, model
    """,
    "usage_totals": """
        SELECT total_requests, total_prompt_tokens, total_completion_tokens
        FROM public.usage_totals
        ORDER BY id
    """,
}

GO_QUERIES = {
    "ledger": """
        SELECT account_id, sum(amount_micro_usd) AS net_micro_usd
        FROM public.ledger_entries
        WHERE entry_type <> 'admin_reward'
        GROUP BY account_id
        HAVING sum(amount_micro_usd) <> 0
        ORDER BY account_id
    """,
    "settlement_provenance": """
        SELECT provider_account_id,
               'platform'::text AS platform_account_id,
               referrer_account_id AS referral_account_id,
               public_model,
               model,
               count(*) AS jobs,
               sum(cost_micro_usd) AS cost_micro_usd,
               sum(provider_payout_micro_usd) AS provider_micro_usd,
               sum(platform_fee_micro_usd) AS platform_micro_usd,
               sum(referral_reward_micro_usd) AS referral_micro_usd,
               sum(prompt_tokens) AS prompt_tokens,
               sum(completion_tokens) AS completion_tokens
        FROM public.inference_settlements
        WHERE record_usage
        GROUP BY provider_account_id, referrer_account_id, public_model, model
        ORDER BY provider_account_id, referrer_account_id, public_model, model
    """,
}

RUST_QUERIES = {
    "ledger": """
        SELECT account_id, sum(amount_micro_usd) AS net_micro_usd
        FROM public.ledger_entries
        WHERE entry_type <> 'admin_reward'
        GROUP BY account_id
        HAVING sum(amount_micro_usd) <> 0
        ORDER BY account_id
    """,
    "attempt_delivery": """
        SELECT kind, state, count(*) AS attempts
        FROM rust_coord.inference_attempts
        GROUP BY kind, state
        ORDER BY kind, state
    """,
    "job_provenance": """
        SELECT state, pricing_version, rounding_version, provider_share_ppm,
               referral_share_ppm, count(*) AS jobs,
               sum(reserved_total_micro_usd) AS reserved_micro_usd,
               sum(provider_payout_micro_usd) AS provider_micro_usd,
               sum(platform_fee_micro_usd) AS platform_micro_usd,
               sum(referral_reward_micro_usd) AS referral_micro_usd,
               sum(usage_prompt_tokens) AS prompt_tokens,
               sum(usage_completion_tokens) AS completion_tokens
        FROM rust_coord.inference_jobs
        GROUP BY state, pricing_version, rounding_version, provider_share_ppm,
                 referral_share_ppm
        ORDER BY state, pricing_version, rounding_version, provider_share_ppm,
                 referral_share_ppm
    """,
    "settlement_provenance": """
        SELECT COALESCE(provider_account_id, '') AS provider_account_id,
               platform_account_id,
               COALESCE(referral_account_id, '') AS referral_account_id,
               COALESCE(public_model, '') AS public_model,
               COALESCE(concrete_model, '') AS model,
               count(*) AS jobs,
               sum(
                   COALESCE(provider_payout_micro_usd, 0)
                   + COALESCE(platform_fee_micro_usd, 0)
                   + COALESCE(referral_reward_micro_usd, 0)
               ) AS cost_micro_usd,
               sum(COALESCE(provider_payout_micro_usd, 0)) AS provider_micro_usd,
               sum(COALESCE(platform_fee_micro_usd, 0)) AS platform_micro_usd,
               sum(COALESCE(referral_reward_micro_usd, 0)) AS referral_micro_usd,
               sum(COALESCE(usage_prompt_tokens, 0)) AS prompt_tokens,
               sum(COALESCE(usage_completion_tokens, 0)) AS completion_tokens
        FROM rust_coord.inference_jobs
        WHERE state IN ('settled', 'settled_reviewed')
        GROUP BY provider_account_id, platform_account_id, referral_account_id,
                 public_model, concrete_model
        ORDER BY provider_account_id, platform_account_id, referral_account_id,
                 public_model, concrete_model
    """,
}


def collect_database_snapshot(
    database_url: str,
    implementation: str,
    *,
    projection_timeout_seconds: float = 30,
) -> dict[str, Any]:
    queries = dict(COMMON_QUERIES)
    if implementation == "go":
        queries.update(GO_QUERIES)
    elif implementation == "rust":
        queries.update(RUST_QUERIES)
    else:
        raise ValueError(f"unknown implementation {implementation!r}")
    deadline = time.monotonic() + projection_timeout_seconds
    while True:
        snapshot: dict[str, Any] = {}
        errors: dict[str, str] = {}
        for name, query in queries.items():
            try:
                snapshot[name] = _query_json(database_url, query)
            except RuntimeError as error:
                errors[name] = str(error)
        result = {"available": not errors, "tables": snapshot, "errors": errors}
        if errors or _projection_complete(snapshot, implementation):
            return result
        if time.monotonic() >= deadline:
            return result
        time.sleep(0.25)


def _projection_complete(snapshot: dict[str, Any], implementation: str) -> bool:
    required = {
        "balances",
        "ledger",
        "provider_earnings",
        "usage",
        "usage_totals",
        "settlement_provenance",
    }
    if implementation == "rust":
        required.update({"attempt_delivery", "job_provenance"})
    return all(isinstance(snapshot.get(name), list) and snapshot[name] for name in required)


def _query_json(database_url: str, query: str) -> list[dict[str, Any]]:
    wrapped = (
        "SELECT COALESCE(jsonb_agg(to_jsonb(pilot_row)), '[]'::jsonb)::text "
        f"FROM ({query.strip().rstrip(';')}) AS pilot_row"
    )
    try:
        completed = subprocess.run(
            [
                "psql",
                database_url,
                "--no-psqlrc",
                "--tuples-only",
                "--no-align",
                "--set",
                "ON_ERROR_STOP=1",
                "--command",
                wrapped,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=isolated_environment({}),
            timeout=10,
            check=True,
        )
    except FileNotFoundError as error:
        raise RuntimeError("psql is unavailable") from error
    except subprocess.CalledProcessError as error:
        message = error.stderr.strip().replace(database_url, "<database-url>")
        raise RuntimeError(message) from error
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("database snapshot query timed out") from error
    value = json.loads(completed.stdout.strip())
    if not isinstance(value, list):
        raise RuntimeError("database snapshot query returned a non-array")
    return value

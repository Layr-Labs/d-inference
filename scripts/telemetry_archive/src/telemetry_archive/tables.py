"""Closed table scope and exact accounting projections; never arbitrary SQL names."""

TELEMETRY_TABLES = {
    "request_profiles": "created_at",
    "fleet_snapshots": "sampled_at",
    "request_rejections": "created_at",
    "inference_routes": "created_at",
    "request_outcomes": "received_at",
}
ACCOUNTING_FIELDS = {
    "usage": ("cost_micro_usd", "prompt_tokens", "completion_tokens"),
    "provider_earnings": ("amount_micro_usd", "prompt_tokens", "completion_tokens"),
    "ledger_entries": ("amount_micro_usd", "balance_after"),
    "provider_floor_draws": ("amount_micro_usd", "floor_micro_usd", "earned_micro_usd"),
}
ACCOUNTING_TEXT_FIELDS = {
    "usage": ("consumer_key_hash", "key_id", "request_id", "public_model"),
    "provider_earnings": ("account_id", "provider_key", "job_id"),
    "ledger_entries": ("account_id", "entry_type", "reference"),
    "provider_floor_draws": ("account_id", "provider_key", "epoch_id"),
}
TABLES = {**TELEMETRY_TABLES, **dict.fromkeys(ACCOUNTING_FIELDS, "created_at")}

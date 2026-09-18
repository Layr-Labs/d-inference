package store

const trialDDL = `
CREATE TABLE IF NOT EXISTS trial_allowances (
 account_id TEXT NOT NULL, campaign_id TEXT NOT NULL,
 limit_tokens BIGINT NOT NULL CHECK(limit_tokens > 0),
 used_tokens BIGINT NOT NULL DEFAULT 0 CHECK(used_tokens >= 0),
 reserved_tokens BIGINT NOT NULL DEFAULT 0 CHECK(reserved_tokens >= 0),
 PRIMARY KEY(account_id,campaign_id),
 CHECK(used_tokens <= limit_tokens AND reserved_tokens <= limit_tokens-used_tokens)
);
CREATE TABLE IF NOT EXISTS trial_reservations (
 id TEXT PRIMARY KEY, account_id TEXT NOT NULL, campaign_id TEXT NOT NULL,
 model TEXT NOT NULL, limit_tokens BIGINT NOT NULL CHECK(limit_tokens > 0),
 reserved_tokens BIGINT NOT NULL CHECK(reserved_tokens > 0),
 used_tokens BIGINT NOT NULL DEFAULT 0 CHECK(used_tokens >= 0 AND used_tokens <= reserved_tokens),
 state TEXT NOT NULL CHECK(state IN ('reserved','dispatched','unresolved','released','settled')),
 pricing_json TEXT NOT NULL DEFAULT '',
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 FOREIGN KEY(account_id,campaign_id) REFERENCES trial_allowances(account_id,campaign_id)
);
CREATE INDEX IF NOT EXISTS trial_reservations_unresolved ON trial_reservations(updated_at) WHERE state IN ('dispatched','unresolved');
CREATE TABLE IF NOT EXISTS trial_subsidies (
 reservation_id TEXT PRIMARY KEY REFERENCES trial_reservations(id),
 serving_request_id TEXT NOT NULL DEFAULT '',
 subsidy_micro_usd BIGINT NOT NULL CHECK(subsidy_micro_usd >= 0),
 provider_credit_micro_usd BIGINT NOT NULL CHECK(provider_credit_micro_usd >= 0 AND provider_credit_micro_usd <= subsidy_micro_usd),
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);`

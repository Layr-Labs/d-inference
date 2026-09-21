package store

const modelTokenPromotionDDL = `
CREATE TABLE IF NOT EXISTS model_token_promotions (
 model_id TEXT PRIMARY KEY,
 tokens BIGINT NOT NULL CHECK (tokens > 0 AND tokens <= 1000000000000),
 claim_starts_at TIMESTAMPTZ NOT NULL,
 claim_ends_at TIMESTAMPTZ CHECK (claim_ends_at > claim_starts_at),
 signup_cutoff_at TIMESTAMPTZ NOT NULL,
 max_claims BIGINT NOT NULL CHECK (max_claims>0 AND max_claims<=1000000),
 claimed_count BIGINT NOT NULL DEFAULT 0 CHECK (claimed_count>=0 AND claimed_count<=max_claims),
 enabled BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE IF NOT EXISTS model_token_grants (
 account_id TEXT NOT NULL REFERENCES users(account_id),
 model_id TEXT NOT NULL REFERENCES model_token_promotions(model_id),
 total_tokens BIGINT NOT NULL CHECK (total_tokens > 0),
 used_tokens BIGINT NOT NULL DEFAULT 0 CHECK (used_tokens >= 0),
 reserved_tokens BIGINT NOT NULL DEFAULT 0 CHECK (reserved_tokens >= 0),
 claimed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 PRIMARY KEY (account_id, model_id),
 CHECK (used_tokens + reserved_tokens <= total_tokens)
);
CREATE TABLE IF NOT EXISTS model_token_provider_carries (
 account_id TEXT PRIMARY KEY,
 remainder BIGINT NOT NULL DEFAULT 0 CHECK (remainder >= 0 AND remainder < 100000000)
);
CREATE TABLE IF NOT EXISTS model_token_reservations (
 id TEXT PRIMARY KEY,
 account_id TEXT NOT NULL,
 model_id TEXT NOT NULL,
 state TEXT NOT NULL CHECK (state IN ('reserved','settled','released')),
 record JSONB NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 touched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 FOREIGN KEY (account_id, model_id) REFERENCES model_token_grants(account_id, model_id)
);
ALTER TABLE model_token_reservations ADD COLUMN IF NOT EXISTS touched_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
CREATE INDEX IF NOT EXISTS idx_model_token_reservations_open ON model_token_reservations(touched_at) WHERE state = 'reserved';
`

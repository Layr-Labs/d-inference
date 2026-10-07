-- +goose Up
CREATE TABLE IF NOT EXISTS consumer_charge_settlements (
	job_id TEXT PRIMARY KEY,
	account_id TEXT NOT NULL,
	reserved_micro_usd BIGINT NOT NULL CHECK (reserved_micro_usd >= 0),
	requested_micro_usd BIGINT NOT NULL CHECK (requested_micro_usd >= 0),
	referral_enabled BOOLEAN NOT NULL,
	collected_micro_usd BIGINT NOT NULL CHECK (collected_micro_usd >= 0),
	referrer_account TEXT NOT NULL DEFAULT '',
	reward_micro_usd BIGINT NOT NULL CHECK (reward_micro_usd >= 0),
	uncollected BOOLEAN NOT NULL,
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_consumer_settlements_referrer
    ON consumer_charge_settlements(referrer_account) WHERE referrer_account <> '';

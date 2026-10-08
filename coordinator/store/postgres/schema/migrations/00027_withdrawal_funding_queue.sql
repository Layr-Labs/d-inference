-- Schema adoption and migration replay may encounter these columns already
-- installed. Preserve their values and definitions, like other additive steps.
-- +goose Up
ALTER TABLE stripe_withdrawals ADD COLUMN IF NOT EXISTS transfer_attempt INTEGER NOT NULL DEFAULT 0;
ALTER TABLE stripe_withdrawals ADD COLUMN IF NOT EXISTS transfer_started_at TIMESTAMPTZ NOT NULL DEFAULT '0001-01-01 00:00:00+00';
ALTER TABLE stripe_withdrawals ADD COLUMN IF NOT EXISTS transfer_lease_until TIMESTAMPTZ NOT NULL DEFAULT '0001-01-01 00:00:00+00';

ALTER TABLE stripe_withdrawals ADD COLUMN IF NOT EXISTS transfer_dispatch_attempts INTEGER NOT NULL DEFAULT 0;

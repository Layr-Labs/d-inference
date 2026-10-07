-- The ordinary grant and its separately funded Autopilot bonus share one
-- immutable machine/epoch idempotency key. Existing settlements get no bonus.
-- +goose Up
ALTER TABLE provider_floor_draws ADD COLUMN IF NOT EXISTS autopilot_bonus_micro_usd BIGINT NOT NULL DEFAULT 0;

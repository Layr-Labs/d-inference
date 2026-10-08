-- +goose Up
-- Existing declarations contain no evidence of daily qualification. Preserve
-- their consent and frozen baselines, but never invent qualifying history.
ALTER TABLE autopilot_reward_consents ADD COLUMN IF NOT EXISTS qualified BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE autopilot_reward_consents ADD COLUMN IF NOT EXISTS chip TEXT NOT NULL DEFAULT '' CHECK (octet_length(chip) <= 128);
ALTER TABLE autopilot_reward_consents ADD COLUMN IF NOT EXISTS memory_gb DOUBLE PRECISION NOT NULL DEFAULT 0 CHECK (memory_gb >= 0 AND memory_gb < 'Infinity'::double precision);

ALTER TABLE autopilot_reward_enrollments DROP CONSTRAINT IF EXISTS autopilot_reward_enrollments_source_check;
ALTER TABLE autopilot_reward_enrollments ADD CONSTRAINT autopilot_reward_enrollments_source_check CHECK (
    (baseline_known AND baseline_source IN ('tracked', 'cohort', 'verified_history')) OR
    (NOT baseline_known AND baseline_source = '')
);

ALTER TABLE autopilot_reward_settlements DROP CONSTRAINT IF EXISTS autopilot_reward_settlements_status_check;
ALTER TABLE autopilot_reward_settlements ADD CONSTRAINT autopilot_reward_settlements_status_check
    CHECK (status IN ('paid', 'zero', 'opted_out', 'ineligible', 'pool_exhausted', 'history_required'));

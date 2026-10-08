-- +goose Up
-- Financial records retain their original machine IDs after inventory merges.
-- They are not operational history and must not be pruned or cascade-deleted.
CREATE TABLE IF NOT EXISTS autopilot_reward_pool (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    cap_micro_usd BIGINT NOT NULL DEFAULT 0 CHECK (cap_micro_usd >= 0),
    spent_micro_usd BIGINT NOT NULL DEFAULT 0 CHECK (spent_micro_usd >= 0 AND spent_micro_usd <= cap_micro_usd),
    tracking_started_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO autopilot_reward_pool(singleton) VALUES(TRUE) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS autopilot_reward_enrollments (
    machine_id TEXT PRIMARY KEY REFERENCES darkbloom_machines(id),
    account_id TEXT NOT NULL CHECK (account_id <> ''),
    first_observed_at TIMESTAMPTZ NOT NULL,
    first_opt_in_at TIMESTAMPTZ,
    seven_day_earnings_micro_usd BIGINT NOT NULL DEFAULT 0 CHECK (seven_day_earnings_micro_usd >= 0),
    daily_floor_micro_usd BIGINT NOT NULL DEFAULT 0,
    baseline_known BOOLEAN NOT NULL DEFAULT FALSE,
    baseline_source TEXT NOT NULL DEFAULT '',
    baseline_evidence TEXT NOT NULL DEFAULT '' CHECK (octet_length(baseline_evidence) <= 1024),
    next_day DATE NOT NULL,
    CONSTRAINT autopilot_reward_enrollments_baseline_check CHECK (
        (baseline_known AND first_opt_in_at IS NOT NULL AND first_opt_in_at <= first_observed_at AND btrim(baseline_evidence) <> '') OR
        (NOT baseline_known AND first_opt_in_at IS NULL AND seven_day_earnings_micro_usd = 0 AND baseline_evidence = '')
    ),
    CONSTRAINT autopilot_reward_enrollments_source_check CHECK (
        (baseline_known AND baseline_source IN ('tracked', 'verified_history')) OR
        (NOT baseline_known AND baseline_source = '')
    ),
    CONSTRAINT autopilot_reward_enrollments_floor_check CHECK (
        daily_floor_micro_usd = seven_day_earnings_micro_usd / 70 * 11 + seven_day_earnings_micro_usd % 70 * 11 / 70
    ),
    CONSTRAINT autopilot_reward_enrollments_next_day_check CHECK (next_day >= (first_observed_at AT TIME ZONE 'UTC')::date)
);

-- Unbound declarations survive connection loss without trusting a machine ID.
-- Keep transitions and one daily checkpoint. Same-value observations in that
-- UTC day only advance its watermark, preserving post-merge day eligibility.
CREATE TABLE IF NOT EXISTS autopilot_reward_consents (
    machine_id TEXT REFERENCES darkbloom_machines(id),
    at TIMESTAMPTZ NOT NULL,
    last_observed_at TIMESTAMPTZ NOT NULL CHECK (last_observed_at >= at),
    account_id TEXT NOT NULL CHECK (account_id <> ''),
    session_id TEXT NOT NULL CHECK (session_id <> ''),
    opted_in BOOLEAN NOT NULL,
    supported BOOLEAN NOT NULL,
    PRIMARY KEY (session_id, at),
    CONSTRAINT autopilot_reward_consents_supported_check CHECK (NOT opted_in OR supported),
    CONSTRAINT autopilot_reward_consents_day_check CHECK ((at AT TIME ZONE 'UTC')::date = (last_observed_at AT TIME ZONE 'UTC')::date)
);
CREATE INDEX IF NOT EXISTS autopilot_reward_consents_machine ON autopilot_reward_consents(machine_id, last_observed_at);
CREATE INDEX IF NOT EXISTS autopilot_reward_consents_unbound ON autopilot_reward_consents(account_id, at) WHERE machine_id IS NULL;

CREATE TABLE IF NOT EXISTS autopilot_reward_settlements (
    machine_id TEXT NOT NULL REFERENCES autopilot_reward_enrollments(machine_id),
    day DATE NOT NULL,
    account_id TEXT NOT NULL CHECK (account_id <> ''),
    floor_micro_usd BIGINT NOT NULL CHECK (floor_micro_usd >= 0),
    inference_micro_usd BIGINT NOT NULL CHECK (inference_micro_usd >= 0),
    due_micro_usd BIGINT NOT NULL CHECK (due_micro_usd >= 0),
    amount_micro_usd BIGINT NOT NULL CHECK (amount_micro_usd >= 0),
    status TEXT NOT NULL CHECK (status IN ('paid', 'zero', 'opted_out', 'pool_exhausted', 'history_required')),
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (machine_id, day),
    CONSTRAINT autopilot_reward_settlements_amount_check CHECK (
        (status = 'paid' AND amount_micro_usd > 0 AND amount_micro_usd = due_micro_usd) OR
        (status <> 'paid' AND amount_micro_usd = 0)
    )
);

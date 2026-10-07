-- Defaults apply to existing machines without rewriting their observations.
-- Adoption and replay preserve any operator intent already stored here.
-- +goose Up
ALTER TABLE darkbloom_machines
    ADD COLUMN IF NOT EXISTS autopilot_desired_mode TEXT NOT NULL DEFAULT 'shadow',
    ADD COLUMN IF NOT EXISTS autopilot_revision BIGINT NOT NULL DEFAULT 0;

-- Add checks without scanning under the exclusive DDL lock. Version 30
-- validates them in a separate transaction that permits ordinary writes.
-- +goose StatementBegin
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
        WHERE conrelid = 'darkbloom_machines'::regclass
          AND conname = 'darkbloom_machines_autopilot_desired_mode_check') THEN
        ALTER TABLE darkbloom_machines
            ADD CONSTRAINT darkbloom_machines_autopilot_desired_mode_check
            CHECK (autopilot_desired_mode IN ('shadow', 'live')) NOT VALID;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
        WHERE conrelid = 'darkbloom_machines'::regclass
          AND conname = 'darkbloom_machines_autopilot_revision_check') THEN
        ALTER TABLE darkbloom_machines
            ADD CONSTRAINT darkbloom_machines_autopilot_revision_check
            CHECK (autopilot_revision >= 0) NOT VALID;
    END IF;
END $$;
-- +goose StatementEnd

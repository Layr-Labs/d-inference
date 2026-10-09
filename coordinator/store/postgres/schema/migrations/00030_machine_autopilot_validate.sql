-- +goose Up
ALTER TABLE darkbloom_machines
    VALIDATE CONSTRAINT darkbloom_machines_autopilot_desired_mode_check,
    VALIDATE CONSTRAINT darkbloom_machines_autopilot_revision_check;

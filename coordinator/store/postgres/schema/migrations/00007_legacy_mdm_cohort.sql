-- +goose Up
CREATE TABLE IF NOT EXISTS legacy_mdm_cohort_freeze (
 singleton BOOLEAN PRIMARY KEY CHECK (singleton), cutoff TIMESTAMPTZ NOT NULL
);
CREATE TABLE IF NOT EXISTS legacy_mdm_cohort (
 account_id TEXT NOT NULL CHECK (account_id <> ''),
 se_public_key TEXT NOT NULL CHECK (se_public_key <> ''),
 serial_number TEXT NOT NULL CHECK (serial_number <> ''),
 PRIMARY KEY (account_id, se_public_key, serial_number)
);

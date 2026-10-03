-- The erasure outbox worker stores the Stripe redaction job of a
-- checkout_sessions row while the job validates and runs. A constant default
-- changes only the catalog; the worker clears the ID when the row is done.
-- +goose Up
ALTER TABLE erasure_outbox ADD COLUMN IF NOT EXISTS stripe_job_id TEXT NOT NULL DEFAULT '';

-- The erasure outbox worker keeps the Stripe redaction job of a
-- checkout_sessions row while the job validates and runs: its ID, the last
-- status seen and since when (for the stuck-job deadline), and a generation
-- that changes the idempotency key when a new job must be made. Constant
-- defaults change only the catalog; the worker clears the job ID when the
-- row is done.
-- +goose Up
ALTER TABLE erasure_outbox ADD COLUMN IF NOT EXISTS stripe_job_id TEXT NOT NULL DEFAULT '';
ALTER TABLE erasure_outbox ADD COLUMN IF NOT EXISTS stripe_job_status TEXT NOT NULL DEFAULT '';
ALTER TABLE erasure_outbox ADD COLUMN IF NOT EXISTS stripe_job_status_since TIMESTAMPTZ;
ALTER TABLE erasure_outbox ADD COLUMN IF NOT EXISTS stripe_job_generation INTEGER NOT NULL DEFAULT 0;

-- Account erasure. erasure_requests holds one row per request and its state.
-- It retains lifecycle/audit identifiers and the operator-supplied reason.
-- The plan has row counts; the confirm token and planned wallet list are hashed.
-- Confirmed wallet_addresses remain raw during grace and are cleared on scrub
-- or cancellation. Reasons must not contain personal details.
-- erasure_outbox holds the external deletions that the scrub
-- leaves for a worker; external_id carries a Stripe ID until that deletion
-- is confirmed and is then cleared. New tables take no lock on existing ones;
-- the file runs in one transaction, and IF NOT EXISTS keeps a replay a no-op.
-- +goose Up
CREATE TABLE IF NOT EXISTS erasure_requests (
    id                 TEXT PRIMARY KEY,
    account_id         TEXT NOT NULL,
    actor              TEXT NOT NULL DEFAULT '',
    canceled_by        TEXT NOT NULL DEFAULT '',
    reason             TEXT NOT NULL DEFAULT '',
    state              TEXT NOT NULL CHECK (state IN ('planned', 'pending', 'erased', 'canceled')),
    plan               JSONB NOT NULL DEFAULT '{}',
    confirm_token_hash TEXT NOT NULL DEFAULT '',
    confirm_expires_at TIMESTAMPTZ,
    wallet_hash        TEXT NOT NULL DEFAULT '',
    wallet_addresses   TEXT[] NOT NULL DEFAULT '{}',
    requested_at       TIMESTAMPTZ,
    scrub_after        TIMESTAMPTZ,
    erased_at          TIMESTAMPTZ,
    canceled_at        TIMESTAMPTZ,
    lease_until        TIMESTAMPTZ,
    last_error         TEXT NOT NULL DEFAULT '',
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX IF NOT EXISTS erasure_requests_open ON erasure_requests (account_id) WHERE state IN ('planned', 'pending');
CREATE INDEX IF NOT EXISTS erasure_requests_account ON erasure_requests (account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS erasure_requests_due ON erasure_requests (scrub_after) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS erasure_requests_erased ON erasure_requests (account_id) WHERE state = 'erased';

CREATE TABLE IF NOT EXISTS erasure_outbox (
    id          TEXT PRIMARY KEY,
    request_id  TEXT NOT NULL REFERENCES erasure_requests (id),
    target      TEXT NOT NULL CHECK (target IN ('stripe_account', 'global_recipient', 'checkout_sessions', 'erasure_log')),
    external_id TEXT NOT NULL DEFAULT '',
    state       TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'done', 'manual_action')),
    attempts    INTEGER NOT NULL DEFAULT 0,
    next_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    lease_until TIMESTAMPTZ,
    last_error  TEXT NOT NULL DEFAULT '',
    done_at     TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS erasure_outbox_request ON erasure_outbox (request_id);
CREATE INDEX IF NOT EXISTS erasure_outbox_due ON erasure_outbox (next_at) WHERE state = 'pending';

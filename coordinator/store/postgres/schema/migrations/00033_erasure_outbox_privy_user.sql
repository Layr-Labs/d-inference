-- Let the erasure outbox hold a privy_user row: the Privy user ID that the
-- outbox worker deletes in Privy. The wider check is added NOT VALID (a short
-- lock), validated without blocking writes, and then replaces the old one.
-- Each statement commits on its own; the first one removes a check left by an
-- interrupted earlier attempt.
-- +goose NO TRANSACTION
-- +goose Up
ALTER TABLE erasure_outbox DROP CONSTRAINT IF EXISTS erasure_outbox_target_allowed;
ALTER TABLE erasure_outbox ADD CONSTRAINT erasure_outbox_target_allowed
    CHECK (target IN ('stripe_account', 'global_recipient', 'checkout_sessions', 'erasure_log', 'resend_contact', 'privy_user')) NOT VALID;
ALTER TABLE erasure_outbox VALIDATE CONSTRAINT erasure_outbox_target_allowed;
ALTER TABLE erasure_outbox DROP CONSTRAINT IF EXISTS erasure_outbox_target_check;

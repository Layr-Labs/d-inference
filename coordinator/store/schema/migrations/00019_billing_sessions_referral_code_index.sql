-- Account erasure replaces a referrer code in the billing sessions that
-- copied it, found by billing_sessions.referral_code.
-- A failed CONCURRENTLY build leaves an invalid index; the DROP removes it
-- before the next attempt.
-- A CONCURRENTLY statement blocks no reads or writes, but it waits for every
-- older snapshot in the database; the 3 s session lock_timeout would cancel it
-- behind any query that runs longer. It waits up to 1 min instead.
-- +goose NO TRANSACTION
-- +goose Up
SET lock_timeout = '1min';
DROP INDEX CONCURRENTLY IF EXISTS idx_billing_sessions_referral_code;
CREATE INDEX CONCURRENTLY idx_billing_sessions_referral_code ON billing_sessions (referral_code) WHERE referral_code <> '';
RESET lock_timeout;

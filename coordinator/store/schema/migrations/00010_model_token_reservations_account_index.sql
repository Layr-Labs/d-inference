-- Account erasure finds rows by model_token_reservations.account_id.
-- A failed CONCURRENTLY build leaves an invalid index; the DROP removes it
-- before the next attempt.
-- A CONCURRENTLY statement blocks no reads or writes, but it waits for every
-- older snapshot in the database; the 3 s session lock_timeout would cancel it
-- behind any query that runs longer. It waits up to 1 min instead.
-- +goose NO TRANSACTION
-- +goose Up
SET lock_timeout = '1min';
DROP INDEX CONCURRENTLY IF EXISTS idx_model_token_reservations_account;
CREATE INDEX CONCURRENTLY idx_model_token_reservations_account ON model_token_reservations (account_id);
RESET lock_timeout;

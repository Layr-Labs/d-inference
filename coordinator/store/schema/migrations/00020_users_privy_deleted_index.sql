-- A Privy login checks whether a soft-deleted user holds the Privy ID, so it
-- can refuse the login while the account waits for erasure. The live unique
-- index does not cover deleted rows; this small partial index does.
-- A failed CONCURRENTLY build leaves an invalid index; the DROP removes it
-- before the next attempt.
-- +goose NO TRANSACTION
-- +goose Up
SET lock_timeout = '1min';
DROP INDEX CONCURRENTLY IF EXISTS idx_users_privy_deleted;
CREATE INDEX CONCURRENTLY idx_users_privy_deleted ON users (privy_user_id) WHERE deleted_at IS NOT NULL;
RESET lock_timeout;

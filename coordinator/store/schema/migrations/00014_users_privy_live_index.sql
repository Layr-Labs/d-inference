-- A Privy user ID is unique among live users only, so the same person can
-- sign up again after an erased account. Versions 15 and 16 drop the old
-- full-table unique constraint and index.
-- A CONCURRENTLY statement blocks no reads or writes, but it waits for every
-- older snapshot in the database; the 3 s session lock_timeout would cancel it
-- behind any query that runs longer. It waits up to 1 min instead.
-- +goose NO TRANSACTION
-- +goose Up
SET lock_timeout = '1min';
DROP INDEX CONCURRENTLY IF EXISTS idx_users_privy_live;
CREATE UNIQUE INDEX CONCURRENTLY idx_users_privy_live ON users (privy_user_id) WHERE deleted_at IS NULL;
RESET lock_timeout;

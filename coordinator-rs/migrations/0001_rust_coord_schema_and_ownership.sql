-- 0001_rust_coord_schema_and_ownership.sql
--
-- Creates the dedicated additive `rust_coord` schema (plan §12.1), the
-- schema-version stamp checked at Rust startup (plan §20), and the persistent
-- single-active-coordinator fencing epoch (plan §20).
--
-- Timeouts: sqlx applies each migration file inside one transaction, so the
-- SET LOCAL statements below bound every statement in this file and expire at
-- commit. This migration only creates brand-new empty objects; it must never
-- wait behind production traffic. If it cannot take its locks quickly, it
-- fails, rolls back atomically, and is safe to re-run.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- All Rust coordinator schema is ADDITIVE and lives in this schema. Legacy
-- (Go) tables in `public` are never altered, dropped, renamed, or re-typed by
-- these migrations (plan §20); Rust updates them only as compatibility
-- projections inside its own transactions (plan §12.1).
CREATE SCHEMA IF NOT EXISTS rust_coord;

-- Plan §20: "Startup checks a supported schema range and refuses an
-- incompatible database." Singleton row stamped by every migration:
--   schema_version     — the highest migration applied (equals the NNNN prefix
--                        of the last migration file).
--   min_reader_version — the oldest application schema-support floor that can
--                        still safely read/write this schema. Stays at 1 until
--                        a semantically breaking change raises it.
-- The Rust binary refuses to start unless
--   app_min_supported <= schema_version AND min_reader_version <= app_max_supported.
CREATE TABLE rust_coord.schema_meta (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	schema_version BIGINT NOT NULL,
	min_reader_version BIGINT NOT NULL,
	updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE rust_coord.schema_meta IS
	'Plan §20: supported schema range stamp; startup refuses an incompatible database.';

INSERT INTO rust_coord.schema_meta (id, schema_version, min_reader_version)
VALUES (1, 1, 1);

-- Plan §20: single-active ownership uses BOTH
--   1. this persistent fencing epoch (survives restarts; every provider
--      session, job start authorization, worker lease, and financial command
--      records the epoch that created it, and every authoritative mutation
--      compares the expected active epoch in the same transaction — zero
--      affected rows means immediate ownership loss), and
--   2. a LIVE PostgreSQL advisory lock/lease taken at runtime by the owning
--      process (session-scoped pg_advisory_lock; NOT represented in DDL).
--      Readiness requires the lock-holding connection to stay healthy.
-- Acquiring ownership = take the advisory lock, then increment fencing_epoch
-- and set holder/acquired_at in one transaction. The rollback-safe Go build
-- acquires the SAME lock and epoch before enabling workers (plan §4.6, §26.1
-- step 10).
CREATE TABLE rust_coord.coordinator_ownership (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	fencing_epoch BIGINT NOT NULL DEFAULT 0,
	holder TEXT NOT NULL DEFAULT '',
	acquired_at TIMESTAMPTZ,
	renewed_at TIMESTAMPTZ
);
COMMENT ON TABLE rust_coord.coordinator_ownership IS
	'Plan §20: persistent single-active coordinator fencing epoch; live exclusivity is a runtime pg advisory lock, not DDL.';

INSERT INTO rust_coord.coordinator_ownership (id, fencing_epoch, holder, acquired_at, renewed_at)
VALUES (1, 0, '', NULL, NULL);

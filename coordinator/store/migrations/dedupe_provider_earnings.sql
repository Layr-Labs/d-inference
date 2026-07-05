-- Offline / admin-only dedupe for provider_earnings(job_id).
--
-- DAR-349: this cleanup used to run inside the coordinator's startup migration
-- path (NewPostgresStore -> migrate). On the production table (~900k rows /
-- ~443MB) the `DELETE ... GROUP BY job_id` full-scanned and held a relation lock
-- for ~15 minutes, blocking the subsequent CREATE INDEX statements and stopping
-- the coordinator from ever binding :8080 — a production outage. Production has
-- zero duplicate job_ids, so it was also doing no useful work.
--
-- It now lives here as a MANUAL job. The coordinator never dedupes at boot; it
-- only verifies the duplicate count and, if zero, builds the partial unique index
-- CONCURRENTLY (see ensureProviderEarningsJobIndex in postgres.go). Run this ONLY
-- if startup reports duplicate job_id groups blocking idx_provider_earnings_job.
--
-- Run it OUT OF BAND (psql against the DB, off the serving startup path), ideally
-- in a maintenance window, NOT during a coordinator deploy.

-- 1. How many duplicate job_id groups exist (0 on healthy prod)?
SELECT count(*) AS duplicate_job_id_groups
FROM (
    SELECT job_id
    FROM provider_earnings
    WHERE job_id <> ''
    GROUP BY job_id
    HAVING count(*) > 1
) d;

-- 2. Dedupe: keep the earliest row (MIN(id)) per job_id, delete the rest.
--    Wrapped in an explicit transaction so it can be reviewed/rolled back.
--    Idempotent: a second run deletes 0 rows.
BEGIN;
DELETE FROM provider_earnings pe
USING (
    SELECT job_id, MIN(id) AS keep_id
    FROM provider_earnings
    WHERE job_id <> ''
    GROUP BY job_id
    HAVING count(*) > 1
) dup
WHERE pe.job_id = dup.job_id
  AND pe.job_id <> ''
  AND pe.id <> dup.keep_id;
COMMIT;

-- 3. Build the partial unique index CONCURRENTLY (no write-blocking lock).
--    CONCURRENTLY cannot run inside a transaction block, so it is OUTSIDE the
--    BEGIN/COMMIT above. If a prior attempt left an INVALID index, drop it first:
--    DROP INDEX IF EXISTS idx_provider_earnings_job;
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_provider_earnings_job
    ON provider_earnings(job_id)
    WHERE job_id <> '';

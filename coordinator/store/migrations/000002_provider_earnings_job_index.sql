-- darkbloom:transaction=false
-- darkbloom:concurrent-index=idx_provider_earnings_job
--
-- This migration stays outside a transaction because PostgreSQL requires that
-- CREATE/DROP INDEX CONCURRENTLY run as standalone statements. The migration
-- runner skips the body only when the target has the exact canonical
-- table/key/predicate definition. Invalid or valid-but-wrong same-name indexes
-- are dropped and rebuilt.

DO $$
DECLARE
    duplicate_groups BIGINT;
BEGIN
    SELECT count(*) INTO duplicate_groups
    FROM (
        SELECT job_id
        FROM provider_earnings
        WHERE job_id <> ''
        GROUP BY job_id
        HAVING count(*) > 1
    ) duplicates;

    IF duplicate_groups > 0 THEN
        RAISE EXCEPTION
            '% duplicate provider_earnings.job_id group(s) block idx_provider_earnings_job',
            duplicate_groups
            USING HINT =
                'Run coordinator/store/migrations/dedupe_provider_earnings.sql out of band, then retry the migration.';
    END IF;
END $$;

DROP INDEX CONCURRENTLY IF EXISTS idx_provider_earnings_job;

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_provider_earnings_job
    ON provider_earnings(job_id)
    WHERE job_id <> '';

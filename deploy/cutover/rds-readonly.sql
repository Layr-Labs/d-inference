SET statement_timeout = '15s';
SET lock_timeout = '2s';
SET idle_in_transaction_session_timeout = '15s';
SET default_transaction_read_only = on;
BEGIN TRANSACTION READ ONLY ISOLATION LEVEL REPEATABLE READ;
SELECT json_build_object(
    'window_started_at', :'window_start',
    'window_ended_at', :'window_end',
    'transaction_read_only', current_setting('transaction_read_only') = 'on',
    'read_only_role', current_user = 'darkbloom_cutover_readonly',
    'is_read_replica', pg_is_in_recovery(),
    'database_instance_id', (
        current_database()
        || '@'
        || COALESCE(inet_server_addr()::text, 'local')
        || ':'
        || inet_server_port()::text
    ),
    'database_system_identifier', (
        SELECT system_identifier::text
        FROM pg_control_system()
    ),
    'role_elevated', (
        SELECT rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls
        FROM pg_roles
        WHERE rolname = current_user
    ),
    'role_has_write_privileges', (
        EXISTS (
            SELECT 1
            FROM pg_class relation
            JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
            WHERE namespace.nspname IN ('public', 'rust_coord')
              AND relation.relkind IN ('r', 'p')
              AND has_table_privilege(
                    current_user,
                    relation.oid,
                    'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
                  )
        )
        OR EXISTS (
            SELECT 1
            FROM pg_class relation
            JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
            WHERE namespace.nspname IN ('public', 'rust_coord')
              AND relation.relkind = 'S'
              AND has_sequence_privilege(
                    current_user,
                    relation.oid,
                    'USAGE,UPDATE'
                  )
        )
        OR EXISTS (
            SELECT 1
            FROM pg_namespace namespace
            WHERE namespace.nspname IN ('public', 'rust_coord')
              AND has_schema_privilege(current_user, namespace.oid, 'CREATE')
        )
    ),
    'public_schema_version', (
        SELECT MAX(version) FROM public.schema_migration_versions
    ),
    'rust_schema_version', (
        SELECT MAX(version) FROM rust_coord.schema_versions
    ),
    'external_unknown', (
        SELECT COUNT(*) FROM public.stripe_withdrawals
        WHERE external_state IN ('submitted_unknown', 'external_unknown')
    ),
    'review_pending', (
        (SELECT COUNT(*) FROM public.stripe_withdrawals WHERE status = 'review_pending')
        + (SELECT COUNT(*) FROM rust_coord.inference_jobs WHERE state = 'review_pending')
    ),
    'sent_unknown', (
        SELECT COUNT(*) FROM rust_coord.inference_attempts WHERE state = 'sent_unknown'
    ),
    'pending_terminals', (
        SELECT COUNT(*) FROM rust_coord.provider_terminals
        WHERE status IN ('pending', 'conflict')
    ),
    'pending_external', (
        SELECT COUNT(*) FROM rust_coord.external_events
        WHERE status IN ('pending', 'processing')
    ),
    'pending_outbox', (
        SELECT COUNT(*) FROM rust_coord.outbox
        WHERE status IN ('pending', 'processing')
    ),
    'pending_fees', (
        SELECT COUNT(*) FROM rust_coord.fee_allocations
        WHERE status IN ('pending', 'processing', 'failed')
    ),
    'fee_projection', (
        SELECT COUNT(*) FROM rust_coord.fee_projection_checkpoints
        WHERE status IN ('running', 'failed')
    ),
    'historical_terminal_acks', (
        SELECT COUNT(*)
        FROM rust_coord.provider_terminals terminal
        JOIN rust_coord.inference_attempts attempt
          ON attempt.job_id = terminal.job_id
         AND attempt.attempt_id = terminal.attempt_id
         AND attempt.provider_id = terminal.provider_id
         AND attempt.provider_process_generation_id =
             terminal.provider_process_generation_id
         AND attempt.session_epoch = terminal.origin_session_epoch
        WHERE terminal.received_count > 1
          AND attempt.state = 'acknowledged'
    ),
    'unique_requests', (
        SELECT COUNT(DISTINCT job_id)
        FROM rust_coord.inference_jobs
        WHERE created_at >= :'window_start'::timestamptz
          AND created_at < :'window_end'::timestamptz
    ),
    'go_db_mutation_writes', (
        SELECT COALESCE(SUM(mutation_count), 0)
        FROM public.coordinator_write_audit
        WHERE "binary" = 'go'
          AND bucket_started_at >= :'window_start'::timestamptz
          AND bucket_started_at < :'window_end'::timestamptz
    ),
    'go_background_writes', (
        SELECT COALESCE(SUM(background_count), 0)
        FROM public.coordinator_write_audit
        WHERE "binary" = 'go'
          AND bucket_started_at >= :'window_start'::timestamptz
          AND bucket_started_at < :'window_end'::timestamptz
    ),
    'go_financial_writes', (
        SELECT COALESCE(SUM(financial_count), 0)
        FROM public.coordinator_write_audit
        WHERE "binary" = 'go'
          AND bucket_started_at >= :'window_start'::timestamptz
          AND bucket_started_at < :'window_end'::timestamptz
    ),
    'go_ownership_epochs', (
        SELECT COUNT(*)
        FROM public.coordinator_ownership_history
        WHERE owner_binary = 'go'
          AND acquired_at >= :'window_start'::timestamptz
          AND acquired_at < :'window_end'::timestamptz
    ),
    'go_sessions', (
        SELECT COUNT(DISTINCT session_id)
        FROM public.coordinator_write_audit
        WHERE "binary" = 'go'
          AND bucket_started_at >= :'window_start'::timestamptz
          AND bucket_started_at < :'window_end'::timestamptz
    ),
    'unknown_ownership_epochs', (
        SELECT COUNT(*)
        FROM public.coordinator_ownership_history
        WHERE owner_binary = 'unknown'
          AND acquired_at >= :'window_start'::timestamptz
          AND acquired_at < :'window_end'::timestamptz
    ),
    'go_audit_trigger_states_valid', (
        SELECT COUNT(*) > 0
          AND BOOL_AND(trigger.oid IS NOT NULL AND trigger.tgenabled = 'O')
        FROM public.coordinator_audit_definition_manifest manifest
        LEFT JOIN pg_namespace namespace
          ON namespace.nspname = manifest.table_schema
        LEFT JOIN pg_class class
          ON class.relnamespace = namespace.oid
         AND class.relname = manifest.table_name
        LEFT JOIN pg_trigger trigger
          ON trigger.tgrelid = class.oid
         AND (
             namespace.nspname
             || '.'
             || class.relname
             || '.'
             || trigger.tgname
         ) = manifest.object_identity
         AND NOT trigger.tgisinternal
        WHERE manifest.object_kind = 'trigger'
    ),
    'go_audit_definition_hashes_valid', (
        SELECT COUNT(*) > 0
          AND BOOL_AND(
              COALESCE(
                  current_definition.definition_sha256 =
                  manifest.definition_sha256,
                  FALSE
              )
          )
        FROM public.coordinator_audit_definition_manifest manifest
        LEFT JOIN (
            SELECT
                'function'::text AS object_kind,
                namespace.nspname || '.' || procedure.proname || '()'
                    AS object_identity,
                encode(
                    sha256(
                        convert_to(
                            pg_get_functiondef(procedure.oid),
                            'UTF8'
                        )
                    ),
                    'hex'
                ) AS definition_sha256
            FROM pg_proc procedure
            JOIN pg_namespace namespace
              ON namespace.oid = procedure.pronamespace
            WHERE namespace.nspname = 'public'
              AND procedure.proname IN (
                  'audit_go_coordinator_write',
                  'record_coordinator_ownership_history'
              )
              AND procedure.pronargs = 0
            UNION ALL
            SELECT
                'trigger'::text,
                namespace.nspname
                    || '.'
                    || class.relname
                    || '.'
                    || trigger.tgname,
                encode(
                    sha256(
                        convert_to(
                            pg_get_triggerdef(trigger.oid, false),
                            'UTF8'
                        )
                    ),
                    'hex'
                )
            FROM pg_trigger trigger
            JOIN pg_class class ON class.oid = trigger.tgrelid
            JOIN pg_namespace namespace
              ON namespace.oid = class.relnamespace
            WHERE NOT trigger.tgisinternal
        ) current_definition
          ON current_definition.object_kind = manifest.object_kind
         AND current_definition.object_identity = manifest.object_identity
    ),
    'go_audit_owner_coverage_complete', (
        SELECT COUNT(*) > 0
          AND BOOL_AND(
              COALESCE(
                  current_owner.owner_name = manifest.expected_owner,
                  FALSE
              )
          )
        FROM public.coordinator_audit_definition_manifest manifest
        LEFT JOIN (
            SELECT
                'function'::text AS object_kind,
                namespace.nspname || '.' || procedure.proname || '()'
                    AS object_identity,
                pg_get_userbyid(procedure.proowner) AS owner_name
            FROM pg_proc procedure
            JOIN pg_namespace namespace
              ON namespace.oid = procedure.pronamespace
            WHERE namespace.nspname = 'public'
            UNION ALL
            SELECT
                'trigger'::text,
                namespace.nspname
                    || '.'
                    || class.relname
                    || '.'
                    || trigger.tgname,
                pg_get_userbyid(class.relowner)
            FROM pg_trigger trigger
            JOIN pg_class class ON class.oid = trigger.tgrelid
            JOIN pg_namespace namespace
              ON namespace.oid = class.relnamespace
            WHERE NOT trigger.tgisinternal
        ) current_owner
          ON current_owner.object_kind = manifest.object_kind
         AND current_owner.object_identity = manifest.object_identity
    ),
    'go_audit_coverage_complete', (
        NOT EXISTS (
            SELECT 1
            FROM pg_class class
            JOIN pg_namespace namespace ON namespace.oid = class.relnamespace
            WHERE namespace.nspname IN ('public', 'rust_coord')
              AND class.relkind IN ('r', 'p')
              AND NOT (
                  namespace.nspname = 'public'
                  AND class.relname IN (
                      'coordinator_write_audit',
                      'coordinator_audit_definition_manifest',
                      'schema_migration_versions'
                  )
              )
              AND (
                  SELECT COUNT(*)
                  FROM pg_trigger trigger
                  WHERE trigger.tgrelid = class.oid
                    AND NOT trigger.tgisinternal
                    AND trigger.tgname LIKE 'audit_go_write_%'
                    AND trigger.tgfoid =
                        'public.audit_go_coordinator_write()'::regprocedure
              ) <> 1
        )
        AND EXISTS (
            SELECT 1
            FROM public.coordinator_audit_definition_manifest manifest
            WHERE manifest.object_kind = 'trigger'
              AND manifest.table_schema = 'public'
              AND manifest.table_name = 'coordinator_ownership_history'
        )
        AND EXISTS (
            SELECT 1
            FROM public.coordinator_audit_definition_manifest manifest
            WHERE manifest.object_identity =
                'public.coordinator_ownership.record_coordinator_ownership_history'
        )
    ),
    'rollback_unresolved', (
        (SELECT COUNT(*) FROM rust_coord.inference_jobs
         WHERE state NOT IN ('settled','released','settled_reviewed','released_reviewed')
            OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
        + (SELECT COUNT(*) FROM rust_coord.inference_attempts
           WHERE state NOT IN ('aborted','acknowledged')
              OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
        + (SELECT COUNT(*) FROM rust_coord.provider_terminals
           WHERE status NOT IN (
              'settled','released','settled_reviewed','released_reviewed',
              'duplicate','late','rejected'
           )
              OR (conflict AND status NOT IN ('settled_reviewed','released_reviewed'))
              OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
        + (SELECT COUNT(*) FROM rust_coord.financial_operations
           WHERE status NOT IN ('applied','released','failed')
              OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
        + (SELECT COUNT(*) FROM rust_coord.external_events
           WHERE status NOT IN ('applied','rejected','ignored','failed')
              OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
        + (SELECT COUNT(*) FROM rust_coord.outbox
           WHERE status NOT IN ('delivered','failed','cancelled')
              OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
        + (SELECT COUNT(*) FROM rust_coord.fee_allocations
           WHERE status NOT IN ('projected','cancelled')
              OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
        + (SELECT COUNT(*) FROM rust_coord.fee_projection_checkpoints
           WHERE status <> 'idle'
              OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
        + (SELECT COUNT(*) FROM rust_coord.mdm_command_expectations
           WHERE status = 'pending')
        + (SELECT COUNT(*) FROM rust_coord.telemetry_events
           WHERE status NOT IN ('delivered','dropped')
              OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
    )
)::text;
ROLLBACK;

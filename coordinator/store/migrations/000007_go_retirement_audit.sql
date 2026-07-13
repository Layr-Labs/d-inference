CREATE TABLE public.coordinator_write_audit (
    bucket_started_at TIMESTAMPTZ NOT NULL,
    "binary" TEXT NOT NULL CHECK ("binary" IN ('go')),
    session_id TEXT NOT NULL CHECK (session_id <> ''),
    table_schema TEXT NOT NULL CHECK (table_schema <> ''),
    table_name TEXT NOT NULL CHECK (table_name <> ''),
    operation TEXT NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE','TRUNCATE')),
    mutation_count BIGINT NOT NULL DEFAULT 0 CHECK (mutation_count >= 0),
    background_count BIGINT NOT NULL DEFAULT 0 CHECK (background_count >= 0),
    financial_count BIGINT NOT NULL DEFAULT 0 CHECK (financial_count >= 0),
    PRIMARY KEY (
        bucket_started_at,
        "binary",
        session_id,
        table_schema,
        table_name,
        operation
    )
);

CREATE TABLE public.coordinator_ownership_history (
    epoch BIGINT PRIMARY KEY CHECK (epoch > 0),
    owner_id TEXT NOT NULL CHECK (owner_id <> ''),
    owner_binary TEXT NOT NULL CHECK (owner_binary IN ('go','rust','unknown')),
    acquired_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE public.coordinator_audit_definition_manifest (
    object_kind TEXT NOT NULL CHECK (object_kind IN ('function','trigger')),
    object_identity TEXT PRIMARY KEY CHECK (object_identity <> ''),
    table_schema TEXT,
    table_name TEXT,
    expected_owner TEXT NOT NULL CHECK (expected_owner <> ''),
    definition_sha256 TEXT NOT NULL CHECK (
        definition_sha256 ~ '^[0-9a-f]{64}$'
    ),
    CHECK (
        (object_kind = 'function' AND table_schema IS NULL AND table_name IS NULL)
        OR
        (object_kind = 'trigger' AND table_schema IS NOT NULL AND table_name IS NOT NULL)
    )
);

CREATE OR REPLACE FUNCTION public.audit_go_coordinator_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    app_name TEXT := current_setting('application_name', true);
    session_value TEXT;
    bucket_value TIMESTAMPTZ;
    is_background BIGINT;
    is_financial BIGINT;
BEGIN
    IF app_name NOT LIKE 'darkbloom-go-coordinator:%' THEN
        RETURN NULL;
    END IF;
    session_value := substring(app_name FROM length('darkbloom-go-coordinator:') + 1);
    IF session_value = '' THEN
        RAISE EXCEPTION 'Go coordinator audit session id is empty';
    END IF;
    bucket_value := date_bin(
        INTERVAL '5 minutes',
        statement_timestamp(),
        TIMESTAMPTZ '2000-01-01 00:00:00+00'
    );
    is_background := CASE
        WHEN TG_TABLE_NAME ~ '(job|event|outbox|telemetry|command|checkpoint|queue)'
        THEN 1 ELSE 0
    END;
    is_financial := CASE
        WHEN TG_TABLE_NAME ~ '(balance|earning|payment|payout|withdraw|deposit|ledger|fee|reservation|stripe|referral)'
        THEN 1 ELSE 0
    END;
    INSERT INTO public.coordinator_write_audit (
        bucket_started_at,
        "binary",
        session_id,
        table_schema,
        table_name,
        operation,
        mutation_count,
        background_count,
        financial_count
    )
    VALUES (
        bucket_value,
        'go',
        session_value,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        TG_OP,
        1,
        is_background,
        is_financial
    )
    ON CONFLICT (
        bucket_started_at,
        "binary",
        session_id,
        table_schema,
        table_name,
        operation
    ) DO UPDATE SET
        mutation_count = coordinator_write_audit.mutation_count + 1,
        background_count = coordinator_write_audit.background_count + EXCLUDED.background_count,
        financial_count = coordinator_write_audit.financial_count + EXCLUDED.financial_count;
    RETURN NULL;
END
$$;

DO $$
DECLARE
    relation RECORD;
    trigger_name TEXT;
BEGIN
    FOR relation IN
        SELECT namespace.nspname AS schema_name, class.relname AS table_name
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
    LOOP
        trigger_name := 'audit_go_write_' || substr(
            md5(relation.schema_name || '.' || relation.table_name),
            1,
            16
        );
        EXECUTE format(
            'CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON %I.%I FOR EACH STATEMENT EXECUTE FUNCTION public.audit_go_coordinator_write()',
            trigger_name,
            relation.schema_name,
            relation.table_name
        );
    END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION public.record_coordinator_ownership_history()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF NEW.owner_id = '' THEN
        RETURN NEW;
    END IF;
    INSERT INTO public.coordinator_ownership_history (
        epoch,
        owner_id,
        owner_binary,
        acquired_at
    )
    VALUES (
        NEW.epoch,
        NEW.owner_id,
        CASE
            WHEN NEW.owner_id LIKE 'go:%' THEN 'go'
            WHEN NEW.owner_id LIKE 'rust:%' THEN 'rust'
            ELSE 'unknown'
        END,
        NEW.acquired_at
    )
    ON CONFLICT (epoch) DO NOTHING;
    RETURN NEW;
END
$$;

CREATE TRIGGER record_coordinator_ownership_history
AFTER INSERT OR UPDATE OF epoch, owner_id, acquired_at
ON public.coordinator_ownership
FOR EACH ROW
EXECUTE FUNCTION public.record_coordinator_ownership_history();

INSERT INTO public.coordinator_audit_definition_manifest (
    object_kind,
    object_identity,
    expected_owner,
    definition_sha256
)
SELECT
    'function',
    namespace.nspname || '.' || procedure.proname || '()',
    pg_get_userbyid(procedure.proowner),
    encode(
        sha256(convert_to(pg_get_functiondef(procedure.oid), 'UTF8')),
        'hex'
    )
FROM pg_proc procedure
JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
WHERE namespace.nspname = 'public'
  AND procedure.proname IN (
      'audit_go_coordinator_write',
      'record_coordinator_ownership_history'
  )
  AND procedure.pronargs = 0;

INSERT INTO public.coordinator_audit_definition_manifest (
    object_kind,
    object_identity,
    table_schema,
    table_name,
    expected_owner,
    definition_sha256
)
SELECT
    'trigger',
    namespace.nspname || '.' || class.relname || '.' || trigger.tgname,
    namespace.nspname,
    class.relname,
    pg_get_userbyid(class.relowner),
    encode(
        sha256(convert_to(pg_get_triggerdef(trigger.oid, false), 'UTF8')),
        'hex'
    )
FROM pg_trigger trigger
JOIN pg_class class ON class.oid = trigger.tgrelid
JOIN pg_namespace namespace ON namespace.oid = class.relnamespace
WHERE NOT trigger.tgisinternal
  AND (
      trigger.tgname LIKE 'audit_go_write_%'
      OR trigger.tgname = 'record_coordinator_ownership_history'
  );

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON public.coordinator_audit_definition_manifest
FROM PUBLIC;

INSERT INTO rust_coord.schema_versions (
    version,
    minimum_public_schema_version,
    maximum_public_schema_version
)
VALUES (5, 7, 7);

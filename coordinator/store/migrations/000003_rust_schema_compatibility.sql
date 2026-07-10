-- Establish the additive Rust coordinator namespace and its compatibility
-- catalog. Rust-owned job tables land in a later migration.

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'rust_coord')
       AND (
            EXISTS (
                SELECT 1
                FROM pg_namespace namespace
                WHERE namespace.nspname = 'rust_coord'
                  AND (
                    namespace.nspowner <> (
                        SELECT oid FROM pg_roles WHERE rolname = current_user
                    )
                    OR namespace.nspacl IS NOT NULL
                  )
            )
            OR to_regclass('rust_coord.schema_versions') IS NULL
            OR EXISTS (
                SELECT 1
                FROM pg_class relation
                JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
                WHERE namespace.nspname = 'rust_coord'
                  AND relation.relname <> 'schema_versions'
                  AND relation.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
            )
            OR EXISTS (
                SELECT 1
                FROM pg_proc procedure
                JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
                WHERE namespace.nspname = 'rust_coord'
            )
       ) THEN
        RAISE EXCEPTION
            'refusing to adopt pre-existing rust_coord namespace';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS rust_coord;

CREATE TABLE IF NOT EXISTS rust_coord.schema_versions (
    version BIGINT PRIMARY KEY CHECK (version > 0),
    minimum_public_schema_version BIGINT NOT NULL
        CHECK (minimum_public_schema_version > 0),
    maximum_public_schema_version BIGINT NOT NULL
        CHECK (maximum_public_schema_version >= minimum_public_schema_version),
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO rust_coord.schema_versions (
    version,
    minimum_public_schema_version,
    maximum_public_schema_version
)
VALUES (1, 3, 3)
ON CONFLICT (version) DO NOTHING;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM rust_coord.schema_versions
        WHERE version = 1
          AND minimum_public_schema_version = 3
          AND maximum_public_schema_version = 3
    ) THEN
        RAISE EXCEPTION
            'rust_coord schema version 1 compatibility metadata is incompatible';
    END IF;
END $$;

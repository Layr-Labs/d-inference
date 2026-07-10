use std::{
    future::Future,
    panic::{AssertUnwindSafe, resume_unwind},
};

use sqlx::{Connection, PgConnection};
use url::Url;
use uuid::Uuid;

pub const TEMP_DATABASE_PREFIX: &str = "darkbloom_rs_test_";

pub async fn with_isolated_database<Test, TestFuture>(test: Test)
where
    Test: FnOnce(String) -> TestFuture,
    TestFuture: Future<Output = ()> + Send + 'static,
{
    let Some(base_url) = database_url() else {
        skip_without_postgres();
        return;
    };
    if !database_creation_available(&base_url).await {
        if is_ci() {
            panic!("DARKBLOOM_TEST_DATABASE_URL role requires CREATEDB in CI");
        }
        eprintln!(
            "skipping real PostgreSQL integration test: the DARKBLOOM_TEST_DATABASE_URL role lacks CREATEDB; shared database was not modified"
        );
        return;
    }
    let before = shared_database_snapshot(&base_url).await;
    let Some(database) = TemporaryDatabase::create(base_url.clone()).await else {
        return;
    };
    let test_url = database.test_url.clone();
    let outcome = tokio::spawn(AssertUnwindSafe(test(test_url))).await;
    let cleanup = database.drop_database().await;
    let after = shared_database_snapshot(&base_url).await;

    if let Err(error) = &cleanup {
        eprintln!("temporary PostgreSQL database cleanup failed: {error}");
    }
    if before != after {
        eprintln!(
            "shared DARKBLOOM_TEST_DATABASE_URL schema changed:\nbefore={before:#?}\nafter={after:#?}"
        );
    }

    match outcome {
        Ok(()) => {
            cleanup.expect("drop temporary PostgreSQL test database");
            assert_eq!(
                before, after,
                "Rust PostgreSQL test changed the shared database schema or migration metadata"
            );
        }
        Err(error) if error.is_panic() => resume_unwind(error.into_panic()),
        Err(error) => panic!("isolated PostgreSQL test task was cancelled: {error}"),
    }
}

struct TemporaryDatabase {
    base_url: String,
    test_url: String,
    name: String,
}

impl TemporaryDatabase {
    async fn create(base_url: String) -> Option<Self> {
        let name = format!("{TEMP_DATABASE_PREFIX}{}", Uuid::new_v4().simple());
        let test_url = database_url_with_name(&base_url, &name)
            .unwrap_or_else(|error| panic!("invalid DARKBLOOM_TEST_DATABASE_URL: {error}"));
        let mut connection = PgConnection::connect(&base_url)
            .await
            .expect("connect shared PostgreSQL database to create isolated test database");
        let create_sql = format!("CREATE DATABASE {}", quote_identifier(&name));
        // `name` is generated from a UUID and identifier-quoted above.
        let create_result = sqlx::query(sqlx::AssertSqlSafe(create_sql))
            .execute(&mut connection)
            .await;
        connection
            .close()
            .await
            .expect("close temporary database creator connection");

        match create_result {
            Ok(_) => Some(Self {
                base_url,
                test_url,
                name,
            }),
            Err(error) if is_insufficient_privilege(&error) && !is_ci() => {
                eprintln!(
                    "skipping real PostgreSQL integration test: the DARKBLOOM_TEST_DATABASE_URL role lacks CREATEDB; shared database was not modified"
                );
                None
            }
            Err(error) => {
                panic!("create isolated PostgreSQL test database: {error}");
            }
        }
    }

    async fn drop_database(self) -> Result<(), String> {
        let mut connection = PgConnection::connect(&self.base_url)
            .await
            .map_err(|error| format!("connect cleanup database: {error}"))?;
        let drop_sql = format!(
            "DROP DATABASE IF EXISTS {} WITH (FORCE)",
            quote_identifier(&self.name)
        );
        // `self.name` is the same generated and identifier-quoted UUID name.
        let drop_result = sqlx::query(sqlx::AssertSqlSafe(drop_sql))
            .execute(&mut connection)
            .await
            .map(|_| ())
            .map_err(|error| format!("drop {}: {error}", self.name));
        let close_result = connection
            .close()
            .await
            .map_err(|error| format!("close cleanup connection: {error}"));
        drop_result.and(close_result)
    }
}

fn database_url() -> Option<String> {
    std::env::var("DARKBLOOM_TEST_DATABASE_URL")
        .ok()
        .filter(|value| !value.trim().is_empty())
}

fn database_url_with_name(base_url: &str, database_name: &str) -> Result<String, String> {
    let mut parsed = Url::parse(base_url).map_err(|error| error.to_string())?;
    if parsed.scheme() != "postgres" && parsed.scheme() != "postgresql" {
        return Err(format!(
            "unsupported URL scheme {:?}; expected postgres or postgresql",
            parsed.scheme()
        ));
    }
    parsed.set_path(&format!("/{database_name}"));
    Ok(parsed.into())
}

fn quote_identifier(identifier: &str) -> String {
    format!("\"{}\"", identifier.replace('"', "\"\""))
}

fn is_insufficient_privilege(error: &sqlx::Error) -> bool {
    match error {
        sqlx::Error::Database(error) => error.code().as_deref() == Some("42501"),
        _ => false,
    }
}

fn is_ci() -> bool {
    std::env::var("CI").as_deref() == Ok("true")
}

async fn database_creation_available(url: &str) -> bool {
    let mut connection = PgConnection::connect(url)
        .await
        .expect("connect shared PostgreSQL database to inspect CREATEDB");
    let available: bool = sqlx::query_scalar(
        "SELECT rolcreatedb OR rolsuper FROM pg_roles WHERE rolname = current_user",
    )
    .fetch_one(&mut connection)
    .await
    .expect("inspect PostgreSQL CREATEDB capability");
    connection
        .close()
        .await
        .expect("close PostgreSQL capability connection");
    available
}

fn skip_without_postgres() {
    assert!(!is_ci(), "DARKBLOOM_TEST_DATABASE_URL is required in CI");
    eprintln!("DARKBLOOM_TEST_DATABASE_URL is unset; skipping real PostgreSQL integration test");
}

#[derive(Debug, Eq, PartialEq)]
struct SharedDatabaseSnapshot {
    schema_objects: String,
    migration_rows: Option<String>,
}

async fn shared_database_snapshot(url: &str) -> SharedDatabaseSnapshot {
    let mut connection = PgConnection::connect(url)
        .await
        .expect("connect shared PostgreSQL database for read-only schema snapshot");
    let schema_objects = sqlx::query_scalar::<_, String>(
        r#"
        WITH user_schemas AS (
            SELECT oid, nspname
            FROM pg_namespace
            WHERE nspname NOT IN ('pg_catalog', 'information_schema')
              AND nspname NOT LIKE 'pg_toast%'
              AND nspname NOT LIKE 'pg_temp_%'
        ),
        objects AS (
            SELECT
                'schema'::TEXT AS kind,
                schemas.nspname::TEXT AS schema_name,
                ''::TEXT AS object_name,
                ''::TEXT AS detail
            FROM user_schemas AS schemas
            UNION ALL
            SELECT
                'relation',
                schemas.nspname,
                relations.relname,
                relations.relkind::TEXT
            FROM pg_class AS relations
            JOIN user_schemas AS schemas ON schemas.oid = relations.relnamespace
            UNION ALL
            SELECT
                'column',
                schemas.nspname,
                relations.relname || '.' || attributes.attname,
                format_type(attributes.atttypid, attributes.atttypmod)
                    || ':' || attributes.attnotnull::TEXT
                    || ':' || COALESCE(pg_get_expr(defaults.adbin, defaults.adrelid), '')
            FROM pg_attribute AS attributes
            JOIN pg_class AS relations ON relations.oid = attributes.attrelid
            JOIN user_schemas AS schemas ON schemas.oid = relations.relnamespace
            LEFT JOIN pg_attrdef AS defaults
                ON defaults.adrelid = attributes.attrelid
               AND defaults.adnum = attributes.attnum
            WHERE attributes.attnum > 0 AND NOT attributes.attisdropped
            UNION ALL
            SELECT
                'constraint',
                schemas.nspname,
                relations.relname || '.' || constraints.conname,
                pg_get_constraintdef(constraints.oid, TRUE)
            FROM pg_constraint AS constraints
            JOIN pg_class AS relations ON relations.oid = constraints.conrelid
            JOIN user_schemas AS schemas ON schemas.oid = relations.relnamespace
            UNION ALL
            SELECT
                'index',
                schemas.nspname,
                indexes.relname,
                pg_get_indexdef(indexes.oid)
            FROM pg_index
            JOIN pg_class AS indexes ON indexes.oid = pg_index.indexrelid
            JOIN user_schemas AS schemas ON schemas.oid = indexes.relnamespace
        )
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_array(kind, schema_name, object_name, detail)
                ORDER BY kind, schema_name, object_name, detail
            ),
            '[]'::JSONB
        )::TEXT
        FROM objects
        "#,
    )
    .fetch_one(&mut connection)
    .await
    .expect("snapshot shared PostgreSQL schema");
    let migration_table: Option<String> =
        sqlx::query_scalar("SELECT to_regclass('public.schema_migration_versions')::TEXT")
            .fetch_one(&mut connection)
            .await
            .expect("inspect shared migration metadata table");
    let migration_rows = match migration_table {
        Some(_) => Some(
            sqlx::query_scalar::<_, String>(
                r#"
                SELECT COALESCE(
                    jsonb_agg(to_jsonb(versions) ORDER BY to_jsonb(versions)::TEXT),
                    '[]'::JSONB
                )::TEXT
                FROM public.schema_migration_versions AS versions
                "#,
            )
            .fetch_one(&mut connection)
            .await
            .expect("snapshot shared migration metadata"),
        ),
        None => None,
    };
    connection
        .close()
        .await
        .expect("close shared schema snapshot connection");
    SharedDatabaseSnapshot {
        schema_objects,
        migration_rows,
    }
}

#[cfg(test)]
mod tests {
    use url::Url;

    use super::database_url_with_name;

    #[test]
    fn temporary_database_url_replaces_only_database_path() {
        let isolated = database_url_with_name(
            "postgresql://user:password@db.example:5433/shared?sslmode=disable&application_name=rust-test",
            "darkbloom_rs_test_1234",
        )
        .expect("valid PostgreSQL URL");
        let parsed = Url::parse(&isolated).expect("isolated URL");

        assert_eq!(parsed.scheme(), "postgresql");
        assert_eq!(parsed.username(), "user");
        assert_eq!(parsed.password(), Some("password"));
        assert_eq!(parsed.host_str(), Some("db.example"));
        assert_eq!(parsed.port(), Some(5433));
        assert_eq!(parsed.path(), "/darkbloom_rs_test_1234");
        assert_eq!(
            parsed.query(),
            Some("sslmode=disable&application_name=rust-test")
        );
    }
}

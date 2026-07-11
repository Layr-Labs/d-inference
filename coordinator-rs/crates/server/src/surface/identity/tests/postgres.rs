use std::{
    future::Future,
    panic::{AssertUnwindSafe, resume_unwind},
    time::Duration,
};

use axum::http::{HeaderMap, HeaderValue, Method, StatusCode, header};
use serde_json::{Value, json};
use sqlx::{Connection as _, PgConnection, PgPool};
use url::Url;
use uuid::Uuid;

use super::{
    super::{
        AuthRequirement, IdentityState, IdentitySurfaceConfig, MutationAuthority, hash_secret,
        router,
    },
    support::{JwtFixture, call},
};

const LEGACY_SCHEMA: &str =
    include_str!("../../../../../../../coordinator/store/migrations/000001_legacy_schema.sql");
const OWNER_ID: &str = "identity-test-owner";
const OWNER_EPOCH: i64 = 7;
const TEMP_DATABASE_PREFIX: &str = "darkbloom_identity_test_";

#[tokio::test]
async fn real_postgres_axum_surface_enforces_auth_concurrency_ownership_and_device_replay() {
    with_isolated_database(|database_url| async move {
        let pool = PgPool::connect(&database_url)
            .await
            .expect("connect isolated identity database");
        sqlx::raw_sql(LEGACY_SCHEMA)
            .execute(&pool)
            .await
            .expect("apply real legacy public schema");
        sqlx::query(
            r#"
            INSERT INTO public.coordinator_ownership (singleton, epoch, owner_id)
            VALUES (TRUE, $1, $2)
            "#,
        )
        .bind(OWNER_EPOCH)
        .bind(OWNER_ID)
        .execute(&pool)
        .await
        .expect("seed coordinator ownership");

        let jwt = JwtFixture::start().await;
        let state = IdentityState::builder(
            pool.clone(),
            MutationAuthority::new(OWNER_ID, OWNER_EPOCH).expect("valid test authority"),
            jwt.verifier(),
        )
        .config(IdentitySurfaceConfig {
            operation_timeout: Duration::from_secs(3),
            console_url: "https://console.test".into(),
            latest_provider_version: "0.9.0".into(),
            minimum_provider_version: "0.8.0".into(),
            heartbeat_timeout: Duration::from_secs(90),
            challenge_max_age: Duration::from_secs(6 * 60),
            maximum_body_bytes: 32 * 1024,
        })
        .build()
        .expect("build identity state");
        let app = router(state.clone());
        let alice = jwt.valid_token("did:privy:alice");
        let bob = jwt.valid_token("did:privy:bob");

        let (status, _) = call(&app, Method::GET, "/v1/keys", None, None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);

        let (status, created) = call(
            &app,
            Method::POST,
            "/v1/keys",
            Some(&alice),
            Some(json!({
                "name": "primary",
                "limit_usd": 12.5,
                "limit_reset": "monthly",
                "rpm_limit": 40,
                "allowed_models": ["private-model"]
            })),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{created}");
        let raw_key = string_at(&created, "/key");
        let key_id = string_at(&created, "/data/id");
        assert!(raw_key.starts_with("sk-db-"));

        let persisted_secret: Option<String> =
            sqlx::query_scalar("SELECT key_hash FROM public.api_keys WHERE id = $1")
                .bind(&key_id)
                .fetch_optional(&pool)
                .await
                .expect("read persisted API key");
        assert_eq!(
            persisted_secret.as_deref(),
            Some(hash_secret(&raw_key).as_str())
        );
        assert_ne!(persisted_secret.as_deref(), Some(raw_key.as_str()));

        let (status, listed) = call(&app, Method::GET, "/v1/keys", Some(&alice), None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(listed["data"].as_array().map(Vec::len), Some(1));
        assert!(
            !listed.to_string().contains(&raw_key),
            "list response disclosed the raw key"
        );

        let (status, _) = call(
            &app,
            Method::GET,
            &format!("/v1/keys/{key_id}"),
            Some(&bob),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::NOT_FOUND);

        let (status, patched) = call(
            &app,
            Method::PATCH,
            &format!("/v1/keys/{key_id}"),
            Some(&alice),
            Some(json!({
                "name": "renamed",
                "limit_usd": null,
                "allowed_models": null,
                "self_route_only": true
            })),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{patched}");
        assert_eq!(patched["name"], "renamed");
        assert_eq!(patched["self_route_only"], true);
        assert!(patched.get("limit_usd").is_none());
        assert!(patched.get("allowed_models").is_none());

        let (status, calling_key) = call(&app, Method::GET, "/v1/key", Some(&raw_key), None).await;
        assert_eq!(status, StatusCode::OK, "{calling_key}");
        assert_eq!(calling_key["id"], key_id);

        let (status, _) = call(&app, Method::GET, "/v1/keys", Some(&raw_key), None).await;
        assert_eq!(
            status,
            StatusCode::FORBIDDEN,
            "an API key was allowed to manage keys"
        );

        exercise_legacy_key_endpoints(&app, &alice).await;
        exercise_account_endpoints(&app, &pool, &alice, &bob).await;

        let rotation_uri = format!("/v1/keys/{key_id}/rotate");
        let first_rotation = call(&app, Method::POST, &rotation_uri, Some(&alice), None);
        let second_rotation = call(&app, Method::POST, &rotation_uri, Some(&alice), None);
        let (first, second) = tokio::join!(first_rotation, second_rotation);
        let rotations = [first, second];
        assert_eq!(
            rotations
                .iter()
                .filter(|(status, _)| *status == StatusCode::OK)
                .count(),
            1,
            "concurrent rotation minted more than one successor: {rotations:?}"
        );
        assert_eq!(
            rotations
                .iter()
                .filter(|(status, _)| *status == StatusCode::NOT_FOUND)
                .count(),
            1
        );
        let rotated = rotations
            .iter()
            .find(|(status, _)| *status == StatusCode::OK)
            .map(|(_, body)| body)
            .expect("successful rotation body");
        let rotated_raw = string_at(rotated, "/key");
        let rotated_id = string_at(rotated, "/data/id");
        assert_ne!(rotated_raw, raw_key);
        assert_ne!(rotated_id, key_id);

        let (status, _) = call(&app, Method::GET, "/v1/key", Some(&raw_key), None).await;
        assert_eq!(
            status,
            StatusCode::UNAUTHORIZED,
            "rotation did not atomically revoke the old key"
        );
        let (status, _) = call(&app, Method::GET, "/v1/key", Some(&rotated_raw), None).await;
        assert_eq!(status, StatusCode::OK);

        exercise_device_flow(&app, &state, &pool, &alice, &bob).await;

        let (status, _) = call(
            &app,
            Method::DELETE,
            &format!("/v1/keys/{rotated_id}"),
            Some(&alice),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let (status, _) = call(&app, Method::GET, "/v1/key", Some(&rotated_raw), None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);

        let keys_before: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM public.api_keys")
            .fetch_one(&pool)
            .await
            .expect("count keys before ownership loss");
        sqlx::query(
            "UPDATE public.coordinator_ownership SET owner_id = 'successor', epoch = epoch + 1",
        )
        .execute(&pool)
        .await
        .expect("transfer test ownership");
        let (status, _) = call(
            &app,
            Method::POST,
            "/v1/keys",
            Some(&alice),
            Some(json!({"name": "must-not-exist"})),
        )
        .await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        let keys_after: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM public.api_keys")
            .fetch_one(&pool)
            .await
            .expect("count keys after ownership loss");
        assert_eq!(keys_after, keys_before, "stale owner mutated api_keys");

        pool.close().await;
    })
    .await;
}

async fn exercise_legacy_key_endpoints(app: &axum::Router, alice: &str) {
    let (status, created) = call(app, Method::POST, "/v1/auth/keys", Some(alice), None).await;
    assert_eq!(status, StatusCode::OK, "{created}");
    let raw = string_at(&created, "/api_key");
    let (status, _) = call(
        app,
        Method::DELETE,
        "/v1/auth/keys",
        Some(alice),
        Some(json!({"key": raw})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(app, Method::GET, "/v1/key", Some(&raw), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

async fn exercise_account_endpoints(app: &axum::Router, pool: &PgPool, alice: &str, bob: &str) {
    let alice_account: String =
        sqlx::query_scalar("SELECT account_id FROM public.users WHERE privy_user_id = $1")
            .bind("did:privy:alice")
            .fetch_one(pool)
            .await
            .expect("Alice account");
    sqlx::query(
        r#"
        INSERT INTO public.providers (
            id, hardware, models, backend, account_id, serial_number,
            trust_level, runtime_verified, attestation_result, mda_cert_chain, last_seen
        )
        VALUES
            (
                'provider-offline', '{}'::JSONB, '[]'::JSONB, 'mlx',
                $1, 'SERIAL-ALICE', 'hardware', TRUE,
                '{
                    "SecureEnclaveAvailable": true,
                    "SIPEnabled": true,
                    "SecureBootEnabled": true,
                    "AuthenticatedRootEnabled": true,
                    "SystemVolumeHash": "volume-hash"
                }'::JSONB,
                '["Y2VydA=="]'::JSONB,
                NOW() - INTERVAL '1 hour'
            ),
            (
                'provider-offline-old', '{}'::JSONB, '[]'::JSONB, 'mlx',
                $1, 'SERIAL-ALICE', 'hardware', TRUE, NULL, NULL,
                NOW() - INTERVAL '2 hours'
            )
        "#,
    )
    .bind(&alice_account)
    .execute(pool)
    .await
    .expect("seed Alice provider");

    let (status, providers) = call(app, Method::GET, "/v1/me/providers", Some(alice), None).await;
    assert_eq!(status, StatusCode::OK, "{providers}");
    assert_eq!(providers["providers"].as_array().map(Vec::len), Some(1));
    assert_eq!(providers["providers"][0]["secure_enclave"], true);
    assert_eq!(providers["providers"][0]["sip_enabled"], true);
    assert_eq!(providers["providers"][0]["secure_boot_enabled"], true);
    assert_eq!(
        providers["providers"][0]["authenticated_root_enabled"],
        true
    );
    assert_eq!(
        providers["providers"][0]["system_volume_hash"],
        "volume-hash"
    );
    assert_eq!(
        providers["providers"][0]["mda_cert_chain_b64"],
        json!(["Y2VydA=="])
    );

    let (status, summary) = call(app, Method::GET, "/v1/me/summary", Some(alice), None).await;
    assert_eq!(status, StatusCode::OK, "{summary}");
    assert_eq!(summary["counts"]["total"], 1);
    assert_eq!(summary["counts"]["offline"], 1);

    sqlx::query(
        r#"
        INSERT INTO public.providers (
            id, hardware, models, backend, account_id, serial_number,
            trust_level, runtime_verified, last_seen
        )
        VALUES (
            'provider-untrusted', '{}'::JSONB, '[]'::JSONB, 'mlx',
            $1, 'SERIAL-UNTRUSTED', 'untrusted', FALSE, NOW()
        )
        "#,
    )
    .bind(&alice_account)
    .execute(pool)
    .await
    .expect("seed fresh untrusted provider");
    let (status, providers) = call(app, Method::GET, "/v1/me/providers", Some(alice), None).await;
    assert_eq!(status, StatusCode::OK, "{providers}");
    let untrusted = providers["providers"]
        .as_array()
        .and_then(|providers| {
            providers
                .iter()
                .find(|provider| provider["id"] == "provider-untrusted")
        })
        .expect("untrusted provider response");
    assert_eq!(untrusted["status"], "untrusted");
    assert_eq!(
        untrusted["online"], false,
        "untrusted providers must not be reported as online"
    );

    let (status, models) = call(
        app,
        Method::GET,
        "/v1/me/self-route-models",
        Some(alice),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{models}");
    assert_eq!(models["models"], json!([]));

    let (status, _) = call(
        app,
        Method::DELETE,
        "/v1/me/providers/SERIAL-ALICE",
        Some(bob),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let still_present: bool =
        sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM public.providers WHERE id = $1)")
            .bind("provider-offline")
            .fetch_one(pool)
            .await
            .expect("check provider after foreign delete");
    assert!(still_present);

    let (status, deleted) = call(
        app,
        Method::DELETE,
        "/v1/me/providers/SERIAL-ALICE",
        Some(alice),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{deleted}");
    assert_eq!(
        deleted["rows_removed"], 2,
        "all historical rows for the owned serial must be removed"
    );

    sqlx::raw_sql(
        r#"
        INSERT INTO public.model_registry (id, display_name)
        VALUES
            ('private-build', 'Private Build'),
            ('hashless-build', 'Hashless Build');
        INSERT INTO public.model_versions (
            model_id, version, r2_prefix, aggregate_sha256, total_size_bytes, file_count
        )
        VALUES
            ('private-build', 'v1', 'private/v1', 'expected-hash', 1, 1),
            ('hashless-build', 'v1', 'hashless/v1', 'catalog-hash', 1, 1);
        INSERT INTO public.model_active_versions (model_id, model_version_id)
        SELECT model_id, id
        FROM public.model_versions
        WHERE model_id IN ('private-build', 'hashless-build') AND version = 'v1';
        INSERT INTO public.model_aliases (alias_id, display_name, desired_build, active)
        VALUES ('private-alias', 'Private Alias', 'private-build', TRUE);
        "#,
    )
    .execute(pool)
    .await
    .expect("seed alias-aware model catalog");
    sqlx::query(
        r#"
        INSERT INTO public.providers (
            id, hardware, models, backend, account_id, serial_number,
            trust_level, runtime_verified, last_challenge_verified, last_seen
        )
        VALUES (
            'provider-online', '{}'::JSONB,
            '[{
                "id": "private-build",
                "weight_hash": "expected-hash",
                "template_render_ok": true
            }, {
                "id": "hashless-build",
                "template_render_ok": true
            }]'::JSONB,
            'mlx', $1, 'SERIAL-ONLINE', 'hardware', TRUE, NOW(), NOW()
        )
        "#,
    )
    .bind(&alice_account)
    .execute(pool)
    .await
    .expect("seed eligible self-route provider");
    let (status, models) = call(
        app,
        Method::GET,
        "/v1/me/self-route-models",
        Some(alice),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{models}");
    assert_eq!(
        models["models"],
        json!(["hashless-build", "private-alias"]),
        "self-route picker hid a hashless catalog build or exposed an aliased build"
    );
}

async fn exercise_device_flow(
    app: &axum::Router,
    state: &IdentityState,
    pool: &PgPool,
    alice: &str,
    bob: &str,
) {
    let (status, code) = call(app, Method::POST, "/v1/device/code", None, None).await;
    assert_eq!(status, StatusCode::OK, "{code}");
    let device_code = string_at(&code, "/device_code");
    let user_code = string_at(&code, "/user_code");

    let (status, pending) = call(
        app,
        Method::POST,
        "/v1/device/token",
        None,
        Some(json!({"device_code": device_code})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{pending}");
    assert_eq!(pending["status"], "authorization_pending");

    let (status, approved) = call(
        app,
        Method::POST,
        "/v1/device/approve",
        Some(alice),
        Some(json!({"user_code": user_code})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{approved}");

    let (status, _) = call(
        app,
        Method::POST,
        "/v1/device/approve",
        Some(bob),
        Some(json!({"user_code": user_code})),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::CONFLICT,
        "a second account replaced the device-code owner"
    );

    let (status, approved) = call(
        app,
        Method::POST,
        "/v1/device/approve",
        Some(alice),
        Some(json!({"user_code": user_code})),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "same-account approval was not idempotent: {approved}"
    );

    let first_poll = call(
        app,
        Method::POST,
        "/v1/device/token",
        None,
        Some(json!({"device_code": device_code})),
    );
    let second_poll = call(
        app,
        Method::POST,
        "/v1/device/token",
        None,
        Some(json!({"device_code": device_code})),
    );
    let (first, second) = tokio::join!(first_poll, second_poll);
    let polls = [first, second];
    assert_eq!(
        polls
            .iter()
            .filter(|(status, body)| {
                *status == StatusCode::OK && body["status"] == "authorized"
            })
            .count(),
        1,
        "device polling replay issued multiple tokens: {polls:?}"
    );
    assert_eq!(
        polls
            .iter()
            .filter(|(status, _)| *status == StatusCode::GONE)
            .count(),
        1
    );
    let authorized = polls
        .iter()
        .find(|(status, body)| *status == StatusCode::OK && body["status"] == "authorized")
        .map(|(_, body)| body)
        .expect("authorized device response");
    let provider_token = string_at(authorized, "/token");
    let account_id = string_at(authorized, "/account_id");

    let mut headers = HeaderMap::new();
    headers.insert(
        header::AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer {provider_token}"))
            .expect("provider token authorization header"),
    );
    let provider_context = state
        .auth()
        .authenticate(&headers, AuthRequirement::ProviderToken)
        .await
        .expect("authenticate issued provider token");
    assert_eq!(provider_context.account_id.as_ref(), account_id);

    let stored_hashes: Vec<String> =
        sqlx::query_scalar("SELECT token_hash FROM public.provider_tokens")
            .fetch_all(pool)
            .await
            .expect("read provider token hashes");
    assert_eq!(stored_hashes, vec![hash_secret(&provider_token)]);
    assert!(!stored_hashes.iter().any(|value| value == &provider_token));

    let (status, _) = call(
        app,
        Method::POST,
        "/v1/device/token",
        None,
        Some(json!({"device_code": device_code})),
    )
    .await;
    assert_eq!(status, StatusCode::GONE);

    let (status, expiring) = call(app, Method::POST, "/v1/device/code", None, None).await;
    assert_eq!(status, StatusCode::OK);
    let expired_device_code = string_at(&expiring, "/device_code");
    let expired_user_code = string_at(&expiring, "/user_code");
    sqlx::query(
        "UPDATE public.device_codes SET expires_at = NOW() - INTERVAL '1 second' WHERE device_code = $1",
    )
    .bind(&expired_device_code)
    .execute(pool)
    .await
    .expect("expire device code");
    let (status, _) = call(
        app,
        Method::POST,
        "/v1/device/token",
        None,
        Some(json!({"device_code": expired_device_code})),
    )
    .await;
    assert_eq!(status, StatusCode::GONE);
    let (status, _) = call(
        app,
        Method::POST,
        "/v1/device/approve",
        Some(alice),
        Some(json!({"user_code": expired_user_code})),
    )
    .await;
    assert_eq!(status, StatusCode::GONE);
}

fn string_at(value: &Value, pointer: &str) -> String {
    value
        .pointer(pointer)
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("missing string at {pointer}: {value}"))
        .to_owned()
}

async fn with_isolated_database<Test, TestFuture>(test: Test)
where
    Test: FnOnce(String) -> TestFuture,
    TestFuture: Future<Output = ()> + Send + 'static,
{
    let Some(base_url) = std::env::var("DARKBLOOM_TEST_DATABASE_URL")
        .ok()
        .filter(|value| !value.trim().is_empty())
    else {
        assert_ne!(
            std::env::var("CI").as_deref(),
            Ok("true"),
            "DARKBLOOM_TEST_DATABASE_URL is required in CI"
        );
        eprintln!("skipping identity PostgreSQL test: DARKBLOOM_TEST_DATABASE_URL is unset");
        return;
    };
    let Some(database) = TemporaryDatabase::create(base_url).await else {
        return;
    };
    let test_url = database.test_url.clone();
    let outcome = tokio::spawn(AssertUnwindSafe(test(test_url))).await;
    let cleanup = database.drop_database().await;
    match outcome {
        Ok(()) => cleanup.expect("drop isolated identity test database"),
        Err(error) if error.is_panic() => {
            if let Err(cleanup_error) = cleanup {
                eprintln!("identity database cleanup after panic failed: {cleanup_error}");
            }
            resume_unwind(error.into_panic());
        }
        Err(error) => panic!("isolated identity test was cancelled: {error}"),
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
            .expect("connect PostgreSQL test control database");
        let create_sql = format!("CREATE DATABASE {}", quote_identifier(&name));
        let result = sqlx::query(sqlx::AssertSqlSafe(create_sql))
            .execute(&mut connection)
            .await;
        connection
            .close()
            .await
            .expect("close PostgreSQL test control connection");
        match result {
            Ok(_) => Some(Self {
                base_url,
                test_url,
                name,
            }),
            Err(error) if is_insufficient_privilege(&error) && !is_ci() => {
                eprintln!(
                    "skipping identity PostgreSQL test: DARKBLOOM_TEST_DATABASE_URL role lacks CREATEDB"
                );
                None
            }
            Err(error) => panic!("create isolated identity test database: {error}"),
        }
    }

    async fn drop_database(self) -> Result<(), String> {
        let mut connection = PgConnection::connect(&self.base_url)
            .await
            .map_err(|error| format!("connect identity cleanup database: {error}"))?;
        let drop_sql = format!(
            "DROP DATABASE IF EXISTS {} WITH (FORCE)",
            quote_identifier(&self.name)
        );
        let result = sqlx::query(sqlx::AssertSqlSafe(drop_sql))
            .execute(&mut connection)
            .await
            .map(|_| ())
            .map_err(|error| format!("drop identity test database: {error}"));
        connection
            .close()
            .await
            .map_err(|error| format!("close identity cleanup connection: {error}"))?;
        result
    }
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
    error
        .as_database_error()
        .and_then(|error| error.code())
        .as_deref()
        == Some("42501")
}

fn is_ci() -> bool {
    std::env::var("CI").as_deref() == Ok("true")
}

use std::{sync::Arc, time::Duration};

use darkbloom_coordinator_protocol::v2::ProviderId as ProtocolProviderId;
use darkbloom_coordinator_server::{
    database::Database,
    ownership::CoordinatorOwnership,
    surface::{
        identity::{ApiKeyRecord, AuthContext, AuthPrincipal},
        inference::{InferenceControl, InferenceControlError},
    },
};
use sqlx::PgPool;
use uuid::Uuid;

use super::support::{seed_service_schema, with_isolated_database};

#[tokio::test]
async fn api_key_controls_are_atomic_alias_aware_revocable_and_owner_pinned() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        let owner_provider = Uuid::new_v4();
        let public_provider = Uuid::new_v4();
        seed_catalog(&pool).await;
        sqlx::query(
            r#"
            INSERT INTO public.users (account_id, privy_user_id, email)
            VALUES ('consumer', 'privy-consumer', 'consumer@example.test');
            "#,
        )
        .execute(&pool)
        .await
        .expect("consumer");
        sqlx::query(
            r#"
            INSERT INTO public.api_keys (
                key_hash, raw_prefix, owner_account_id, id, name, active,
                limit_micro_usd, rpm_limit, itpm_limit, otpm_limit,
                allowed_models, self_route_only
            ) VALUES (
                'credential-hash', 'key-', 'consumer', 'controlled-key',
                'controlled', TRUE, 5000, 1, 1000, 20,
                '["model/build"]', TRUE
            )
            "#,
        )
        .execute(&pool)
        .await
        .expect("controlled key");
        seed_provider(&pool, owner_provider, "consumer").await;
        seed_provider(&pool, public_provider, "another-account").await;

        let control = InferenceControl::new(database.clone());
        let auth = api_key_auth();
        let request = br#"{
            "model":"model",
            "messages":[{"role":"user","content":"atomic alias request"}],
            "max_tokens":10
        }"#;
        let (left, right) = tokio::join!(
            control.prepare(&auth, request),
            control.prepare(&auth, request)
        );
        let prepared = match (left, right) {
            (Ok(prepared), Err(InferenceControlError::RateLimited))
            | (Err(InferenceControlError::RateLimited), Ok(prepared)) => prepared,
            _ => panic!("RPM race did not admit exactly one request"),
        };
        assert_eq!(
            prepared.required_provider_id.map(|id| id.as_uuid()),
            Some(owner_provider)
        );
        assert_eq!(prepared.api_key_limit_micro_usd, Some(5_000));
        assert!(prepared.api_key_controlled);

        reset_window(&pool, None, Some(1), None, r#"["model/build"]"#).await;
        assert!(matches!(
            control.prepare(&auth, request).await,
            Err(InferenceControlError::RateLimited)
        ));

        reset_window(&pool, None, None, Some(5), r#"["model/build"]"#).await;
        assert!(matches!(
            control.prepare(&auth, request).await,
            Err(InferenceControlError::RateLimited)
        ));

        reset_window(&pool, None, None, None, r#"["other/model"]"#).await;
        assert!(matches!(
            control.prepare(&auth, request).await,
            Err(InferenceControlError::ModelForbidden)
        ));

        sqlx::query(
            r#"
            UPDATE public.api_keys
            SET allowed_models='["model/build"]',
                expires_at=NOW()-INTERVAL '1 second'
            WHERE id='controlled-key'
            "#,
        )
        .execute(&pool)
        .await
        .expect("expire key");
        assert!(matches!(
            control.prepare(&auth, request).await,
            Err(InferenceControlError::CredentialChanged)
        ));

        sqlx::query(
            "UPDATE public.api_keys SET expires_at=NULL, active=FALSE WHERE id='controlled-key'",
        )
        .execute(&pool)
        .await
        .expect("revoke key");
        assert!(matches!(
            control.prepare(&auth, request).await,
            Err(InferenceControlError::CredentialChanged)
        ));

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn model_price_provider_fee_and_referral_changes_only_affect_subsequent_jobs() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        let provider_id = Uuid::new_v4();
        seed_catalog(&pool).await;
        sqlx::raw_sql(
            r#"
            INSERT INTO public.users (
                account_id, privy_user_id, email, role
            ) VALUES
                ('consumer', 'privy-consumer', 'consumer@example.test', ''),
                ('referrer-a', 'privy-referrer-a', 'a@example.test', ''),
                ('referrer-b', 'privy-referrer-b', 'b@example.test', '');
            INSERT INTO public.referrers (account_id, code) VALUES
                ('referrer-a', 'REF-A'),
                ('referrer-b', 'REF-B');
            INSERT INTO public.referrals (referred_account, referrer_code)
            VALUES ('consumer', 'REF-A');
            UPDATE public.billing_runtime_settings
            SET provider_share_ppm=900000, referral_share_ppm=200000;
            "#,
        )
        .execute(&pool)
        .await
        .expect("dynamic billing controls");
        seed_provider(&pool, provider_id, "provider-account").await;
        sqlx::raw_sql(
            r#"
            INSERT INTO public.model_prices (
                account_id, model, input_price, output_price
            ) VALUES
                ('consumer', 'model/build', 1, 1),
                ('provider-account', 'model/build', 30, 40);
            "#,
        )
        .execute(&pool)
        .await
        .expect("consumer and provider prices");
        let control = InferenceControl::new(database.clone());
        let auth = privy_auth();
        let request = br#"{
            "model":"model",
            "messages":[{"role":"user","content":"dynamic control request"}],
            "max_tokens":10
        }"#;

        let first = control
            .prepare(&auth, request)
            .await
            .expect("first immutable controls");
        assert_eq!(first.catalog.input_micro_usd_per_million.as_i64(), 10);
        assert_eq!(first.catalog.output_micro_usd_per_million.as_i64(), 20);
        let (first_provider_account, first_provider_policy) = first
            .billing
            .provider_terms(ProtocolProviderId::new(*provider_id.as_bytes()))
            .expect("first provider terms");
        assert_eq!(first_provider_account.as_str(), "provider-account");
        assert_eq!(
            first_provider_policy
                .input_micro_usd_per_million
                .as_i64(),
            30
        );
        assert_eq!(
            first_provider_policy
                .output_micro_usd_per_million
                .as_i64(),
            40
        );
        assert_eq!(first.billing.policy().provider_share_ppm, 900_000);
        assert_eq!(first.billing.policy().referral_share_ppm, 200_000);
        assert_eq!(
            first
                .billing
                .policy()
                .referral_account_id
                .as_ref()
                .map(|account| account.as_str()),
            Some("referrer-a")
        );
        assert_eq!(
            first
                .billing
                .provider_account(ProtocolProviderId::new(*provider_id.as_bytes()))
                .map(|account| account.as_str()),
            Some("provider-account")
        );
        let first_price_version = first.catalog.pricing_version;

        sqlx::raw_sql(
            r#"
            UPDATE public.model_prices
            SET input_price=50, output_price=60
            WHERE account_id='platform' AND model='model/build';
            UPDATE public.model_prices
            SET input_price=70, output_price=80
            WHERE account_id='provider-account' AND model='model/build';
            UPDATE public.users
            SET platform_fee_percent=5
            WHERE account_id='consumer';
            UPDATE public.referrals
            SET referrer_code='REF-B'
            WHERE referred_account='consumer';
            "#,
        )
        .execute(&pool)
        .await
        .expect("change dynamic controls");

        let second = control
            .prepare(&auth, request)
            .await
            .expect("subsequent immutable controls");
        assert_eq!(second.catalog.input_micro_usd_per_million.as_i64(), 50);
        assert_eq!(second.catalog.output_micro_usd_per_million.as_i64(), 60);
        assert_ne!(second.catalog.pricing_version, first_price_version);
        let (_, second_provider_policy) = second
            .billing
            .provider_terms(ProtocolProviderId::new(*provider_id.as_bytes()))
            .expect("second provider terms");
        assert_eq!(
            second_provider_policy
                .input_micro_usd_per_million
                .as_i64(),
            70
        );
        assert_eq!(
            second_provider_policy
                .output_micro_usd_per_million
                .as_i64(),
            80
        );
        assert_eq!(second.billing.policy().provider_share_ppm, 950_000);
        assert_eq!(second.billing.policy().referral_share_ppm, 200_000);
        assert_eq!(
            second
                .billing
                .policy()
                .referral_account_id
                .as_ref()
                .map(|account| account.as_str()),
            Some("referrer-b")
        );

        assert_eq!(first.catalog.input_micro_usd_per_million.as_i64(), 10);
        assert_eq!(
            first_provider_policy
                .input_micro_usd_per_million
                .as_i64(),
            30
        );
        assert_eq!(first.billing.policy().provider_share_ppm, 900_000);
        assert_eq!(
            first
                .billing
                .policy()
                .referral_account_id
                .as_ref()
                .map(|account| account.as_str()),
            Some("referrer-a")
        );

        sqlx::query(
            "DELETE FROM public.model_prices WHERE account_id IN ('platform', 'provider-account') AND model='model/build'",
        )
        .execute(&pool)
        .await
        .expect("remove platform and provider prices");
        let fallback = control
            .prepare(&auth, request)
            .await
            .expect("Go-compatible fallback controls");
        assert_eq!(
            fallback.catalog.input_micro_usd_per_million.as_i64(),
            50_000
        );
        assert_eq!(
            fallback.catalog.output_micro_usd_per_million.as_i64(),
            200_000
        );
        let (_, fallback_provider_policy) = fallback
            .billing
            .provider_terms(ProtocolProviderId::new(*provider_id.as_bytes()))
            .expect("fallback provider terms");
        assert_eq!(
            fallback_provider_policy
                .input_micro_usd_per_million
                .as_i64(),
            50_000
        );
        assert_eq!(
            fallback_provider_policy
                .output_micro_usd_per_million
                .as_i64(),
            200_000
        );

        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn service_account_uses_published_platform_price_and_allocation_only() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        let provider_id = Uuid::new_v4();
        seed_catalog(&pool).await;
        seed_provider(&pool, provider_id, "provider-account").await;
        sqlx::raw_sql(
            r#"
            INSERT INTO public.users (
                account_id, privy_user_id, email, role, platform_fee_percent
            ) VALUES (
                'service-consumer', 'privy-service',
                'service@example.test', 'service', 99
            );
            INSERT INTO public.users (
                account_id, privy_user_id, email, role
            ) VALUES (
                'service-referrer', 'privy-referrer',
                'referrer@example.test', ''
            );
            INSERT INTO public.referrers (account_id, code)
            VALUES ('service-referrer', 'SERVICE-REF');
            INSERT INTO public.referrals (referred_account, referrer_code)
            VALUES ('service-consumer', 'SERVICE-REF');
            INSERT INTO public.model_prices (
                account_id, model, input_price, output_price
            ) VALUES (
                'provider-account', 'model/build', 1000000, 50000000
            );
            UPDATE public.billing_runtime_settings
            SET provider_share_ppm=100000, referral_share_ppm=900000;
            "#,
        )
        .execute(&pool)
        .await
        .expect("service billing controls");

        let auth = AuthContext {
            principal: AuthPrincipal::Privy {
                subject: Arc::from("privy-service"),
            },
            account_id: Arc::from("service-consumer"),
            credential_hash: Arc::from("service-credential"),
            email: Arc::from("service@example.test"),
            role: Arc::from("service"),
            stripe_account_status: Arc::from(""),
            api_key: None,
        };
        let prepared = InferenceControl::new(database.clone())
            .prepare(
                &auth,
                br#"{
                    "model":"model",
                    "messages":[{"role":"user","content":"wholesale request"}],
                    "max_tokens":10
                }"#,
            )
            .await
            .expect("service controls");
        let (_, provider_policy) = prepared
            .billing
            .provider_terms(ProtocolProviderId::new(*provider_id.as_bytes()))
            .expect("provider terms");

        assert_eq!(
            provider_policy.input_micro_usd_per_million.as_i64(),
            prepared.catalog.input_micro_usd_per_million.as_i64()
        );
        assert_eq!(
            provider_policy.output_micro_usd_per_million.as_i64(),
            prepared.catalog.output_micro_usd_per_million.as_i64()
        );
        assert_eq!(provider_policy.input_micro_usd_per_million.as_i64(), 10);
        assert_eq!(provider_policy.output_micro_usd_per_million.as_i64(), 20);
        assert_eq!(provider_policy.provider_share_ppm, 1_000_000);
        assert_eq!(provider_policy.referral_share_ppm, 0);
        assert!(provider_policy.referral_account_id.is_none());

        shutdown(database, ownership, pool).await;
    })
    .await;
}

async fn seed_catalog(pool: &PgPool) {
    sqlx::query(
        r#"
        INSERT INTO public.model_registry (
            id, display_name, max_context_length, max_output_length,
            capabilities, status, runtime_parameters
        ) VALUES (
            'model/build', 'Model', 4096, 512, ARRAY['text'], 'active', '{}'
        )
        "#,
    )
    .execute(pool)
    .await
    .expect("model registry");
    let version_id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO public.model_versions (
            model_id, version, r2_prefix, aggregate_sha256,
            total_size_bytes, file_count, status
        ) VALUES (
            'model/build', 'v1', 'models/v1', repeat('a', 64), 1, 1, 'ready'
        )
        RETURNING id
        "#,
    )
    .fetch_one(pool)
    .await
    .expect("model version");
    sqlx::query(
        "INSERT INTO public.model_active_versions (model_id, model_version_id) VALUES ('model/build', $1)",
    )
    .bind(version_id)
    .execute(pool)
    .await
    .expect("active model version");
    sqlx::raw_sql(
        r#"
        INSERT INTO public.model_aliases (alias_id, desired_build)
        VALUES ('model', 'model/build');
        INSERT INTO public.model_prices (
            account_id, model, input_price, output_price
        ) VALUES ('platform', 'model/build', 10, 20);
        "#,
    )
    .execute(pool)
    .await
    .expect("model alias and price");
}

async fn seed_provider(pool: &PgPool, provider_id: Uuid, account_id: &str) {
    sqlx::query(
        r#"
        INSERT INTO public.providers (
            id, hardware, models, backend, account_id, connected,
            session_id, session_epoch, trust_level, last_seen
        ) VALUES (
            $1, '{}'::JSONB, '[{"id":"model/build"}]'::JSONB, 'mlx',
            $2, TRUE, $3, 1, 'hardware', NOW()
        )
        "#,
    )
    .bind(provider_id.to_string())
    .bind(account_id)
    .bind(format!("session-{provider_id}"))
    .execute(pool)
    .await
    .expect("provider");
}

async fn reset_window(
    pool: &PgPool,
    rpm_limit: Option<i64>,
    itpm_limit: Option<i64>,
    otpm_limit: Option<i64>,
    allowed_models: &str,
) {
    sqlx::query(
        "DELETE FROM rust_coord.api_key_rate_windows WHERE credential_hash='credential-hash'",
    )
    .execute(pool)
    .await
    .expect("clear rate window");
    sqlx::query(
        r#"
        UPDATE public.api_keys
        SET rpm_limit=$1, itpm_limit=$2, otpm_limit=$3, allowed_models=$4
        WHERE id='controlled-key'
        "#,
    )
    .bind(rpm_limit)
    .bind(itpm_limit)
    .bind(otpm_limit)
    .bind(allowed_models)
    .execute(pool)
    .await
    .expect("update key controls");
}

fn api_key_auth() -> AuthContext {
    AuthContext {
        principal: AuthPrincipal::ApiKey {
            key_id: Arc::from("controlled-key"),
        },
        account_id: Arc::from("consumer"),
        credential_hash: Arc::from("credential-hash"),
        email: Arc::from("consumer@example.test"),
        role: Arc::from(""),
        stripe_account_status: Arc::from(""),
        api_key: Some(ApiKeyRecord {
            id: "controlled-key".to_owned(),
            owner_account_id: "consumer".to_owned(),
            name: "controlled".to_owned(),
            label: "key-".to_owned(),
            disabled: false,
            limit_micro_usd: Some(5_000),
            limit_reset: String::new(),
            usage_micro_usd: 0,
            rpm_limit: Some(1),
            itpm_limit: Some(1_000),
            otpm_limit: Some(20),
            allowed_models: vec!["model/build".to_owned()],
            self_route_only: true,
            expires_at: None,
            created_at: String::new(),
            last_used_at: None,
        }),
    }
}

fn privy_auth() -> AuthContext {
    AuthContext {
        principal: AuthPrincipal::Privy {
            subject: Arc::from("privy-consumer"),
        },
        account_id: Arc::from("consumer"),
        credential_hash: Arc::from("privy-credential"),
        email: Arc::from("consumer@example.test"),
        role: Arc::from(""),
        stripe_account_status: Arc::from(""),
        api_key: None,
    }
}

async fn service_database(url: &str) -> (Database, CoordinatorOwnership, PgPool) {
    seed_service_schema(url).await;
    let database = Database::connect(url, 16, Duration::from_secs(5))
        .await
        .expect("database");
    let ownership = CoordinatorOwnership::configure(&database, url, true)
        .await
        .expect("ownership");
    let pool = PgPool::connect(url).await.expect("inspection pool");
    (database, ownership, pool)
}

async fn shutdown(database: Database, ownership: CoordinatorOwnership, pool: PgPool) {
    pool.close().await;
    database
        .close(Duration::from_secs(2))
        .await
        .expect("close database");
    ownership.release().await.expect("release ownership");
}

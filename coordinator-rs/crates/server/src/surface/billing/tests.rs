use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use axum::{
    Json, Router,
    body::Body,
    extract::Path,
    http::{Request, StatusCode},
    routing::{get, post},
};
use http_body_util::BodyExt as _;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use sqlx::PgPool;
use tokio::{net::TcpListener, task::JoinHandle};
use tower::ServiceExt as _;

use crate::{database::Database, ownership::CoordinatorOwnership};

use super::{AuthenticationKind, BillingPrincipal, BillingState, StripeSettings, router};

#[allow(clippy::duplicate_mod)]
#[path = "../../../tests/postgres/support/database.rs"]
mod database;
#[allow(clippy::duplicate_mod)]
#[path = "../../../tests/postgres/support/schema_seed.rs"]
mod schema_seed;

use database::with_isolated_database;
use schema_seed::seed_service_schema;

#[tokio::test]
async fn duplicate_and_concurrent_checkout_webhooks_credit_once() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        let stripe = TestStripe::start(StripeMode::Working).await;
        let app = test.app(stripe.settings()).await;
        sqlx::raw_sql(
            r#"
            INSERT INTO public.users (account_id, privy_user_id, email)
            VALUES ('consumer', 'privy-consumer', 'consumer@example.test');
            INSERT INTO public.balances (
                account_id, balance_micro_usd, withdrawable_micro_usd
            ) VALUES ('consumer', 0, 0);
            INSERT INTO public.billing_sessions (
                id, account_id, payment_method, currency, amount_micro_usd,
                external_id, status
            ) VALUES (
                'billing-1', 'consumer', 'stripe', 'usd', 500000,
                'cs_test_checkout', 'pending'
            );
            "#,
        )
        .execute(&test.pool)
        .await
        .expect("seed checkout");
        let event = json!({
            "id": "evt_checkout_once",
            "type": "checkout.session.completed",
            "data": {
                "object": {
                    "id": "cs_test_checkout",
                    "amount_total": 50,
                    "currency": "usd",
                    "payment_status": "paid",
                    "metadata": {"billing_session_id": "billing-1"}
                }
            }
        });
        let raw = serde_json::to_vec(&event).expect("event");
        let signature = stripe_signature(&raw, "checkout-secret");
        let first = webhook_request("/v1/billing/stripe/webhook", raw.clone(), &signature);
        let second = webhook_request("/v1/billing/stripe/webhook", raw, &signature);
        let (first, second) = tokio::join!(app.clone().oneshot(first), app.clone().oneshot(second));
        assert_eq!(first.expect("first response").status(), StatusCode::OK);
        assert_eq!(second.expect("second response").status(), StatusCode::OK);
        let balance: i64 = sqlx::query_scalar(
            "SELECT balance_micro_usd FROM public.balances WHERE account_id = 'consumer'",
        )
        .fetch_one(&test.pool)
        .await
        .expect("balance");
        assert_eq!(balance, 500_000);
        let entries: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM public.ledger_entries WHERE entry_type = 'stripe_deposit'",
        )
        .fetch_one(&test.pool)
        .await
        .expect("ledger count");
        assert_eq!(entries, 1);
        stripe.stop();
        test.stop().await;
    })
    .await;
}

#[tokio::test]
async fn accepted_external_unknown_keeps_checkout_pending_for_same_key_retry() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        let stripe = TestStripe::start(StripeMode::UnknownCheckout).await;
        let app = test.app(stripe.settings()).await;
        seed_user(&test.pool, "consumer", "consumer@example.test").await;
        let response = app
            .clone()
            .oneshot(authenticated_json_request(
                "POST",
                "/v1/billing/stripe/create-session",
                json!({"amount_usd": "1.00"}),
                principal("consumer"),
                Some("checkout-unknown"),
            ))
            .await
            .expect("response");
        assert_eq!(response.status(), StatusCode::ACCEPTED);
        let retry = app
            .oneshot(authenticated_json_request(
                "POST",
                "/v1/billing/stripe/create-session",
                json!({"amount_usd": "1.00"}),
                principal("consumer"),
                Some("checkout-unknown"),
            ))
            .await
            .expect("retry response");
        assert_eq!(retry.status(), StatusCode::OK);
        let session: (String, String, i64) = sqlx::query_as(
            r#"
            SELECT
                status,
                external_id,
                (SELECT COUNT(*) FROM public.billing_sessions
                 WHERE account_id = $1)::BIGINT
            FROM public.billing_sessions
            WHERE account_id = $1
            "#,
        )
        .bind("consumer")
        .fetch_one(&test.pool)
        .await
        .expect("reconciled checkout");
        assert_eq!(
            session,
            ("pending".to_owned(), "cs_test_checkout".to_owned(), 1)
        );
        let balance: i64 = sqlx::query_scalar(
            "SELECT balance_micro_usd FROM public.balances WHERE account_id = 'consumer'",
        )
        .fetch_one(&test.pool)
        .await
        .expect("balance");
        assert_eq!(balance, 0);
        stripe.stop();
        test.stop().await;
    })
    .await;
}

#[tokio::test]
async fn withdrawal_and_concurrent_reversal_refund_principal_once() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        let stripe = TestStripe::start(StripeMode::Working).await;
        let app = test.app(stripe.settings()).await;
        seed_user(&test.pool, "provider", "provider@example.test").await;
        sqlx::raw_sql(
            r#"
            UPDATE public.users
            SET stripe_account_id = 'acct_provider',
                stripe_account_status = 'ready',
                stripe_account_country = 'US'
            WHERE account_id = 'provider';
            INSERT INTO public.balances (
                account_id, balance_micro_usd, withdrawable_micro_usd
            ) VALUES ('provider', 5000000, 5000000);
            "#,
        )
        .execute(&test.pool)
        .await
        .expect("seed provider funds");
        let response = app
            .clone()
            .oneshot(authenticated_json_request(
                "POST",
                "/v1/billing/withdraw/stripe",
                json!({"amount_usd": "2.00", "method": "standard"}),
                principal("provider"),
                Some("withdraw-once"),
            ))
            .await
            .expect("withdraw response");
        assert_eq!(response.status(), StatusCode::OK);
        let payload = response_json(response).await;
        let transfer_id = payload
            .get("transfer_id")
            .and_then(Value::as_str)
            .expect("transfer id");
        let withdrawal_id = payload
            .get("withdrawal_id")
            .and_then(Value::as_str)
            .expect("withdrawal id")
            .to_owned();
        let event = json!({
            "id": "evt_transfer_reversed",
            "type": "transfer.reversed",
            "account": "acct_provider",
            "data": {
                "object": {
                    "id": transfer_id,
                    "amount": 200,
                    "amount_reversed": 200,
                    "reversed": true,
                    "destination": "acct_provider"
                }
            }
        });
        let raw = serde_json::to_vec(&event).expect("event");
        let signature = stripe_signature(&raw, "connect-secret");
        let first = webhook_request(
            "/v1/billing/stripe/connect/webhook",
            raw.clone(),
            &signature,
        );
        let second = webhook_request("/v1/billing/stripe/connect/webhook", raw, &signature);
        let (first, second) = tokio::join!(app.clone().oneshot(first), app.clone().oneshot(second));
        assert_eq!(first.expect("first reversal").status(), StatusCode::OK);
        assert_eq!(second.expect("second reversal").status(), StatusCode::OK);
        let balance: (i64, i64) = sqlx::query_as(
            r#"
            SELECT balance_micro_usd, withdrawable_micro_usd
            FROM public.balances WHERE account_id = 'provider'
            "#,
        )
        .fetch_one(&test.pool)
        .await
        .expect("refunded balance");
        assert_eq!(balance, (5_000_000, 5_000_000));
        let row: (String, bool) =
            sqlx::query_as("SELECT status, refunded FROM public.stripe_withdrawals WHERE id = $1")
                .bind(withdrawal_id)
                .fetch_one(&test.pool)
                .await
                .expect("withdrawal");
        assert_eq!(row, ("failed".to_owned(), true));
        stripe.stop();
        test.stop().await;
    })
    .await;
}

#[tokio::test]
async fn reversal_recorded_before_transfer_attachment_is_reconciled() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        let stripe = TestStripe::start(StripeMode::Working).await;
        let app = test.app(stripe.settings()).await;
        seed_user(&test.pool, "provider", "provider@example.test").await;
        sqlx::raw_sql(
            r#"
            UPDATE public.users
            SET stripe_account_id = 'acct_provider',
                stripe_account_status = 'ready',
                stripe_account_country = 'US'
            WHERE account_id = 'provider';
            INSERT INTO public.balances (
                account_id, balance_micro_usd, withdrawable_micro_usd
            ) VALUES ('provider', 5000000, 5000000);
            "#,
        )
        .execute(&test.pool)
        .await
        .expect("seed provider funds");
        let reversal = json!({
            "id": "evt_reversal_before_attach",
            "type": "transfer.reversed",
            "account": "acct_provider",
            "data": {
                "object": {
                    "id": "tr_test_withdrawal",
                    "amount": 200,
                    "amount_reversed": 200,
                    "reversed": true,
                    "destination": "acct_provider"
                }
            }
        });
        let raw = serde_json::to_vec(&reversal).expect("reversal");
        let signature = stripe_signature(&raw, "connect-secret");
        let recorded = app
            .clone()
            .oneshot(webhook_request(
                "/v1/billing/stripe/connect/webhook",
                raw,
                &signature,
            ))
            .await
            .expect("early reversal response");
        assert_eq!(recorded.status(), StatusCode::OK);

        let withdrawn = app
            .oneshot(authenticated_json_request(
                "POST",
                "/v1/billing/withdraw/stripe",
                json!({"amount_usd": "2.00", "method": "standard"}),
                principal("provider"),
                Some("withdraw-after-reversal"),
            ))
            .await
            .expect("withdraw response");
        assert_eq!(withdrawn.status(), StatusCode::BAD_GATEWAY);
        let balance: (i64, i64) = sqlx::query_as(
            r#"
            SELECT balance_micro_usd, withdrawable_micro_usd
            FROM public.balances WHERE account_id = 'provider'
            "#,
        )
        .fetch_one(&test.pool)
        .await
        .expect("refunded balance");
        assert_eq!(balance, (5_000_000, 5_000_000));
        let withdrawal: (String, bool) = sqlx::query_as(
            r#"
            SELECT status, refunded
            FROM public.stripe_withdrawals
            WHERE transfer_id = 'tr_test_withdrawal'
            "#,
        )
        .fetch_one(&test.pool)
        .await
        .expect("reconciled withdrawal");
        assert_eq!(withdrawal, ("failed".to_owned(), true));
        stripe.stop();
        test.stop().await;
    })
    .await;
}

#[tokio::test]
async fn failed_sweep_tombstone_wins_over_late_paid_delivery() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        let stripe = TestStripe::start(StripeMode::Working).await;
        let app = test.app(stripe.settings()).await;
        sqlx::query(
            r#"
            INSERT INTO public.stripe_withdrawals (
                id, account_id, stripe_account_id, amount_micro_usd,
                fee_micro_usd, net_micro_usd, method, status
            ) VALUES (
                'wd_sweep_race', 'provider', 'acct_provider', 2000000,
                0, 2000000, 'standard', 'transferred'
            )
            "#,
        )
        .execute(&test.pool)
        .await
        .expect("seed sweep withdrawal");
        let failed = json!({
            "id": "evt_sweep_failed",
            "type": "payout.failed",
            "account": "acct_provider",
            "data": {
                "object": {
                    "id": "po_test_sweep",
                    "automatic": true,
                    "created": 2000000000_i64,
                    "failure_code": "bank_account_closed",
                    "failure_message": "closed"
                }
            }
        });
        let failed_raw = serde_json::to_vec(&failed).expect("failed sweep");
        let failed_signature = stripe_signature(&failed_raw, "connect-secret");
        let failed_response = app
            .clone()
            .oneshot(webhook_request(
                "/v1/billing/stripe/connect/webhook",
                failed_raw,
                &failed_signature,
            ))
            .await
            .expect("failed sweep response");
        assert_eq!(failed_response.status(), StatusCode::OK);

        let paid = json!({
            "id": "evt_sweep_paid_late",
            "type": "payout.paid",
            "account": "acct_provider",
            "data": {
                "object": {
                    "id": "po_test_sweep",
                    "automatic": true,
                    "created": 2000000000_i64
                }
            }
        });
        let paid_raw = serde_json::to_vec(&paid).expect("paid sweep");
        let paid_signature = stripe_signature(&paid_raw, "connect-secret");
        let paid_response = app
            .oneshot(webhook_request(
                "/v1/billing/stripe/connect/webhook",
                paid_raw,
                &paid_signature,
            ))
            .await
            .expect("late paid response");
        assert_eq!(paid_response.status(), StatusCode::OK);
        let withdrawal: (String, String) = sqlx::query_as(
            r#"
            SELECT status, sweep_payout_id
            FROM public.stripe_withdrawals
            WHERE id = 'wd_sweep_race'
            "#,
        )
        .fetch_one(&test.pool)
        .await
        .expect("sweep withdrawal");
        assert_eq!(withdrawal, ("transferred".to_owned(), String::new()));
        let tombstones: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM public.stripe_sweep_failures WHERE payout_id = 'po_test_sweep'",
        )
        .fetch_one(&test.pool)
        .await
        .expect("sweep tombstone");
        assert_eq!(tombstones, 1);
        stripe.stop();
        test.stop().await;
    })
    .await;
}

#[tokio::test]
async fn referral_allocation_is_exact_and_uses_persisted_relationship() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        sqlx::raw_sql(
            r#"
            INSERT INTO public.referrers (account_id, code)
            VALUES ('referrer', 'REF-CODE');
            INSERT INTO public.referrals (referred_account, referrer_code)
            VALUES ('consumer', 'REF-CODE');
            "#,
        )
        .execute(&test.pool)
        .await
        .expect("seed referral");
        let state = BillingState::builder(test.database.clone())
            .with_referral_share_percent(20)
            .build()
            .expect("state");
        let allocation = state
            .referral_service()
            .allocation("consumer", 101)
            .await
            .expect("allocation");
        assert_eq!(
            allocation.beneficiary_account_id.as_deref(),
            Some("referrer")
        );
        assert_eq!(allocation.reward_micro_usd, 20);
        assert_eq!(allocation.platform_fee_micro_usd, 81);
        test.stop().await;
    })
    .await;
}

#[tokio::test]
async fn invite_max_use_race_credits_exactly_one_account_atomically() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        let app = test.app_without_stripe().await;
        sqlx::query(
            r#"
            INSERT INTO public.invite_codes (
                code, amount_micro_usd, max_uses, used_count, active
            ) VALUES ('ONLY-ONE', 750000, 1, 0, TRUE)
            "#,
        )
        .execute(&test.pool)
        .await
        .expect("seed invite");
        let first = authenticated_json_request(
            "POST",
            "/v1/invite/redeem",
            json!({"code": "ONLY-ONE"}),
            principal("first"),
            None,
        );
        let second = authenticated_json_request(
            "POST",
            "/v1/invite/redeem",
            json!({"code": "ONLY-ONE"}),
            principal("second"),
            None,
        );
        let (first, second) = tokio::join!(app.clone().oneshot(first), app.clone().oneshot(second));
        let statuses = [
            first.expect("first response").status(),
            second.expect("second response").status(),
        ];
        assert_eq!(
            statuses
                .iter()
                .filter(|status| **status == StatusCode::OK)
                .count(),
            1
        );
        let credited: i64 = sqlx::query_scalar(
            "SELECT COALESCE(SUM(balance_micro_usd), 0)::BIGINT FROM public.balances",
        )
        .fetch_one(&test.pool)
        .await
        .expect("credited total");
        assert_eq!(credited, 750_000);
        let state: (i32, i64) = sqlx::query_as(
            r#"
            SELECT used_count,
                   (SELECT COUNT(*) FROM public.invite_redemptions)::BIGINT
            FROM public.invite_codes WHERE code = 'ONLY-ONE'
            "#,
        )
        .fetch_one(&test.pool)
        .await
        .expect("invite state");
        assert_eq!(state, (1, 1));
        test.stop().await;
    })
    .await;
}

#[tokio::test]
async fn pricing_delete_is_scoped_to_authenticated_owner() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        let app = test.app_without_stripe().await;
        let created = app
            .clone()
            .oneshot(authenticated_json_request(
                "PUT",
                "/v1/pricing",
                json!({
                    "model": "owned-model",
                    "input_price": 100,
                    "output_price": 200
                }),
                principal("owner-a"),
                None,
            ))
            .await
            .expect("create response");
        assert_eq!(created.status(), StatusCode::OK);
        let denied = app
            .clone()
            .oneshot(authenticated_json_request(
                "DELETE",
                "/v1/pricing",
                json!({"model": "owned-model"}),
                principal("owner-b"),
                None,
            ))
            .await
            .expect("delete response");
        assert_eq!(denied.status(), StatusCode::NOT_FOUND);
        let owner: String = sqlx::query_scalar(
            "SELECT account_id FROM public.model_prices WHERE model = 'owned-model'",
        )
        .fetch_one(&test.pool)
        .await
        .expect("price owner");
        assert_eq!(owner, "owner-a");
        test.stop().await;
    })
    .await;
}

struct TestDatabase {
    database: Database,
    ownership: CoordinatorOwnership,
    pool: PgPool,
}

impl TestDatabase {
    async fn start(url: &str) -> Self {
        seed_service_schema(url).await;
        let pool = PgPool::connect(url).await.expect("inspection pool");
        sqlx::raw_sql(
            r#"
            CREATE TABLE public.users (
                account_id TEXT PRIMARY KEY,
                privy_user_id TEXT UNIQUE NOT NULL,
                email TEXT NOT NULL DEFAULT '',
                role TEXT NOT NULL DEFAULT '',
                platform_fee_percent BIGINT,
                stripe_account_id TEXT NOT NULL DEFAULT '',
                stripe_account_status TEXT NOT NULL DEFAULT '',
                stripe_account_country TEXT NOT NULL DEFAULT '',
                stripe_destination_type TEXT NOT NULL DEFAULT '',
                stripe_destination_last4 TEXT NOT NULL DEFAULT '',
                stripe_instant_eligible BOOLEAN NOT NULL DEFAULT FALSE
            );
            CREATE UNIQUE INDEX test_users_stripe
                ON public.users(stripe_account_id) WHERE stripe_account_id <> '';
            CREATE TABLE public.api_keys (
                key_hash TEXT PRIMARY KEY,
                id TEXT NOT NULL DEFAULT '',
                owner_account_id TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE public.providers (
                id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL DEFAULT '',
                public_key TEXT NOT NULL DEFAULT '',
                se_public_key TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE public.referrers (
                account_id TEXT PRIMARY KEY,
                code TEXT UNIQUE NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            );
            CREATE TABLE public.referrals (
                referred_account TEXT PRIMARY KEY,
                referrer_code TEXT NOT NULL REFERENCES public.referrers(code),
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            );
            CREATE TABLE public.invite_codes (
                code TEXT PRIMARY KEY,
                amount_micro_usd BIGINT NOT NULL,
                max_uses INTEGER NOT NULL DEFAULT 1,
                used_count INTEGER NOT NULL DEFAULT 0,
                active BOOLEAN NOT NULL DEFAULT TRUE,
                expires_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            );
            CREATE TABLE public.invite_redemptions (
                code TEXT NOT NULL REFERENCES public.invite_codes(code),
                account_id TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                PRIMARY KEY (code, account_id)
            );
            "#,
        )
        .execute(&pool)
        .await
        .expect("augment billing test schema");
        let database = Database::connect(url, 16, Duration::from_secs(5))
            .await
            .expect("database");
        let ownership = CoordinatorOwnership::configure(&database, url, true)
            .await
            .expect("ownership");
        Self {
            database,
            ownership,
            pool,
        }
    }

    async fn app(&self, stripe: StripeSettings) -> Router {
        router(
            BillingState::builder(self.database.clone())
                .with_stripe(stripe)
                .with_admin_key("test-admin")
                .build()
                .expect("billing state"),
        )
    }

    async fn app_without_stripe(&self) -> Router {
        router(
            BillingState::builder(self.database.clone())
                .with_admin_key("test-admin")
                .build()
                .expect("billing state"),
        )
    }

    async fn stop(self) {
        self.pool.close().await;
        self.database
            .close(Duration::from_secs(2))
            .await
            .expect("close database");
        self.ownership.release().await.expect("release ownership");
    }
}

#[derive(Clone, Copy)]
enum StripeMode {
    Working,
    UnknownCheckout,
}

struct TestStripe {
    base: String,
    task: JoinHandle<()>,
}

impl TestStripe {
    async fn start(mode: StripeMode) -> Self {
        let checkout_attempts = Arc::new(AtomicUsize::new(0));
        let checkout = move || {
            let attempt = checkout_attempts.fetch_add(1, Ordering::SeqCst);
            async move {
                match mode {
                    StripeMode::UnknownCheckout if attempt == 0 => (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(json!({"error": {"message": "indeterminate"}})),
                    ),
                    StripeMode::Working | StripeMode::UnknownCheckout => (
                        StatusCode::OK,
                        Json(json!({
                            "id": "cs_test_checkout",
                            "url": "https://checkout.stripe.test/session"
                        })),
                    ),
                }
            }
        };
        let app = Router::new()
            .route("/v1/checkout/sessions", post(checkout))
            .route(
                "/v1/accounts/{account}",
                get(|| async {
                    Json(json!({
                        "id": "acct_provider",
                        "country": "US",
                        "payouts_enabled": true,
                        "details_submitted": true,
                        "tos_acceptance": {"service_agreement": "full"},
                        "settings": {"payouts": {"schedule": {"interval": "daily"}}},
                        "requirements": {"currently_due": [], "disabled_reason": null},
                        "external_accounts": {
                            "data": [{
                                "object": "bank_account",
                                "last4": "4242",
                                "default_for_currency": true
                            }]
                        }
                    }))
                }),
            )
            .route(
                "/v1/transfers",
                post(|| async {
                    Json(json!({
                        "id": "tr_test_withdrawal",
                        "amount": 200,
                        "destination": "acct_provider",
                        "created": 1000
                    }))
                }),
            )
            .route(
                "/v1/payouts/{payout}",
                get(|Path(payout): Path<String>| async move {
                    Json(json!({
                        "id": payout,
                        "status": "paid",
                        "arrival_date": 2000000000_i64
                    }))
                }),
            );
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind Stripe");
        let address = listener.local_addr().expect("Stripe address");
        let task = tokio::spawn(async move {
            axum::serve(listener, app)
                .await
                .expect("serve Stripe test API");
        });
        Self {
            base: format!("http://{address}"),
            task,
        }
    }

    fn settings(&self) -> StripeSettings {
        StripeSettings {
            secret_key: Arc::from("sk_test"),
            webhook_secret: Arc::from("checkout-secret"),
            connect_webhook_secret: Arc::from("connect-secret"),
            api_base: Arc::from(self.base.as_str()),
            checkout_success_url: Arc::from("https://console.test/billing/success"),
            checkout_cancel_url: Arc::from("https://console.test/billing/cancel"),
            connect_return_url: Arc::from("https://console.test/billing"),
            connect_refresh_url: Arc::from("https://console.test/billing"),
            platform_country: Arc::from("US"),
            request_timeout: Duration::from_secs(2),
        }
    }

    fn stop(self) {
        self.task.abort();
    }
}

async fn seed_user(pool: &PgPool, account: &str, email: &str) {
    sqlx::query("INSERT INTO public.users (account_id, privy_user_id, email) VALUES ($1, $2, $3)")
        .bind(account)
        .bind(format!("privy-{account}"))
        .bind(email)
        .execute(pool)
        .await
        .expect("seed user");
}

fn principal(account: &str) -> BillingPrincipal {
    BillingPrincipal::new(
        account,
        format!("{account}@example.test"),
        AuthenticationKind::Privy,
        false,
    )
    .expect("principal")
}

fn authenticated_json_request(
    method: &str,
    uri: &str,
    payload: Value,
    principal: BillingPrincipal,
    idempotency_key: Option<&str>,
) -> Request<Body> {
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json");
    if let Some(key) = idempotency_key {
        builder = builder.header("idempotency-key", key);
    }
    let mut request = builder
        .body(Body::from(serde_json::to_vec(&payload).expect("payload")))
        .expect("request");
    request.extensions_mut().insert(principal);
    request
}

fn webhook_request(uri: &str, raw: Vec<u8>, signature: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("stripe-signature", signature)
        .header("content-type", "application/json")
        .body(Body::from(raw))
        .expect("webhook request")
}

async fn response_json(response: axum::response::Response) -> Value {
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("collect response")
        .to_bytes();
    serde_json::from_slice(&bytes).expect("response JSON")
}

fn stripe_signature(body: &[u8], secret: &str) -> String {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_secs();
    let mut signed = timestamp.to_string().into_bytes();
    signed.push(b'.');
    signed.extend_from_slice(body);
    format!(
        "t={timestamp},v1={}",
        hex(&test_hmac_sha256(secret.as_bytes(), &signed))
    )
}

fn test_hmac_sha256(secret: &[u8], message: &[u8]) -> [u8; 32] {
    const BLOCK: usize = 64;
    let mut key = [0_u8; BLOCK];
    if secret.len() > BLOCK {
        key[..32].copy_from_slice(&Sha256::digest(secret));
    } else {
        key[..secret.len()].copy_from_slice(secret);
    }
    let mut inner_pad = [0x36_u8; BLOCK];
    let mut outer_pad = [0x5c_u8; BLOCK];
    for index in 0..BLOCK {
        inner_pad[index] ^= key[index];
        outer_pad[index] ^= key[index];
    }
    let mut inner = Sha256::new();
    inner.update(inner_pad);
    inner.update(message);
    let inner = inner.finalize();
    let mut outer = Sha256::new();
    outer.update(outer_pad);
    outer.update(inner);
    outer.finalize().into()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().fold(String::new(), |mut output, byte| {
        use std::fmt::Write as _;
        write!(output, "{byte:02x}").expect("hex");
        output
    })
}

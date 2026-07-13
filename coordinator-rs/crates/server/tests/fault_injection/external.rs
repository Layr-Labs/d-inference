use super::*;
use axum::{
    Json,
    body::Body,
    extract::Path as AxumPath,
    http::{Request, StatusCode},
    routing::get,
};
use darkbloom_coordinator_server::{
    recovery::RecoveryService,
    surface::billing::{
        AuthenticationKind, BillingPrincipal, BillingState, StripeSettings,
        WithdrawalRecoveryAction, router,
    },
};
use http_body_util::BodyExt as _;
use serde_json::json;
use tower::ServiceExt as _;

#[tokio::test(flavor = "current_thread")]
#[allow(clippy::await_holding_lock)]
async fn external_call_unknown_reuses_one_idempotency_key_and_money_mutation() {
    let _serial = FAULT_TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    support::with_isolated_database(|url| async move {
        support::seed_service_schema(&url).await;
        let database = Database::connect(&url, 8, Duration::from_secs(5))
            .await
            .expect("connect external-call database");
        let ownership = CoordinatorOwnership::configure(&database, &url, true)
            .await
            .expect("configure external-call ownership");
        let pool = PgPool::connect(&url)
            .await
            .expect("external-call inspection pool");
        seed_provider(&pool).await;
        let stripe = FaultStripe::start().await;
        let state = BillingState::builder(database.clone())
            .with_stripe(stripe.settings())
            .with_admin_key("fault-admin")
            .build()
            .expect("fault billing state");
        let withdrawal_recovery = state.withdrawal_recovery().expect("withdrawal recovery");
        let app = router(state);

        let response = app
            .oneshot(withdrawal_request())
            .await
            .expect("withdrawal response");
        assert_eq!(response.status(), StatusCode::ACCEPTED);
        let withdrawal_id = response_json(response).await["withdrawal_id"]
            .as_str()
            .expect("withdrawal id")
            .to_owned();
        assert_eq!(provider_balance(&pool).await, 3_000_000);

        let recovery = RecoveryService::new(database.clone());
        let worker = Uuid::new_v4();
        let leases = recovery
            .claim_outbox(worker, 1, Duration::from_secs(5))
            .await
            .expect("claim external-call lease");
        assert_eq!(leases.len(), 1);
        let fault = arm(FaultPoint::ExternalCallUnknown, FaultAction::Fail)
            .expect("arm external-call unknown");
        assert_eq!(
            withdrawal_recovery
                .process(worker, &leases[0])
                .await
                .expect("inject external-call unknown"),
            WithdrawalRecoveryAction::Retry
        );
        fault
            .wait_until_hit(Duration::from_secs(1))
            .await
            .expect("external-call checkpoint");
        assert_eq!(provider_balance(&pool).await, 3_000_000);

        assert_eq!(
            withdrawal_recovery
                .process(worker, &leases[0])
                .await
                .expect("resume same external-call lease"),
            WithdrawalRecoveryAction::Handled
        );
        let persisted: (String, String, String) = sqlx::query_as(
            r#"
            SELECT withdrawals.status, withdrawals.external_state, outbox.status
            FROM public.stripe_withdrawals AS withdrawals
            JOIN rust_coord.outbox AS outbox
              ON outbox.operation_key = 'withdrawal-call:' || withdrawals.id
            WHERE withdrawals.id = $1
            "#,
        )
        .bind(&withdrawal_id)
        .fetch_one(&pool)
        .await
        .expect("recovered withdrawal");
        assert_eq!(
            persisted,
            (
                "transferred".to_owned(),
                "confirmed".to_owned(),
                "delivered".to_owned(),
            )
        );
        assert_eq!(provider_balance(&pool).await, 3_000_000);
        let keys = stripe.idempotency_keys();
        assert_eq!(keys.len(), 3);
        assert!(
            keys.windows(2).all(|pair| pair[0] == pair[1]),
            "external retry changed its idempotency key"
        );
        record_receipt(
            "external_call_unknown_reuses_idempotency_key",
            &[&fault],
            &["exactly_one_disposition", "no_double_money_mutation"],
        );

        stripe.stop();
        pool.close().await;
        database
            .close(Duration::from_secs(2))
            .await
            .expect("close external-call database");
        ownership
            .release()
            .await
            .expect("release external-call ownership");
    })
    .await;
}

struct FaultStripe {
    base: String,
    keys: Arc<Mutex<Vec<String>>>,
    task: tokio::task::JoinHandle<()>,
}

impl FaultStripe {
    async fn start() -> Self {
        let attempts = Arc::new(AtomicUsize::new(0));
        let keys = Arc::new(Mutex::new(Vec::new()));
        let create_transfer = {
            let attempts = attempts.clone();
            let keys = keys.clone();
            move |headers: axum::http::HeaderMap| {
                let attempt = attempts.fetch_add(1, Ordering::SeqCst);
                let keys = keys.clone();
                async move {
                    keys.lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .push(
                            headers
                                .get("idempotency-key")
                                .and_then(|value| value.to_str().ok())
                                .unwrap_or_default()
                                .to_owned(),
                        );
                    if attempt == 0 {
                        (
                            StatusCode::INTERNAL_SERVER_ERROR,
                            Json(json!({"error": {"message": "indeterminate transfer"}})),
                        )
                    } else {
                        (
                            StatusCode::OK,
                            Json(json!({
                                "id": "tr_fault_withdrawal",
                                "amount": 200,
                                "destination": "acct_fault_provider",
                                "created": 1000
                            })),
                        )
                    }
                }
            }
        };
        let app = Router::new()
            .route(
                "/v1/accounts/{account}",
                get(|AxumPath(account): AxumPath<String>| async move {
                    Json(json!({
                        "id": account,
                        "country": "US",
                        "payouts_enabled": true,
                        "details_submitted": true,
                        "tos_acceptance": {"service_agreement": "full"},
                        "settings": {"payouts": {"schedule": {"interval": "daily"}}},
                        "requirements": {"currently_due": [], "disabled_reason": null},
                        "external_accounts": {"data": []}
                    }))
                }),
            )
            .route(
                "/v1/transfers",
                get(|| async { Json(json!({"data": []})) }).post(create_transfer),
            );
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind fault Stripe");
        let address = listener.local_addr().expect("fault Stripe address");
        let task = tokio::spawn(async move {
            axum::serve(listener, app)
                .await
                .expect("serve fault Stripe");
        });
        Self {
            base: format!("http://{address}"),
            keys,
            task,
        }
    }

    fn settings(&self) -> StripeSettings {
        StripeSettings {
            secret_key: Arc::from("sk_fault"),
            webhook_secret: Arc::from("checkout-fault"),
            connect_webhook_secret: Arc::from("connect-fault"),
            api_base: Arc::from(self.base.as_str()),
            checkout_success_url: Arc::from("https://console.test/billing/success"),
            checkout_cancel_url: Arc::from("https://console.test/billing/cancel"),
            connect_return_url: Arc::from("https://console.test/billing"),
            connect_refresh_url: Arc::from("https://console.test/billing"),
            platform_country: Arc::from("US"),
            request_timeout: Duration::from_secs(2),
        }
    }

    fn idempotency_keys(&self) -> Vec<String> {
        self.keys
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    fn stop(self) {
        self.task.abort();
    }
}

async fn seed_provider(pool: &PgPool) {
    sqlx::raw_sql(
        r#"
        INSERT INTO public.users (
            account_id, privy_user_id, email, stripe_account_id,
            stripe_account_status, stripe_account_country
        ) VALUES (
            'fault-provider', 'privy-fault-provider', 'fault-provider@example.test',
            'acct_fault_provider', 'ready', 'US'
        );
        INSERT INTO public.balances (
            account_id, balance_micro_usd, withdrawable_micro_usd
        ) VALUES ('fault-provider', 5000000, 5000000);
        "#,
    )
    .execute(pool)
    .await
    .expect("seed external-call provider");
}

fn withdrawal_request() -> Request<Body> {
    let mut request = Request::builder()
        .method("POST")
        .uri("/v1/billing/withdraw/stripe")
        .header("content-type", "application/json")
        .header("idempotency-key", "fault-external-call")
        .body(Body::from(
            br#"{"amount_usd":"2.00","method":"standard"}"#.as_slice(),
        ))
        .expect("withdrawal request");
    request.extensions_mut().insert(
        BillingPrincipal::new(
            "fault-provider",
            "fault-provider@example.test",
            AuthenticationKind::Privy,
            false,
        )
        .expect("fault billing principal"),
    );
    request
}

async fn response_json(response: axum::response::Response) -> serde_json::Value {
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("collect withdrawal response")
        .to_bytes();
    serde_json::from_slice(&bytes).expect("withdrawal response JSON")
}

async fn provider_balance(pool: &PgPool) -> i64 {
    sqlx::query_scalar(
        "SELECT balance_micro_usd FROM public.balances WHERE account_id='fault-provider'",
    )
    .fetch_one(pool)
    .await
    .expect("fault provider balance")
}

use std::{
    sync::{
        Arc, Mutex,
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

use crate::{database::Database, ownership::CoordinatorOwnership, recovery::RecoveryService};
use uuid::Uuid;

use super::{
    AuthenticationKind, BillingPrincipal, BillingState, StripeSettings, WithdrawalRecoveryAction,
    router,
};

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
async fn withdrawal_outbox_recovers_crash_window_with_the_same_stripe_idempotency_key() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        let stripe = TestStripe::start(StripeMode::UnknownTransferThenWorking).await;
        let state = BillingState::builder(test.database.clone())
            .with_stripe(stripe.settings())
            .with_admin_key("test-admin")
            .build()
            .expect("billing state");
        let withdrawal_recovery = state.withdrawal_recovery().expect("withdrawal recovery");
        let app = router(state);
        seed_user(&test.pool, "provider", "provider@example.test").await;
        sqlx::raw_sql(
            r#"
            UPDATE public.users
            SET stripe_account_id='acct_provider',
                stripe_account_status='ready',
                stripe_account_country='US'
            WHERE account_id='provider';
            INSERT INTO public.balances (
                account_id, balance_micro_usd, withdrawable_micro_usd
            ) VALUES ('provider', 5000000, 5000000);
            "#,
        )
        .execute(&test.pool)
        .await
        .expect("seed recoverable withdrawal");

        let response = app
            .oneshot(authenticated_json_request(
                "POST",
                "/v1/billing/withdraw/stripe",
                json!({"amount_usd": "2.00", "method": "standard"}),
                principal("provider"),
                Some("recover-after-debit"),
            ))
            .await
            .expect("withdraw response");
        assert_eq!(response.status(), StatusCode::ACCEPTED);
        let withdrawal_id = response_json(response).await["withdrawal_id"]
            .as_str()
            .expect("withdrawal id")
            .to_owned();
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT balance_micro_usd FROM public.balances WHERE account_id='provider'",
            )
            .fetch_one(&test.pool)
            .await
            .expect("debited balance"),
            3_000_000
        );

        let recovery = RecoveryService::new(test.database.clone());
        let worker = Uuid::new_v4();
        let leases = recovery
            .claim_outbox(worker, 1, Duration::from_secs(5))
            .await
            .expect("claim withdrawal outbox");
        assert_eq!(leases.len(), 1);
        assert_eq!(
            withdrawal_recovery
                .process(worker, &leases[0])
                .await
                .expect("recover withdrawal"),
            WithdrawalRecoveryAction::Handled
        );
        let persisted: (String, String, String) = sqlx::query_as(
            r#"
            SELECT withdrawals.status, withdrawals.external_state, outbox.status
            FROM public.stripe_withdrawals AS withdrawals
            JOIN rust_coord.outbox AS outbox
              ON outbox.operation_key='withdrawal-call:' || withdrawals.id
            WHERE withdrawals.id=$1
            "#,
        )
        .bind(&withdrawal_id)
        .fetch_one(&test.pool)
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
        assert_eq!(
            stripe.transfer_idempotency_keys(),
            vec![
                format!(
                    "wd-tr-{}",
                    super::auth::operation_suffix("provider", "recover-after-debit")
                ),
                format!(
                    "wd-tr-{}",
                    super::auth::operation_suffix("provider", "recover-after-debit")
                ),
            ]
        );

        stripe.stop();
        test.stop().await;
    })
    .await;
}

#[tokio::test]
async fn max_unknown_withdrawal_recovery_stays_debited_for_operator_review() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        let stripe = TestStripe::start(StripeMode::UnknownTransferAlways).await;
        let state = BillingState::builder(test.database.clone())
            .with_stripe(stripe.settings())
            .with_admin_key("test-admin")
            .build()
            .expect("billing state");
        let withdrawal_recovery = state
            .withdrawal_recovery()
            .expect("withdrawal recovery");
        let app = router(state);
        seed_user(&test.pool, "provider", "provider@example.test").await;
        sqlx::raw_sql(
            r#"
            UPDATE public.users
            SET stripe_account_id='acct_provider',
                stripe_account_status='ready',
                stripe_account_country='US'
            WHERE account_id='provider';
            INSERT INTO public.balances (
                account_id, balance_micro_usd, withdrawable_micro_usd
            ) VALUES ('provider', 5000000, 5000000);
            "#,
        )
        .execute(&test.pool)
        .await
        .expect("seed max-attempt withdrawal");

        let response = app
            .oneshot(authenticated_json_request(
                "POST",
                "/v1/billing/withdraw/stripe",
                json!({"amount_usd": "2.00", "method": "standard"}),
                principal("provider"),
                Some("recover-max-failure"),
            ))
            .await
            .expect("withdraw response");
        assert_eq!(response.status(), StatusCode::ACCEPTED);
        let withdrawal_id = response_json(response).await["withdrawal_id"]
            .as_str()
            .expect("withdrawal id")
            .to_owned();
        sqlx::query(
            "UPDATE rust_coord.outbox SET max_attempts=1 WHERE operation_key='withdrawal-call:' || $1",
        )
        .bind(&withdrawal_id)
        .execute(&test.pool)
        .await
        .expect("bound recovery attempts");

        let recovery = RecoveryService::new(test.database.clone());
        let worker = Uuid::new_v4();
        let leases = recovery
            .claim_outbox(worker, 1, Duration::from_secs(5))
            .await
            .expect("claim max-attempt outbox");
        assert_eq!(
            withdrawal_recovery
                .process(worker, &leases[0])
                .await
                .expect("finish max-attempt withdrawal"),
            WithdrawalRecoveryAction::Handled
        );
        let state: (i64, i64, String, bool, String, String, i64) = sqlx::query_as(
            r#"
            SELECT
                balances.balance_micro_usd,
                balances.withdrawable_micro_usd,
                withdrawals.status,
                withdrawals.refunded,
                withdrawals.external_state,
                outbox.status,
                (SELECT COUNT(*) FROM public.stripe_withdrawal_failures
                 WHERE withdrawal_id=withdrawals.id)::BIGINT
            FROM public.balances AS balances
            JOIN public.stripe_withdrawals AS withdrawals
              ON withdrawals.account_id=balances.account_id
            JOIN rust_coord.outbox AS outbox
              ON outbox.operation_key='withdrawal-call:' || withdrawals.id
            WHERE withdrawals.id=$1
            "#,
        )
        .bind(&withdrawal_id)
        .fetch_one(&test.pool)
        .await
        .expect("failed withdrawal state");
        assert_eq!(
            state,
            (
                3_000_000,
                3_000_000,
                "review_pending".to_owned(),
                false,
                "external_unknown".to_owned(),
                "failed".to_owned(),
                0,
            )
        );
        let refunds: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM public.ledger_entries WHERE reference='stripe_withdraw:' || $1 AND entry_type='refund'",
        )
        .bind(&withdrawal_id)
        .fetch_one(&test.pool)
        .await
        .expect("refund count");
        assert_eq!(refunds, 0);

        stripe.stop();
        test.stop().await;
    })
    .await;
}

#[tokio::test]
async fn definitive_transfer_failure_refunds_once_and_records_failure_tombstone() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        let stripe = TestStripe::start(StripeMode::UnknownTransferThenPermanentFailure).await;
        let state = BillingState::builder(test.database.clone())
            .with_stripe(stripe.settings())
            .with_admin_key("test-admin")
            .build()
            .expect("billing state");
        let withdrawal_recovery = state
            .withdrawal_recovery()
            .expect("withdrawal recovery");
        let app = router(state);
        seed_user(&test.pool, "provider", "provider@example.test").await;
        sqlx::raw_sql(
            r#"
            UPDATE public.users
            SET stripe_account_id='acct_provider',
                stripe_account_status='ready',
                stripe_account_country='US'
            WHERE account_id='provider';
            INSERT INTO public.balances (
                account_id, balance_micro_usd, withdrawable_micro_usd
            ) VALUES ('provider', 5000000, 5000000);
            "#,
        )
        .execute(&test.pool)
        .await
        .expect("seed definitively failed withdrawal");

        let response = app
            .oneshot(authenticated_json_request(
                "POST",
                "/v1/billing/withdraw/stripe",
                json!({"amount_usd": "2.00", "method": "standard"}),
                principal("provider"),
                Some("recover-definitive-failure"),
            ))
            .await
            .expect("withdraw response");
        assert_eq!(response.status(), StatusCode::ACCEPTED);
        let withdrawal_id = response_json(response).await["withdrawal_id"]
            .as_str()
            .expect("withdrawal id")
            .to_owned();

        let recovery = RecoveryService::new(test.database.clone());
        let worker = Uuid::new_v4();
        let leases = recovery
            .claim_outbox(worker, 1, Duration::from_secs(5))
            .await
            .expect("claim failed withdrawal outbox");
        assert_eq!(
            withdrawal_recovery
                .process(worker, &leases[0])
                .await
                .expect("finish definitive failure"),
            WithdrawalRecoveryAction::Handled
        );
        let state: (i64, i64, String, bool, String, String, i64) = sqlx::query_as(
            r#"
            SELECT
                balances.balance_micro_usd,
                balances.withdrawable_micro_usd,
                withdrawals.status,
                withdrawals.refunded,
                withdrawals.external_state,
                outbox.status,
                (SELECT COUNT(*) FROM public.stripe_withdrawal_failures
                 WHERE withdrawal_id=withdrawals.id)::BIGINT
            FROM public.balances AS balances
            JOIN public.stripe_withdrawals AS withdrawals
              ON withdrawals.account_id=balances.account_id
            JOIN rust_coord.outbox AS outbox
              ON outbox.operation_key='withdrawal-call:' || withdrawals.id
            WHERE withdrawals.id=$1
            "#,
        )
        .bind(&withdrawal_id)
        .fetch_one(&test.pool)
        .await
        .expect("definitive withdrawal failure");
        assert_eq!(
            state,
            (
                5_000_000,
                5_000_000,
                "failed".to_owned(),
                true,
                "permanent_failure".to_owned(),
                "failed".to_owned(),
                1,
            )
        );
        let refunds: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM public.ledger_entries WHERE reference='stripe_withdraw:' || $1 AND entry_type='refund'",
        )
        .bind(&withdrawal_id)
        .fetch_one(&test.pool)
        .await
        .expect("definitive refund count");
        assert_eq!(refunds, 1);

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
            CREATE FUNCTION delay_first_test_reversal() RETURNS trigger
            LANGUAGE plpgsql AS $$
            BEGIN
                IF NEW.refunded AND NOT OLD.refunded THEN
                    PERFORM pg_sleep(0.25);
                END IF;
                RETURN NEW;
            END;
            $$;
            CREATE TRIGGER delay_first_test_reversal
            BEFORE UPDATE OF refunded ON public.stripe_withdrawals
            FOR EACH ROW EXECUTE FUNCTION delay_first_test_reversal();
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
        let first = first.expect("first reversal");
        let first_status = first.status();
        let first_body = response_json(first).await;
        let second = second.expect("second reversal");
        let second_status = second.status();
        let second_body = response_json(second).await;
        assert_eq!(
            first_status,
            StatusCode::OK,
            "first reversal response: {first_body}"
        );
        assert_eq!(
            second_status,
            StatusCode::OK,
            "second reversal response: {second_body}"
        );
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
        let event_state: (String, i64, bool, bool) = sqlx::query_as(
            r#"
            SELECT status, version, worker_owner IS NULL, lease_until IS NULL
            FROM rust_coord.external_events
            WHERE source = 'stripe_connect' AND event_id = 'evt_transfer_reversed'
            "#,
        )
        .fetch_one(&test.pool)
        .await
        .expect("terminal reversal event");
        assert_eq!(
            event_state,
            ("applied".to_owned(), 2, true, true),
            "a concurrent duplicate must replay the first terminal result"
        );
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
                fee_micro_usd, net_micro_usd, method, status, idempotency_key
            ) VALUES (
                'wd_sweep_race', 'provider', 'acct_provider', 2000000,
                0, 2000000, 'standard', 'transferred', 'wd-sweep-race'
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
        sqlx::query(
            "UPDATE public.billing_runtime_settings SET referral_share_ppm=100000 WHERE singleton",
        )
        .execute(&test.pool)
        .await
        .expect("update database referral policy");
        let subsequent = state
            .referral_service()
            .allocation("consumer", 101)
            .await
            .expect("dynamic allocation");
        assert_eq!(subsequent.reward_micro_usd, 10);
        assert_eq!(subsequent.platform_fee_micro_usd, 91);
        assert_eq!(
            state
                .referral_service()
                .share_percent()
                .await
                .expect("dynamic referral policy"),
            10
        );
        assert_eq!(allocation.reward_micro_usd, 20);
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
async fn public_provider_earnings_matches_the_go_wallet_contract_without_account_auth() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        let app = test.app_without_stripe().await;
        sqlx::raw_sql(
            r#"
            INSERT INTO public.balances (
                account_id, balance_micro_usd, withdrawable_micro_usd
            ) VALUES ('wallet-public', 1234567, 1234567);
            INSERT INTO public.provider_payouts (
                provider_address, amount_micro_usd, model, job_id, settled,
                created_at
            ) VALUES (
                'wallet-public', 400000, 'model/build', 'job-public', TRUE,
                TIMESTAMPTZ '2026-07-11 20:00:00.120000+00'
            );
            INSERT INTO public.ledger_entries (
                account_id, entry_type, amount_micro_usd, balance_after,
                reference, created_at
            ) VALUES (
                'wallet-public', 'payout', 400000, 1234567, 'job-public',
                TIMESTAMPTZ '2026-07-11 20:00:00+00'
            );
            "#,
        )
        .execute(&test.pool)
        .await
        .expect("seed public provider earnings");

        let missing = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/v1/provider/earnings")
                    .body(Body::empty())
                    .expect("missing-wallet request"),
            )
            .await
            .expect("missing-wallet response");
        assert_eq!(missing.status(), StatusCode::BAD_REQUEST);

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/v1/provider/earnings?wallet=wallet-public")
                    .body(Body::empty())
                    .expect("public earnings request"),
            )
            .await
            .expect("public earnings response");
        assert_eq!(response.status(), StatusCode::OK);
        let payload = response_json(response).await;
        let keys = payload
            .as_object()
            .expect("earnings object")
            .keys()
            .cloned()
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(
            keys,
            [
                "balance_micro_usd",
                "balance_usd",
                "ledger",
                "payouts",
                "total_earned_micro_usd",
                "total_earned_usd",
                "total_jobs",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect()
        );
        assert_eq!(payload["balance_micro_usd"], 1_234_567);
        assert_eq!(payload["balance_usd"], "1.234567");
        assert_eq!(payload["total_earned_micro_usd"], 400_000);
        assert_eq!(payload["total_earned_usd"], "0.400000");
        assert_eq!(payload["total_jobs"], 1);
        assert_eq!(payload["payouts"][0]["provider_address"], "wallet-public");
        assert_eq!(payload["payouts"][0]["job_id"], "job-public");
        assert_eq!(
            payload["payouts"][0]["timestamp"],
            "2026-07-11T20:00:00.12Z"
        );
        assert_eq!(payload["ledger"][0]["type"], "payout");
        assert_eq!(payload["ledger"][0]["created_at"], "2026-07-11T20:00:00Z");
        assert!(payload.get("account_id").is_none());
        assert!(payload.get("email").is_none());

        let header_response = app
            .oneshot(
                Request::builder()
                    .uri("/v1/provider/earnings")
                    .header("x-provider-wallet", "wallet-public")
                    .body(Body::empty())
                    .expect("header wallet request"),
            )
            .await
            .expect("header wallet response");
        assert_eq!(header_response.status(), StatusCode::OK);

        test.stop().await;
    })
    .await;
}

#[tokio::test]
async fn pricing_writes_and_deletes_are_scoped_to_authenticated_owner() {
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
        let underpriced = app
            .clone()
            .oneshot(authenticated_json_request(
                "PUT",
                "/v1/pricing",
                json!({
                    "model": "owned-model",
                    "input_price": 1,
                    "output_price": 1
                }),
                principal("owner-b"),
                None,
            ))
            .await
            .expect("underpriced owner response");
        assert_eq!(underpriced.status(), StatusCode::OK);
        let prices: Vec<(String, i64, i64)> = sqlx::query_as(
            "SELECT account_id, input_price, output_price FROM public.model_prices WHERE model = 'owned-model' ORDER BY account_id",
        )
        .fetch_all(&test.pool)
        .await
        .expect("owner-scoped prices");
        assert_eq!(
            prices,
            vec![
                ("owner-a".to_owned(), 100, 200),
                ("owner-b".to_owned(), 1, 1),
            ]
        );
        let denied = app
            .clone()
            .oneshot(authenticated_json_request(
                "DELETE",
                "/v1/pricing",
                json!({"model": "owned-model"}),
                principal("owner-c"),
                None,
            ))
            .await
            .expect("delete response");
        assert_eq!(denied.status(), StatusCode::NOT_FOUND);
        let unchanged: Vec<(String, i64, i64)> = sqlx::query_as(
            "SELECT account_id, input_price, output_price FROM public.model_prices WHERE model = 'owned-model' ORDER BY account_id",
        )
        .fetch_all(&test.pool)
        .await
        .expect("unchanged owner-scoped prices");
        assert_eq!(unchanged, prices);
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
    UnknownTransferThenWorking,
    UnknownTransferThenPermanentFailure,
    UnknownTransferAlways,
}

struct TestStripe {
    base: String,
    transfer_keys: Arc<Mutex<Vec<String>>>,
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
                    StripeMode::Working
                    | StripeMode::UnknownCheckout
                    | StripeMode::UnknownTransferThenWorking
                    | StripeMode::UnknownTransferThenPermanentFailure
                    | StripeMode::UnknownTransferAlways => (
                        StatusCode::OK,
                        Json(json!({
                            "id": "cs_test_checkout",
                            "url": "https://checkout.stripe.test/session"
                        })),
                    ),
                }
            }
        };
        let transfer_attempts = Arc::new(AtomicUsize::new(0));
        let transfer_keys = Arc::new(Mutex::new(Vec::new()));
        let create_transfer = {
            let transfer_attempts = Arc::clone(&transfer_attempts);
            let transfer_keys = Arc::clone(&transfer_keys);
            move |headers: axum::http::HeaderMap| {
                let attempt = transfer_attempts.fetch_add(1, Ordering::SeqCst);
                let transfer_keys = Arc::clone(&transfer_keys);
                async move {
                    transfer_keys
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .push(
                            headers
                                .get("idempotency-key")
                                .and_then(|value| value.to_str().ok())
                                .unwrap_or_default()
                                .to_owned(),
                        );
                    match mode {
                        StripeMode::UnknownTransferThenWorking
                        | StripeMode::UnknownTransferThenPermanentFailure
                            if attempt == 0 =>
                        {
                            (
                                StatusCode::INTERNAL_SERVER_ERROR,
                                Json(json!({"error": {"message": "indeterminate transfer"}})),
                            )
                        }
                        StripeMode::UnknownTransferThenPermanentFailure => (
                            StatusCode::BAD_REQUEST,
                            Json(json!({"error": {"message": "transfer was rejected"}})),
                        ),
                        StripeMode::UnknownTransferAlways => (
                            StatusCode::INTERNAL_SERVER_ERROR,
                            Json(json!({"error": {"message": "indeterminate transfer"}})),
                        ),
                        StripeMode::Working
                        | StripeMode::UnknownCheckout
                        | StripeMode::UnknownTransferThenWorking => (
                            StatusCode::OK,
                            Json(json!({
                                "id": "tr_test_withdrawal",
                                "amount": 200,
                                "destination": "acct_provider",
                                "created": 1000
                            })),
                        ),
                    }
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
                get(|| async { Json(json!({"data": []})) }).post(create_transfer),
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
            transfer_keys,
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

    fn transfer_idempotency_keys(&self) -> Vec<String> {
        self.transfer_keys
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
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

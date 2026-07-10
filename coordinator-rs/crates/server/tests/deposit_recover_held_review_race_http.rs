//! Deposit vs recover-batch + held-review vs force-settle (DECISIONS #99).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn concurrent_deposit_and_recover_batch_conserves_balance() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-drb".into()),
            "drb-res",
            "pilot-account",
            150_000,
            epoch,
        )
        .unwrap();
    }

    let app = Arc::new(router(state.clone()));
    let mut deposit_handles = Vec::new();
    let mut recover_handles = Vec::new();

    for i in 0..4 {
        let app = app.clone();
        deposit_handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/deposits")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({
                                "event_id": format!("evt-drb-{i}"),
                                "amount_micro_usd": 40_000,
                                "withdrawable_micro_usd": 0
                            })
                            .to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["applied"].as_bool().unwrap()
        }));
    }
    for _ in 0..4 {
        let app = app.clone();
        recover_handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/recover-undispatched-batch")
                        .header("content-type", "application/json")
                        .body(Body::from("{}"))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["released_count"].as_u64().unwrap_or(0)
        }));
    }

    let mut applied = 0usize;
    for h in deposit_handles {
        if h.await.unwrap() {
            applied += 1;
        }
    }
    let mut released = 0u64;
    for h in recover_handles {
        released += h.await.unwrap();
    }
    assert_eq!(applied, 4);
    assert_eq!(released, 1);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000 + 160_000
    );
}

#[tokio::test]
async fn held_review_batch_never_moves_money_vs_force_settle() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-hrfs".into()),
            "hrfs-held",
            "pilot-account",
            100_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "hrfs-held", "pilot-account")
            .unwrap();
    }
    let bal_before = state.ledger.lock().await.balance("pilot-account").0;

    let app = Arc::new(router(state.clone()));
    let mut review_handles = Vec::new();
    let mut settle_handles = Vec::new();

    for _ in 0..8 {
        let app = app.clone();
        review_handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/held-review-batch")
                        .header("content-type", "application/json")
                        .body(Body::from("{}"))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await
        }));
    }
    for _ in 0..4 {
        let app = app.clone();
        settle_handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/force-settle-batch")
                        .header("content-type", "application/json")
                        .body(Body::from(r#"{"actual_micro_usd":25000}"#))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["settled_count"].as_u64().unwrap_or(0)
        }));
    }

    for h in review_handles {
        let v = h.await.unwrap();
        // Review never claims to move money.
        assert!(v.get("charged_micro_usd").is_none());
        assert!(v.get("refunded_micro_usd").is_none());
    }
    let mut settled = 0u64;
    for h in settle_handles {
        settled += h.await.unwrap();
    }
    assert_eq!(settled, 1);
    // Charged 25k from 100k reserved → bal = bal_before + 75k refund = start - 25k
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        bal_before + 75_000
    );
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
}

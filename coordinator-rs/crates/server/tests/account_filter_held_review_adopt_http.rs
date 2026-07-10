//! Account-filtered held-review-batch + adopt-jobs (DECISIONS #107).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn held_review_batch_account_filter_scopes_and_never_moves_money() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("rina", 250_000, 0).unwrap();
        led.credit("sam", 250_000, 0).unwrap();
        for (id, acct) in [("hr-r1", "rina"), ("hr-r2", "rina"), ("hr-s1", "sam")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                35_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct)
                .unwrap();
        }
    }
    let bal_rina = state.ledger.lock().await.balance("rina").0;
    let bal_sam = state.ledger.lock().await.balance("sam").0;
    let app = router(state.clone());

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/held-review-batch")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"account":"rina"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["account_filter"], "rina");
    assert_eq!(v["held_for_review_count"], 2);
    let reviews = v["reviews"].as_array().unwrap();
    assert_eq!(reviews.len(), 2);
    assert!(reviews.iter().all(|r| r["account_id"] == "rina"));
    assert_eq!(state.ledger.lock().await.balance("rina").0, bal_rina);
    assert_eq!(state.ledger.lock().await.balance("sam").0, bal_sam);
    assert_eq!(state.ledger.lock().await.held_start_authorized_count(), 3);
}

#[tokio::test]
async fn adopt_jobs_account_filter_then_force_settle_clears_one_account() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let old_epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("tina", 200_000, 0).unwrap();
        led.credit("uma", 200_000, 0).unwrap();
        for (id, acct) in [("aj-t1", "tina"), ("aj-t2", "tina"), ("aj-u1", "uma")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                40_000,
                old_epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(old_epoch, id, acct)
                .unwrap();
        }
    }
    ownership.release();
    ownership.acquire(Epoch(old_epoch + 10)).unwrap();

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-jobs")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"account":"tina"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["account_filter"], "tina");
    assert_eq!(v["adopted_count"], 2);

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle-batch")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"account":"tina","actual_micro_usd":0}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["settled_count"], 2);
    assert_eq!(state.ledger.lock().await.balance("tina").0, 200_000);
    // uma still held under old fencing epoch.
    assert_eq!(state.ledger.lock().await.held_start_authorized_count(), 1);
    assert_eq!(state.ledger.lock().await.balance("uma").0, 160_000);

    // Quiescence not ready — foreign orphan remains.
    let q = app
        .oneshot(
            Request::builder()
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q.status(), StatusCode::SERVICE_UNAVAILABLE);
    let qv = body_json(q).await;
    assert_eq!(qv["ready"], false);
    assert_eq!(qv["held_start_authorized"], 1);
}

#[tokio::test]
async fn concurrent_held_review_and_force_settle_account_filter() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("vera", 180_000, 0).unwrap();
        for id in ["cf-v1", "cf-v2"] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                "vera",
                30_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, "vera")
                .unwrap();
        }
    }
    let bal_before = state.ledger.lock().await.balance("vera").0;
    let app = Arc::new(router(state.clone()));

    let mut review_handles = Vec::new();
    let mut settle_handles = Vec::new();
    for _ in 0..5 {
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
                        .body(Body::from(r#"{"account":"vera"}"#))
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
                        .body(Body::from(r#"{"account":"vera","actual_micro_usd":0}"#))
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
        assert_eq!(v["account_filter"], "vera");
        // Review never reports money movement fields.
        assert!(v.get("refunded_micro_usd").is_none());
        assert!(v.get("charged_micro_usd").is_none());
    }
    let mut settled = 0u64;
    for h in settle_handles {
        settled += h.await.unwrap();
    }
    assert_eq!(settled, 2);
    assert_eq!(state.ledger.lock().await.balance("vera").0, bal_before + 60_000);
    assert_eq!(state.ledger.lock().await.held_start_authorized_count(), 0);
}

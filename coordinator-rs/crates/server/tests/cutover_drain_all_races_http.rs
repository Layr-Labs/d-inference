//! cutover-drain-all allowlist + concurrent/deposit races (DECISIONS #116).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn cutover_drain_all_allowlist_leaves_foreign() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("ally", 300_000, 0).unwrap();
        led.credit("beau", 300_000, 0).unwrap();
        for (id, acct) in [("al-a1", "ally"), ("al-a2", "ally"), ("al-b1", "beau")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                40_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct)
                .unwrap();
        }
    }
    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "accounts": ["ally"], "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "cutover_drain_all");
    assert_eq!(v["scoped_ready"], true);
    assert_eq!(v["ready"], false);
    assert_eq!(v["accounts_needing_cutover"], json!(["beau"]));
    assert_eq!(state.ledger.lock().await.balance("ally").0, 300_000);
    assert_eq!(state.ledger.lock().await.balance("beau").0, 260_000);
    assert_eq!(state.ledger.lock().await.held_start_authorized_count(), 1);

    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "accounts": ["beau"], "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(state.ledger.lock().await.balance("beau").0, 300_000);
}

#[tokio::test]
async fn cutover_drain_all_idempotent_when_ready() {
    let state = pilot_app_state(true);
    let app = router(state.clone());
    for _ in 0..3 {
        let res = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/cutover-drain-all")
                    .header("content-type", "application/json")
                    .body(Body::from("{}"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let v = body_json(res).await;
        assert_eq!(v["ready"], true);
        assert_eq!(v["scoped_ready"], true);
        assert_eq!(v["rounds_run"], 0);
    }
    assert_eq!(state.ledger.lock().await.balance("pilot-account").0, 1_000_000);
}

#[tokio::test]
async fn concurrent_cutover_drain_all_conserves_balance() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("cory", 400_000, 0).unwrap();
        led.credit("drew", 400_000, 0).unwrap();
        for (id, acct) in [
            ("cc-c1", "cory"),
            ("cc-c2", "cory"),
            ("cc-d1", "drew"),
            ("cc-d2", "drew"),
        ] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                50_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct)
                .unwrap();
        }
    }
    let app = Arc::new(router(state.clone()));
    let mut handles = Vec::new();
    for _ in 0..4 {
        let app = app.clone();
        handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/cutover-drain-all")
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
    let mut any_ready = false;
    for h in handles {
        let v = h.await.unwrap();
        if v["ready"] == true {
            any_ready = true;
        }
    }
    assert!(any_ready);
    assert_eq!(state.ledger.lock().await.balance("cory").0, 400_000);
    assert_eq!(state.ledger.lock().await.balance("drew").0, 400_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
}

#[tokio::test]
async fn deposit_vs_cutover_drain_all_conserves() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("eden", 250_000, 0).unwrap();
        for id in ["dv-e1", "dv-e2"] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                "eden",
                30_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, "eden")
                .unwrap();
        }
    }
    let bal_start = state.ledger.lock().await.balance("eden").0;
    let app = Arc::new(router(state.clone()));

    let cut = {
        let app = app.clone();
        tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/cutover-drain-all")
                        .header("content-type", "application/json")
                        .body(Body::from("{}"))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await
        })
    };
    let mut deps = Vec::new();
    for i in 0..6 {
        let app = app.clone();
        deps.push(tokio::spawn(async move {
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
                                "event_id": format!("cda-dep-{i}"),
                                "amount_micro_usd": 10_000,
                                "account": "eden"
                            })
                            .to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["applied"].as_bool().unwrap_or(false)
        }));
    }
    let cut_v = cut.await.unwrap();
    assert_eq!(cut_v["ready"], true);
    let mut applied = 0u64;
    for h in deps {
        if h.await.unwrap() {
            applied += 1;
        }
    }
    assert_eq!(applied, 6);
    // Start had 60k reserved; clear refunds → bal_start+60k; +60k deposits.
    assert_eq!(
        state.ledger.lock().await.balance("eden").0,
        bal_start + 60_000 + 60_000
    );
}

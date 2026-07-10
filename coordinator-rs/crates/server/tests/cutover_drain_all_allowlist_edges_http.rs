//! cutover-drain-all concurrent allowlists + max_rounds (DECISIONS #118).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn concurrent_disjoint_allowlist_cutover_drain_all() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (acct, ids) in [
            ("finn", &["cd-f1", "cd-f2"][..]),
            ("gina", &["cd-g1"][..]),
            ("hugo", &["cd-h1", "cd-h2"][..]),
        ] {
            led.credit(acct, 400_000, 0).unwrap();
            for id in ids {
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
    }
    let app = Arc::new(router(state.clone()));
    let mut handles = Vec::new();
    for acct in ["finn", "gina", "hugo"] {
        let app = app.clone();
        let acct = acct.to_string();
        handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/cutover-drain-all")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({
                                "accounts": [acct],
                                "actual_micro_usd": 0
                            })
                            .to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await
        }));
    }
    let mut scoped = 0u64;
    for h in handles {
        let v = h.await.unwrap();
        assert_eq!(v["scoped_ready"], true);
        if v["accounts_cleared"].as_array().unwrap().len() >= 1 {
            scoped += 1;
        }
    }
    assert_eq!(scoped, 3);
    assert_eq!(state.ledger.lock().await.balance("finn").0, 400_000);
    assert_eq!(state.ledger.lock().await.balance("gina").0, 400_000);
    assert_eq!(state.ledger.lock().await.balance("hugo").0, 400_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);

    // Global ready after all allowlists finished.
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
    assert_eq!(body_json(res).await["ready"], true);
}

#[tokio::test]
async fn cutover_drain_all_max_rounds_one_clears_multi_tenant() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (acct, id) in [("iris", "mr-i1"), ("jade", "mr-j1"), ("kyle", "mr-k1")] {
            led.credit(acct, 200_000, 0).unwrap();
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                20_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct)
                .unwrap();
        }
    }
    let app = router(state.clone());
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "max_rounds": 1,
                        "actual_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(v["rounds_run"], 1);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
    assert_eq!(state.ledger.lock().await.balance("iris").0, 200_000);
    assert_eq!(state.ledger.lock().await.balance("jade").0, 200_000);
    assert_eq!(state.ledger.lock().await.balance("kyle").0, 200_000);
}

#[tokio::test]
async fn cutover_drain_all_unknown_allowlist_is_scoped_ready() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("jade", 150_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-j1".into()),
            "ua-j1",
            "jade",
            25_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "ua-j1", "jade")
            .unwrap();
    }
    let app = router(state.clone());
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "accounts": ["nobody"],
                        "actual_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["scoped_ready"], true);
    assert_eq!(v["ready"], false);
    assert_eq!(v["accounts_needing_cutover"], json!(["jade"]));
    assert_eq!(state.ledger.lock().await.balance("jade").0, 125_000);
}

#[tokio::test]
async fn charged_allowlist_cutover_drain_all() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("kite", 500_000, 0).unwrap();
        led.credit("liam", 500_000, 0).unwrap();
        for (id, acct) in [("ch-k1", "kite"), ("ch-k2", "kite"), ("ch-l1", "liam")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                100_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct)
                .unwrap();
        }
    }
    let app = router(state.clone());
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "accounts": ["kite"],
                        "actual_micro_usd": 30_000
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["scoped_ready"], true);
    assert_eq!(v["ready"], false);
    // kite: 2×30k charged → 440k; liam untouched at 400k reserved.
    assert_eq!(state.ledger.lock().await.balance("kite").0, 440_000);
    assert_eq!(state.ledger.lock().await.balance("liam").0, 400_000);
}

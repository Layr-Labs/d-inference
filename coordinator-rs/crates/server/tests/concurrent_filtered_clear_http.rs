//! Concurrent filtered clear-orphans after adopt-all fencing (DECISIONS #122).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn concurrent_filtered_clear_adopts_all_conserves_money() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let old = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (acct, ids) in [
            ("tina", &["cf-t1", "cf-t2"][..]),
            ("uma", &["cf-u1"][..]),
            ("vera", &["cf-v1", "cf-v2"][..]),
        ] {
            led.credit(acct, 400_000, 0).unwrap();
            for id in ids {
                led.reserve_with_epoch(
                    darkbloom_coordinator::OperationKey(format!("r-{id}")),
                    id,
                    acct,
                    50_000,
                    old,
                )
                .unwrap();
                led.mark_start_authorized_fenced(old, id, acct).unwrap();
            }
        }
    }
    ownership.release();
    ownership.acquire(Epoch(old + 40)).unwrap();

    let app = Arc::new(router(state.clone()));
    let mut handles = Vec::new();
    for acct in ["tina", "uma", "vera"] {
        let app = app.clone();
        let acct = acct.to_string();
        handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/clear-orphans")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({
                                "account": acct,
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

    let mut settled_total = 0u64;
    let mut max_adopted = 0u64;
    for h in handles {
        let v = h.await.unwrap();
        settled_total += v["settled_count"].as_u64().unwrap_or(0);
        max_adopted = max_adopted.max(v["adopted_count"].as_u64().unwrap_or(0));
    }
    // Exactly 5 holds cleared across concurrent filtered clears.
    assert_eq!(settled_total, 5);
    // At least one caller saw all 5 jobs during adopt (first to run).
    assert!(max_adopted >= 1);
    assert_eq!(state.ledger.lock().await.balance("tina").0, 400_000);
    assert_eq!(state.ledger.lock().await.balance("uma").0, 400_000);
    assert_eq!(state.ledger.lock().await.balance("vera").0, 400_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
    assert_eq!(state.ledger.lock().await.balance("pilot-account").0, 1_000_000);
}

#[tokio::test]
async fn deposit_during_filtered_clear_conserves() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let old = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("wynn", 300_000, 0).unwrap();
        led.credit("xavi", 300_000, 0).unwrap();
        for (id, acct) in [("dc-w1", "wynn"), ("dc-w2", "wynn"), ("dc-x1", "xavi")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                40_000,
                old,
            )
            .unwrap();
            led.mark_start_authorized_fenced(old, id, acct).unwrap();
        }
    }
    ownership.release();
    ownership.acquire(Epoch(old + 55)).unwrap();
    let bal_xavi_start = state.ledger.lock().await.balance("xavi").0;

    let app = Arc::new(router(state.clone()));
    let clear = {
        let app = app.clone();
        tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/clear-orphans")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({ "account": "wynn", "actual_micro_usd": 0 }).to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await
        })
    };
    let mut deps = Vec::new();
    for i in 0..5 {
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
                                "event_id": format!("fc-dep-{i}"),
                                "amount_micro_usd": 12_000,
                                "account": "xavi"
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

    let clear_v = clear.await.unwrap();
    assert_eq!(clear_v["settled_count"], 2);
    assert_eq!(state.ledger.lock().await.balance("wynn").0, 300_000);
    // xavi still held (one job) but fencing adopted — balance still reserved.
    assert_eq!(state.ledger.lock().await.held_start_authorized_count(), 1);

    let mut applied = 0u64;
    for h in deps {
        if h.await.unwrap() {
            applied += 1;
        }
    }
    assert_eq!(applied, 5);
    assert_eq!(
        state.ledger.lock().await.balance("xavi").0,
        bal_xavi_start + 60_000
    );

    // Finish xavi without adopt (fencing already rebound).
    let res = app
        .as_ref()
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "account": "xavi", "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(state.ledger.lock().await.balance("xavi").0, bal_xavi_start + 60_000 + 40_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
}

#[tokio::test]
async fn concurrent_filtered_cutover_drain_after_shared_adopt() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let old = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (acct, id) in [("yara", "cd-y1"), ("zane", "cd-z1")] {
            led.credit(acct, 200_000, 0).unwrap();
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                30_000,
                old,
            )
            .unwrap();
            led.mark_start_authorized_fenced(old, id, acct).unwrap();
        }
    }
    ownership.release();
    ownership.acquire(Epoch(old + 70)).unwrap();

    let app = Arc::new(router(state.clone()));
    let mut handles = Vec::new();
    for acct in ["yara", "zane"] {
        let app = app.clone();
        let acct = acct.to_string();
        handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/cutover-drain")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({
                                "account": acct,
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
    for h in handles {
        let v = h.await.unwrap();
        // Each call adopts both (or already-adopted), settles its own.
        assert!(v["clear_orphans"]["adopted_count"].as_u64().unwrap() <= 2);
    }
    assert_eq!(state.ledger.lock().await.balance("yara").0, 200_000);
    assert_eq!(state.ledger.lock().await.balance("zane").0, 200_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
}

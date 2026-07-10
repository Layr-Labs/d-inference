//! Ops loop over accounts_needing_cutover + outbox-only hint (DECISIONS #113).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn ops_loop_accounts_needing_cutover_reaches_ready() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (acct, ids) in [
            ("iris", &["ol-i1", "ol-i2"][..]),
            ("jade", &["ol-j1"][..]),
            ("kite", &["ol-k1", "ol-k2"][..]),
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
    let app = router(state.clone());

    // Discover tenants from quiescence, clear each, then drain.
    let mut rounds = 0;
    loop {
        rounds += 1;
        assert!(rounds <= 10, "ops loop did not converge");
        let q = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/v1/admin/quiescence")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let qv = body_json(q).await;
        if qv["ready"] == true {
            break;
        }
        let accounts: Vec<String> = qv["accounts_needing_cutover"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();
        if accounts.is_empty() {
            assert_eq!(qv["cutover_hint"], "outbox-drain");
            let res = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/outbox-drain")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            continue;
        }
        for acct in accounts {
            let res = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/cutover-drain")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({ "account": acct, "actual_micro_usd": 0 }).to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
        }
    }
    assert_eq!(state.ledger.lock().await.balance("iris").0, 400_000);
    assert_eq!(state.ledger.lock().await.balance("jade").0, 400_000);
    assert_eq!(state.ledger.lock().await.balance("kite").0, 400_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
}

#[tokio::test]
async fn outbox_only_quiescence_accounts_needing_cutover_empty() {
    let state = pilot_app_state(true);
    {
        let mut box_ = state.outbox.lock().await;
        let _ = box_.enqueue_critical("billing.deposit_applied", r#"{"event_id":"oo-1"}"#);
        let _ = box_.enqueue_critical("inference.settled", r#"{"job_id":"oo-j"}"#);
    }
    let app = router(state.clone());
    let q = app
        .clone()
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
    assert_eq!(qv["active_jobs"], 0);
    assert_eq!(qv["cutover_hint"], "outbox-drain");
    assert!(qv["accounts_needing_cutover"]
        .as_array()
        .unwrap()
        .is_empty());
    assert!(qv["orphan_summary_by_account"]
        .as_array()
        .unwrap()
        .is_empty());

    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/outbox-drain")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["ready"], true);
}

#[tokio::test]
async fn deposit_foreign_account_during_filtered_cutover_conserves() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("lena", 300_000, 0).unwrap();
        led.credit("mira", 300_000, 0).unwrap();
        for id in ["df-l1", "df-l2"] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                "lena",
                40_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, "lena")
                .unwrap();
        }
    }
    let app = Arc::new(router(state.clone()));
    let cutover = {
        let app = app.clone();
        tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/cutover-drain")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({ "account": "lena", "actual_micro_usd": 0 }).to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await
        })
    };
    let mut dep_handles = Vec::new();
    for i in 0..5 {
        let app = app.clone();
        dep_handles.push(tokio::spawn(async move {
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
                                "event_id": format!("df-mira-{i}"),
                                "amount_micro_usd": 15_000,
                                "account": "mira"
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
    let cut = cutover.await.unwrap();
    assert_eq!(cut["clear_orphans"]["settled_count"], 2);
    let mut applied = 0u64;
    for h in dep_handles {
        if h.await.unwrap() {
            applied += 1;
        }
    }
    // Idempotent: exactly 5 unique events applied across races.
    assert_eq!(applied, 5);
    assert_eq!(state.ledger.lock().await.balance("lena").0, 300_000);
    assert_eq!(state.ledger.lock().await.balance("mira").0, 300_000 + 75_000);

    // Drain deposit outbox side effects; lena already cleared.
    let res = app
        .as_ref()
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/outbox-drain")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(state.ledger.lock().await.balance("mira").0, 375_000);
}

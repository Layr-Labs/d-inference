//! Concurrent deposit vs cutover-drain conserves money (DECISIONS #94).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn concurrent_deposit_and_cutover_drain_conserves_balance() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-dcd".into()),
            "dcd-res",
            "pilot-account",
            80_000,
            epoch0,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-dcd-h".into()),
            "dcd-held",
            "pilot-account",
            120_000,
            epoch0,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch0, "dcd-held", "pilot-account")
            .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(81)).unwrap();

    let app = Arc::new(router(state.clone()));
    let mut deposit_handles = Vec::new();
    let mut drain_handles = Vec::new();

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
                                "event_id": format!("evt-dcd-{i}"),
                                "amount_micro_usd": 25_000,
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
        drain_handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/cutover-drain")
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

    let mut applied = 0usize;
    for h in deposit_handles {
        if h.await.unwrap() {
            applied += 1;
        }
    }
    let mut released = 0usize;
    let mut settled = 0usize;
    for h in drain_handles {
        let v = h.await.unwrap();
        released += v["clear_orphans"]["released_count"]
            .as_u64()
            .unwrap_or(0) as usize;
        settled += v["clear_orphans"]["settled_count"]
            .as_u64()
            .unwrap_or(0) as usize;
    }

    assert_eq!(applied, 4);
    assert_eq!(released, 1);
    assert_eq!(settled, 1);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
    assert_eq!(state.outbox.lock().await.pending_under_retry_cap(), 0);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000 + 100_000
    );
}

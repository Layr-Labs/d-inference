//! Concurrent HTTP force-settle vs recover-undispatched: force clears; recover never releases.

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use tower::ServiceExt;

fn test_state() -> darkbloom_coordinator::AppState {
    pilot_app_state(true)
}

#[tokio::test]
async fn concurrent_http_force_settle_vs_recover_undispatched() {
    let state = test_state();
    let ledger = state.ledger.clone();
    {
        let mut led = ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-fru".into()),
            "held-fru",
            "pilot-account",
            160_000,
        )
        .unwrap();
        led.mark_start_authorized("held-fru", "pilot-account")
            .unwrap();
    }
    let app = router(state);

    let app_f = app.clone();
    let force = tokio::spawn(async move {
        let res = app_f
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/force-settle")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "job_id": "held-fru",
                            "actual_micro_usd": 40_000,
                            "terminal_digest": "fru-d"
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        body_json(res).await["action"].as_str().unwrap().to_string()
    });

    let mut recovers = Vec::new();
    for _ in 0..8 {
        let app = app.clone();
        recovers.push(tokio::spawn(async move {
            let res = app
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/recover-undispatched")
                        .header("content-type", "application/json")
                        .body(Body::from(json!({ "job_id": "held-fru" }).to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["action"].as_str().unwrap().to_string()
        }));
    }

    assert_eq!(force.await.unwrap(), "released");
    for h in recovers {
        match h.await.unwrap().as_str() {
            // skipped while still start_authorized; already_terminal after force
            "skipped" | "already_terminal" => {}
            other => panic!("recover must never release authorized job; got {other}"),
        }
    }

    let led = ledger.lock().await;
    assert_eq!(led.active_job_count(), 0);
    assert_eq!(led.job_disposition("held-fru"), Some("force_settled"));
    // 1M - 160k + 120k refund = 960k
    assert_eq!(led.balance("pilot-account").0, 960_000);
}

//! Concurrent HTTP recover-undispatched vs force-settle on reserved-only job.

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
async fn concurrent_http_recover_vs_force_on_reserved_only() {
    let state = test_state();
    let ledger = state.ledger.clone();
    {
        let mut led = ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-rf".into()),
            "reserved-rf",
            "pilot-account",
            110_000,
        )
        .unwrap();
    }
    let app = router(state);

    let app_r = app.clone();
    let recover = tokio::spawn(async move {
        let res = app_r
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/recover-undispatched")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({ "job_id": "reserved-rf" }).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        body_json(res).await["action"].as_str().unwrap().to_string()
    });

    let mut forces = Vec::new();
    for _ in 0..8 {
        let app = app.clone();
        forces.push(tokio::spawn(async move {
            let res = app
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/force-settle")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({
                                "job_id": "reserved-rf",
                                "actual_micro_usd": 10_000,
                                "terminal_digest": "rf-d"
                            })
                            .to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["action"].as_str().unwrap().to_string()
        }));
    }

    let recovered = recover.await.unwrap();
    assert!(
        recovered == "released" || recovered == "already_terminal",
        "unexpected recover {recovered}"
    );
    for h in forces {
        match h.await.unwrap().as_str() {
            // skipped while still reserved; already_terminal if recover disposed first
            "skipped" | "already_terminal" => {}
            other => panic!("force must not settle reserved-only; got {other}"),
        }
    }

    let led = ledger.lock().await;
    // Exactly one of recover/force paths can clear — force never settles reserved-only,
    // so recover must have released (or we would still have an active job).
    assert_eq!(led.active_job_count(), 0);
    assert_eq!(led.balance("pilot-account").0, 1_000_000);
    assert_eq!(recovered, "released");
}

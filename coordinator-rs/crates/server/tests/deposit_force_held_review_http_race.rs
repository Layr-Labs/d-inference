//! Concurrent HTTP deposit + force-settle + held-review: money conserved.

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
async fn concurrent_http_deposit_force_held_review_conserves() {
    let state = test_state();
    let ledger = state.ledger.clone();
    {
        let mut led = ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-dfh".into()),
            "held-dfh",
            "pilot-account",
            200_000,
        )
        .unwrap();
        led.mark_start_authorized("held-dfh", "pilot-account")
            .unwrap();
    }
    let app = router(state);

    let app_d = app.clone();
    let deposit = tokio::spawn(async move {
        let res = app_d
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/deposits")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "event_id": "evt_dfh",
                            "amount_micro_usd": 55_000,
                            "withdrawable_micro_usd": 5_000
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        body_json(res).await["applied"].as_bool().unwrap()
    });

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
                            "job_id": "held-dfh",
                            "actual_micro_usd": 70_000,
                            "terminal_digest": "dfh-d"
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        body_json(res).await["action"].as_str().unwrap() == "released"
    });

    let mut reviews = Vec::new();
    for _ in 0..8 {
        let app = app.clone();
        reviews.push(tokio::spawn(async move {
            let res = app
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/held-review")
                        .header("content-type", "application/json")
                        .body(Body::from(json!({ "job_id": "held-dfh" }).to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["action"].as_str().unwrap().to_string()
        }));
    }

    assert!(deposit.await.unwrap());
    assert!(force.await.unwrap());
    for h in reviews {
        match h.await.unwrap().as_str() {
            "held_for_review" | "already_terminal" => {}
            other => panic!("unexpected {other}"),
        }
    }

    let led = ledger.lock().await;
    assert_eq!(led.active_job_count(), 0);
    // 1M + 55k deposit - 70k charge = 985_000
    assert_eq!(led.balance("pilot-account").0, 985_000);
    assert_eq!(led.job_disposition("held-dfh"), Some("force_settled"));
}

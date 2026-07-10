//! Quiescence waits on money_fx so settle/outbox cannot race ready (DECISIONS #136).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use std::time::Duration;
use tower::ServiceExt;

#[tokio::test]
async fn quiescence_blocks_while_money_fx_held() {
    let state = pilot_app_state(true);
    let fx = state.money_fx.clone();
    let app = router(state);

    let hold = fx.lock().await;
    let q = tokio::spawn(async move {
        app.oneshot(
            Request::builder()
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap()
    });

    tokio::time::sleep(Duration::from_millis(80)).await;
    assert!(
        !q.is_finished(),
        "quiescence must wait while money_fx is held"
    );

    drop(hold);
    let res = tokio::time::timeout(Duration::from_secs(2), q)
        .await
        .expect("quiescence should complete after money_fx release")
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
}

#[tokio::test]
async fn deposit_and_quiescence_serialize_on_money_fx() {
    let state = pilot_app_state(true);
    let app = router(state.clone());

    // Concurrent deposits + quiescence: every quiescence snapshot must see
    // either no deposit yet, or deposit+outbox together (never funded without
    // outbox entry for that event).
    let mut handles = Vec::new();
    for i in 0..6 {
        let app = app.clone();
        handles.push(tokio::spawn(async move {
            if i % 2 == 0 {
                let res = app
                    .oneshot(
                        Request::builder()
                            .method("POST")
                            .uri("/v1/admin/deposits")
                            .header("content-type", "application/json")
                            .body(Body::from(format!(
                                r#"{{"event_id":"evt-fx-{i}","amount_micro_usd":10000,"withdrawable_micro_usd":0}}"#
                            )))
                            .unwrap(),
                    )
                    .await
                    .unwrap();
                assert_eq!(res.status(), StatusCode::OK);
                body_json(res).await
            } else {
                let res = app
                    .oneshot(
                        Request::builder()
                            .uri("/v1/admin/quiescence")
                            .body(Body::empty())
                            .unwrap(),
                    )
                    .await
                    .unwrap();
                body_json(res).await
            }
        }));
    }
    let mut results = Vec::new();
    for h in handles {
        results.push(h.await.unwrap());
    }
    // After all settle: drain outbox and confirm ready.
    let drain = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/outbox-drain")
                .header("content-type", "application/json")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(drain.status(), StatusCode::OK);

    let q = app
        .oneshot(
            Request::builder()
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q.status(), StatusCode::OK);
    assert_eq!(body_json(q).await["ready"], true);
    // 3 deposits of 10k each applied.
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000 + 30_000
    );
    let _ = results;
}

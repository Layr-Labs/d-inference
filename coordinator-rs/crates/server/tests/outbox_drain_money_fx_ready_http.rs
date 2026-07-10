//! Outbox-drain final ready snapshot waits on money_fx (DECISIONS #147).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use std::time::Duration;
use tower::ServiceExt;

#[tokio::test]
async fn outbox_drain_ready_blocks_while_money_fx_held() {
    let state = pilot_app_state(true);
    let fx = state.money_fx.clone();
    let app = router(state);

    let hold = fx.lock().await;
    let drain = tokio::spawn(async move {
        app.oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/outbox-drain")
                .header("content-type", "application/json")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap()
    });

    tokio::time::sleep(Duration::from_millis(120)).await;
    assert!(
        !drain.is_finished(),
        "outbox-drain final ready snapshot must wait on money_fx"
    );

    drop(hold);
    let res = tokio::time::timeout(Duration::from_secs(2), drain)
        .await
        .expect("drain should complete after money_fx release")
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "outbox_drained");
    assert_eq!(v["ready"], true);
    assert_eq!(v["acked_count"], 0);
}

//! Single-job recover-undispatched holds money_fx (DECISIONS #143).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use std::time::Duration;
use tower::ServiceExt;

#[tokio::test]
async fn recover_undispatched_blocks_while_money_fx_held() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-rfx".into()),
            "rfx-1",
            "pilot-account",
            25_000,
            epoch,
        )
        .unwrap();
    }

    let fx = state.money_fx.clone();
    let app = router(state.clone());
    let hold = fx.lock().await;

    let recover = {
        let app = app.clone();
        tokio::spawn(async move {
            app.oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/recover-undispatched")
                    .header("content-type", "application/json")
                    .body(Body::from(json!({ "job_id": "rfx-1" }).to_string()))
                    .unwrap(),
            )
            .await
            .unwrap()
        })
    };

    tokio::time::sleep(Duration::from_millis(80)).await;
    assert!(
        !recover.is_finished(),
        "recover-undispatched must wait on money_fx"
    );
    drop(hold);

    let res = tokio::time::timeout(Duration::from_secs(5), recover)
        .await
        .expect("recover should complete")
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["action"], "released");
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
    assert!(state.outbox.lock().await.len() >= 1);
}

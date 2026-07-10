//! clear-orphans holds money_fx per job (DECISIONS #140).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use std::time::Duration;
use tower::ServiceExt;

#[tokio::test]
async fn clear_orphans_blocks_while_money_fx_held() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-cox".into()),
            "cox-1",
            "pilot-account",
            30_000,
            epoch,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-cox2".into()),
            "cox-2",
            "pilot-account",
            20_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "cox-2", "pilot-account")
            .unwrap();
    }

    let fx = state.money_fx.clone();
    let app = router(state.clone());
    let hold = fx.lock().await;

    let clear = {
        let app = app.clone();
        tokio::spawn(async move {
            app.oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/clear-orphans")
                    .header("content-type", "application/json")
                    .body(Body::from(json!({ "actual_micro_usd": 0 }).to_string()))
                    .unwrap(),
            )
            .await
            .unwrap()
        })
    };

    tokio::time::sleep(Duration::from_millis(80)).await;
    assert!(
        !clear.is_finished(),
        "clear-orphans must wait on money_fx during money phases"
    );
    drop(hold);

    let res = tokio::time::timeout(Duration::from_secs(5), clear)
        .await
        .expect("clear should complete")
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["released_count"], 1);
    assert_eq!(v["settled_count"], 1);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
}

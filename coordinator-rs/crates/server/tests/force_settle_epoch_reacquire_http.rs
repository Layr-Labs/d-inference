//! After ownership re-acquire with a new epoch, force-settle of an older job
//! is refused (DECISIONS #52).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn force_settle_after_epoch_reacquire_returns_ownership_lost() {
    let state = pilot_app_state(true);
    let epoch_at_reserve = state.ownership.epoch().0;
    assert_eq!(epoch_at_reserve, 9);

    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-ep".into()),
            "held-ep",
            "pilot-account",
            100_000,
        )
        .unwrap();
        led.bind_fencing_epoch("held-ep", epoch_at_reserve).unwrap();
        led.mark_start_authorized("held-ep", "pilot-account")
            .unwrap();
    }

    // Steal and re-acquire with a newer fencing epoch.
    state.ownership.release();
    state.ownership.acquire(Epoch(10)).unwrap();
    assert_eq!(state.ownership.epoch().0, 10);

    let app = router(state.clone());
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "held-ep",
                        "actual_micro_usd": 10_000,
                        "terminal_digest": "ep-d"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");

    let led = state.ledger.lock().await;
    assert_eq!(led.held_start_authorized_count(), 1);
    assert_eq!(led.balance("pilot-account").0, 900_000);
}

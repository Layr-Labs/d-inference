//! After ownership re-acquire with a new epoch, recover-undispatched of an
//! older reserved job is refused (DECISIONS #52).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn recover_after_epoch_reacquire_returns_ownership_lost() {
    let state = pilot_app_state(true);
    let epoch_at_reserve = state.ownership.epoch().0;

    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-rec-ep".into()),
            "undisp-ep",
            "pilot-account",
            80_000,
        )
        .unwrap();
        led.bind_fencing_epoch("undisp-ep", epoch_at_reserve)
            .unwrap();
    }

    state.ownership.release();
    state.ownership.acquire(Epoch(11)).unwrap();
    assert_eq!(state.ownership.epoch().0, 11);

    let app = router(state.clone());
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "undisp-ep" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");

    let led = state.ledger.lock().await;
    assert_eq!(led.active_job_count(), 1);
    assert_eq!(led.balance("pilot-account").0, 920_000);
}

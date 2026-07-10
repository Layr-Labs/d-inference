//! Deposit after ownership release refuses money move (DECISIONS #64).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn admin_deposit_after_ownership_release_returns_503() {
    let state = pilot_app_state(true);
    let ledger = state.ledger.clone();
    let bal_before = ledger.lock().await.balance("pilot-account").0;

    // Steal ownership after route would have passed require_admin's initial check
    // if we released mid-handler — here we release before the request so both
    // require_admin and the money-boundary re-check refuse.
    state.ownership.release();

    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_after_steal",
                        "amount_micro_usd": 250_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");
    assert_eq!(ledger.lock().await.balance("pilot-account").0, bal_before);
}

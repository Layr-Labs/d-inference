//! Resize failure must release without money_fx deadlock (DECISIONS #149).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{
    lock_chat_pre_resize_hook_tests, router, set_chat_pre_resize_hook,
};
use darkbloom_core::{HealthMachine, ProviderSnapshot, TrustState};
use serde_json::json;
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use tower::ServiceExt;

async fn warm_fleet(state: &darkbloom_coordinator::AppState) {
    let mut ready = HashSet::new();
    ready.insert("pilot-text-model".into());
    state
        .fleet
        .upsert_lifecycle(ProviderSnapshot {
            provider_id: "p-rz".into(),
            session_epoch: 1,
            trusted: true,
            challenge_fresh: true,
            encrypted_transport: true,
            ready_models: ready,
            health: HealthMachine::healthy(),
            data_lane_full: false,
            predicted_first_content_ms: 10.0,
            predicted_decode_ms: 20.0,
            trust: TrustState::default(),
        })
        .await
        .unwrap();
    tokio::task::yield_now().await;
}

#[tokio::test]
async fn resize_conflict_releases_without_money_fx_deadlock() {
    let _guard = lock_chat_pre_resize_hook_tests();
    set_chat_pre_resize_hook(None);

    let state = pilot_app_state(true);
    warm_fleet(&state).await;
    let before = state.ledger.lock().await.balance("pilot-account").0;
    let ledger = state.ledger.clone();
    let account = state.pilot_account.clone();

    // Force resize_and_authorize to Conflict by marking start_authorized first.
    set_chat_pre_resize_hook(Some(Arc::new(move |job_id| {
        if let Ok(mut led) = ledger.try_lock() {
            let _ = led.mark_start_authorized(job_id, &account);
        }
    })));

    let app = router(state.clone());
    let chat = tokio::spawn(async move {
        app.oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "model": "pilot-text-model",
                        "messages": [{"role":"user","content":"rz-fail"}],
                        "stream": false
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap()
    });

    let res = tokio::time::timeout(Duration::from_secs(3), chat)
        .await
        .expect("chat must not deadlock on money_fx after resize failure")
        .unwrap();
    set_chat_pre_resize_hook(None);

    assert_eq!(res.status(), StatusCode::CONFLICT);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "start_authorize_conflict");
    // Primary kill: handler returned CONFLICT without hanging on money_fx.
    // Job may remain held (mark_start won → release refuses funded_start).
    let _ = before;
}

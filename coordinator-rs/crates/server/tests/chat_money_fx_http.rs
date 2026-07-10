//! Chat settle runs under money_fx with outbox (DECISIONS #137).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use darkbloom_core::{HealthMachine, ProviderSnapshot, TrustState};
use serde_json::json;
use std::collections::HashSet;
use std::time::Duration;
use tower::ServiceExt;

async fn warm_fleet(state: &darkbloom_coordinator::AppState) {
    let mut ready = HashSet::new();
    ready.insert("pilot-text-model".into());
    state
        .fleet
        .upsert_lifecycle(ProviderSnapshot {
            provider_id: "p-fx".into(),
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
async fn mock_chat_settle_blocks_while_money_fx_held() {
    let state = pilot_app_state(true);
    warm_fleet(&state).await;
    let fx = state.money_fx.clone();
    let app = router(state.clone());

    let hold = fx.lock().await;
    let chat = {
        let app = app.clone();
        tokio::spawn(async move {
            app.oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "model": "pilot-text-model",
                            "messages": [{"role":"user","content":"blocked"}],
                            "stream": false
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap()
        })
    };

    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(
        !chat.is_finished(),
        "chat must wait on money_fx during settle+outbox"
    );

    drop(hold);
    let res = tokio::time::timeout(Duration::from_secs(5), chat)
        .await
        .expect("chat should complete after money_fx release")
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert!(v["choices"][0]["message"]["content"]
        .as_str()
        .unwrap_or("")
        .contains("blocked"));
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
    assert!(state.outbox.lock().await.len() >= 1);
}

#[tokio::test]
async fn mock_chat_happy_path_settles_and_enqueues_outbox() {
    let state = pilot_app_state(true);
    warm_fleet(&state).await;
    let before_bal = state.ledger.lock().await.balance("pilot-account").0;
    let before_outbox = state.outbox.lock().await.len();
    let app = router(state.clone());
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "model": "pilot-text-model",
                        "messages": [{"role":"user","content":"settle-me"}],
                        "stream": false
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert!(v["choices"][0]["message"]["content"]
        .as_str()
        .unwrap_or("")
        .contains("settle-me"));
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
    assert!(state.outbox.lock().await.len() > before_outbox);
    // Charged 1000 µUSD for mock settle.
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        before_bal - 1_000
    );
}

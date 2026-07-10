//! Force-settle during chat must not enqueue a second inference.settled (DECISIONS #154).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{
    lock_chat_pre_settle_hook_tests, router, set_chat_pre_settle_hook,
};
use darkbloom_core::{HealthMachine, ProviderSnapshot, TrustState};
use serde_json::json;
use std::collections::HashSet;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::time::Duration;
use tower::ServiceExt;

async fn warm_fleet(state: &darkbloom_coordinator::AppState) {
    let mut ready = HashSet::new();
    ready.insert("pilot-text-model".into());
    state
        .fleet
        .upsert_lifecycle(ProviderSnapshot {
            provider_id: "p-ss".into(),
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn force_settle_before_chat_settle_no_duplicate_outbox() {
    let _guard = lock_chat_pre_settle_hook_tests();
    set_chat_pre_settle_hook(None);

    let state = pilot_app_state(true);
    warm_fleet(&state).await;
    let before_outbox = state.outbox.lock().await.len();

    let job_slot: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let proceed = Arc::new(AtomicBool::new(false));
    let job_slot_h = job_slot.clone();
    let proceed_h = proceed.clone();
    set_chat_pre_settle_hook(Some(Arc::new(move |job_id| {
        *job_slot_h.lock().unwrap() = Some(job_id.to_string());
        while !proceed_h.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(5));
        }
    })));

    let app = router(state.clone());
    // Run chat on a dedicated OS thread so the sync sleep in the pre-settle
    // hook cannot stall this test's tokio worker.
    let handle = tokio::runtime::Handle::current();
    let chat = std::thread::spawn(move || {
        handle.block_on(async move {
            app.oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "model": "pilot-text-model",
                            "messages": [{"role":"user","content":"race-settle"}],
                            "stream": false
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap()
        })
    });

    let job_id = {
        let mut found = None;
        for _ in 0..400 {
            if let Some(id) = job_slot.lock().unwrap().clone() {
                found = Some(id);
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        found.expect("chat should reach pre-settle hook")
    };

    {
        let led = state.ledger.lock().await;
        assert_eq!(led.active_job_count(), 1, "job must still be active at pre-settle");
        assert!(led.job_funded_start(&job_id));
        assert!(led.job_disposition(&job_id).is_none());
    }

    let force = router(state.clone())
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": job_id,
                        "actual_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(force.status(), StatusCode::OK);
    let force_v = body_json(force).await;
    let action = force_v["action"].as_str().unwrap_or("");
    assert!(
        action == "force_settled" || action == "released",
        "force body: {force_v}"
    );

    proceed.store(true, Ordering::SeqCst);
    set_chat_pre_settle_hook(None);

    let chat_res = tokio::task::spawn_blocking(move || chat.join().unwrap())
        .await
        .unwrap();
    assert_eq!(chat_res.status(), StatusCode::OK);

    let after = state.outbox.lock().await.len();
    assert_eq!(
        after,
        before_outbox + 1,
        "exactly one inference.settled (force-settle only), got delta {}",
        after - before_outbox
    );
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
}

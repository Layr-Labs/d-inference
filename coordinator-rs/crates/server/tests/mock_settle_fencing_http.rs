//! Mock settle refuses after ownership steal (DECISIONS #134).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{complete_authorized_job, router, Epoch};
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn mock_chat_rejects_when_not_holding() {
    let state = pilot_app_state(true);
    state.ownership.release();

    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header("content-type", "application/json")
                .header("authorization", "Bearer pilot-key")
                .body(Body::from(
                    json!({
                        "model": "test-model",
                        "messages": [{"role":"user","content":"hi"}],
                        "stream": false
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");
}

#[tokio::test]
async fn mock_fenced_settle_holds_job_on_epoch_mismatch() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let old = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-ms1".into()),
            "ms-job-1",
            &state.pilot_account,
            100_000,
            old,
        )
        .unwrap();
        led.mark_start_authorized_fenced(old, "ms-job-1", &state.pilot_account)
            .unwrap();
    }
    ownership.release();
    ownership.acquire(Epoch(old + 9)).unwrap();

    let bal_before = state.ledger.lock().await.balance(&state.pilot_account).0;
    let permit = darkbloom_core::admission::DispatchPermit {
        attempt: darkbloom_core::AttemptId::new("a-ms"),
        provider_id: "p-ms".into(),
        model: "m".into(),
        expires_after: std::time::Duration::from_secs(2),
    };
    let err = {
        let mut led = state.ledger.lock().await;
        complete_authorized_job(
            &mut led,
            &state.pilot_account,
            "ms-job-1",
            &permit,
            "lease-ms",
            "hello",
            "rust-mock",
            None,
            true,
            ownership.epoch().0,
        )
        .unwrap_err()
    };
    assert!(err.contains("ownership lost"), "err={err}");
    assert_eq!(state.ledger.lock().await.active_job_count(), 1);
    assert!(state.ledger.lock().await.job_funded_start("ms-job-1"));
    assert_eq!(
        state.ledger.lock().await.balance(&state.pilot_account).0,
        bal_before
    );
}

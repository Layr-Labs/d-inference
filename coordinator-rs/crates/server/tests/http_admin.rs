//! Axum integration: admin deposits + ownership fencing on chat.

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Outbox};
use serde_json::json;
use std::sync::Arc;
use tokio::sync::Mutex;
use tower::ServiceExt;

fn test_state(holding: bool) -> darkbloom_coordinator::AppState {
    pilot_app_state(holding)
}

#[tokio::test]
async fn admin_deposit_applies_then_replays() {
    let state = test_state(true);
    let outbox = state.outbox.clone();
    let app = router(state);
    let req = Request::builder()
        .method("POST")
        .uri("/v1/admin/deposits")
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "event_id": "evt_it_1",
                "amount_micro_usd": 250_000,
                "withdrawable_micro_usd": 100_000
            })
            .to_string(),
        ))
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["applied"], true);
    assert_eq!(v["balance_micro_usd"], 1_250_000);
    assert_eq!(outbox.lock().await.len(), 1);

    let req2 = Request::builder()
        .method("POST")
        .uri("/v1/admin/deposits")
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "event_id": "evt_it_1",
                "amount_micro_usd": 250_000,
                "withdrawable_micro_usd": 100_000
            })
            .to_string(),
        ))
        .unwrap();
    let res2 = app.oneshot(req2).await.unwrap();
    assert_eq!(res2.status(), StatusCode::OK);
    let v2 = body_json(res2).await;
    assert_eq!(v2["applied"], false);
    assert_eq!(v2["balance_micro_usd"], 1_250_000);
    // Replay must not enqueue a second outbox side effect.
    assert_eq!(outbox.lock().await.len(), 1);
}

#[tokio::test]
async fn admin_deposit_mismatched_replay_returns_conflict() {
    let state = test_state(true);
    let app = router(state);
    let first = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_mm_http",
                        "amount_micro_usd": 100_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    assert_eq!(body_json(first).await["applied"], true);

    let mismatched = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_mm_http",
                        "amount_micro_usd": 999_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(mismatched.status(), StatusCode::CONFLICT);
    assert_eq!(
        body_json(mismatched).await["error"]["code"],
        "deposit_payload_conflict"
    );
}

#[tokio::test]
async fn chat_rejects_when_ownership_lost() {
    let app = router(test_state(false));
    let req = Request::builder()
        .method("POST")
        .uri("/v1/chat/completions")
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "model": "pilot-text-model",
                "messages": [{"role":"user","content":"x"}],
                "stream": false
            })
            .to_string(),
        ))
        .unwrap();
    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "ownership_lost");
}

#[tokio::test]
async fn terminal_ingest_missing_identity_returns_400() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/terminal-ingest")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "j",
                        "attempt_id": "",
                        "terminal_digest": "d"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "terminal_ingest_failed");
}

#[tokio::test]
async fn terminal_ingest_known_and_late() {
    let state = test_state(true);
    {
        let mut terms = state.terminals.lock().await;
        terms.record("j1", "a1", "d1", "settled", None);
    }
    let app = router(state);
    let req = Request::builder()
        .method("POST")
        .uri("/v1/admin/terminal-ingest")
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "job_id": "j1",
                "attempt_id": "a1",
                "terminal_digest": "d1"
            })
            .to_string(),
        ))
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["disposition"], "settled");
    assert_eq!(v["type"], "terminal_ack");

    let req2 = Request::builder()
        .method("POST")
        .uri("/v1/admin/terminal-ingest")
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "job_id": "j2",
                "attempt_id": "a2",
                "terminal_digest": "unknown"
            })
            .to_string(),
        ))
        .unwrap();
    let res2 = app.oneshot(req2).await.unwrap();
    assert_eq!(res2.status(), StatusCode::OK);
    let v2 = body_json(res2).await;
    assert_eq!(v2["disposition"], "late");
}

#[tokio::test]
async fn admin_deposit_rejects_empty_event_id() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "",
                        "amount_micro_usd": 1000
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "invalid_deposit");
}

#[tokio::test]
async fn admin_deposit_rejects_zero_amount() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_zero",
                        "amount_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "invalid_deposit");
}

#[tokio::test]
async fn admin_deposit_rejects_missing_auth_when_keys_configured() {
    let mut state = test_state(true);
    state.pilot_api_keys = Arc::new(vec!["good-key".into()]);
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_no_auth",
                        "amount_micro_usd": 10_000
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn admin_deposit_accepts_valid_pilot_key() {
    let mut state = test_state(true);
    state.pilot_api_keys = Arc::new(vec!["good-key".into()]);
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .header("authorization", "Bearer good-key")
                .body(Body::from(
                    json!({
                        "event_id": "evt_auth_ok",
                        "amount_micro_usd": 10_000,
                        "withdrawable_micro_usd": 1_000
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["applied"], true);
    assert_eq!(v["balance_micro_usd"], 1_010_000);
}

#[tokio::test]
async fn admin_deposit_rejects_invalid_pilot_key() {
    let mut state = test_state(true);
    state.pilot_api_keys = Arc::new(vec!["good-key".into()]);
    let app = router(state);
    let req = Request::builder()
        .method("POST")
        .uri("/v1/admin/deposits")
        .header("content-type", "application/json")
        .header("authorization", "Bearer bad-key")
        .body(Body::from(
            json!({
                "event_id": "evt_auth",
                "amount_micro_usd": 1000
            })
            .to_string(),
        ))
        .unwrap();
    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "invalid_api_key");
}

#[tokio::test]
async fn readyz_ok_when_holding() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/readyz")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(v["ownership_epoch"], 9);
}

#[tokio::test]
async fn readyz_fails_without_ownership() {
    let app = router(test_state(false));
    let req = Request::builder()
        .method("GET")
        .uri("/readyz")
        .body(Body::empty())
        .unwrap();
    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["ready"], false);
    assert_eq!(v["reason"], "ownership_lost");
}

#[tokio::test]
async fn invalid_sealed_body_returns_400() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "encrypted_body": "not-valid-base64!!!" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "invalid_sealed_body");
}

#[tokio::test]
async fn sealed_chat_body_decrypts_then_429_without_provider() {
    use darkbloom_protocol::seal_box;
    let state = test_state(true);
    let pub_key = state.keys.public_key_bytes();
    let inner = json!({
        "model": "pilot-text-model",
        "messages": [{"role":"user","content":"sealed hi"}],
        "stream": false
    });
    let sealed = seal_box(&pub_key, serde_json::to_vec(&inner).unwrap().as_slice()).unwrap();
    let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, sealed);
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "encrypted_body": b64 }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    // Sealed body decrypted successfully; no warm provider → 429 (not 400).
    assert_eq!(res.status(), StatusCode::TOO_MANY_REQUESTS);
    let v = body_json(res).await;
    assert_eq!(v["error"]["type"], "rate_limit_exceeded");
}

#[tokio::test]
async fn chat_429_signals_placement_demand() {
    let app = router(test_state(true));
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "model": "pilot-text-model",
                        "messages": [{"role":"user","content":"hi"}],
                        "stream": false
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::TOO_MANY_REQUESTS);

    let q = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q.status(), StatusCode::OK);
    let v = body_json(q).await;
    assert!(
        v["placement_version"].as_u64().unwrap_or(0) >= 1,
        "placement should bump after cold demand"
    );
    assert!(
        v["placement_demand"]["pilot-text-model"].is_object(),
        "demand for pilot model should be recorded"
    );
}

#[tokio::test]
async fn chat_without_provider_returns_429() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "model": "pilot-text-model",
                        "messages": [{"role":"user","content":"hi"}],
                        "stream": false
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::TOO_MANY_REQUESTS);
    let v = body_json(res).await;
    assert_eq!(v["error"]["type"], "rate_limit_exceeded");
}

#[tokio::test]
async fn list_models_returns_pilot_card() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/models")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["object"], "list");
    assert_eq!(v["data"][0]["id"], "pilot-text-model");
}

#[tokio::test]
async fn health_and_encryption_key_ok() {
    let app = router(test_state(true));
    let health = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/health")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(health.status(), StatusCode::OK);
    let hv = body_json(health).await;
    assert_eq!(hv["status"], "ok");
    assert_eq!(hv["coordinator"], "rust");

    let key = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/encryption-key")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(key.status(), StatusCode::OK);
    let kv = body_json(key).await;
    assert_eq!(kv["public_key"].as_str().unwrap().len() > 20, true);
    assert_eq!(kv["kid"], "test");
}

#[tokio::test]
async fn unsupported_routes_return_501() {
    let app = router(test_state(true));
    for uri in ["/v1/completions", "/v1/messages", "/v1/unknown"] {
        let req = Request::builder()
            .method("POST")
            .uri(uri)
            .header("content-type", "application/json")
            .body(Body::from("{}"))
            .unwrap();
        let res = app.clone().oneshot(req).await.unwrap();
        assert_eq!(res.status(), StatusCode::NOT_IMPLEMENTED, "uri={uri}");
        let v = body_json(res).await;
        assert_eq!(v["error"]["code"], "unsupported_route", "uri={uri}");
    }
}

#[tokio::test]
async fn quiescence_reports_late_terminals_after_ingest() {
    let state = test_state(true);
    let app = router(state);
    let req = Request::builder()
        .method("POST")
        .uri("/v1/admin/terminal-ingest")
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "job_id": "j-late",
                "attempt_id": "a-late",
                "terminal_digest": "d-late"
            })
            .to_string(),
        ))
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["disposition"], "late");

    let q = Request::builder()
        .method("GET")
        .uri("/v1/admin/quiescence")
        .body(Body::empty())
        .unwrap();
    let res_q = app.oneshot(q).await.unwrap();
    assert_eq!(res_q.status(), StatusCode::OK);
    let v = body_json(res_q).await;
    assert_eq!(v["late_terminals"], 1);
    assert_eq!(v["ready"], true);
}

#[tokio::test]
async fn quiescence_reports_ownership_and_empty_outbox() {
    let app = router(test_state(true));
    let req = Request::builder()
        .method("GET")
        .uri("/v1/admin/quiescence")
        .body(Body::empty())
        .unwrap();
    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(v["ownership_holding"], true);
    assert_eq!(v["ownership_epoch"], 9);
    assert_eq!(v["active_jobs"], 0);
    assert_eq!(v["outbox_retryable"], 0);
    assert_eq!(v["external_events_seen"], 0);
    assert_eq!(v["late_terminals"], 0);
}

#[tokio::test]
async fn responses_route_shares_chat_handler_429_without_provider() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/responses")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "model": "pilot-text-model",
                        "messages": [{"role":"user","content":"hi"}],
                        "stream": false
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::TOO_MANY_REQUESTS);
    let v = body_json(res).await;
    assert_eq!(v["error"]["type"], "rate_limit_exceeded");
}

#[tokio::test]
async fn responses_without_ownership_returns_503() {
    let app = router(test_state(false));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/responses")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "model": "pilot-text-model",
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
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "ownership_lost");
}

#[tokio::test]
async fn quiescence_reports_held_start_authorized_jobs() {
    let state = test_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-held".into()),
            "held-job-1",
            "pilot-account",
            100_000,
        )
        .unwrap();
        led.mark_start_authorized("held-job-1", "pilot-account").unwrap();
    }
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["ready"], false);
    assert_eq!(v["held_start_authorized"], 1);
    assert_eq!(v["held_start_authorized_job_ids"][0], "held-job-1");
    assert_eq!(v["active_jobs"], 1);
}

#[tokio::test]
async fn quiescence_ready_after_force_settle_clears_hold() {
    let state = test_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-fs".into()),
            "held-fs",
            "pilot-account",
            100_000,
        )
        .unwrap();
        led.mark_start_authorized("held-fs", "pilot-account").unwrap();
        assert!(led
            .settle_capped_as(
                darkbloom_coordinator::OperationKey("force_settle:held-fs".into()),
                "held-fs",
                "pilot-account",
                40_000,
                100_000,
                "force-http-d",
                "force_settled",
            )
            .unwrap());
        assert_eq!(led.job_disposition("held-fs"), Some("force_settled"));
        assert_eq!(led.active_job_count(), 0);
    }
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(v["held_start_authorized"], 0);
    assert_eq!(v["active_jobs"], 0);
}

#[tokio::test]
async fn admin_deposit_creates_new_account() {
    let state = test_state(true);
    let ledger = state.ledger.clone();
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_new_acct_http",
                        "account": "fresh-user",
                        "amount_micro_usd": 750_000,
                        "withdrawable_micro_usd": 150_000
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["applied"], true);
    assert_eq!(v["balance_micro_usd"], 750_000);
    assert_eq!(v["withdrawable_micro_usd"], 150_000);
    assert_eq!(ledger.lock().await.balance("fresh-user"), (750_000, 150_000));
    // Pilot account unchanged.
    assert_eq!(ledger.lock().await.balance("pilot-account").0, 1_000_000);
}

#[tokio::test]
async fn admin_terminal_ingest_digest_fallback_acks_settled() {
    let state = test_state(true);
    {
        let mut terms = state.terminals.lock().await;
        // Settle wrote empty attempt_id; ingest arrives with real attempt_id.
        terms.record("j-fb", "", "d-http-fb", "settled", None);
    }
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/terminal-ingest")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "j-fb",
                        "attempt_id": "real-attempt",
                        "terminal_digest": "d-http-fb"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["disposition"], "settled");
    assert_eq!(v["type"], "terminal_ack");
}

#[tokio::test]
async fn admin_deposit_rejects_withdrawable_exceeding_total() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_wdr_over",
                        "amount_micro_usd": 100_000,
                        "withdrawable_micro_usd": 200_000
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "deposit_failed");
}

#[tokio::test]
async fn admin_deposit_rejects_negative_withdrawable() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_wdr_neg",
                        "amount_micro_usd": 100_000,
                        "withdrawable_micro_usd": -1
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "deposit_failed");
}

#[tokio::test]
async fn admin_deposit_rejects_empty_source() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_empty_src",
                        "source": "",
                        "amount_micro_usd": 100_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "deposit_failed");
}

#[tokio::test]
async fn admin_deposit_without_ownership_returns_503() {
    let app = router(test_state(false));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_no_own",
                        "amount_micro_usd": 100_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "ownership_lost");
}

#[tokio::test]
async fn admin_terminal_ingest_without_ownership_returns_503() {
    let app = router(test_state(false));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/terminal-ingest")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "j",
                        "attempt_id": "a",
                        "terminal_digest": "d"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "ownership_lost");
}

#[tokio::test]
async fn quiescence_readable_without_ownership_reports_not_holding() {
    // Quiescence is an ops observation surface — readable without holding,
    // but reports ownership_holding=false for cutover visibility.
    let app = router(test_state(false));
    let res = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(v["ownership_holding"], false);
    assert_eq!(v["active_jobs"], 0);
}

#[tokio::test]
async fn admin_terminal_ingest_force_settled_disposition() {
    let state = test_state(true);
    {
        let mut terms = state.terminals.lock().await;
        terms.record("j-fs", "a-fs", "d-fs", "force_settled", None);
    }
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/terminal-ingest")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "j-fs",
                        "attempt_id": "a-fs",
                        "terminal_digest": "d-fs"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["disposition"], "force_settled");
    assert_eq!(v["type"], "terminal_ack");
}

#[tokio::test]
async fn admin_terminal_ingest_wrong_job_returns_conflict() {
    let state = test_state(true);
    {
        let mut terms = state.terminals.lock().await;
        terms.record("j-real", "a1", "d-job", "settled", None);
    }
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/terminal-ingest")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "j-attacker",
                        "attempt_id": "a1",
                        "terminal_digest": "d-job"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["disposition"], "conflict");
    assert_eq!(v["type"], "terminal_ack");
}

#[tokio::test]
async fn deposit_outbox_blocks_quiescence_until_drained() {
    let state = test_state(true);
    let outbox = state.outbox.clone();
    let app = router(state);
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_outbox_q",
                        "amount_micro_usd": 50_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(outbox.lock().await.len(), 1);

    let q1 = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q1.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v1 = body_json(q1).await;
    assert_eq!(v1["ready"], false);
    assert_eq!(v1["outbox_retryable"], 1);

    // Drain like the background worker: claim + ack.
    {
        let mut box_ = outbox.lock().await;
        let entry = box_.try_claim().expect("pending outbox entry");
        let _ = box_.ack_done(entry.id);
    }
    assert!(outbox.lock().await.is_empty());

    let q2 = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q2.status(), StatusCode::OK);
    let v2 = body_json(q2).await;
    assert_eq!(v2["ready"], true);
    assert_eq!(v2["outbox_retryable"], 0);
}

#[tokio::test]
async fn outbox_requeue_keeps_quiescence_not_ready() {
    let state = test_state(true);
    let outbox = state.outbox.clone();
    {
        let mut box_ = outbox.lock().await;
        box_
            .enqueue("billing.deposit_applied", r#"{"event_id":"evt_rq"}"#)
            .unwrap();
        let entry = box_.try_claim().unwrap();
        box_.requeue(entry).unwrap();
    }
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["ready"], false);
    assert_eq!(v["outbox_retryable"], 1);
}

#[tokio::test]
async fn deposit_critical_outbox_extends_when_full() {
    let mut state = test_state(true);
    state.outbox = Arc::new(Mutex::new(Outbox::new(1)));
    let outbox = state.outbox.clone();
    {
        let mut box_ = outbox.lock().await;
        box_.enqueue("filler", "{}").unwrap();
        assert!(box_.enqueue("overflow", "{}").is_err());
    }
    let app = router(state);
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_critical_full",
                        "amount_micro_usd": 40_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["applied"], true);
    assert_eq!(outbox.lock().await.len(), 2);

    let q = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q.status(), StatusCode::SERVICE_UNAVAILABLE);
    let qv = body_json(q).await;
    assert_eq!(qv["ready"], false);
    assert_eq!(qv["outbox_retryable"], 2);
}

#[tokio::test]
async fn admin_force_settle_clears_held_job() {
    let state = test_state(true);
    let outbox = state.outbox.clone();
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-afs".into()),
            "held-afs",
            "pilot-account",
            200_000,
        )
        .unwrap();
        led.mark_start_authorized("held-afs", "pilot-account")
            .unwrap();
    }
    let app = router(state);
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "held-afs",
                        "actual_micro_usd": 50_000,
                        "terminal_digest": "force-afs-d"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "released");
    assert_eq!(v["held_start_authorized"], 0);
    // 1M - 200k + 150k refund = 950k
    assert_eq!(v["balance_micro_usd"], 950_000);
    assert_eq!(outbox.lock().await.len(), 1);

    let q = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    // Outbox still pending — not ready until drained.
    assert_eq!(q.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(q).await["held_start_authorized"], 0);
}

#[tokio::test]
async fn admin_force_settle_without_ownership_returns_503() {
    let app = router(test_state(false));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "j",
                        "actual_micro_usd": 1
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
async fn admin_force_settle_skips_when_not_authorized() {
    let state = test_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-skip".into()),
            "reserved-only",
            "pilot-account",
            100_000,
        )
        .unwrap();
    }
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "reserved-only",
                        "actual_micro_usd": 10_000
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["action"], "skipped");
}

#[tokio::test]
async fn admin_force_settle_idempotent_replay() {
    let state = test_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-idemp".into()),
            "held-idemp",
            "pilot-account",
            100_000,
        )
        .unwrap();
        led.mark_start_authorized("held-idemp", "pilot-account")
            .unwrap();
    }
    let app = router(state);
    let body = json!({
        "job_id": "held-idemp",
        "actual_micro_usd": 40_000,
        "terminal_digest": "force-idemp-d"
    })
    .to_string();
    let res1 = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(body.clone()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res1.status(), StatusCode::OK);
    assert_eq!(body_json(res1).await["action"], "released");

    let res2 = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res2.status(), StatusCode::OK);
    assert_eq!(body_json(res2).await["action"], "already_terminal");
}

#[tokio::test]
async fn admin_recover_undispatched_releases_reserved() {
    let state = test_state(true);
    let outbox = state.outbox.clone();
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-undisp".into()),
            "undisp-1",
            "pilot-account",
            150_000,
        )
        .unwrap();
    }
    let app = router(state);
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "job_id": "undisp-1" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "released");
    assert_eq!(v["active_jobs"], 0);
    assert_eq!(v["balance_micro_usd"], 1_000_000);
    assert_eq!(outbox.lock().await.len(), 1);

    // Critical release outbox blocks quiescence until drained (DECISIONS #43).
    let q1 = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q1.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(q1).await["outbox_retryable"], 1);

    {
        let mut box_ = outbox.lock().await;
        let e = box_.try_claim().unwrap();
        assert_eq!(e.kind, "inference.released");
        let _ = box_.ack_done(e.id);
    }

    let q = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q.status(), StatusCode::OK);
    assert_eq!(body_json(q).await["ready"], true);
}

#[tokio::test]
async fn admin_recover_undispatched_skips_start_authorized() {
    let state = test_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-auth".into()),
            "auth-1",
            "pilot-account",
            100_000,
        )
        .unwrap();
        led.mark_start_authorized("auth-1", "pilot-account").unwrap();
    }
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "auth-1" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "skipped");
    assert_eq!(v["active_jobs"], 1);
}

#[tokio::test]
async fn admin_recover_undispatched_without_ownership_returns_503() {
    let app = router(test_state(false));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "j" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");
}

#[tokio::test]
async fn admin_force_settle_then_recover_already_terminal() {
    let state = test_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-combo".into()),
            "combo-1",
            "pilot-account",
            100_000,
        )
        .unwrap();
        led.mark_start_authorized("combo-1", "pilot-account").unwrap();
    }
    let app = router(state);
    let fs = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "combo-1",
                        "actual_micro_usd": 25_000,
                        "terminal_digest": "combo-d"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(fs).await["action"], "released");

    let rec = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "combo-1" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(rec.status(), StatusCode::OK);
    assert_eq!(body_json(rec).await["action"], "already_terminal");
}

#[tokio::test]
async fn admin_held_review_classifies_without_moving_money() {
    let state = test_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-hr".into()),
            "held-hr",
            "pilot-account",
            175_000,
        )
        .unwrap();
        led.mark_start_authorized("held-hr", "pilot-account").unwrap();
    }
    let app = router(state);
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/held-review")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "held-hr" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "held_for_review");
    assert_eq!(v["reserved_micro_usd"], 175_000);
    assert_eq!(v["held_start_authorized"], 1);
    assert_eq!(v["balance_micro_usd"], 825_000);

    let fs = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "held-hr",
                        "actual_micro_usd": 25_000,
                        "terminal_digest": "hr-force-d"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(fs).await["action"], "released");
}

#[tokio::test]
async fn admin_held_review_after_force_settle_already_terminal() {
    let state = test_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-hr2".into()),
            "held-hr2",
            "pilot-account",
            100_000,
        )
        .unwrap();
        led.mark_start_authorized("held-hr2", "pilot-account").unwrap();
    }
    let app = router(state);
    let _ = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "held-hr2",
                        "actual_micro_usd": 10_000,
                        "terminal_digest": "hr2-d"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/held-review")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "held-hr2" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["action"], "already_terminal");
}

#[tokio::test]
async fn admin_force_settle_drain_outbox_makes_quiescence_ready() {
    let state = test_state(true);
    let outbox = state.outbox.clone();
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-drain".into()),
            "held-drain",
            "pilot-account",
            100_000,
        )
        .unwrap();
        led.mark_start_authorized("held-drain", "pilot-account")
            .unwrap();
    }
    let app = router(state);
    let fs = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "held-drain",
                        "actual_micro_usd": 30_000,
                        "terminal_digest": "drain-d"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(fs).await["action"], "released");
    assert_eq!(outbox.lock().await.len(), 1);

    let q1 = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q1.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(q1).await["outbox_retryable"], 1);

    {
        let mut box_ = outbox.lock().await;
        let e = box_.try_claim().unwrap();
        let _ = box_.ack_done(e.id);
    }

    let q2 = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q2.status(), StatusCode::OK);
    let v = body_json(q2).await;
    assert_eq!(v["ready"], true);
    assert_eq!(v["held_start_authorized"], 0);
    assert_eq!(v["outbox_retryable"], 0);
}

#[tokio::test]
async fn admin_held_review_without_ownership_returns_503() {
    let app = router(test_state(false));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/held-review")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "j" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");
}

#[tokio::test]
async fn admin_force_settle_wrong_account_returns_conflict() {
    let state = test_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.credit("other-account", 1_000_000, 0).unwrap();
        led.reserve(
            darkbloom_coordinator::OperationKey("r-wa".into()),
            "held-wa",
            "pilot-account",
            100_000,
        )
        .unwrap();
        led.mark_start_authorized("held-wa", "pilot-account").unwrap();
    }
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "held-wa",
                        "actual_micro_usd": 10_000,
                        "account": "other-account",
                        "terminal_digest": "wa-d"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CONFLICT);
    assert_eq!(body_json(res).await["error"]["code"], "force_settle_failed");
}

#[tokio::test]
async fn admin_recover_undispatched_wrong_account_returns_conflict() {
    let state = test_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.credit("other-account", 1_000_000, 0).unwrap();
        led.reserve(
            darkbloom_coordinator::OperationKey("r-rwa".into()),
            "undisp-wa",
            "pilot-account",
            100_000,
        )
        .unwrap();
    }
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "undisp-wa",
                        "account": "other-account"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CONFLICT);
    assert_eq!(
        body_json(res).await["error"]["code"],
        "recover_undispatched_failed"
    );
}

#[tokio::test]
async fn admin_held_review_skips_reserved_not_authorized() {
    let state = test_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-hrs".into()),
            "reserved-hrs",
            "pilot-account",
            90_000,
        )
        .unwrap();
    }
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/held-review")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "job_id": "reserved-hrs" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "skipped");
    assert_eq!(v["held_start_authorized"], 0);
    assert_eq!(v["balance_micro_usd"], 910_000);
}

#[tokio::test]
async fn admin_held_review_rejects_empty_job_id() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/held-review")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    assert_eq!(body_json(res).await["error"]["code"], "invalid_job_id");
}

#[tokio::test]
async fn admin_force_settle_rejects_empty_job_id() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "job_id": "", "actual_micro_usd": 1 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    assert_eq!(body_json(res).await["error"]["code"], "invalid_job_id");
}

#[tokio::test]
async fn admin_recover_undispatched_makes_quiescence_ready() {
    let state = test_state(true);
    let outbox = state.outbox.clone();
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-qr".into()),
            "undisp-qr",
            "pilot-account",
            80_000,
        )
        .unwrap();
    }
    let app = router(state);
    let rec = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "undisp-qr" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(rec).await["action"], "released");
    assert_eq!(outbox.lock().await.len(), 1);

    let q1 = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q1.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(q1).await["outbox_retryable"], 1);

    {
        let mut box_ = outbox.lock().await;
        let e = box_.try_claim().unwrap();
        assert_eq!(e.kind, "inference.released");
        let payload: serde_json::Value = serde_json::from_str(&e.payload).unwrap();
        assert_eq!(payload["refunded_micro_usd"], 80_000);
        let _ = box_.ack_done(e.id);
    }

    let q = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q.status(), StatusCode::OK);
    let v = body_json(q).await;
    assert_eq!(v["ready"], true);
    assert_eq!(v["active_jobs"], 0);
    assert_eq!(v["outbox_retryable"], 0);
}

#[tokio::test]
async fn admin_recover_undispatched_rejects_empty_job_id() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    assert_eq!(body_json(res).await["error"]["code"], "invalid_job_id");
}

#[tokio::test]
async fn admin_force_settle_rejects_negative_actual() {
    let app = router(test_state(true));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "j",
                        "actual_micro_usd": -1
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    assert_eq!(body_json(res).await["error"]["code"], "invalid_amount");
}

#[tokio::test]
async fn admin_force_settle_zero_actual_full_refund() {
    let state = test_state(true);
    let outbox = state.outbox.clone();
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-zfs".into()),
            "held-zfs",
            "pilot-account",
            120_000,
        )
        .unwrap();
        led.mark_start_authorized("held-zfs", "pilot-account").unwrap();
    }
    let app = router(state);
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "held-zfs",
                        "actual_micro_usd": 0,
                        "terminal_digest": "zfs-d"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "released");
    // Full reservation refunded → back to 1M
    assert_eq!(v["balance_micro_usd"], 1_000_000);
    assert_eq!(v["held_start_authorized"], 0);
    assert_eq!(outbox.lock().await.len(), 1);

    {
        let mut box_ = outbox.lock().await;
        let e = box_.try_claim().unwrap();
        let _ = box_.ack_done(e.id);
    }
    let q = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q.status(), StatusCode::OK);
    assert_eq!(body_json(q).await["ready"], true);
}

//! Terminal-wait ownership steal → adopt → force-settle e2e (DECISIONS #65/#66/#73).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use darkbloom_coordinator::{Epoch, InboundReply, OutboundCmd};
use darkbloom_core::{HealthMachine, ProviderSnapshot, TrustState};
use serde_json::json;
use std::collections::HashSet;
use std::sync::Arc;
use tokio::sync::{mpsc, Notify};
use tower::ServiceExt;

#[tokio::test]
async fn wait_steal_then_adopt_force_settle_clears_hold() {
    let state = pilot_app_state(true);
    let ledger = state.ledger.clone();
    let ownership = state.ownership.clone();
    let hub = state.hub.clone();
    let epoch0 = ownership.epoch().0;

    let mut ready = HashSet::new();
    ready.insert("pilot-text-model".into());
    state
        .fleet
        .upsert_lifecycle(ProviderSnapshot {
            provider_id: "p-wait-orphan".into(),
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

    let started = Arc::new(Notify::new());
    let started2 = started.clone();
    let (tx, mut rx) = mpsc::channel(8);
    hub.attach("p-wait-orphan".into(), 1, tx).await;
    let hub2 = hub.clone();
    tokio::spawn(async move {
        while let Some(OutboundCmd::Text(t)) = rx.recv().await {
            let v: serde_json::Value = serde_json::from_str(&t).unwrap();
            let attempt = v["attempt_id"].as_str().unwrap_or("").to_string();
            match v["type"].as_str() {
                Some("prepare") => {
                    hub2.deliver_reply(
                        "p-wait-orphan",
                        &attempt,
                        InboundReply::Prepared(json!({
                            "type": "prepared",
                            "attempt_id": attempt,
                            "lease_ttl_ms": 15000,
                            "prompt_tokens": 2,
                            "max_output_tokens": 8,
                            "engine_queue_depth": 0,
                            "prefill_can_begin": true
                        })),
                    )
                    .await;
                }
                Some("start") => {
                    hub2.deliver_reply(
                        "p-wait-orphan",
                        &attempt,
                        InboundReply::Started(json!({
                            "type": "started",
                            "attempt_id": attempt,
                            "job_id": v["job_id"],
                            "lease_id": v["lease_id"],
                        })),
                    )
                    .await;
                    // Never send terminal — steal during wait_terminal.
                    started2.notify_one();
                }
                _ => {}
            }
        }
    });

    let bal_before = ledger.lock().await.balance("pilot-account").0;
    let app = router(state.clone());
    let req_fut = async {
        app.clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "model": "pilot-text-model",
                            "messages": [{"role":"user","content":"wait orphan"}],
                            "stream": false
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap()
    };
    let steal_fut = async {
        started.notified().await;
        ownership.release();
    };
    let (res, _) = tokio::join!(req_fut, steal_fut);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");

    // Discover orphan via quiescence without ownership.
    let q = app
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
    let qv = body_json(q).await;
    assert_eq!(qv["ownership_holding"], false);
    assert_eq!(qv["active_jobs"], 1);
    let orphan_id = qv["active_job_ids"][0].as_str().unwrap().to_string();

    ownership.acquire(Epoch(epoch0 + 1)).unwrap();

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-jobs")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["adopted_count"], 1);

    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": orphan_id,
                        "actual_micro_usd": 30_000,
                        "terminal_digest": "wait-orphan-d"
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
    assert_eq!(v["balance_micro_usd"], bal_before - 30_000);
}

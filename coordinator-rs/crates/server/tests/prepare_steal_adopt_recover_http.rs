//! Full orphan path: prepare ownership steal → re-acquire → adopt → recover
//! (DECISIONS #66/#67/#70).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use darkbloom_coordinator::{Epoch, OutboundCmd};
use darkbloom_core::{HealthMachine, ProviderSnapshot, TrustState};
use serde_json::json;
use std::collections::HashSet;
use std::sync::Arc;
use tokio::sync::{mpsc, Notify};
use tower::ServiceExt;

#[tokio::test]
async fn prepare_steal_then_adopt_recover_clears_orphan() {
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
            provider_id: "p-orphan-e2e".into(),
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

    let saw_prepare = Arc::new(Notify::new());
    let saw_prepare2 = saw_prepare.clone();
    let (tx, mut rx) = mpsc::channel(8);
    hub.attach("p-orphan-e2e".into(), 1, tx).await;
    tokio::spawn(async move {
        while let Some(OutboundCmd::Text(t)) = rx.recv().await {
            let v: serde_json::Value = serde_json::from_str(&t).unwrap();
            if v["type"].as_str() == Some("prepare") {
                saw_prepare2.notify_one();
            }
            // Never reply Prepared — ownership steal aborts the wait.
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
                            "messages": [{"role":"user","content":"orphan e2e"}],
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
        saw_prepare.notified().await;
        ownership.release();
    };
    let (res, _) = tokio::join!(req_fut, steal_fut);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");

    {
        let led = ledger.lock().await;
        assert_eq!(led.active_job_count(), 1);
        assert_eq!(led.held_start_authorized_count(), 0);
        assert_eq!(led.balance("pilot-account").0, bal_before - 100_000);
    }

    // Re-acquire with a new fencing epoch.
    ownership.acquire(Epoch(epoch0 + 1)).unwrap();
    let orphan_ids = ledger.lock().await.active_job_ids();
    assert_eq!(orphan_ids.len(), 1);
    let orphan_id = orphan_ids[0].clone();
    assert_eq!(
        ledger.lock().await.job_fencing_epoch(&orphan_id),
        Some(epoch0)
    );

    // Adopt + recover clears the orphan and restores balance.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-job")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": orphan_id }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["fencing_epoch"], epoch0 + 1);

    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": orphan_id }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "released");
    assert_eq!(v["active_jobs"], 0);
    assert_eq!(v["balance_micro_usd"], bal_before);
}

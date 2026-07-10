//! cutover-drain / cutover-drain-all use CutoverStatus (DECISIONS #132).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{
    lock_clear_orphans_hook_tests, router, set_clear_orphans_phase_hook, Epoch,
};
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn cutover_drain_all_reports_cutover_status_fields() {
    let _guard = lock_clear_orphans_hook_tests();
    set_clear_orphans_phase_hook(None);

    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let old = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("uma", 200_000, 0).unwrap();
        led.credit("vera", 200_000, 0).unwrap();
        for (id, acct) in [("cd-u1", "uma"), ("cd-v1", "vera")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                40_000,
                old,
            )
            .unwrap();
            led.mark_start_authorized_fenced(old, id, acct).unwrap();
        }
    }
    ownership.release();
    ownership.acquire(Epoch(old + 5)).unwrap();

    let app = router(state.clone());

    // Quiescence accounts come from cutover_status.
    let q = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let qv = body_json(q).await;
    assert_eq!(qv["orphan_summary"]["needs_adopt_count"], 2);
    let mut accounts = qv["accounts_needing_cutover"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    accounts.sort();
    assert_eq!(accounts, vec!["uma".to_string(), "vera".to_string()]);

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "actual_micro_usd": 0 }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(v["needs_adopt_count"], 0);
    assert_eq!(v["accounts_needing_cutover"], json!([]));
    assert_eq!(state.ledger.lock().await.balance("uma").0, 200_000);
    assert_eq!(state.ledger.lock().await.balance("vera").0, 200_000);
}

#[tokio::test]
async fn cutover_drain_abort_uses_cutover_status_active_jobs() {
    let _guard = lock_clear_orphans_hook_tests();
    set_clear_orphans_phase_hook(None);

    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("wade", 150_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-cd-w".into()),
            "cd-w1",
            "wade",
            30_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "cd-w1", "wade")
            .unwrap();
    }

    let gate = ownership.clone();
    set_clear_orphans_phase_hook(Some(Arc::new(move |phase| {
        if phase == "after_adopt" {
            gate.release();
        }
    })));

    let app = router(state.clone());
    // Seed outbox so cutover-drain reaches drain phase after clear would succeed;
    // steal during clear aborts before drain.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "account": "wade" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    set_clear_orphans_phase_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    // clear_orphans_aborted bubbled, or cutover_drain_aborted — both carry status fields.
    assert!(
        v["action"] == "clear_orphans_aborted" || v["action"] == "cutover_drain_aborted",
        "body={v}"
    );
    assert!(v.get("needs_adopt_count").is_some() || v.get("accounts_needing_cutover").is_some());
    assert!(state.ledger.lock().await.active_job_count() >= 1);
}

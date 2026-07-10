//! accounts_needing_cutover + charged account-filtered cutover (DECISIONS #112).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn quiescence_accounts_needing_cutover_lists_tenants() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("ella", 200_000, 0).unwrap();
        led.credit("finn", 200_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-e1".into()),
            "anc-e1",
            "ella",
            30_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "anc-e1", "ella")
            .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-f1".into()),
            "anc-f1",
            "finn",
            20_000,
            epoch,
        )
        .unwrap();
    }
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    let accounts: Vec<&str> = v["accounts_needing_cutover"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_str().unwrap())
        .collect();
    assert_eq!(accounts, vec!["ella", "finn"]);
    assert_eq!(v["cutover_hint"], "cutover-drain-all");
}

#[tokio::test]
async fn charged_account_filtered_cutover_drain() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("gina", 500_000, 0).unwrap();
        led.credit("hugo", 500_000, 0).unwrap();
        for (id, acct) in [("ch-g1", "gina"), ("ch-g2", "gina"), ("ch-h1", "hugo")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                100_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct)
                .unwrap();
        }
    }
    // Charge 40k per gina hold (clamped to reserved).
    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "account": "gina",
                        "actual_micro_usd": 40_000
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["clear_orphans"]["settled_count"], 2);
    assert_eq!(v["clear_orphans"]["charged_micro_usd"], 80_000);
    // gina: 500k - 200k reserved + (200k-80k) refund = 500k - 80k = 420k
    assert_eq!(state.ledger.lock().await.balance("gina").0, 420_000);
    // hugo untouched.
    assert_eq!(state.ledger.lock().await.balance("hugo").0, 400_000);
    assert_eq!(state.ledger.lock().await.held_start_authorized_count(), 1);

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
    assert_eq!(qv["accounts_needing_cutover"], json!(["hugo"]));
    assert_eq!(qv["ready"], false);

    // Full refund hugo.
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "account": "hugo", "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["ready"], true);
    assert_eq!(state.ledger.lock().await.balance("hugo").0, 500_000);
    assert_eq!(state.ledger.lock().await.balance("gina").0, 420_000);
}

//! cutover-drain-all readiness holds money_fx (DECISIONS #158).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use std::time::Duration;
use tower::ServiceExt;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cutover_drain_all_ready_blocks_while_money_fx_held() {
    let state = pilot_app_state(true);
    // No active jobs, empty outbox → would be ready, but money_fx must fence the snapshot.
    let fx = state.money_fx.clone();
    let app = router(state);

    let hold = fx.lock().await;
    let handle = tokio::runtime::Handle::current();
    let drain = std::thread::spawn(move || {
        handle.block_on(async move {
            app.oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/cutover-drain-all")
                    .header("content-type", "application/json")
                    .body(Body::from("{}"))
                    .unwrap(),
            )
            .await
            .unwrap()
        })
    });

    tokio::time::sleep(Duration::from_millis(80)).await;
    assert!(
        !drain.is_finished(),
        "cutover-drain-all ready snapshot must wait on money_fx"
    );

    drop(hold);
    let res = tokio::task::spawn_blocking(move || drain.join().unwrap())
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "cutover_drain_all");
    assert_eq!(v["scoped_ready"], true);
    assert_eq!(v["ready"], true);
}

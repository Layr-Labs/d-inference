//! Full-stack e2e (real Postgres + real bootstrap app, fake provider):
//! a client disconnect mid-stream surfaces as a cancel frame on the
//! provider socket, and the v1 partial usage settles within the bounded
//! wait.
//!
//! Skipped (with a message) when `initdb`/`pg_ctl` are not on PATH.

use crate::support::e2e::*;
use crate::support::pg;

// -----------------------------------------------------------------------
// (d) cancellation: client disconnects mid-stream → provider receives the
//     cancel frame → v1 partial settles within the bounded wait
// -----------------------------------------------------------------------

#[tokio::test]
async fn client_disconnect_cancels_provider_and_settles_partial() {
    if !pg::pg_available() {
        pg::skip();
        return;
    }
    let stack = Stack::boot().await;
    let mut provider = connect_provider(&stack, "E2E-CANCEL", false).await;
    stack.wait_warm(CONCRETE_MODEL, 1).await;

    let script = tokio::spawn(async move {
        let frame = provider.next_json().await;
        let (request_id, session_pub, _) = open_v1_request(&provider, &frame);
        send_v1_chunk(&mut provider, &request_id, &session_pub, "partial").await;

        // The client disconnect must surface as a cancel frame.
        let cancel = provider.next_json().await;
        assert_eq!(cancel["type"], "cancel", "provider receives cancel");
        assert_eq!(cancel["request_id"], request_id.as_str());

        // Authenticated partial usage: exactly the one accepted chunk.
        provider
            .send_json(&serde_json::json!({
                "type": "inference_complete",
                "request_id": request_id,
                "usage": {"prompt_tokens": 12, "completion_tokens": 1},
                "response_hash": "partial-hash",
            }))
            .await;
    });

    let mut response = send_chat(&stack, CONSUMER_KEY, PUBLIC_MODEL, true).await;
    assert_eq!(response.status(), 200);
    let job = job_id_of(&response);
    // Read the first streamed chunk, then vanish mid-stream.
    let first = tokio::time::timeout(RECV, response.chunk())
        .await
        .expect("first chunk in time")
        .expect("chunk read")
        .expect("stream open");
    assert!(String::from_utf8_lossy(&first).contains("partial"));
    drop(response);

    script.await.expect("cancel script");

    // Settles partial within the bounded wait: charge = 5*2 + 1*5 = 15.
    wait_job_state(stack.pool(), job, "settled").await;
    let (accepted,): (i64,) = sqlx::query_as(
        "SELECT accepted_cumulative_tokens FROM rust_coord.inference_jobs WHERE job_id = $1",
    )
    .bind(job)
    .fetch_one(stack.pool())
    .await
    .expect("job row");
    assert_eq!(accepted, 1, "cancelled stream caps at the accepted chunk");
    assert_settled_money(stack.pool(), job, 15, RESERVE_HOLD, 12, 3).await;
    assert_eq!(
        pg::balance_of(stack.pool(), CONSUMER_ACCOUNT).await,
        (CONSUMER_SEED - 15, 0)
    );

    stack.assert_quiescent(&[]).await;
    stack.shutdown().await;
}

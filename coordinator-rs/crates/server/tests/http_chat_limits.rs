//! Failure/limit chat-completions scenarios through the real router: 402
//! before admission, 429 with Retry-After, pipe overflow, client
//! disconnect after content, and ordered shutdown draining (plan §22.3
//! style — no real DB, no real fleet).

#[path = "http_support/mod.rs"]
mod support;

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::Notify;
use tower::ServiceExt;
use uuid::Uuid;

use darkbloom_core::ids::LeaseId;
use darkbloom_protocol::json_v2::FrameV2;
use darkbloom_server::contracts::{AttemptEvent, ChunkFrame, ControlFrame, LedgerError};

use support::*;

// -------------------------------------------------------------------
// (d) capacity RetryAfter → fast 429 with Retry-After, reserve released
// -------------------------------------------------------------------

#[tokio::test]
async fn capacity_retry_after_returns_429_and_releases() {
    let h = HarnessBuilder::new()
        .admit_script(vec![AdmitReply::RetryAfter(Duration::from_secs(2))])
        .build();
    let response = h
        .router
        .clone()
        .oneshot(chat_request(&chat_body(true)))
        .await
        .expect("router");
    assert_eq!(response.status(), 429);
    assert_eq!(response.headers().get("retry-after").unwrap(), "2");
    let body = read_body(response).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(parsed["error"]["code"], "rate_limit_exceeded");

    let names: Vec<&str> = h.ledger.snapshot().iter().map(call_name).collect();
    assert_eq!(names, vec!["reserve", "release"]);
}

// -------------------------------------------------------------------
// (e) insufficient funds → 402, no admit call
// -------------------------------------------------------------------

#[tokio::test]
async fn insufficient_funds_is_402_before_admission() {
    let h = HarnessBuilder::new()
        .reserve_error(LedgerError::InsufficientFunds)
        .build();
    let response = h
        .router
        .clone()
        .oneshot(chat_request(&chat_body(false)))
        .await
        .expect("router");
    assert_eq!(response.status(), 402);
    let body = read_body(response).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(parsed["error"]["code"], "insufficient_quota");
    assert_eq!(parsed["error"]["type"], "insufficient_funds");

    assert_eq!(
        h.fleet_record.admit_count(),
        0,
        "no admission after reserve failure"
    );
    assert_eq!(h.ledger.count("release"), 0, "nothing was debited");
}

// -------------------------------------------------------------------
// (g) pipe overflow → provider cancelled, stream fails with an error event
// -------------------------------------------------------------------

#[tokio::test]
async fn pipe_overflow_cancels_provider_and_fails_stream() {
    let mut h = HarnessBuilder::new().build();
    let mut provider = h.providers.remove(0);
    let coordinator_public = h.coordinator_public.clone();
    let overflow = Arc::new(Notify::new());
    let overflow_signal = overflow.clone();

    let script = tokio::spawn(async move {
        let attach = provider.expect_attach().await;
        let (prepare, _) = expect_v2_prepare(provider.expect_data().await);
        let lease = LeaseId::new(Uuid::new_v4());
        attach
            .events
            .send(prepared_event(&prepare, lease, 20))
            .await
            .expect("prepared");
        let _ = expect_control_start(provider.expect_control().await);
        attach
            .events
            .send(AttemptEvent::Started)
            .await
            .expect("started");
        attach
            .chunks
            .try_send(ChunkFrame {
                payload: provider
                    .seal_v2_chunk(&coordinator_public, content_chunk("first").as_bytes()),
                sequence: 1,
                cumulative_tokens: 1,
            })
            .expect("chunk");

        overflow_signal.notified().await;
        // The session reports consumer backpressure (pipe rejected a chunk,
        // plan §13.6).
        attach
            .events
            .send(AttemptEvent::PipeOverflow)
            .await
            .expect("overflow");

        // The coordinator must cancel the running attempt.
        match provider.expect_control().await {
            ControlFrame::V2(f) => match *f {
                FrameV2::Cancel(cancel) => {
                    assert_eq!(cancel.scope.attempt_id, prepare.scope.attempt_id);
                }
                other => panic!("expected cancel, got {}", other.type_str()),
            },
            other => panic!("expected control frame, got {other:?}"),
        }
        // Cancelled terminal with the partial claim.
        let terminal = cancelled_terminal(scope_with_lease(&prepare, lease), "prov", 5);
        attach
            .events
            .send(AttemptEvent::Terminal(Box::new(terminal)))
            .await
            .expect("terminal");
        let _ = provider.expect_control().await; // ack
    });

    let response = h
        .router
        .clone()
        .oneshot(chat_request(&chat_body(true)))
        .await
        .expect("router");
    assert_eq!(response.status(), 200);

    use futures::StreamExt;
    let mut stream = response.into_body().into_data_stream();
    let first = tokio::time::timeout(RECV_TIMEOUT, stream.next())
        .await
        .expect("first")
        .expect("open")
        .expect("ok");
    assert!(std::str::from_utf8(&first).unwrap().contains("first"));
    overflow.notify_one();
    let mut rest = Vec::new();
    while let Some(frame) = tokio::time::timeout(RECV_TIMEOUT, stream.next())
        .await
        .expect("read")
    {
        rest.extend_from_slice(&frame.expect("ok"));
    }
    let tail = String::from_utf8(rest).unwrap();
    assert!(
        tail.contains("consumer_backpressure"),
        "stream must terminate with the backpressure error event, got: {tail}"
    );
    assert!(!tail.contains("[DONE]"), "no DONE after an error event");

    script.await.expect("script");
    // Partial settle capped at the accepted checkpoint (1 accepted chunk),
    // not the provider's claimed 5.
    wait_until(|| h.ledger.count("settle") == 1).await;
    let settle = h.ledger.find_settle().unwrap();
    assert_eq!(settle.completion_tokens_claimed, 5);
    assert_eq!(settle.accepted_cumulative_tokens, 1);
}

// -------------------------------------------------------------------
// (h) client disconnect after first content → cancel + partial settle
// -------------------------------------------------------------------

#[tokio::test]
async fn client_disconnect_after_content_cancels_and_settles_partial() {
    let mut h = HarnessBuilder::new().build();
    let mut provider = h.providers.remove(0);
    let coordinator_public = h.coordinator_public.clone();

    let script = tokio::spawn(async move {
        let attach = provider.expect_attach().await;
        let (prepare, _) = expect_v2_prepare(provider.expect_data().await);
        let lease = LeaseId::new(Uuid::new_v4());
        attach
            .events
            .send(prepared_event(&prepare, lease, 20))
            .await
            .expect("prepared");
        let _ = expect_control_start(provider.expect_control().await);
        attach
            .events
            .send(AttemptEvent::Started)
            .await
            .expect("started");
        attach
            .chunks
            .try_send(ChunkFrame {
                payload: provider
                    .seal_v2_chunk(&coordinator_public, content_chunk("partial").as_bytes()),
                sequence: 1,
                cumulative_tokens: 1,
            })
            .expect("chunk");

        // Client walks away → the coordinator cancels the started attempt
        // (plan §13.5) on the control lane.
        match provider.expect_control().await {
            ControlFrame::V2(f) => match *f {
                FrameV2::Cancel(cancel) => {
                    assert_eq!(cancel.scope.attempt_id, prepare.scope.attempt_id);
                }
                other => panic!("expected cancel, got {}", other.type_str()),
            },
            other => panic!("expected control frame, got {other:?}"),
        }
        // Authenticated partial usage arrives within the terminal window.
        let terminal = cancelled_terminal(scope_with_lease(&prepare, lease), "prov", 4);
        attach
            .events
            .send(AttemptEvent::Terminal(Box::new(terminal)))
            .await
            .expect("terminal");
    });

    let response = h
        .router
        .clone()
        .oneshot(chat_request(&chat_body(true)))
        .await
        .expect("router");
    assert_eq!(response.status(), 200);
    use futures::StreamExt;
    let mut stream = response.into_body().into_data_stream();
    let first = tokio::time::timeout(RECV_TIMEOUT, stream.next())
        .await
        .expect("first")
        .expect("open")
        .expect("ok");
    assert!(std::str::from_utf8(&first).unwrap().contains("partial"));
    // Disconnect: drop the response body mid-stream.
    drop(stream);

    script.await.expect("script");
    wait_until(|| h.ledger.count("settle") == 1).await;
    let settle = h.ledger.find_settle().unwrap();
    assert_eq!(settle.completion_tokens_claimed, 4);
    assert_eq!(
        settle.accepted_cumulative_tokens, 1,
        "capped at accepted checkpoint"
    );
}

// -------------------------------------------------------------------
// Ordered shutdown drains request tasks (plan §15.1 step 2)
// -------------------------------------------------------------------

/// Request tasks spawned by the chat handler must register with the
/// requests-phase tracker AND stop on the shutdown token: with a provider
/// that never answers, firing shutdown makes the handler return promptly
/// and leaves the tracker drainable — the supervisor's requests phase no
/// longer drains nothing.
#[tokio::test]
async fn shutdown_cancels_and_drains_request_tasks() {
    let mut h = HarnessBuilder::new().build();
    let mut provider = h.providers.remove(0);

    // The provider swallows the prepare and then goes silent forever,
    // keeping its session lanes open (a dropped lane would be session loss
    // — a different, self-resolving path).
    let script = tokio::spawn(async move {
        let _attach = provider.expect_attach().await;
        let _prepare = provider.expect_data().await;
        std::future::pending::<()>().await;
    });

    let router = h.router.clone();
    let request = tokio::spawn(async move {
        router
            .oneshot(chat_request(&chat_body(true)))
            .await
            .expect("router")
    });

    // The request is in flight and its task is TRACKED.
    wait_until(|| h.fleet_record.admit_count() == 1).await;
    wait_until(|| h.request_tracker.len() == 1).await;

    // Supervisor step 2, reproduced: fire the shutdown token, then drain.
    h.shutdown.cancel();
    let response = tokio::time::timeout(Duration::from_secs(5), request)
        .await
        .expect("handler must return promptly on shutdown")
        .expect("join");
    assert_eq!(
        response.status(),
        504,
        "pre-content shutdown cancellation maps to the timeout error"
    );

    h.request_tracker.close();
    tokio::time::timeout(Duration::from_secs(5), h.request_tracker.wait())
        .await
        .expect("requests phase drains after cancellation");
    script.abort();
}

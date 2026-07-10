//! End-to-end chat-completions tests through the real router, with every
//! seam faked at the frozen contracts: in-memory recording ledger, static
//! key store, scripted fleet actor, and provider simulators draining real
//! session channels (plan §22.3 style — no real DB, no real fleet).

#[path = "http_harness.rs"]
mod harness;

use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use tokio::sync::Notify;
use tower::ServiceExt;
use uuid::Uuid;

use darkbloom_core::ids::LeaseId;
use darkbloom_core::money::Tokens;
use darkbloom_protocol::crypto::nacl_box;
use darkbloom_protocol::crypto::sealed_sender;
use darkbloom_protocol::crypto::terminal_digest;
use darkbloom_protocol::json_v1::UsageInfo;
use darkbloom_protocol::json_v2::{
    self, ExecutionFacts, FrameV2, PrepareFrame, PreparedFrame, RequestScope, ResourceFacts,
    RollingHashCheckpoint, TerminalFrame, TerminalUsage,
};
use darkbloom_server::contracts::{
    AttemptEvent, ChunkFrame, ControlFrame, DataFrame, LedgerError, ProtocolGen,
};

use harness::*;

// -------------------------------------------------------------------
// Small helpers
// -------------------------------------------------------------------

async fn wait_until(mut condition: impl FnMut() -> bool) {
    for _ in 0..500 {
        if condition() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("condition not reached within 5s");
}

fn expect_v2_prepare(frame: DataFrame) -> (PrepareFrame, Bytes) {
    match frame {
        DataFrame::V2Prepare { frame, binary_body } => match *frame {
            FrameV2::Prepare(prepare) => (prepare, binary_body.expect("binary body present")),
            other => panic!("expected prepare frame, got {}", other.type_str()),
        },
        other => panic!("expected v2 prepare data frame, got {other:?}"),
    }
}

fn scope_with_lease(prepare: &PrepareFrame, lease: LeaseId) -> RequestScope {
    RequestScope {
        lease_id: Some(json_v2::LeaseId(*lease.as_bytes())),
        ..prepare.scope
    }
}

fn prepared_event(prepare: &PrepareFrame, lease: LeaseId, eta_ms: u64) -> AttemptEvent {
    AttemptEvent::Prepared {
        lease,
        ttl: Duration::from_secs(30),
        billable_prompt_tokens: 6,
        queue_depth: 0,
        prefill_can_start: true,
        frame: Box::new(PreparedFrame {
            scope: scope_with_lease(prepare, lease),
            ttl_ms: 30_000,
            billable_input_tokens: 6,
            resource: ResourceFacts::default(),
            execution: ExecutionFacts {
                engine_queue_depth: 0,
                prefill_can_start: true,
                predicted_first_content_ms: Some(eta_ms),
            },
        }),
    }
}

fn completed_terminal(
    scope: RequestScope,
    provider: &str,
    completion_tokens: u64,
    sequence: u64,
) -> TerminalFrame {
    TerminalFrame {
        scope,
        provider_id: provider.to_owned(),
        model_id: CONCRETE_MODEL.to_owned(),
        origin_session_epoch: json_v2::SessionEpoch(1),
        outcome: json_v2::TerminalOutcome::Completed,
        error_class: None,
        usage: TerminalUsage {
            prompt_tokens: 6,
            completion_tokens,
            reasoning_tokens: 0,
        },
        generated_tokens: completion_tokens,
        response_hash: json_v2::ResponseHash([7; 32]),
        checkpoint: RollingHashCheckpoint {
            sequence,
            cumulative_completion_tokens: completion_tokens,
            rolling_hash: json_v2::ResponseHash([8; 32]),
        },
        se_signature: "test-signature".to_owned(),
    }
}

fn cancelled_terminal(
    scope: RequestScope,
    provider: &str,
    claimed_completion: u64,
) -> TerminalFrame {
    TerminalFrame {
        scope,
        provider_id: provider.to_owned(),
        model_id: CONCRETE_MODEL.to_owned(),
        origin_session_epoch: json_v2::SessionEpoch(1),
        outcome: json_v2::TerminalOutcome::Cancelled,
        error_class: Some(json_v2::ErrorClass::Cancelled),
        usage: TerminalUsage {
            prompt_tokens: 6,
            completion_tokens: claimed_completion,
            reasoning_tokens: 0,
        },
        generated_tokens: claimed_completion,
        response_hash: json_v2::ResponseHash([7; 32]),
        checkpoint: RollingHashCheckpoint {
            sequence: claimed_completion,
            cumulative_completion_tokens: claimed_completion,
            rolling_hash: json_v2::ResponseHash([8; 32]),
        },
        se_signature: "test-signature".to_owned(),
    }
}

fn expect_control_start(frame: ControlFrame) -> RequestScope {
    match frame {
        ControlFrame::V2(f) => match *f {
            FrameV2::Start(start) => start.scope,
            other => panic!("expected start, got {}", other.type_str()),
        },
        other => panic!("expected v2 control frame, got {other:?}"),
    }
}

// -------------------------------------------------------------------
// (a) v2 happy path, streaming
// -------------------------------------------------------------------

#[tokio::test]
async fn v2_happy_path_streaming() {
    let mut h = HarnessBuilder::new().build();
    let mut provider = h.providers.remove(0);
    let provider_id = provider.provider;
    let coordinator_public = h.coordinator_public.clone();
    let normalized_body_check = Arc::new(std::sync::Mutex::new(None::<serde_json::Value>));
    let body_check = normalized_body_check.clone();

    let script = tokio::spawn(async move {
        let attach = provider.expect_attach().await;
        let (prepare, binary_body) = expect_v2_prepare(provider.expect_data().await);
        assert_eq!(prepare.model_id, CONCRETE_MODEL);
        assert_eq!(prepare.max_output_tokens, 64);
        assert!(prepare.scope.lease_id.is_none());

        // The binary body decodes and decrypts to the normalized request.
        let (header, ciphertext) =
            darkbloom_protocol::binary::decode(&binary_body, 32 * 1024 * 1024).expect("decode");
        assert_eq!(header.job_id, prepare.scope.job_id);
        assert_eq!(header.attempt_id, prepare.scope.attempt_id);
        let plain = nacl_box::open_bytes(&ciphertext, &coordinator_public, &provider.secret)
            .expect("decrypt prepare body");
        let parsed: serde_json::Value = serde_json::from_slice(&plain).expect("body json");
        *body_check.lock().unwrap() = Some(parsed);

        let lease = LeaseId::new(Uuid::new_v4());
        attach
            .events
            .send(prepared_event(&prepare, lease, 30))
            .await
            .expect("send prepared");

        let start_scope = expect_control_start(provider.expect_control().await);
        assert_eq!(
            start_scope.lease_id,
            Some(json_v2::LeaseId(*lease.as_bytes()))
        );
        attach
            .events
            .send(AttemptEvent::Started)
            .await
            .expect("send started");

        for (i, text) in ["Hello", " world"].iter().enumerate() {
            let plaintext = content_chunk(text);
            attach
                .chunks
                .try_send(ChunkFrame {
                    payload: provider.seal_v2_chunk(&coordinator_public, plaintext.as_bytes()),
                    sequence: (i + 1) as u64,
                    cumulative_tokens: (i + 1) as u64,
                })
                .expect("push chunk");
        }

        let terminal = completed_terminal(scope_with_lease(&prepare, lease), "prov-a", 2, 2);
        let digest = terminal_digest::terminal_digest(&terminal).expect("digest");
        attach
            .events
            .send(AttemptEvent::Terminal(Box::new(terminal)))
            .await
            .expect("send terminal");

        // ACK arrives only after the durable settle (plan §12.8).
        match provider.expect_control().await {
            ControlFrame::V2(f) => match *f {
                FrameV2::TerminalAck(ack) => {
                    assert_eq!(ack.terminal_digest, digest);
                    assert_eq!(ack.disposition, json_v2::AckDisposition::Recorded);
                }
                other => panic!("expected terminal_ack, got {}", other.type_str()),
            },
            other => panic!("expected control frame, got {other:?}"),
        }
    });

    let response = h
        .router
        .clone()
        .oneshot(chat_request(&chat_body(true)))
        .await
        .expect("router");
    assert_eq!(response.status(), 200);
    assert_eq!(
        response.headers().get("content-type").unwrap(),
        "text/event-stream"
    );
    let body = read_body(response).await;
    let events = sse_events(&body);

    // Exact relay bytes: chunk JSON with the model rewritten to the public
    // alias, in order.
    assert_eq!(
        events[0],
        content_chunk("Hello").replace(CONCRETE_MODEL, PUBLIC_MODEL)
    );
    assert_eq!(
        events[1],
        content_chunk(" world").replace(CONCRETE_MODEL, PUBLIC_MODEL)
    );
    // Final usage chunk carries authoritative terminal counts and the SE
    // signature; then exactly one [DONE].
    let usage: serde_json::Value = serde_json::from_str(&events[2]).expect("usage chunk json");
    assert_eq!(usage["object"], "chat.completion.chunk");
    assert_eq!(usage["model"], PUBLIC_MODEL);
    assert_eq!(usage["usage"]["prompt_tokens"], 6);
    assert_eq!(usage["usage"]["completion_tokens"], 2);
    assert_eq!(usage["usage"]["total_tokens"], 8);
    assert_eq!(usage["se_signature"], "test-signature");
    assert_eq!(events[3], "[DONE]");
    assert_eq!(events.len(), 4);

    script.await.expect("provider script");

    // The provider saw the normalized body: concrete model, injected bound.
    let seen = normalized_body_check.lock().unwrap().take().expect("body");
    assert_eq!(seen["model"], CONCRETE_MODEL);
    assert_eq!(seen["max_tokens"], 64);
    assert_eq!(seen["stream"], true);

    // Money legs in order, with the frozen terms from the prepared facts.
    let names: Vec<&str> = h.ledger.snapshot().iter().map(call_name).collect();
    assert_eq!(names, vec!["reserve", "resize", "mark_running", "settle"]);
    let resize = h.ledger.find_resize().expect("resize");
    assert_eq!(resize.frozen.billable_input_tokens, Tokens::new(6));
    assert_eq!(resize.frozen.max_output_tokens, Tokens::new(64));
    assert_eq!(resize.provider, provider_id);
    let settle = h.ledger.find_settle().expect("settle");
    assert_eq!(settle.completion_tokens_claimed, 2);
    assert_eq!(settle.accepted_cumulative_tokens, 2);
    assert_eq!(settle.accepted_sequence, 2);
    assert_eq!(settle.prompt_tokens, 6);
}

// -------------------------------------------------------------------
// (b) prepare-stage hedge: slow primary, second prepare to a different
//     provider, first usable lease wins, loser aborted, one resize.
// -------------------------------------------------------------------

#[tokio::test]
async fn hedge_second_prepare_wins_loser_aborted() {
    let mut h = HarnessBuilder::new()
        .providers(vec![ProtocolGen::V2, ProtocolGen::V2])
        .admit_script(vec![AdmitReply::Grant(0), AdmitReply::Grant(1)])
        .policy(|p| p.hedge_prepare_timeout = Duration::from_millis(100))
        .build();
    let mut provider_b = h.providers.remove(1);
    let mut provider_a = h.providers.remove(0);
    let provider_a_id = provider_a.provider;
    let provider_b_id = provider_b.provider;
    let coordinator_public = h.coordinator_public.clone();
    let release_a = Arc::new(Notify::new());
    let release_a_signal = release_a.clone();

    let script = tokio::spawn(async move {
        // Primary prepare reaches A; A stalls past the hedge timer.
        let attach_a = provider_a.expect_attach().await;
        let (prepare_a, _) = expect_v2_prepare(provider_a.expect_data().await);

        // The hedge dispatches to B; B prepares fast and wins funding.
        let attach_b = provider_b.expect_attach().await;
        let (prepare_b, _) = expect_v2_prepare(provider_b.expect_data().await);
        assert_ne!(prepare_a.scope.attempt_id, prepare_b.scope.attempt_id);
        let lease_b = LeaseId::new(Uuid::new_v4());
        attach_b
            .events
            .send(prepared_event(&prepare_b, lease_b, 20))
            .await
            .expect("prepared b");
        let _ = expect_control_start(provider_b.expect_control().await);
        attach_b
            .events
            .send(AttemptEvent::Started)
            .await
            .expect("started b");
        attach_b
            .chunks
            .try_send(ChunkFrame {
                payload: provider_b
                    .seal_v2_chunk(&coordinator_public, content_chunk("Hi").as_bytes()),
                sequence: 1,
                cumulative_tokens: 1,
            })
            .expect("chunk b");

        // Wait until the consumer has seen content, then let A's late lease
        // arrive: it must lose and be aborted (plan §11.8, §13.3).
        release_a_signal.notified().await;
        let lease_a = LeaseId::new(Uuid::new_v4());
        attach_a
            .events
            .send(prepared_event(&prepare_a, lease_a, 20))
            .await
            .expect("late prepared a");
        match provider_a.expect_control().await {
            ControlFrame::V2(f) => match *f {
                FrameV2::Abort(abort) => {
                    assert_eq!(abort.scope.attempt_id, prepare_a.scope.attempt_id);
                    assert_eq!(abort.reason, json_v2::AbortReason::HedgeLoss);
                }
                other => panic!("expected abort for loser, got {}", other.type_str()),
            },
            other => panic!("expected control frame, got {other:?}"),
        }
        attach_a
            .events
            .send(AttemptEvent::Aborted {
                reason: json_v2::AbortReason::HedgeLoss,
            })
            .await
            .expect("aborted a");

        // B completes.
        let terminal = completed_terminal(scope_with_lease(&prepare_b, lease_b), "prov-b", 1, 1);
        attach_b
            .events
            .send(AttemptEvent::Terminal(Box::new(terminal)))
            .await
            .expect("terminal b");
        let _ = provider_b.expect_control().await; // terminal ack
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
        .expect("first frame")
        .expect("stream open")
        .expect("frame ok");
    assert!(first.starts_with(b"data: "));
    release_a.notify_one();
    // Drain the rest of the stream.
    let mut rest = Vec::new();
    while let Some(frame) = tokio::time::timeout(RECV_TIMEOUT, stream.next())
        .await
        .expect("stream read")
    {
        rest.extend_from_slice(&frame.expect("frame ok"));
    }
    assert!(std::str::from_utf8(&rest).unwrap().contains("[DONE]"));

    script.await.expect("provider script");

    // Two admissions: the hedge excluded the primary.
    let admits = h.fleet_record.admits.lock().unwrap().clone();
    assert_eq!(admits.len(), 2);
    assert!(admits[0].exclude.is_empty());
    assert_eq!(admits[1].exclude, vec![provider_a_id]);

    // Exactly one funding leg, for the winner.
    assert_eq!(h.ledger.count("resize"), 1);
    assert_eq!(h.ledger.find_resize().unwrap().provider, provider_b_id);
    assert_eq!(h.ledger.count("settle"), 1);
}

// -------------------------------------------------------------------
// (c) prepare rejection → one sequential alternate → success
// -------------------------------------------------------------------

#[tokio::test]
async fn prepare_rejection_takes_one_alternate() {
    let mut h = HarnessBuilder::new()
        .providers(vec![ProtocolGen::V2, ProtocolGen::V2])
        .admit_script(vec![AdmitReply::Grant(0), AdmitReply::Grant(1)])
        .build();
    let mut provider_b = h.providers.remove(1);
    let mut provider_a = h.providers.remove(0);
    let provider_a_id = provider_a.provider;
    let coordinator_public = h.coordinator_public.clone();

    let script = tokio::spawn(async move {
        // A rejects the prepare with a capacity-class terminal.
        let attach_a = provider_a.expect_attach().await;
        let (prepare_a, _) = expect_v2_prepare(provider_a.expect_data().await);
        let mut rejection = cancelled_terminal(
            scope_with_lease(&prepare_a, LeaseId::new(Uuid::new_v4())),
            "prov-a",
            0,
        );
        rejection.outcome = json_v2::TerminalOutcome::Failed;
        rejection.error_class = Some(json_v2::ErrorClass::Capacity);
        attach_a
            .events
            .send(AttemptEvent::Terminal(Box::new(rejection)))
            .await
            .expect("rejection");

        // The invisible alternate lands on B and succeeds.
        let attach_b = provider_b.expect_attach().await;
        let (prepare_b, _) = expect_v2_prepare(provider_b.expect_data().await);
        let lease_b = LeaseId::new(Uuid::new_v4());
        attach_b
            .events
            .send(prepared_event(&prepare_b, lease_b, 20))
            .await
            .expect("prepared b");
        let _ = expect_control_start(provider_b.expect_control().await);
        attach_b
            .events
            .send(AttemptEvent::Started)
            .await
            .expect("started");
        attach_b
            .chunks
            .try_send(ChunkFrame {
                payload: provider_b
                    .seal_v2_chunk(&coordinator_public, content_chunk("ok").as_bytes()),
                sequence: 1,
                cumulative_tokens: 1,
            })
            .expect("chunk");
        let terminal = completed_terminal(scope_with_lease(&prepare_b, lease_b), "prov-b", 1, 1);
        attach_b
            .events
            .send(AttemptEvent::Terminal(Box::new(terminal)))
            .await
            .expect("terminal");
        let _ = provider_b.expect_control().await; // ack
    });

    let response = h
        .router
        .clone()
        .oneshot(chat_request(&chat_body(true)))
        .await
        .expect("router");
    assert_eq!(response.status(), 200, "rejection stayed invisible");
    let body = read_body(response).await;
    let events = sse_events(&body);
    assert!(events[0].contains("\"ok\""));
    assert_eq!(events.last().unwrap(), "[DONE]");

    script.await.expect("script");
    let admits = h.fleet_record.admits.lock().unwrap().clone();
    assert_eq!(admits.len(), 2);
    assert_eq!(admits[1].exclude, vec![provider_a_id]);
    assert_eq!(h.ledger.count("settle"), 1);
    assert_eq!(h.ledger.count("release"), 0);
}

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
// (f) sealed request/response round trip (non-streaming)
// -------------------------------------------------------------------

#[tokio::test]
async fn sealed_round_trip_non_streaming() {
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
                    .seal_v2_chunk(&coordinator_public, content_chunk("sealed!").as_bytes()),
                sequence: 1,
                cumulative_tokens: 1,
            })
            .expect("chunk");
        let terminal = completed_terminal(scope_with_lease(&prepare, lease), "prov", 1, 1);
        attach
            .events
            .send(AttemptEvent::Terminal(Box::new(terminal)))
            .await
            .expect("terminal");
        let _ = provider.expect_control().await; // ack
    });

    // Client-side sealing.
    let (_, client_secret) = nacl_box::generate_keypair();
    let kid = sealed_sender::derive_kid(&h.coordinator_public);
    let plaintext = serde_json::to_vec(&chat_body(false)).unwrap();
    let envelope =
        sealed_sender::seal_request(&plaintext, &h.coordinator_public, &kid, &client_secret)
            .expect("seal request");
    let request = axum::http::Request::builder()
        .method("POST")
        .uri("/v1/chat/completions")
        .header("authorization", format!("Bearer {API_TOKEN}"))
        .header("content-type", sealed_sender::SEALED_CONTENT_TYPE)
        .body(axum::body::Body::from(
            serde_json::to_vec(&envelope).unwrap(),
        ))
        .unwrap();

    let response = h.router.clone().oneshot(request).await.expect("router");
    assert_eq!(response.status(), 200);
    assert_eq!(
        response.headers().get("content-type").unwrap(),
        sealed_sender::SEALED_CONTENT_TYPE
    );
    let body = read_body(response).await;
    let sealed_envelope: sealed_sender::SealedResponseEnvelope =
        serde_json::from_slice(&body).expect("sealed envelope");
    let opened = sealed_sender::open_response(
        &sealed_envelope,
        &h.coordinator_public,
        &client_secret,
        &kid,
    )
    .expect("open response");
    let parsed: serde_json::Value = serde_json::from_slice(&opened).expect("json");
    assert_eq!(parsed["object"], "chat.completion");
    assert_eq!(parsed["model"], PUBLIC_MODEL);
    assert_eq!(parsed["choices"][0]["message"]["content"], "sealed!");
    assert_eq!(parsed["usage"]["completion_tokens"], 1);

    script.await.expect("script");
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
// (i) non-streaming aggregation
// -------------------------------------------------------------------

#[tokio::test]
async fn non_streaming_aggregates_deltas_and_terminal_usage() {
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
        for (i, text) in ["Hello", " world"].iter().enumerate() {
            attach
                .chunks
                .try_send(ChunkFrame {
                    payload: provider
                        .seal_v2_chunk(&coordinator_public, content_chunk(text).as_bytes()),
                    sequence: (i + 1) as u64,
                    cumulative_tokens: (i + 1) as u64,
                })
                .expect("chunk");
        }
        // Finish chunk (empty delta + finish_reason) rides the same pipe.
        let finish = format!(
            r#"{{"id":"chatcmpl-p","object":"chat.completion.chunk","model":"{CONCRETE_MODEL}","choices":[{{"delta":{{}},"finish_reason":"stop"}}],"usage":null}}"#
        );
        attach
            .chunks
            .try_send(ChunkFrame {
                payload: provider.seal_v2_chunk(&coordinator_public, finish.as_bytes()),
                sequence: 3,
                cumulative_tokens: 2,
            })
            .expect("finish chunk");
        let terminal = completed_terminal(scope_with_lease(&prepare, lease), "prov", 2, 3);
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
        .oneshot(chat_request(&chat_body(false)))
        .await
        .expect("router");
    assert_eq!(response.status(), 200);
    let body = read_body(response).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(parsed["object"], "chat.completion");
    assert_eq!(parsed["model"], PUBLIC_MODEL);
    assert_eq!(parsed["choices"][0]["message"]["role"], "assistant");
    assert_eq!(parsed["choices"][0]["message"]["content"], "Hello world");
    assert_eq!(parsed["choices"][0]["finish_reason"], "stop");
    assert_eq!(parsed["usage"]["prompt_tokens"], 6);
    assert_eq!(parsed["usage"]["completion_tokens"], 2);
    assert_eq!(parsed["se_signature"], "test-signature");

    script.await.expect("script");
}

// -------------------------------------------------------------------
// (j) v1 happy path: golden wire shape, chunk decrypt, settle from usage
// -------------------------------------------------------------------

#[tokio::test]
async fn v1_happy_path_golden_wire_and_settle() {
    let mut h = HarnessBuilder::new()
        .providers(vec![ProtocolGen::V1])
        .build();
    let mut provider = h.providers.remove(0);

    let script = tokio::spawn(async move {
        let attach = provider.expect_attach().await;
        let frame = provider.expect_data().await;
        let bytes = match frame {
            DataFrame::V1InferenceRequest(bytes) => bytes,
            other => panic!("expected v1 inference_request, got {other:?}"),
        };
        let wire: serde_json::Value = serde_json::from_slice(&bytes).expect("wire json");

        // Golden shape: same key structure as the fixture vectors.
        let fixture: serde_json::Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../fixtures/vectors/json_v1/inference_request__encrypted.json"
        )))
        .expect("fixture");
        let wire_keys: Vec<&str> = wire
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        let fixture_keys: Vec<&str> = fixture
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(wire_keys, fixture_keys, "top-level key set matches golden");
        assert_eq!(wire["type"], "inference_request");
        assert_eq!(wire["request_id"], attach.wire_id.as_str());
        // Zero-valued `body` is ALWAYS on the wire (Go omitempty is a no-op
        // on struct fields; the Swift strict decoder depends on it).
        assert_eq!(wire["body"], fixture["body"]);
        let encrypted_keys: Vec<&str> = wire["encrypted_body"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(encrypted_keys, vec!["ciphertext", "ephemeral_public_key"]);

        // Decrypt the body like the provider would.
        let session_public_b64 = wire["encrypted_body"]["ephemeral_public_key"]
            .as_str()
            .unwrap()
            .to_owned();
        let payload = darkbloom_protocol::json_v1::EncryptedPayload {
            ephemeral_public_key: session_public_b64.clone(),
            ciphertext: wire["encrypted_body"]["ciphertext"]
                .as_str()
                .unwrap()
                .to_owned(),
        };
        let plain = nacl_box::open(&payload, &provider.secret).expect("decrypt v1 body");
        let body: serde_json::Value = serde_json::from_slice(&plain).expect("body json");
        assert_eq!(body["model"], CONCRETE_MODEL);
        assert_eq!(body["stream"], true);

        // Accepted → encrypted chunks (v1 style: `data: ` prefix baked in,
        // sealed back to the session key) → complete with usage.
        attach
            .events
            .send(AttemptEvent::AcceptedV1)
            .await
            .expect("accepted");
        for text in ["Hello", " v1"] {
            let plaintext = format!("data: {}", content_chunk(text));
            attach
                .chunks
                .try_send(ChunkFrame {
                    payload: provider.seal_v1_chunk(&session_public_b64, plaintext.as_bytes()),
                    sequence: 0,
                    cumulative_tokens: 0,
                })
                .expect("chunk");
        }
        attach
            .events
            .send(AttemptEvent::CompleteV1 {
                usage: Some(UsageInfo {
                    prompt_tokens: 6,
                    completion_tokens: 9,
                    reasoning_tokens: 2,
                }),
                se_signature: Some("v1-sig".to_owned()),
                response_hash: Some("v1-hash".to_owned()),
            })
            .await
            .expect("complete");
    });

    let response = h
        .router
        .clone()
        .oneshot(chat_request(&chat_body(true)))
        .await
        .expect("router");
    assert_eq!(response.status(), 200);
    let body = read_body(response).await;
    let events = sse_events(&body);
    assert_eq!(
        events[0],
        content_chunk("Hello").replace(CONCRETE_MODEL, PUBLIC_MODEL)
    );
    assert_eq!(
        events[1],
        content_chunk(" v1").replace(CONCRETE_MODEL, PUBLIC_MODEL)
    );
    let usage: serde_json::Value = serde_json::from_str(&events[2]).expect("usage json");
    assert_eq!(usage["usage"]["prompt_tokens"], 6);
    assert_eq!(usage["usage"]["completion_tokens"], 9);
    assert_eq!(
        usage["usage"]["completion_tokens_details"]["reasoning_tokens"],
        2
    );
    assert_eq!(usage["se_signature"], "v1-sig");
    assert_eq!(events[3], "[DONE]");

    script.await.expect("script");

    // v1 funding leg is the reserve itself: no resize, settle from the
    // terminal UsageInfo with the checkpoint promoted to the claimed count.
    let names: Vec<&str> = h.ledger.snapshot().iter().map(call_name).collect();
    assert_eq!(names, vec!["reserve", "mark_running", "settle"]);
    let settle = h.ledger.find_settle().unwrap();
    assert_eq!(settle.completion_tokens_claimed, 9);
    assert_eq!(
        settle.accepted_cumulative_tokens, 9,
        "intact stream promotes checkpoint"
    );
    assert_eq!(settle.prompt_tokens, 6);
}

//! v2 chat-completions scenarios through the real router: the happy
//! streaming path, the prepare-stage hedge, and rejection/alternate
//! handling — every seam faked at the frozen contracts (plan §22.3 style —
//! no real DB, no real fleet).

#[path = "http_support/mod.rs"]
mod support;

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::Notify;
use tower::ServiceExt;
use uuid::Uuid;

use darkbloom_core::ids::LeaseId;
use darkbloom_core::money::Tokens;
use darkbloom_protocol::crypto::nacl_box;
use darkbloom_protocol::json_v2::{self, FrameV2};
use darkbloom_server::contracts::{AttemptEvent, ChunkFrame, ControlFrame, ProtocolGen};

use support::*;

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
        let digest = darkbloom_protocol::crypto::terminal_digest::terminal_digest(&terminal)
            .expect("digest");
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
    // The typed rejection reached the fleet (plan §11.3 advisory
    // invalidation / §11.6 health), and every released permit id was the
    // one the fleet minted.
    let observations = h.fleet_record.observations.lock().unwrap().clone();
    assert!(
        observations.iter().any(|o| o == "prepare_rejected"),
        "fleet never observed the prepare rejection: {observations:?}"
    );
    h.fleet_record.assert_releases_echo_minted();
}

// -------------------------------------------------------------------
// (c2) a deterministic (invalid_request) rejection terminal fails the
//      request once — no alternate is dispatched (plan §10.5).
// -------------------------------------------------------------------

#[tokio::test]
async fn v2_invalid_request_rejection_terminal_fails_without_alternate() {
    let mut h = HarnessBuilder::new()
        .providers(vec![ProtocolGen::V2, ProtocolGen::V2])
        .admit_script(vec![AdmitReply::Grant(0), AdmitReply::Grant(1)])
        .build();
    let _provider_b = h.providers.remove(1);
    let mut provider_a = h.providers.remove(0);

    let script = tokio::spawn(async move {
        let attach_a = provider_a.expect_attach().await;
        let (prepare_a, _) = expect_v2_prepare(provider_a.expect_data().await);
        let mut rejection = cancelled_terminal(
            scope_with_lease(&prepare_a, LeaseId::new(Uuid::new_v4())),
            "prov-a",
            0,
        );
        rejection.outcome = json_v2::TerminalOutcome::Failed;
        rejection.error_class = Some(json_v2::ErrorClass::InvalidRequest);
        attach_a
            .events
            .send(AttemptEvent::Terminal(Box::new(rejection)))
            .await
            .expect("rejection");
    });

    let response = h
        .router
        .clone()
        .oneshot(chat_request(&chat_body(true)))
        .await
        .expect("router");
    // Deterministic class: retrying would fail identically (plan §10.5).
    assert_eq!(response.status(), 400);

    script.await.expect("script");
    assert_eq!(
        h.fleet_record.admit_count(),
        1,
        "invalid_request must not dispatch an alternate"
    );
    let names: Vec<&str> = h.ledger.snapshot().iter().map(call_name).collect();
    assert_eq!(names, vec!["reserve", "release"]);
    h.fleet_record.assert_releases_echo_minted();
}

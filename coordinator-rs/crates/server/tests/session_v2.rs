//! Protocol v2 session integration tests: prepare→prepared→start→started,
//! binary chunk frames, terminal + coordinator ACK, epoch/nonce fencing,
//! and the abort tombstone (plan §10.2, §10.3, §15.3).

#[path = "session_support/mod.rs"]
mod support;

use std::time::Duration;

use bytes::Bytes;

use darkbloom_core::ids::AttemptId;
use darkbloom_protocol::binary::{self, BinaryFrameHeader, FrameKind};
use darkbloom_protocol::json_v2::{
    AbortFrame, AbortReason, AbortedFrame, AckDisposition, CancelledFrame, ExecutionFacts, FrameV2,
    ModelReadyFrame, PrepareFrame, PreparedFrame, RequestScope, ResourceFacts,
    RollingHashCheckpoint, StartFrame, StartedFrame, TerminalAckFrame, TerminalFrame,
    TerminalOutcome, TerminalUsage,
};
use darkbloom_server::contracts::{AttemptEvent, ControlFrame, DataFrame};

use support::{attempt_sinks, FakeProvider, Harness, COORD_EPOCH, MODEL};

/// One attempt's wire identity, mirroring what a request task would mint.
struct AttemptWire {
    scope: RequestScope,
    attempt: AttemptId,
    wire_id: String,
}

fn new_attempt(session_epoch: u64, seed: u8) -> AttemptWire {
    let attempt_uuid = uuid::Uuid::new_v4();
    let scope = RequestScope {
        job_id: darkbloom_protocol::json_v2::JobId([seed; 16]),
        attempt_id: darkbloom_protocol::json_v2::AttemptId(*attempt_uuid.as_bytes()),
        lease_id: None,
        session_epoch: darkbloom_protocol::json_v2::SessionEpoch(session_epoch),
        coordinator_epoch: darkbloom_protocol::json_v2::CoordinatorEpoch(COORD_EPOCH),
        dispatch_nonce: darkbloom_protocol::json_v2::DispatchNonce([seed.wrapping_add(1); 16]),
        request_digest: darkbloom_protocol::json_v2::RequestDigest([seed.wrapping_add(2); 32]),
    };
    AttemptWire {
        scope,
        attempt: AttemptId::new(attempt_uuid),
        wire_id: scope.attempt_id.to_string(),
    }
}

fn with_lease(scope: RequestScope, lease: [u8; 16]) -> RequestScope {
    RequestScope {
        lease_id: Some(darkbloom_protocol::json_v2::LeaseId(lease)),
        ..scope
    }
}

fn chunk_header(scope: &RequestScope, sequence: u64, cumulative: u64) -> BinaryFrameHeader {
    BinaryFrameHeader {
        kind: FrameKind::ResponseChunk,
        job_id: scope.job_id,
        attempt_id: scope.attempt_id,
        lease_id: scope.lease_id,
        session_epoch: scope.session_epoch,
        coordinator_epoch: scope.coordinator_epoch,
        dispatch_nonce: scope.dispatch_nonce,
        request_digest: scope.request_digest,
        sequence,
        cumulative_completion_tokens: cumulative,
    }
}

async fn recv_event(events: &mut tokio::sync::mpsc::Receiver<AttemptEvent>) -> AttemptEvent {
    tokio::time::timeout(Duration::from_secs(5), events.recv())
        .await
        .expect("event in time")
        .expect("events open")
}

/// Bring up a v2 provider: register (with extension), answer the challenge,
/// declare the model via a v2 lifecycle event, and get a grant.
async fn establish_v2(
    harness: &Harness,
    provider: &mut FakeProvider,
) -> Box<darkbloom_server::contracts::AdmitGrant> {
    provider.establish(true).await;
    let ready = FrameV2::ModelReady(ModelReadyFrame {
        model_id: MODEL.to_owned(),
        state_revision: 1,
    });
    provider
        .send_json(&serde_json::from_slice(&ready.encode().expect("encode")).expect("value"))
        .await;
    harness.admit_until_grant(support::ALIAS).await
}

#[tokio::test]
async fn v2_two_phase_flow_with_binary_chunks_and_terminal_ack() {
    let harness = Harness::start().await;
    let mut provider = FakeProvider::connect(&harness, "SER-V2").await;
    let grant = establish_v2(&harness, &mut provider).await;
    let epoch = grant.session.epoch.get();

    let wire = new_attempt(epoch, 0x10);
    let (sinks, mut events, mut chunks) = attempt_sinks();
    grant
        .session
        .attach_attempt(wire.wire_id.clone(), wire.attempt, sinks)
        .await
        .expect("attach");

    // prepare (JSON control part + binary encrypted body).
    let prepare = FrameV2::Prepare(PrepareFrame {
        scope: wire.scope,
        model_id: MODEL.to_owned(),
        max_output_tokens: 256,
        first_content_budget_ms: 8_000,
    });
    let body_header = BinaryFrameHeader {
        kind: FrameKind::PrepareBody,
        ..chunk_header(&wire.scope, 0, 0)
    };
    let body = binary::encode(&body_header, b"sealed-prepare-body").expect("encode body");
    let on_wire = grant
        .session
        .submit_data(DataFrame::V2Prepare {
            frame: Box::new(prepare),
            binary_body: Some(body),
        })
        .expect("submit prepare");
    on_wire.await.expect("writer alive").expect("on wire");

    let prepare_json = provider.next_json().await;
    assert_eq!(prepare_json["type"], "prepare");
    let body_frame = provider.next_binary().await;
    let (got_header, got_body) =
        binary::decode(&Bytes::from(body_frame), 1 << 20).expect("decode body");
    assert_eq!(got_header.kind, FrameKind::PrepareBody);
    assert_eq!(&got_body[..], b"sealed-prepare-body");

    // prepared: the provider issues a lease with execution facts.
    let lease = [0xAA; 16];
    let leased = with_lease(wire.scope, lease);
    let prepared = FrameV2::Prepared(PreparedFrame {
        scope: leased,
        ttl_ms: 10_000,
        billable_input_tokens: 42,
        resource: ResourceFacts {
            kv_reserved_tokens: 512,
            kv_headroom_tokens: 8_192,
            batch_running: 1,
        },
        execution: ExecutionFacts {
            engine_queue_depth: 2,
            prefill_can_start: true,
            predicted_first_content_ms: Some(300),
        },
    });
    provider
        .send_json(&serde_json::from_slice(&prepared.encode().expect("encode")).expect("value"))
        .await;
    match recv_event(&mut events).await {
        AttemptEvent::Prepared {
            ttl,
            billable_prompt_tokens,
            queue_depth,
            prefill_can_start,
            ..
        } => {
            assert_eq!(ttl, Duration::from_millis(10_000));
            assert_eq!(billable_prompt_tokens, 42);
            assert_eq!(queue_depth, 2);
            assert!(prefill_can_start);
        }
        other => panic!("expected Prepared, got {other:?}"),
    }

    // start (control lane) -> started.
    let start = FrameV2::Start(StartFrame { scope: leased });
    grant
        .session
        .submit_control(ControlFrame::V2(Box::new(start)))
        .expect("submit start")
        .await
        .expect("writer alive")
        .expect("on wire");
    let start_json = provider.next_json().await;
    assert_eq!(start_json["type"], "start");
    let started = FrameV2::Started(StartedFrame { scope: leased });
    provider
        .send_json(&serde_json::from_slice(&started.encode().expect("encode")).expect("value"))
        .await;
    assert!(matches!(
        recv_event(&mut events).await,
        AttemptEvent::Started
    ));

    // Binary response chunks flow into the pipe with their sequence and
    // cumulative-token facts (plan §10.6).
    for (sequence, cumulative, payload) in [
        (1u64, 3u64, b"cipher-one".as_slice()),
        (2, 6, b"cipher-two"),
    ] {
        let frame = binary::encode(&chunk_header(&leased, sequence, cumulative), payload)
            .expect("encode chunk");
        provider.send_binary(frame.to_vec()).await;
    }
    for (sequence, cumulative, payload) in [
        (1u64, 3u64, b"cipher-one".as_slice()),
        (2, 6, b"cipher-two"),
    ] {
        let chunk = tokio::time::timeout(Duration::from_secs(5), chunks.recv())
            .await
            .expect("chunk in time")
            .expect("pipe open");
        assert_eq!(chunk.sequence, sequence);
        assert_eq!(chunk.cumulative_tokens, cumulative);
        assert_eq!(&chunk.payload[..], payload);
    }

    // Terminal -> coordinator ACK (test stands in for the request task).
    let terminal = FrameV2::Terminal(TerminalFrame {
        scope: leased,
        provider_id: "prov-v2".to_owned(),
        model_id: MODEL.to_owned(),
        origin_session_epoch: leased.session_epoch,
        outcome: TerminalOutcome::Completed,
        error_class: None,
        usage: TerminalUsage {
            prompt_tokens: 42,
            completion_tokens: 6,
            reasoning_tokens: 0,
        },
        generated_tokens: 6,
        response_hash: darkbloom_protocol::json_v2::ResponseHash([0x0B; 32]),
        checkpoint: RollingHashCheckpoint {
            sequence: 2,
            cumulative_completion_tokens: 6,
            rolling_hash: darkbloom_protocol::json_v2::ResponseHash([0x0C; 32]),
        },
        se_signature: "sig".to_owned(),
    });
    provider
        .send_json(&serde_json::from_slice(&terminal.encode().expect("encode")).expect("value"))
        .await;
    match recv_event(&mut events).await {
        AttemptEvent::Terminal(frame) => {
            assert_eq!(frame.outcome, TerminalOutcome::Completed);
            assert_eq!(frame.usage.completion_tokens, 6);
        }
        other => panic!("expected Terminal, got {other:?}"),
    }
    let ack = FrameV2::TerminalAck(TerminalAckFrame {
        scope: leased,
        terminal_digest: darkbloom_protocol::json_v2::TerminalDigest([0x0D; 32]),
        disposition: AckDisposition::Recorded,
    });
    grant
        .session
        .submit_control(ControlFrame::V2(Box::new(ack)))
        .expect("submit ack")
        .await
        .expect("writer alive")
        .expect("on wire");
    let ack_json = provider.next_json().await;
    assert_eq!(ack_json["type"], "terminal_ack");
    assert_eq!(ack_json["disposition"], "recorded");

    harness.runtime.shutdown().await;
}

/// v2 has no dedicated prepare-rejection frame (plan §10.5): a provider
/// that cannot serve a prepare answers with a `terminal` carrying
/// `outcome=failed` + `error_class`. The session must forward that
/// PRE-START terminal to the attached attempt's events sink — it is the
/// rejection vehicle the request task maps to `PrepareRejected` (which the
/// reducer resolves into the sequential alternate; that half is covered by
/// the http_chat alternate tests).
#[tokio::test]
async fn pre_start_rejection_terminal_reaches_events_sink() {
    let harness = Harness::start().await;
    let mut provider = FakeProvider::connect(&harness, "SER-V2R").await;
    let grant = establish_v2(&harness, &mut provider).await;
    let epoch = grant.session.epoch.get();

    let wire = new_attempt(epoch, 0x40);
    let (sinks, mut events, _chunks) = attempt_sinks();
    grant
        .session
        .attach_attempt(wire.wire_id.clone(), wire.attempt, sinks)
        .await
        .expect("attach");

    // prepare goes out; the provider rejects instead of returning prepared.
    let prepare = FrameV2::Prepare(PrepareFrame {
        scope: wire.scope,
        model_id: MODEL.to_owned(),
        max_output_tokens: 16,
        first_content_budget_ms: 1_000,
    });
    grant
        .session
        .submit_data(DataFrame::V2Prepare {
            frame: Box::new(prepare),
            binary_body: None,
        })
        .expect("submit prepare")
        .await
        .expect("writer alive")
        .expect("on wire");
    let prepare_json = provider.next_json().await;
    assert_eq!(prepare_json["type"], "prepare");

    // The rejection terminal: outcome=failed with a structured class. The
    // frame invariant requires a lease id, so the provider mints one for
    // the rejection record.
    let leased = with_lease(wire.scope, [0xDD; 16]);
    let rejection = FrameV2::Terminal(TerminalFrame {
        scope: leased,
        provider_id: "prov-v2".to_owned(),
        model_id: MODEL.to_owned(),
        origin_session_epoch: leased.session_epoch,
        outcome: TerminalOutcome::Failed,
        error_class: Some(darkbloom_protocol::json_v2::ErrorClass::Capacity),
        usage: TerminalUsage::default(),
        generated_tokens: 0,
        response_hash: darkbloom_protocol::json_v2::ResponseHash([0; 32]),
        checkpoint: RollingHashCheckpoint::default(),
        se_signature: "sig".to_owned(),
    });
    provider
        .send_json(&serde_json::from_slice(&rejection.encode().expect("encode")).expect("value"))
        .await;

    match recv_event(&mut events).await {
        AttemptEvent::Terminal(frame) => {
            assert_eq!(frame.outcome, TerminalOutcome::Failed);
            assert_eq!(
                frame.error_class,
                Some(darkbloom_protocol::json_v2::ErrorClass::Capacity)
            );
        }
        other => panic!("expected the rejection terminal, got {other:?}"),
    }

    harness.runtime.shutdown().await;
}

#[tokio::test]
async fn stale_epoch_and_nonce_mismatch_chunks_are_dropped() {
    let harness = Harness::start().await;
    let mut provider = FakeProvider::connect(&harness, "SER-V2F").await;
    let grant = establish_v2(&harness, &mut provider).await;
    let epoch = grant.session.epoch.get();

    let wire = new_attempt(epoch, 0x20);
    let (sinks, _events, mut chunks) = attempt_sinks();
    grant
        .session
        .attach_attempt(wire.wire_id.clone(), wire.attempt, sinks)
        .await
        .expect("attach");
    // Dispatch the prepare so the session binds the expected nonce/digest.
    let prepare = FrameV2::Prepare(PrepareFrame {
        scope: wire.scope,
        model_id: MODEL.to_owned(),
        max_output_tokens: 16,
        first_content_budget_ms: 1_000,
    });
    grant
        .session
        .submit_data(DataFrame::V2Prepare {
            frame: Box::new(prepare),
            binary_body: None,
        })
        .expect("submit prepare")
        .await
        .expect("writer alive")
        .expect("on wire");
    let _ = provider.next_json().await;
    let leased = with_lease(wire.scope, [0xBB; 16]);

    // 1) Stale session epoch.
    let mut stale = chunk_header(&leased, 1, 1);
    stale.session_epoch = darkbloom_protocol::json_v2::SessionEpoch(epoch + 41);
    provider
        .send_binary(binary::encode(&stale, b"stale").expect("encode").to_vec())
        .await;
    // 2) Substituted dispatch nonce.
    let mut swapped = chunk_header(&leased, 1, 1);
    swapped.dispatch_nonce = darkbloom_protocol::json_v2::DispatchNonce([0xEE; 16]);
    provider
        .send_binary(binary::encode(&swapped, b"swap").expect("encode").to_vec())
        .await;
    // 3) The genuine chunk.
    provider
        .send_binary(
            binary::encode(&chunk_header(&leased, 1, 1), b"good")
                .expect("encode")
                .to_vec(),
        )
        .await;

    // Single reader => in-order handling: the first delivered chunk must be
    // the genuine one; the fenced two never reach the pipe.
    let chunk = tokio::time::timeout(Duration::from_secs(5), chunks.recv())
        .await
        .expect("chunk in time")
        .expect("pipe open");
    assert_eq!(&chunk.payload[..], b"good");
    let nothing = tokio::time::timeout(Duration::from_millis(200), chunks.recv()).await;
    assert!(nothing.is_err(), "fenced chunks must never be delivered");

    harness.runtime.shutdown().await;
}

#[tokio::test]
async fn abort_tombstone_rejects_late_started() {
    let harness = Harness::start().await;
    let mut provider = FakeProvider::connect(&harness, "SER-V2A").await;
    let grant = establish_v2(&harness, &mut provider).await;
    let epoch = grant.session.epoch.get();

    let wire = new_attempt(epoch, 0x30);
    let (sinks, mut events, _chunks) = attempt_sinks();
    grant
        .session
        .attach_attempt(wire.wire_id.clone(), wire.attempt, sinks)
        .await
        .expect("attach");

    // prepare -> prepared.
    let prepare = FrameV2::Prepare(PrepareFrame {
        scope: wire.scope,
        model_id: MODEL.to_owned(),
        max_output_tokens: 16,
        first_content_budget_ms: 1_000,
    });
    grant
        .session
        .submit_data(DataFrame::V2Prepare {
            frame: Box::new(prepare),
            binary_body: None,
        })
        .expect("submit prepare")
        .await
        .expect("writer alive")
        .expect("on wire");
    let _ = provider.next_json().await;
    let leased = with_lease(wire.scope, [0xCC; 16]);
    let prepared = FrameV2::Prepared(PreparedFrame {
        scope: leased,
        ttl_ms: 10_000,
        billable_input_tokens: 8,
        resource: ResourceFacts::default(),
        execution: ExecutionFacts::default(),
    });
    provider
        .send_json(&serde_json::from_slice(&prepared.encode().expect("encode")).expect("value"))
        .await;
    assert!(matches!(
        recv_event(&mut events).await,
        AttemptEvent::Prepared { .. }
    ));

    // The coordinator aborts (hedge loss); the provider tombstones and acks.
    let abort = FrameV2::Abort(AbortFrame {
        scope: leased,
        reason: AbortReason::HedgeLoss,
    });
    grant
        .session
        .submit_control(ControlFrame::V2(Box::new(abort)))
        .expect("submit abort")
        .await
        .expect("writer alive")
        .expect("on wire");
    let abort_json = provider.next_json().await;
    assert_eq!(abort_json["type"], "abort");
    let aborted = FrameV2::Aborted(AbortedFrame { scope: leased });
    provider
        .send_json(&serde_json::from_slice(&aborted.encode().expect("encode")).expect("value"))
        .await;
    match recv_event(&mut events).await {
        AttemptEvent::Aborted { reason } => assert_eq!(reason, AbortReason::HedgeLoss),
        other => panic!("expected Aborted, got {other:?}"),
    }

    // A LATE started for the aborted attempt is inert (tombstone). The
    // provider then sends cancelled as an ordering fence: the next event
    // must be Cancelled, never Started.
    let late_started = FrameV2::Started(StartedFrame { scope: leased });
    provider
        .send_json(&serde_json::from_slice(&late_started.encode().expect("encode")).expect("value"))
        .await;
    let fence = FrameV2::Cancelled(CancelledFrame { scope: leased });
    provider
        .send_json(&serde_json::from_slice(&fence.encode().expect("encode")).expect("value"))
        .await;
    match recv_event(&mut events).await {
        AttemptEvent::Cancelled => {}
        other => panic!("late started leaked through the tombstone: {other:?}"),
    }

    harness.runtime.shutdown().await;
}

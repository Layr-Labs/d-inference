use super::*;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use darkbloom_coordinator_core::{
    deadline::{AbsoluteDeadline, EpochMillis},
    ids::{
        FundingId, ModelId, PermitId, ProviderId as CoreProviderId, RequestId as CoreRequestId,
        SessionId, SessionRevision, TrustRevision,
    },
    money::MicroUsd,
    request::{AttemptKind, ProviderFence, RequestContext},
};
use darkbloom_coordinator_protocol::v2::{
    AttemptIdentity, Digest as WireDigest, Prepare, Prepared, StartAck,
};
use darkbloom_coordinator_server::{
    provider::DeliveryState,
    request::{
        AttemptPhase, CommitmentLimits, OutputLimits, OutputMode, RequestExecutionError,
        RequestTask, RequestTaskConfig,
    },
};

#[test]
fn request_prepare_faults_preserve_pre_authorization_state() {
    let _serial = FAULT_TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);

    let (mut sent_task, _sent_body) = request_task();
    let sent_prepare = prepare(1);
    let sent_identity = sent_prepare.identity.clone();
    let (_sent_driver, sent_writer) =
        provider_writer(ProviderWriterConfig::default(), CancellationToken::new())
            .expect("prepare sent writer");
    let context = request_context();
    let (sent_attempt, _receipt) = sent_task
        .enqueue_prepare(
            AttemptKind::Primary,
            sent_prepare,
            provider_fence(1),
            core_id(31, PermitId::new),
            &context,
            &sent_writer,
        )
        .expect("queue prepare for sent fault");
    let sent_fault =
        arm(FaultPoint::PrepareSent, FaultAction::Fail).expect("arm prepare sent fault");
    assert!(matches!(
        sent_task.observe_prepare_delivery(sent_attempt, DeliveryState::OnWire, &context),
        Err(RequestExecutionError::OutboundFailed(_))
    ));
    assert_eq!(
        sent_task.attempt_phase(sent_attempt),
        Some(AttemptPhase::PrepareOnWire),
        "wire ambiguity was collapsed into a safe alternate"
    );
    record_receipt(
        "prepare_sent_preserves_pre_authorization_state",
        &[&sent_fault],
        &["preauthorization_failover_only"],
    );
    drop(sent_fault);

    let (mut received_task, _received_body) = request_task();
    let received_prepare = Prepare {
        identity: sent_identity,
        ..prepare(2)
    };
    let (_received_driver, received_writer) =
        provider_writer(ProviderWriterConfig::default(), CancellationToken::new())
            .expect("prepare received writer");
    let (received_attempt, _receipt) = received_task
        .enqueue_prepare(
            AttemptKind::Primary,
            received_prepare.clone(),
            provider_fence(1),
            core_id(32, PermitId::new),
            &context,
            &received_writer,
        )
        .expect("queue prepare for received fault");
    let received_fault =
        arm(FaultPoint::PrepareReceived, FaultAction::Fail).expect("arm prepare received fault");
    assert!(matches!(
        received_task.accept_prepared(prepared(&received_prepare)),
        Err(RequestExecutionError::InvalidPrepared(_))
    ));
    assert_eq!(
        received_task.attempt_phase(received_attempt),
        Some(AttemptPhase::Prepared),
        "validated provider authorization facts were discarded"
    );
    record_receipt(
        "prepare_received_preserves_pre_authorization_state",
        &[&received_fault],
        &["preauthorization_failover_only"],
    );
}

#[test]
fn first_chunk_fault_commits_once_and_never_reopens_failover() {
    let _serial = FAULT_TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let (mut task, body) = request_task();
    let prepare = prepare(1);
    let context = request_context();
    let (_driver, writer) =
        provider_writer(ProviderWriterConfig::default(), CancellationToken::new())
            .expect("first chunk writer");
    let (attempt_id, _receipt) = task
        .enqueue_prepare(
            AttemptKind::Primary,
            prepare.clone(),
            provider_fence(1),
            core_id(33, PermitId::new),
            &context,
            &writer,
        )
        .expect("queue prepare");
    task.accept_prepared(prepared(&prepare))
        .expect("accept prepared");
    let _staged = task
        .enqueue_start(attempt_id, &context)
        .expect("authorize start");
    task.accept_start_ack(&StartAck {
        identity: prepare.identity.clone(),
    })
    .expect("accept start");

    let content = b"data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}\n\n";
    let digest = darkbloom_coordinator_server::request::next_rolling_digest([0; 32], 0, 1, content);
    let frame = output_header(&prepare.identity, digest, content.len());
    let fault = arm(FaultPoint::FirstChunk, FaultAction::Fail).expect("arm first chunk");
    assert!(matches!(
        task.accept_chunk(&frame, content.to_vec(), &context),
        Err(RequestExecutionError::OutboundFailed(_))
    ));
    assert!(task.is_committed(), "authenticated content did not commit");
    assert_eq!(
        task.attempt_phase(attempt_id),
        Some(AttemptPhase::StartAcknowledged)
    );
    assert_eq!(
        body.stats().queued_items,
        0,
        "faulted first chunk became consumer-visible"
    );
    record_receipt(
        "first_chunk_commits_once_without_failover",
        &[&fault],
        &["no_failover_after_auth", "exactly_one_disposition"],
    );
    drop(fault);
}

fn request_task() -> (
    RequestTask,
    darkbloom_coordinator_server::request::BytePipeReceiver<Vec<u8>>,
) {
    RequestTask::new(
        RequestTaskConfig {
            request_id: core_id(4, CoreRequestId::new),
            wire_request_id: WireRequestId::new([4; 16]),
            deadline: AbsoluteDeadline::new(10_000).expect("deadline"),
            funding_id: core_id(9, FundingId::new),
            funding_amount: MicroUsd::new(100),
            model: ModelId::new("model").expect("model"),
            request_digest: request_digest(),
            maximum_prompt_tokens: 32,
            output_mode: OutputMode::Streaming,
            output_limits: OutputLimits {
                maximum_chunk_bytes: 1024,
                maximum_output_bytes: 4096,
                maximum_chunks: 32,
                maximum_output_tokens: 8,
            },
            commitment_limits: CommitmentLimits {
                maximum_items: 8,
                maximum_bytes: 2048,
            },
            pipe_limits: BytePipeLimits {
                maximum_items: 8,
                maximum_bytes: 4096,
            },
        },
        EpochMillis::new(1),
        RequestCancellation::token_only(CancellationToken::new()),
        None,
    )
    .expect("request task")
}

fn prepare(byte: u8) -> Prepare {
    let encrypted_body = darkbloom_coordinator_protocol::v1::EncryptedPayload {
        ephemeral_public_key: STANDARD.encode([1; 32]),
        ciphertext: STANDARD.encode([2; 32]),
    };
    Prepare {
        identity: AttemptIdentity {
            provider_id: ProviderId::new([byte; 16]),
            provider_process_generation: ProviderProcessGenerationId::new(
                [byte.saturating_add(10); 16],
            ),
            session_epoch: SessionEpoch(1),
            request_id: WireRequestId::new([4; 16]),
            attempt_id: AttemptId::new([byte.saturating_add(20); 16]),
            reservation_id: WireReservationId::new([byte.saturating_add(30); 16]),
            lease_id: LeaseId::new([byte.saturating_add(40); 16]),
        },
        model: "model".into(),
        request_digest: request_digest(),
        encrypted_body,
    }
}

fn prepared(prepare: &Prepare) -> Prepared {
    Prepared {
        identity: prepare.identity.clone(),
        model: prepare.model.clone(),
        request_digest: prepare.request_digest,
        lease_ttl_ms: 1_000,
        prompt_tokens: 2,
        max_output_tokens: 8,
        engine_queue_depth: 0,
        reserved_kv_bytes: 1,
        reserved_media_bytes: 0,
        prefill_can_begin: true,
        estimated_prefill_ms: Some(1),
    }
}

fn request_digest() -> WireDigest {
    let encrypted_body = darkbloom_coordinator_protocol::v1::EncryptedPayload {
        ephemeral_public_key: STANDARD.encode([1; 32]),
        ciphertext: STANDARD.encode([2; 32]),
    };
    Prepare::encrypted_payload_digest(&encrypted_body).expect("request digest")
}

fn request_context() -> RequestContext {
    RequestContext::new(EpochMillis::new(2)).with_provider(provider_fence(1))
}

fn provider_fence(byte: u8) -> ProviderFence {
    ProviderFence {
        provider_id: core_id(byte, CoreProviderId::new),
        session_id: core_id(byte.saturating_add(20), SessionId::new),
        session_revision: SessionRevision::new(1).expect("session revision"),
        trust_revision: TrustRevision::new(1).expect("trust revision"),
        model_id: ModelId::new("model").expect("model"),
        model_revision: darkbloom_coordinator_core::ids::ModelRevision::new(1)
            .expect("model revision"),
    }
}

fn core_id<T, E: std::fmt::Debug>(byte: u8, create: impl FnOnce(Uuid) -> Result<T, E>) -> T {
    create(Uuid::from_bytes([byte; 16])).expect("core identifier")
}

fn output_header(
    identity: &AttemptIdentity,
    rolling_digest: [u8; 32],
    plaintext_len: usize,
) -> BinaryFrameHeader {
    BinaryFrameHeader {
        kind: BinaryFrameKind::ResponseChunk,
        flags: BinaryFrameFlags::EMPTY,
        minor: 1,
        provider_id: identity.provider_id,
        provider_process_generation: identity.provider_process_generation,
        session_epoch: identity.session_epoch,
        request_id: identity.request_id,
        attempt_id: identity.attempt_id,
        reservation_id: identity.reservation_id,
        lease_id: identity.lease_id,
        nonce: [0; 24],
        rolling_digest,
        sequence: 0,
        ciphertext_len: u32::try_from(plaintext_len).expect("chunk length"),
        cumulative_tokens: 1,
    }
}

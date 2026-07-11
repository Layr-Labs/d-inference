use darkbloom_coordinator_protocol::{
    TerminalError,
    v1::{EncryptedPayload, Heartbeat, ProviderMessage as V1ProviderMessage},
    v2::{
        Abort, AttemptId, AttemptIdentity, AttemptStatus, AttemptStatusState, Cancel,
        CoordinatorControlMessage, CoordinatorReplayFenceProof, Digest, LeaseId, ModelGone,
        ModelReady, Prepare, Prepared, ProtocolCapabilities, ProviderControlMessage, ProviderId,
        ProviderProcessGenerationId, ProviderSessionIdentity, ProviderSessionTracker,
        ProviderTerminal, QueryAttempt, RegisterAcknowledgement, RegistrationResponse,
        ReplayFenceAck, ReplayFenceProofId, RequestId, ReservationId, SessionEpoch, Start,
        StartAck, TerminalOutcome, TerminalSignature,
    },
};

fn identity() -> AttemptIdentity {
    AttemptIdentity {
        provider_id: ProviderId::new([0x11; 16]),
        provider_process_generation: ProviderProcessGenerationId::new([0x22; 16]),
        session_epoch: SessionEpoch(7),
        request_id: RequestId::new([0x33; 16]),
        attempt_id: AttemptId::new([0x44; 16]),
        reservation_id: ReservationId::new([0x55; 16]),
        lease_id: LeaseId::new([0x66; 16]),
    }
}

fn terminal() -> ProviderTerminal {
    let mut terminal = ProviderTerminal {
        identity: identity(),
        outcome: TerminalOutcome::Completed,
        error_class: None,
        prompt_tokens: 10,
        completion_tokens: 5,
        reasoning_tokens: 0,
        response_hash: Digest::new([0x77; 32]),
        final_generated_tokens: 5,
        rolling_digest: Digest::new([0x88; 32]),
        model: "model-a".into(),
        terminal_digest: Digest::default(),
        signature: TerminalSignature::new(vec![0x30, 0x01, 0x02]),
    };
    terminal.terminal_digest = terminal.computed_digest().expect("canonical digest");
    terminal
}

#[test]
fn canonical_terminal_bytes_have_pinned_field_order() {
    let terminal = terminal();
    assert_eq!(
        terminal.canonical_bytes().expect("canonical terminal"),
        br#"{"attempt_id":"44444444-4444-4444-4444-444444444444","completion_tokens":5,"final_generated_tokens":5,"lease_id":"66666666-6666-6666-6666-666666666666","model":"model-a","outcome":"completed","prompt_tokens":10,"provider_id":"11111111-1111-1111-1111-111111111111","provider_process_generation":"22222222-2222-2222-2222-222222222222","request_id":"33333333-3333-3333-3333-333333333333","reservation_id":"55555555-5555-5555-5555-555555555555","response_hash":"d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3c=","rolling_digest":"iIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIg=","session_epoch":7}"#
    );
}

#[test]
fn terminal_validates_digest_and_provider_process_signature_identity() {
    let terminal = terminal();
    terminal
        .validate_with(&identity(), |provider, generation, digest, signature| {
            provider == ProviderId::new([0x11; 16])
                && generation == ProviderProcessGenerationId::new([0x22; 16])
                && digest == &terminal.terminal_digest
                && signature == [0x30, 0x01, 0x02]
        })
        .expect("valid terminal");

    let mut wrong_identity = identity();
    wrong_identity.session_epoch = SessionEpoch(8);
    assert_eq!(
        terminal.validate_with(&wrong_identity, |_, _, _, _| true),
        Err(TerminalError::IdentityMismatch)
    );

    let mut tampered = terminal.clone();
    tampered.completion_tokens += 1;
    assert_eq!(
        tampered.validate_with(&identity(), |_, _, _, _| true),
        Err(TerminalError::DigestMismatch)
    );
    assert_eq!(
        terminal.validate_with(&identity(), |_, _, _, _| false),
        Err(TerminalError::SignatureIdentityMismatch)
    );
}

#[test]
fn v2_control_discriminators_and_unknown_fields_are_stable() {
    let digest = Digest::new([9; 32]);
    let encrypted_body = EncryptedPayload {
        ephemeral_public_key: base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            [0xAB; 32],
        ),
        ciphertext: base64::Engine::encode(&base64::engine::general_purpose::STANDARD, [0xCD; 40]),
    };
    let messages = [
        (
            serde_json::to_value(CoordinatorControlMessage::Prepare(Prepare {
                identity: identity(),
                model: "model-a".into(),
                request_digest: digest,
                encrypted_body,
            }))
            .expect("prepare"),
            "prepare",
        ),
        (
            serde_json::to_value(CoordinatorControlMessage::Start(Start {
                identity: identity(),
            }))
            .expect("start"),
            "start",
        ),
        (
            serde_json::to_value(CoordinatorControlMessage::QueryAttempt(QueryAttempt {
                identity: identity(),
            }))
            .expect("query attempt"),
            "query_attempt",
        ),
        (
            serde_json::to_value(CoordinatorControlMessage::Abort(Abort {
                identity: identity(),
                reason: None,
            }))
            .expect("abort"),
            "abort",
        ),
        (
            serde_json::to_value(CoordinatorControlMessage::Cancel(Cancel {
                identity: identity(),
                reason: Some("consumer_gone".into()),
            }))
            .expect("cancel"),
            "cancel",
        ),
    ];
    for (message, expected) in messages {
        assert_eq!(message["type"], expected);
    }

    let mut prepared = serde_json::to_value(ProviderControlMessage::Prepared(Prepared {
        identity: identity(),
        model: "model-a".into(),
        request_digest: digest,
        lease_ttl_ms: 15_000,
        prompt_tokens: 42,
        max_output_tokens: 128,
        engine_queue_depth: 0,
        reserved_kv_bytes: 4096,
        reserved_media_bytes: 0,
        prefill_can_begin: true,
        estimated_prefill_ms: None,
    }))
    .expect("prepared");
    prepared
        .as_object_mut()
        .expect("object")
        .insert("future".into(), true.into());
    let decoded: ProviderControlMessage =
        serde_json::from_value(prepared).expect("unknown field compatible");
    assert!(matches!(decoded, ProviderControlMessage::Prepared(_)));

    let start_ack = ProviderControlMessage::StartAck(StartAck {
        identity: identity(),
    });
    assert_eq!(
        serde_json::to_value(start_ack).expect("start ACK")["type"],
        "start_ack"
    );
    let status = ProviderControlMessage::AttemptStatus(AttemptStatus {
        identity: identity(),
        state: AttemptStatusState::Terminal,
        terminal_digest: Some(digest),
    });
    let status = serde_json::to_value(status).expect("attempt status");
    assert_eq!(status["type"], "attempt_status");
    assert_eq!(status["state"], "terminal");
    assert!(serde_json::from_value::<ProviderControlMessage>(status).is_ok());

    let replay_ack = ProviderControlMessage::ReplayFenceAck(ReplayFenceAck {
        proof_id: ReplayFenceProofId::new([0x99; 16]),
        provider_id: identity().provider_id,
        provider_process_generation: ProviderProcessGenerationId::new([0x77; 16]),
    });
    let replay_ack = serde_json::to_value(replay_ack).expect("replay fence ACK");
    assert_eq!(replay_ack["type"], "replay_fence_ack");
    assert_eq!(
        replay_ack["provider_process_generation"],
        ProviderProcessGenerationId::new([0x77; 16]).to_string()
    );
}

#[test]
fn coordinator_replay_fence_has_stable_signed_wire_digest() {
    let mut proof = CoordinatorReplayFenceProof {
        proof_id: ReplayFenceProofId::new([0x99; 16]),
        provider_id: identity().provider_id,
        provider_process_generation: identity().provider_process_generation,
        through_session_epoch: SessionEpoch(7),
        coordinator_revision: 42,
        proof_digest: Digest::default(),
        coordinator_signature: TerminalSignature::new(vec![0x30, 0x01, 0x02]),
    };
    proof.proof_digest = proof.computed_digest();
    assert!(proof.digest_is_valid());
    assert_eq!(
        base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            proof.proof_digest.as_bytes()
        ),
        "cvIixyrwtQ8/CkkhmH2F0NKOAYG3ULxOxjuZ0wC6eSs="
    );

    let message = CoordinatorControlMessage::CoordinatorReplayFence(proof.clone());
    let wire = serde_json::to_value(&message).expect("replay fence wire");
    assert_eq!(wire["type"], "coordinator_replay_fence");
    assert_eq!(wire["through_session_epoch"], 7);
    assert_eq!(wire["coordinator_revision"], 42);
    assert_eq!(
        serde_json::from_value::<CoordinatorControlMessage>(wire).expect("replay fence decode"),
        message
    );

    proof.coordinator_revision += 1;
    assert!(!proof.digest_is_valid());
}

#[test]
fn prepare_requires_an_encrypted_payload_object_and_binds_its_complete_envelope() {
    use base64::{Engine, engine::general_purpose::STANDARD};

    let payload = EncryptedPayload {
        ephemeral_public_key: STANDARD.encode([0x11; 32]),
        ciphertext: STANDARD.encode([0x22; 40]),
    };
    let digest = Prepare::encrypted_payload_digest(&payload).expect("valid encrypted payload");
    let mut payload_with_other_key = payload.clone();
    payload_with_other_key.ephemeral_public_key = STANDARD.encode([0x33; 32]);
    assert_ne!(
        digest,
        Prepare::encrypted_payload_digest(&payload_with_other_key)
            .expect("other valid encrypted payload")
    );

    let mut wire = serde_json::to_value(CoordinatorControlMessage::Prepare(Prepare {
        identity: identity(),
        model: "model-a".into(),
        request_digest: digest,
        encrypted_body: payload,
    }))
    .expect("prepare wire");
    assert!(wire.get("body").is_none());

    wire.as_object_mut()
        .expect("prepare object")
        .insert("body".into(), serde_json::json!({"model": "plaintext"}));
    wire.as_object_mut()
        .expect("prepare object")
        .remove("encrypted_body");
    assert!(
        serde_json::from_value::<CoordinatorControlMessage>(wire).is_err(),
        "plaintext body cannot substitute for encrypted_body"
    );
}

#[test]
fn capability_negotiation_requires_the_complete_v2_contract() {
    let provider = ProtocolCapabilities {
        protocol_major: 2,
        protocol_minor: 3,
        minimum_compatible_minor: 1,
        prepared_leases: true,
        start_authorization: true,
        structured_errors: true,
        start_ack: true,
        abort_ack: true,
        cancel_ack: true,
        durable_terminals: true,
        model_lifecycle_events: true,
        binary_payload_frames: true,
        coordinator_replay_fences: true,
        attempt_reconciliation: true,
    };
    let coordinator = ProtocolCapabilities {
        protocol_major: 2,
        protocol_minor: 1,
        prepared_leases: true,
        start_authorization: true,
        structured_errors: true,
        start_ack: true,
        abort_ack: true,
        cancel_ack: true,
        durable_terminals: true,
        model_lifecycle_events: true,
        binary_payload_frames: false,
        coordinator_replay_fences: true,
        ..Default::default()
    };
    let negotiated = coordinator.negotiate(&provider).expect("same major");
    assert_eq!(negotiated.protocol_minor, 1);
    assert_eq!(negotiated.minimum_compatible_minor, 1);
    assert!(!negotiated.binary_payload_frames);
    assert!(!negotiated.supports_v2());
}

#[test]
fn register_ack_echoes_generation_and_allocates_stable_monotonic_sessions() {
    let provider_id = ProviderId::new([0x11; 16]);
    let generation = ProviderProcessGenerationId::new([0x22; 16]);
    let mut tracker = ProviderSessionTracker::new(provider_id);
    let capabilities = ProtocolCapabilities {
        protocol_major: 2,
        prepared_leases: true,
        start_authorization: true,
        structured_errors: true,
        start_ack: true,
        abort_ack: true,
        cancel_ack: true,
        durable_terminals: true,
        model_lifecycle_events: true,
        binary_payload_frames: true,
        coordinator_replay_fences: true,
        attempt_reconciliation: true,
        ..Default::default()
    };
    let replay_key = {
        let mut raw = [0x22; 65];
        raw[0] = 0x04;
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, raw)
    };
    let mut missing_key_tracker = ProviderSessionTracker::new(provider_id);
    assert!(
        missing_key_tracker
            .acknowledge(generation, &capabilities, &capabilities, None)
            .is_err()
    );
    assert_eq!(missing_key_tracker.last_session_epoch(), None);

    let first = tracker
        .acknowledge(generation, &capabilities, &capabilities, Some(&replay_key))
        .expect("first session");
    let second = tracker
        .acknowledge(generation, &capabilities, &capabilities, Some(&replay_key))
        .expect("second session");
    assert_eq!(first.provider_id, provider_id);
    assert_eq!(second.provider_id, provider_id);
    assert_eq!(first.provider_process_generation, generation);
    assert_eq!(first.session_epoch, SessionEpoch(1));
    assert_eq!(second.session_epoch, SessionEpoch(2));
    assert!(first.protocol_capabilities.is_some());

    let wire = serde_json::to_value(RegistrationResponse::RegisterAck(first.clone()))
        .expect("register ACK JSON");
    assert_eq!(wire["type"], "register_ack");
    assert_eq!(wire["provider_process_generation"], generation.to_string());
    assert_eq!(wire["coordinator_replay_fence_public_key"], replay_key);
    let decoded: RegistrationResponse = serde_json::from_value(wire).expect("decode register ACK");
    assert_eq!(
        decoded,
        RegistrationResponse::RegisterAck(RegisterAcknowledgement {
            provider_id,
            provider_process_generation: generation,
            session_epoch: SessionEpoch(1),
            protocol_capabilities: first.protocol_capabilities,
            coordinator_replay_fence_public_key: Some(replay_key.clone()),
        })
    );

    let mut resumed = ProviderSessionTracker::resume(provider_id, SessionEpoch(41));
    let after_restart = resumed
        .acknowledge(generation, &capabilities, &capabilities, Some(&replay_key))
        .expect("durably resumed session");
    assert_eq!(after_restart.session_epoch, SessionEpoch(42));
}

#[test]
fn register_ack_selects_v1_when_the_explicit_capability_ranges_do_not_overlap() {
    let mut tracker = ProviderSessionTracker::new(ProviderId::new([0x11; 16]));
    let provider = ProtocolCapabilities {
        protocol_major: 2,
        protocol_minor: 1,
        minimum_compatible_minor: 1,
        prepared_leases: true,
        start_authorization: true,
        durable_terminals: true,
        ..Default::default()
    };
    let coordinator = ProtocolCapabilities {
        protocol_major: 2,
        protocol_minor: 4,
        minimum_compatible_minor: 3,
        prepared_leases: true,
        start_authorization: true,
        durable_terminals: true,
        ..Default::default()
    };
    let acknowledgement = tracker
        .acknowledge(
            ProviderProcessGenerationId::new([0x22; 16]),
            &provider,
            &coordinator,
            None,
        )
        .expect("session allocation still succeeds");
    assert_eq!(acknowledgement.protocol_capabilities, None);
    assert_eq!(acknowledgement.coordinator_replay_fence_public_key, None);
}

#[test]
fn model_lifecycle_events_carry_provider_process_session_fence() {
    let identity = ProviderSessionIdentity {
        provider_id: ProviderId::new([1; 16]),
        process_generation: ProviderProcessGenerationId::new([2; 16]),
        session_epoch: SessionEpoch(9),
    };
    for message in [
        ProviderControlMessage::ModelReady(ModelReady {
            identity: identity.clone(),
            model: "model-a".into(),
            state_revision: 4,
            weight_hash: Some("hash".into()),
        }),
        ProviderControlMessage::ModelGone(ModelGone {
            identity: identity.clone(),
            model: "model-a".into(),
            state_revision: 5,
            reason: Some("evicted".into()),
        }),
    ] {
        let wire = serde_json::to_value(message).expect("model lifecycle event");
        assert_eq!(wire["provider_id"], identity.provider_id.to_string());
        assert_eq!(
            wire["process_generation"],
            identity.process_generation.to_string()
        );
        assert_eq!(wire["session_epoch"], 9);
    }
}

#[test]
fn heartbeat_model_revision_correlates_with_lifecycle_events_and_remains_optional() {
    let heartbeat: Heartbeat = serde_json::from_value(serde_json::json!({
        "status": "ready",
        "stats": {
            "requests_served": 0,
            "tokens_generated": 0
        },
        "system_metrics": {
            "memory_pressure": 0,
            "cpu_usage": 0,
            "thermal_state": "nominal"
        },
        "model_state_revision": 41
    }))
    .expect("heartbeat shape");
    let heartbeat_wire =
        serde_json::to_value(V1ProviderMessage::Heartbeat(heartbeat)).expect("heartbeat wire");
    assert_eq!(heartbeat_wire["type"], "heartbeat");
    assert_eq!(heartbeat_wire["model_state_revision"], 41);

    let lifecycle = serde_json::to_value(ProviderControlMessage::ModelReady(ModelReady {
        identity: ProviderSessionIdentity {
            provider_id: ProviderId::new([1; 16]),
            process_generation: ProviderProcessGenerationId::new([2; 16]),
            session_epoch: SessionEpoch(9),
        },
        model: "model-a".into(),
        state_revision: 41,
        weight_hash: None,
    }))
    .expect("lifecycle wire");
    assert_eq!(
        heartbeat_wire["model_state_revision"],
        lifecycle["state_revision"]
    );

    let mut without_revision = heartbeat_wire;
    without_revision
        .as_object_mut()
        .expect("heartbeat object")
        .remove("model_state_revision");
    let decoded: V1ProviderMessage =
        serde_json::from_value(without_revision).expect("legacy heartbeat");
    let legacy_wire = serde_json::to_value(decoded).expect("legacy heartbeat wire");
    assert!(legacy_wire.get("model_state_revision").is_none());
}

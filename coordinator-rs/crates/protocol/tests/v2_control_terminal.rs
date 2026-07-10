use darkbloom_coordinator_protocol::{
    TerminalError,
    v2::{
        Abort, AttemptId, AttemptIdentity, Cancel, CoordinatorControlMessage, Digest, LeaseId,
        ModelGone, ModelReady, Prepare, Prepared, ProtocolCapabilities, ProviderControlMessage,
        ProviderId, ProviderProcessGenerationId, ProviderSessionIdentity, ProviderTerminal,
        RequestId, ReservationId, SessionEpoch, Start, StartAck, TerminalOutcome,
        TerminalSignature,
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
    let messages = [
        (
            serde_json::to_value(CoordinatorControlMessage::Prepare(Prepare {
                identity: identity(),
                model: "model-a".into(),
                request_digest: digest,
                body: None,
                encrypted_body: None,
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
        lease_ttl_ms: 15_000,
        prompt_tokens: 42,
        max_output_tokens: 128,
        engine_queue_depth: 0,
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
}

#[test]
fn capability_negotiation_requires_the_complete_v2_contract() {
    let provider = ProtocolCapabilities {
        protocol_major: 2,
        protocol_minor: 3,
        minimum_compatible_minor: 1,
        prepared_leases: true,
        start_authorization: true,
        durable_terminals: true,
        binary_payload_frames: true,
        ..Default::default()
    };
    let coordinator = ProtocolCapabilities {
        protocol_major: 2,
        protocol_minor: 1,
        prepared_leases: true,
        start_authorization: true,
        durable_terminals: true,
        binary_payload_frames: false,
        ..Default::default()
    };
    let negotiated = coordinator.negotiate(&provider).expect("same major");
    assert_eq!(negotiated.protocol_minor, 1);
    assert_eq!(negotiated.minimum_compatible_minor, 1);
    assert!(!negotiated.binary_payload_frames);
    assert!(negotiated.supports_v2());
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

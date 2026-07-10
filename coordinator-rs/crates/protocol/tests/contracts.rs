use std::{fs, path::PathBuf};

use base64::{Engine, engine::general_purpose::STANDARD};
use darkbloom_coordinator_protocol::{
    ProtocolError,
    crypto::{BoxPayload, open_box, seal_box_with},
    raw_json::registration_attestation,
    v1::{
        AttestationStatus, CoordinatorMessage, OptionalNullable, ProviderMessage,
        parse_coordinator_message, parse_provider_message,
    },
};
use serde::Deserialize;

const PROVIDER_CASE_NAMES: [&str; 17] = [
    "register_minimal",
    "register_full_raw_attestation",
    "heartbeat_no_active_model",
    "heartbeat_full",
    "inference_accepted",
    "inference_response_chunk_plain",
    "inference_response_chunk_encrypted",
    "inference_complete",
    "inference_error",
    "attestation_response_current",
    "attestation_response_legacy_hypervisor_false",
    "code_attestation_response",
    "load_model_status_started",
    "load_model_status_failed",
    "prefetch_model_status_downloading",
    "prefetch_model_status_verified",
    "models_update",
];

const COORDINATOR_CASE_NAMES: [&str; 11] = [
    "inference_request_plain",
    "inference_request_encrypted",
    "cancel",
    "attestation_challenge",
    "runtime_status_verified",
    "runtime_status_mismatch",
    "load_model",
    "prefetch_model_default_priority",
    "prefetch_model_priority",
    "desired_models",
    "trust_status",
];

#[derive(Debug, Deserialize)]
struct WireContract {
    schema_version: u32,
    direction: String,
    cases: Vec<WireCase>,
}

#[derive(Debug, Deserialize)]
struct WireCase {
    name: String,
    message_type: String,
    wire: String,
    exact_bytes: bool,
}

#[derive(Debug, Deserialize)]
struct CryptoContract {
    schema_version: u32,
    plaintext_base64: String,
    sender_private_key_base64: String,
    sender_public_key_base64: String,
    recipient_private_key_base64: String,
    recipient_public_key_base64: String,
    nonce_base64: String,
    payload: EncryptedPayload,
    tampered_payload: EncryptedPayload,
    status_canonical: StatusCanonical,
}

#[derive(Debug, Deserialize)]
struct StatusCanonical {
    current_base64: String,
    legacy_hypervisor_false_base64: String,
    explicit_security_false_base64: String,
}

#[derive(Debug, Deserialize)]
struct EncryptedPayload {
    ephemeral_public_key: String,
    ciphertext: String,
}

#[test]
fn protocol_v1_contracts_have_exact_typed_semantic_round_trip() {
    let provider: WireContract = read_contract("protocol/v1/provider_to_coordinator.json");
    assert_eq!(provider.schema_version, 1);
    assert_eq!(provider.direction, "provider_to_coordinator");
    assert_case_names(&provider.cases, &PROVIDER_CASE_NAMES);
    for contract in &provider.cases {
        let original: serde_json::Value =
            serde_json::from_str(&contract.wire).expect("valid provider fixture JSON");
        let parsed = parse_provider_message(contract.wire.as_bytes())
            .unwrap_or_else(|error| panic!("{} failed typed decode: {error}", contract.name));
        assert_eq!(parsed.message.message_type(), contract.message_type);
        assert_provider_variant(&parsed.message, &contract.message_type);
        let encoded = serde_json::to_value(&parsed.message).expect("encode typed provider message");
        assert_eq!(
            encoded, original,
            "{} lost or normalized a fixture field without an explicit contract exception",
            contract.name
        );
        if contract.name == "register_full_raw_attestation" {
            let ProviderMessage::Register(registration) = &parsed.message else {
                panic!("register variant");
            };
            assert_eq!(registration.models[0].template_render_ok, Some(false));
            let encoded = serde_json::to_value(&parsed.message).expect("encode registration");
            assert_eq!(encoded["models"][0]["template_render_ok"], false);
        }
        if contract.exact_bytes {
            let expected = br#"{"signature":"sig","attestation":{"z":1,"a":[true,false]}}"#;
            assert_eq!(parsed.signed_registration.attestation, Some(&expected[..]));
            assert_eq!(
                parsed.signed_registration.status,
                Some(&br#"{"z":1,"a":[true,false]}"#[..])
            );
            assert_eq!(
                registration_attestation(&contract.wire).expect("valid registration JSON"),
                Some(std::str::from_utf8(expected).expect("ASCII"))
            );
        }
    }

    let coordinator: WireContract = read_contract("protocol/v1/coordinator_to_provider.json");
    assert_eq!(coordinator.schema_version, 1);
    assert_eq!(coordinator.direction, "coordinator_to_provider");
    assert_case_names(&coordinator.cases, &COORDINATOR_CASE_NAMES);
    for contract in &coordinator.cases {
        let original: serde_json::Value =
            serde_json::from_str(&contract.wire).expect("valid coordinator fixture JSON");
        let parsed = parse_coordinator_message(contract.wire.as_bytes())
            .unwrap_or_else(|error| panic!("{} failed typed decode: {error}", contract.name));
        assert_eq!(parsed.message_type(), contract.message_type);
        assert_coordinator_variant(&parsed, &contract.message_type);
        let encoded = serde_json::to_value(&parsed).expect("encode typed coordinator message");
        assert_eq!(
            encoded, original,
            "{} lost or normalized a fixture field without an explicit contract exception",
            contract.name
        );
        if contract.name == "inference_request_encrypted" {
            let CoordinatorMessage::InferenceRequest(request) = &parsed else {
                panic!("inference request variant");
            };
            let OptionalNullable::Value(body) = &request.body else {
                panic!("body object");
            };
            assert!(body.messages.is_null());
            let encoded = serde_json::to_value(&parsed).expect("encode encrypted request");
            assert!(encoded["body"]["messages"].is_null());
        }
    }
}

fn assert_case_names(cases: &[WireCase], expected: &[&str]) {
    let actual: Vec<_> = cases.iter().map(|case| case.name.as_str()).collect();
    assert_eq!(actual.len(), expected.len(), "fixture case count changed");
    assert_eq!(actual, expected, "fixture case names/order changed");
}

#[test]
fn rust_decrypts_go_nacl_box_contract_and_rejects_tamper() {
    let fixture: CryptoContract = read_contract("crypto/nacl_box.json");
    assert_eq!(fixture.schema_version, 1);
    let expected = STANDARD
        .decode(fixture.plaintext_base64)
        .expect("valid plaintext base64");
    let recipient_private_key = decode_array::<32>(&fixture.recipient_private_key_base64);
    let recipient_public_key = decode_array::<32>(&fixture.recipient_public_key_base64);
    let sender_private_key = decode_array::<32>(&fixture.sender_private_key_base64);
    let sender_public_key = decode_array::<32>(&fixture.sender_public_key_base64);
    let nonce = decode_array::<24>(&fixture.nonce_base64);

    let payload = BoxPayload {
        ephemeral_public_key: fixture.payload.ephemeral_public_key.clone(),
        ciphertext: fixture.payload.ciphertext.clone(),
    };
    let plaintext =
        open_box(&recipient_private_key, &payload).expect("Rust decrypts the Go contract vector");
    assert_eq!(plaintext, expected);
    assert!(
        open_box(
            &recipient_private_key,
            &BoxPayload {
                ephemeral_public_key: fixture.tampered_payload.ephemeral_public_key,
                ciphertext: fixture.tampered_payload.ciphertext,
            },
        )
        .is_err(),
        "tampered contract vector must fail authentication"
    );
    let sealed = seal_box_with(
        &sender_private_key,
        &recipient_public_key,
        &nonce,
        &expected,
    )
    .expect("seal Go-compatible vector");
    assert_eq!(
        sealed.ephemeral_public_key,
        STANDARD.encode(sender_public_key)
    );
    assert_eq!(sealed.ciphertext, fixture.payload.ciphertext);
}

#[test]
fn status_canonical_bytes_match_all_go_vectors() {
    let fixture: CryptoContract = read_contract("crypto/nacl_box.json");
    assert_eq!(
        full_status(None)
            .canonical_bytes()
            .expect("canonical current status"),
        STANDARD
            .decode(fixture.status_canonical.current_base64)
            .expect("current canonical base64")
    );
    assert_eq!(
        full_status(Some(false))
            .canonical_bytes()
            .expect("canonical legacy status"),
        STANDARD
            .decode(fixture.status_canonical.legacy_hypervisor_false_base64)
            .expect("legacy canonical base64")
    );
    assert_eq!(
        AttestationStatus {
            nonce: "n".into(),
            timestamp: "t".into(),
            sip_enabled: Some(false),
            ..Default::default()
        }
        .canonical_bytes()
        .expect("canonical explicit false"),
        STANDARD
            .decode(fixture.status_canonical.explicit_security_false_base64)
            .expect("false canonical base64")
    );
}

#[test]
fn omission_null_and_false_remain_distinct() {
    let omitted = parse_provider_message(
        br#"{"type":"heartbeat","status":"idle","stats":{"requests_served":0,"tokens_generated":0},"system_metrics":{"memory_pressure":0,"cpu_usage":0,"thermal_state":"nominal"}}"#,
    )
    .expect("omitted active_model and unknown field");
    let ProviderMessage::Heartbeat(mut heartbeat) = omitted.message else {
        panic!("heartbeat variant");
    };
    assert!(heartbeat.active_model.is_missing());
    let encoded = serde_json::to_value(ProviderMessage::Heartbeat(heartbeat.clone()))
        .expect("encode omission");
    assert!(
        !encoded
            .as_object()
            .expect("object")
            .contains_key("active_model")
    );

    heartbeat.active_model = OptionalNullable::Null;
    let encoded = serde_json::to_value(ProviderMessage::Heartbeat(heartbeat)).expect("encode null");
    assert!(encoded["active_model"].is_null());

    let missing_body = parse_coordinator_message(
        br#"{"type":"inference_request","request_id":"r","encrypted_body":{"ephemeral_public_key":"k","ciphertext":"c"}}"#,
    )
    .expect("missing inference body");
    let CoordinatorMessage::InferenceRequest(mut request) = missing_body else {
        panic!("inference request variant");
    };
    assert!(request.body.is_missing());
    let encoded = serde_json::to_value(CoordinatorMessage::InferenceRequest(request.clone()))
        .expect("encode missing body");
    assert!(!encoded.as_object().expect("object").contains_key("body"));
    request.body = OptionalNullable::Null;
    let encoded = serde_json::to_value(CoordinatorMessage::InferenceRequest(request))
        .expect("encode null body");
    assert!(encoded["body"].is_null());

    let legacy = parse_provider_message(
        br#"{"type":"attestation_response","nonce":"n","signature":"s","public_key":"p","hypervisor_active":false}"#,
    )
    .expect("legacy explicit false");
    let ProviderMessage::AttestationResponse(response) = legacy.message else {
        panic!("attestation response variant");
    };
    assert_eq!(response.hypervisor_active, Some(false));
    let encoded =
        serde_json::to_value(ProviderMessage::AttestationResponse(response)).expect("encode false");
    assert_eq!(encoded["hypervisor_active"], false);
}

#[test]
fn unknown_additive_fields_are_accepted_separately() {
    let provider = parse_provider_message(
        br#"{"type":"heartbeat","status":"idle","stats":{"requests_served":0,"tokens_generated":0},"system_metrics":{"memory_pressure":0,"cpu_usage":0,"thermal_state":"nominal"},"future_provider_field":{"nested":true}}"#,
    )
    .expect("provider additive field");
    let encoded = serde_json::to_value(provider.message).expect("encode provider");
    assert!(encoded.get("future_provider_field").is_none());

    let coordinator = parse_coordinator_message(
        br#"{"type":"cancel","request_id":"r","future_coordinator_field":42}"#,
    )
    .expect("coordinator additive field");
    let encoded = serde_json::to_value(coordinator).expect("encode coordinator");
    assert!(encoded.get("future_coordinator_field").is_none());
}

#[test]
fn v2_registration_requires_top_level_process_generation_identity() {
    let fixture: WireContract = read_contract("protocol/v1/provider_to_coordinator.json");
    let mut registration: serde_json::Value =
        serde_json::from_str(&fixture.cases[0].wire).expect("minimal registration");
    registration["protocol_capabilities"] = serde_json::json!({
        "protocol_major": 2,
        "protocol_minor": 3,
        "minimum_compatible_minor": 1,
        "prepared_leases": true,
        "start_authorization": true,
        "durable_terminals": true,
        "process_generation": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    });
    let wire = serde_json::to_vec(&registration).expect("registration JSON");
    assert!(matches!(
        parse_provider_message(&wire),
        Err(ProtocolError::MissingProviderProcessGeneration)
    ));

    registration["provider_process_generation"] = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb".into();
    let wire = serde_json::to_vec(&registration).expect("registration JSON");
    let parsed = parse_provider_message(&wire).expect("fenced v2 registration");
    let ProviderMessage::Register(registration) = parsed.message else {
        panic!("registration variant");
    };
    assert_eq!(
        registration
            .provider_process_generation
            .expect("top-level generation")
            .to_string(),
        "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    );
    let capabilities = serde_json::to_value(
        registration
            .protocol_capabilities
            .expect("protocol capabilities"),
    )
    .expect("serialize capabilities");
    assert!(
        capabilities.get("process_generation").is_none(),
        "process generation must not be negotiated as a capability"
    );
}

fn full_status(hypervisor_active: Option<bool>) -> AttestationStatus {
    AttestationStatus {
        nonce: "test-nonce".into(),
        timestamp: "2026-04-16T12:00:00Z".into(),
        hypervisor_active,
        rdma_disabled: Some(true),
        sip_enabled: Some(true),
        secure_boot_enabled: Some(true),
        binary_hash: "binhash".into(),
        active_model_hash: "activemodel".into(),
        python_hash: "pyhash".into(),
        runtime_hash: "rthash".into(),
        template_hashes: [
            ("chatml".into(), "tmplhash1".into()),
            ("gemma".into(), "tmplhash2".into()),
        ]
        .into_iter()
        .collect(),
        model_hashes: [
            ("qwen".into(), "modelhash1".into()),
            ("trinity".into(), "modelhash2".into()),
        ]
        .into_iter()
        .collect(),
        grpc_binary_hash: String::new(),
    }
}

fn assert_provider_variant(message: &ProviderMessage, expected: &str) {
    let matches = matches!(
        (message, expected),
        (ProviderMessage::Register(_), "register")
            | (ProviderMessage::Heartbeat(_), "heartbeat")
            | (ProviderMessage::InferenceAccepted(_), "inference_accepted")
            | (
                ProviderMessage::InferenceResponseChunk(_),
                "inference_response_chunk"
            )
            | (ProviderMessage::InferenceComplete(_), "inference_complete")
            | (ProviderMessage::InferenceError(_), "inference_error")
            | (
                ProviderMessage::AttestationResponse(_),
                "attestation_response"
            )
            | (
                ProviderMessage::CodeAttestationResponse(_),
                "code_attestation_response"
            )
            | (ProviderMessage::LoadModelStatus(_), "load_model_status")
            | (
                ProviderMessage::PrefetchModelStatus(_),
                "prefetch_model_status"
            )
            | (ProviderMessage::ModelsUpdate(_), "models_update")
    );
    assert!(matches, "wrong provider variant for {expected}");
}

fn assert_coordinator_variant(message: &CoordinatorMessage, expected: &str) {
    let matches = matches!(
        (message, expected),
        (CoordinatorMessage::InferenceRequest(_), "inference_request")
            | (CoordinatorMessage::Cancel(_), "cancel")
            | (
                CoordinatorMessage::AttestationChallenge(_),
                "attestation_challenge"
            )
            | (CoordinatorMessage::RuntimeStatus(_), "runtime_status")
            | (CoordinatorMessage::LoadModel(_), "load_model")
            | (CoordinatorMessage::PrefetchModel(_), "prefetch_model")
            | (CoordinatorMessage::DesiredModels(_), "desired_models")
            | (CoordinatorMessage::TrustStatus(_), "trust_status")
    );
    assert!(matches, "wrong coordinator variant for {expected}");
}

fn decode_array<const N: usize>(encoded: &str) -> [u8; N] {
    STANDARD
        .decode(encoded)
        .expect("valid base64")
        .try_into()
        .unwrap_or_else(|value: Vec<u8>| panic!("decoded {} bytes, want {N}", value.len()))
}

fn read_contract<T: for<'de> Deserialize<'de>>(relative: &str) -> T {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .join("tests/contracts")
        .join(relative);
    let data = fs::read(&path).unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    serde_json::from_slice(&data)
        .unwrap_or_else(|error| panic!("decode {}: {error}", path.display()))
}

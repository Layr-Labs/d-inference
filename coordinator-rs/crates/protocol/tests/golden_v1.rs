//! JSON v1 golden-vector compatibility: every Go-marshaled frame decodes
//! into the Rust types and re-encodes to a semantically identical document —
//! same key sets (including omissions), same values, exact base64 payloads.
//!
//! The goldens are the Go encoder's output, so a green run pins the Rust
//! types to `encoding/json` behavior: omitempty per field, null-vs-absent
//! slices, always-present zero structs, and pointer-field survival.

mod common;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use darkbloom_protocol::crypto::signing::verify_signed_payload;
use darkbloom_protocol::json_v1::{
    msg_type, peek_type, CoordinatorMessage, DecodeError, ProviderMessage,
};
use serde_json::Value;

/// Number-normalizing deep equality: Go marshals `float64(128)` as `128`
/// while serde_json emits `128.0`; both denote the same value, so numbers
/// compare numerically while everything else (keys, strings, base64
/// payloads, null-vs-absent) compares exactly.
fn json_equivalent(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => match (x.as_u64(), y.as_u64()) {
            (Some(i), Some(j)) => i == j,
            _ => match (x.as_i64(), y.as_i64()) {
                (Some(i), Some(j)) => i == j,
                _ => x.as_f64() == y.as_f64(),
            },
        },
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, v)| y.get(k).is_some_and(|w| json_equivalent(v, w)))
        }
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(v, w)| json_equivalent(v, w))
        }
        _ => a == b,
    }
}

// Test-only convenience; size disparity between the variants is irrelevant.
#[allow(clippy::large_enum_variant)]
enum Decoded {
    Provider(ProviderMessage),
    Coordinator(CoordinatorMessage),
}

impl Decoded {
    fn decode(bytes: &[u8]) -> Self {
        match ProviderMessage::decode(bytes) {
            Ok(m) => Self::Provider(m),
            Err(DecodeError::UnknownType(_)) => Self::Coordinator(
                CoordinatorMessage::decode(bytes).expect("frame decodes as coordinator message"),
            ),
            Err(e) => panic!("provider decode failed: {e}"),
        }
    }

    fn encode(&self) -> Vec<u8> {
        match self {
            Self::Provider(m) => m.encode().expect("encode"),
            Self::Coordinator(m) => m.encode().expect("encode"),
        }
    }

    fn type_str(&self) -> &'static str {
        match self {
            Self::Provider(m) => m.type_str(),
            Self::Coordinator(m) => m.type_str(),
        }
    }
}

fn golden_files() -> Vec<(String, Vec<u8>)> {
    let dir = common::vectors_dir().join("json_v1");
    let mut files: Vec<(String, Vec<u8>)> = std::fs::read_dir(&dir)
        .unwrap_or_else(|e| {
            panic!(
                "missing goldens dir {} ({e}) — run `go run ./coordinator-rs/fixtures/gen`",
                dir.display()
            )
        })
        .map(|entry| {
            let entry = entry.expect("dir entry");
            let name = entry.file_name().to_string_lossy().into_owned();
            let bytes = std::fs::read(entry.path()).expect("read golden");
            (name, bytes)
        })
        .filter(|(name, _)| name.ends_with(".json"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no goldens found in {}", dir.display());
    files
}

/// Every golden decodes, re-encodes, and matches the Go bytes semantically.
#[test]
fn every_golden_round_trips_semantically() {
    for (name, bytes) in golden_files() {
        let golden: Value = serde_json::from_slice(&bytes)
            .unwrap_or_else(|e| panic!("{name}: golden is not valid JSON: {e}"));
        let decoded = Decoded::decode(&bytes);
        assert_eq!(
            golden["type"].as_str().expect("type tag"),
            decoded.type_str(),
            "{name}: envelope dispatched to the wrong variant"
        );
        let reencoded: Value =
            serde_json::from_slice(&decoded.encode()).expect("re-encode is valid JSON");
        assert!(
            json_equivalent(&golden, &reencoded),
            "{name}: re-encode diverges from Go\n  go:   {golden}\n  rust: {reencoded}"
        );
    }
}

/// The cheap type scanner resolves every real Go-marshaled frame without the
/// envelope fallback.
#[test]
fn peek_type_resolves_every_golden() {
    for (name, bytes) in golden_files() {
        let golden: Value = serde_json::from_slice(&bytes).expect("valid JSON");
        assert_eq!(
            peek_type(&bytes),
            golden["type"].as_str(),
            "{name}: scanner disagreed with the full parse"
        );
    }
}

/// Guard against generator drift: every v1 message type must have at least
/// one golden.
#[test]
fn goldens_cover_every_message_type() {
    let mut seen: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for (_, bytes) in golden_files() {
        let golden: Value = serde_json::from_slice(&bytes).expect("valid JSON");
        seen.insert(golden["type"].as_str().expect("type tag").to_owned());
    }
    let expected = [
        msg_type::REGISTER,
        msg_type::HEARTBEAT,
        msg_type::INFERENCE_ACCEPTED,
        msg_type::INFERENCE_RESPONSE_CHUNK,
        msg_type::INFERENCE_COMPLETE,
        msg_type::INFERENCE_ERROR,
        msg_type::ATTESTATION_RESPONSE,
        msg_type::CODE_ATTESTATION_RESPONSE,
        msg_type::LOAD_MODEL_STATUS,
        msg_type::PREFETCH_MODEL_STATUS,
        msg_type::MODELS_UPDATE,
        msg_type::INFERENCE_REQUEST,
        msg_type::CANCEL,
        msg_type::ATTESTATION_CHALLENGE,
        msg_type::RUNTIME_STATUS,
        msg_type::LOAD_MODEL,
        msg_type::PREFETCH_MODEL,
        msg_type::DESIRED_MODELS,
        msg_type::TRUST_STATUS,
    ];
    for t in expected {
        assert!(seen.contains(t), "no golden covers message type {t:?}");
    }
    assert_eq!(
        seen.len(),
        expected.len(),
        "unexpected extra types: {seen:?}"
    );
}

/// Omission pins that matter most for strict Swift decoders: explicit-false
/// pointers survive, zero counters vanish, and `null` stays distinct from
/// absent.
#[test]
fn omitempty_pins() {
    for (name, bytes) in golden_files() {
        let golden: Value = serde_json::from_slice(&bytes).expect("valid JSON");
        let obj = golden.as_object().unwrap();
        match name.as_str() {
            "heartbeat__zero.json" => {
                assert_eq!(
                    obj["active_model"],
                    Value::Null,
                    "no-model is null, not absent"
                );
                assert!(!obj.contains_key("warm_models"));
                assert!(!obj.contains_key("backend_capacity"));
                let stats = obj["stats"].as_object().unwrap();
                assert!(!stats.contains_key("cancellations_received"));
            }
            "register__zero.json" => {
                assert_eq!(obj["models"], Value::Null, "nil slice is null, not absent");
                assert!(!obj.contains_key("attestation"));
                assert!(!obj.contains_key("privacy_capabilities"));
            }
            "inference_request__zero.json" => {
                // Go omitempty is a no-op on struct fields: body must exist.
                assert!(obj.contains_key("body"));
                assert_eq!(obj["body"]["messages"], Value::Null);
                assert!(!obj.contains_key("encrypted_body"));
            }
            "attestation_response__populated.json" => {
                assert_eq!(obj["hypervisor_active"], Value::Bool(false));
            }
            "models_update__empty_slice.json" => {
                assert_eq!(obj["models"], serde_json::json!([]));
            }
            _ => {}
        }
    }
}

/// The signed attestation blob inside register__populated.json must survive
/// decode → re-encode byte-exact (Swift `\/` escapes and all), and the Go
/// signature must verify over exactly those preserved bytes.
#[test]
fn attestation_raw_bytes_round_trip_byte_exact() {
    let bytes = common::read_vector_file("json_v1/register__populated.json");
    let register = match ProviderMessage::decode(&bytes).expect("decode register") {
        ProviderMessage::Register(m) => m,
        other => panic!("wrong variant: {}", other.type_str()),
    };
    let raw = register.attestation.as_ref().expect("attestation present");

    #[derive(serde::Deserialize)]
    struct SignedAttestation<'a> {
        #[serde(borrow)]
        attestation: &'a serde_json::value::RawValue,
        signature: String,
    }
    let signed: SignedAttestation = serde_json::from_str(raw.get()).expect("signed attestation");

    #[derive(serde::Deserialize)]
    struct SigningVectors {
        se_public_key_b64: String,
        raw_blob: RawBlob,
    }
    #[derive(serde::Deserialize)]
    struct RawBlob {
        blob_b64: String,
    }
    let vectors: SigningVectors =
        serde_json::from_slice(&common::read_vector_file("signing/vectors.json"))
            .expect("signing vectors");
    let expected_blob = BASE64.decode(&vectors.raw_blob.blob_b64).expect("blob b64");

    // Byte-exact preservation of the signed bytes through the Rust decode.
    assert_eq!(
        signed.attestation.get().as_bytes(),
        expected_blob.as_slice(),
        "RawValue must preserve the signed attestation bytes exactly"
    );

    // And the SE signature verifies over those exact preserved bytes.
    verify_signed_payload(
        &vectors.se_public_key_b64,
        &signed.signature,
        signed.attestation.get().as_bytes(),
    )
    .expect("signature over preserved raw bytes");
}

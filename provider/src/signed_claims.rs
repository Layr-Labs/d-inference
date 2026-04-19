//! Signed integrity claims for provider→coordinator messages.
//!
//! The provider used to send a Register / AttestationResponse with dozens of
//! integrity-bearing fields (binary_hash, runtime_hash, model weight hashes,
//! wallet address, …) but the SE signature only covered `nonce || timestamp`.
//! Anything else could be lied about with a one-line patch to this binary.
//!
//! `SignedClaims` is the canonical envelope that captures every such field.
//! It is serialized as deterministic JSON (sorted keys, no whitespace, the
//! same encoding both Rust and Go produce), then SE-signed. The coordinator
//! recomputes the same canonical JSON from the fields it received, verifies
//! the signature against the provider's SE public key, and only trusts the
//! values that came out of the signed envelope.
//!
//! Float fields (TPS) are represented as integer milli-units to avoid
//! cross-language float formatting differences.

use serde::Serialize;
use std::collections::BTreeMap;

/// Integrity claims included in a `Register` message.
#[derive(Debug, Clone, Serialize)]
pub struct RegisterClaims<'a> {
    /// RFC3339 timestamp, identical to the attestation blob's timestamp.
    pub timestamp: &'a str,
    /// Backend identifier (e.g. "vllm_mlx").
    pub backend: &'a str,
    /// Provider binary version string.
    pub version: &'a str,
    /// X25519 encryption public key (base64).
    pub public_key: &'a str,
    /// Ethereum-style wallet address, lowercase hex.
    pub wallet_address: &'a str,
    /// Device-link auth token (from `darkbloom login`), if any.
    pub auth_token: &'a str,
    /// SHA-256 of the Python interpreter binary.
    pub python_hash: &'a str,
    /// Combined SHA-256 of the inference runtime (vllm-mlx) site-packages.
    pub runtime_hash: &'a str,
    /// SHA-256 of the gRPCServerCLI binary, if present.
    pub grpc_binary_hash: &'a str,
    /// Combined SHA-256 of image bridge Python source.
    pub image_bridge_hash: &'a str,
    /// Per-template SHA-256 hashes (sorted by name in canonical JSON).
    pub template_hashes: &'a BTreeMap<String, String>,
    /// Per-model weight hashes (sorted by model_id in canonical JSON).
    pub model_hashes: &'a BTreeMap<String, String>,
    /// Benchmark prefill TPS, encoded as integer (tps * 1000) to avoid
    /// cross-language float formatting drift.
    pub prefill_tps_milli: u64,
    /// Benchmark decode TPS, encoded as integer (tps * 1000).
    pub decode_tps_milli: u64,
}

/// Integrity claims included in an `AttestationResponse` message. Bound to the
/// coordinator-issued challenge nonce + timestamp so this envelope cannot be
/// replayed across challenges or providers.
#[derive(Debug, Clone, Serialize)]
pub struct ChallengeClaims<'a> {
    pub nonce: &'a str,
    pub timestamp: &'a str,
    pub binary_hash: &'a str,
    pub active_model_hash: &'a str,
    pub python_hash: &'a str,
    pub runtime_hash: &'a str,
    pub grpc_binary_hash: &'a str,
    pub image_bridge_hash: &'a str,
    pub template_hashes: &'a BTreeMap<String, String>,
    pub model_hashes: &'a BTreeMap<String, String>,
    pub sip_enabled: bool,
    pub secure_boot_enabled: bool,
    pub rdma_disabled: bool,
    pub hypervisor_active: bool,
}

/// Encode the claims as canonical JSON: sorted keys, no whitespace, UTF-8.
///
/// Uses `serde_json::to_vec` against a `BTreeMap<String, serde_json::Value>`
/// built from the struct so map keys are emitted in alphabetical (Unicode
/// code point) order, matching Go's `encoding/json` output for `map[string]any`.
pub fn canonical_register_json(c: &RegisterClaims<'_>) -> Vec<u8> {
    let mut m: BTreeMap<&'static str, serde_json::Value> = BTreeMap::new();
    m.insert("auth_token", serde_json::Value::String(c.auth_token.into()));
    m.insert("backend", serde_json::Value::String(c.backend.into()));
    m.insert(
        "decode_tps_milli",
        serde_json::Value::Number(c.decode_tps_milli.into()),
    );
    m.insert(
        "grpc_binary_hash",
        serde_json::Value::String(c.grpc_binary_hash.into()),
    );
    m.insert(
        "image_bridge_hash",
        serde_json::Value::String(c.image_bridge_hash.into()),
    );
    m.insert("model_hashes", map_to_json(c.model_hashes));
    m.insert(
        "prefill_tps_milli",
        serde_json::Value::Number(c.prefill_tps_milli.into()),
    );
    m.insert("public_key", serde_json::Value::String(c.public_key.into()));
    m.insert(
        "python_hash",
        serde_json::Value::String(c.python_hash.into()),
    );
    m.insert(
        "runtime_hash",
        serde_json::Value::String(c.runtime_hash.into()),
    );
    m.insert("template_hashes", map_to_json(c.template_hashes));
    m.insert("timestamp", serde_json::Value::String(c.timestamp.into()));
    m.insert("version", serde_json::Value::String(c.version.into()));
    m.insert(
        "wallet_address",
        serde_json::Value::String(c.wallet_address.into()),
    );
    serde_json::to_vec(&m).expect("BTreeMap of plain values must serialize")
}

pub fn canonical_challenge_json(c: &ChallengeClaims<'_>) -> Vec<u8> {
    let mut m: BTreeMap<&'static str, serde_json::Value> = BTreeMap::new();
    m.insert(
        "active_model_hash",
        serde_json::Value::String(c.active_model_hash.into()),
    );
    m.insert(
        "binary_hash",
        serde_json::Value::String(c.binary_hash.into()),
    );
    m.insert(
        "grpc_binary_hash",
        serde_json::Value::String(c.grpc_binary_hash.into()),
    );
    m.insert(
        "hypervisor_active",
        serde_json::Value::Bool(c.hypervisor_active),
    );
    m.insert(
        "image_bridge_hash",
        serde_json::Value::String(c.image_bridge_hash.into()),
    );
    m.insert("model_hashes", map_to_json(c.model_hashes));
    m.insert("nonce", serde_json::Value::String(c.nonce.into()));
    m.insert(
        "python_hash",
        serde_json::Value::String(c.python_hash.into()),
    );
    m.insert(
        "rdma_disabled",
        serde_json::Value::Bool(c.rdma_disabled),
    );
    m.insert(
        "runtime_hash",
        serde_json::Value::String(c.runtime_hash.into()),
    );
    m.insert(
        "secure_boot_enabled",
        serde_json::Value::Bool(c.secure_boot_enabled),
    );
    m.insert("sip_enabled", serde_json::Value::Bool(c.sip_enabled));
    m.insert("template_hashes", map_to_json(c.template_hashes));
    m.insert("timestamp", serde_json::Value::String(c.timestamp.into()));
    serde_json::to_vec(&m).expect("BTreeMap of plain values must serialize")
}

fn map_to_json(m: &BTreeMap<String, String>) -> serde_json::Value {
    let mut out = serde_json::Map::with_capacity(m.len());
    for (k, v) in m {
        out.insert(k.clone(), serde_json::Value::String(v.clone()));
    }
    serde_json::Value::Object(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn challenge_canonical_is_sorted_and_stable() {
        let mh: BTreeMap<String, String> = [
            ("zebra".to_string(), "z".to_string()),
            ("apple".to_string(), "a".to_string()),
        ]
        .into_iter()
        .collect();
        let th: BTreeMap<String, String> = BTreeMap::new();
        let c = ChallengeClaims {
            nonce: "n",
            timestamp: "t",
            binary_hash: "bh",
            active_model_hash: "amh",
            python_hash: "ph",
            runtime_hash: "rh",
            grpc_binary_hash: "",
            image_bridge_hash: "",
            template_hashes: &th,
            model_hashes: &mh,
            sip_enabled: true,
            secure_boot_enabled: true,
            rdma_disabled: true,
            hypervisor_active: false,
        };
        let json = canonical_challenge_json(&c);
        let s = std::str::from_utf8(&json).unwrap();
        // Top-level keys are alphabetical
        let active_pos = s.find("\"active_model_hash\"").unwrap();
        let binary_pos = s.find("\"binary_hash\"").unwrap();
        let nonce_pos = s.find("\"nonce\"").unwrap();
        assert!(active_pos < binary_pos);
        assert!(binary_pos < nonce_pos);
        // model_hashes inner keys are alphabetical
        let apple_pos = s.find("\"apple\"").unwrap();
        let zebra_pos = s.find("\"zebra\"").unwrap();
        assert!(apple_pos < zebra_pos);
        // Stable across runs
        assert_eq!(canonical_challenge_json(&c), canonical_challenge_json(&c));
    }

    #[test]
    fn register_canonical_is_stable() {
        let mh = BTreeMap::new();
        let th = BTreeMap::new();
        let c = RegisterClaims {
            timestamp: "2026-01-01T00:00:00Z",
            backend: "vllm_mlx",
            version: "0.4.0",
            public_key: "abc",
            wallet_address: "0x0",
            auth_token: "",
            python_hash: "",
            runtime_hash: "",
            grpc_binary_hash: "",
            image_bridge_hash: "",
            template_hashes: &th,
            model_hashes: &mh,
            prefill_tps_milli: 500_000,
            decode_tps_milli: 100_000,
        };
        let a = canonical_register_json(&c);
        let b = canonical_register_json(&c);
        assert_eq!(a, b);
    }

    /// Byte-for-byte parity with the Go coordinator's
    /// CanonicalChallengeJSON test vector. Drift here means the SE
    /// signature the provider produces will not verify on the
    /// coordinator — the entire claims envelope mechanism breaks.
    #[test]
    fn challenge_canonical_matches_go_byte_for_byte() {
        let mut mh: BTreeMap<String, String> = BTreeMap::new();
        mh.insert("apple".to_string(), "a".to_string());
        mh.insert("zebra".to_string(), "z".to_string());
        let th: BTreeMap<String, String> = BTreeMap::new();
        let c = ChallengeClaims {
            nonce: "n",
            timestamp: "t",
            binary_hash: "bh",
            active_model_hash: "amh",
            python_hash: "ph",
            runtime_hash: "rh",
            grpc_binary_hash: "",
            image_bridge_hash: "",
            template_hashes: &th,
            model_hashes: &mh,
            sip_enabled: true,
            secure_boot_enabled: true,
            rdma_disabled: true,
            hypervisor_active: false,
        };
        let got = String::from_utf8(canonical_challenge_json(&c)).unwrap();
        let want = r#"{"active_model_hash":"amh","binary_hash":"bh","grpc_binary_hash":"","hypervisor_active":false,"image_bridge_hash":"","model_hashes":{"apple":"a","zebra":"z"},"nonce":"n","python_hash":"ph","rdma_disabled":true,"runtime_hash":"rh","secure_boot_enabled":true,"sip_enabled":true,"template_hashes":{},"timestamp":"t"}"#;
        assert_eq!(got, want);
    }

    /// Byte-for-byte parity with Go for RegisterClaims.
    #[test]
    fn register_canonical_matches_go_byte_for_byte() {
        let mh = BTreeMap::new();
        let th = BTreeMap::new();
        let c = RegisterClaims {
            timestamp: "2026-01-01T00:00:00Z",
            backend: "vllm_mlx",
            version: "0.4.0",
            public_key: "abc",
            wallet_address: "0x0",
            auth_token: "",
            python_hash: "",
            runtime_hash: "",
            grpc_binary_hash: "",
            image_bridge_hash: "",
            template_hashes: &th,
            model_hashes: &mh,
            prefill_tps_milli: 500_000,
            decode_tps_milli: 100_000,
        };
        let got = String::from_utf8(canonical_register_json(&c)).unwrap();
        let want = r#"{"auth_token":"","backend":"vllm_mlx","decode_tps_milli":100000,"grpc_binary_hash":"","image_bridge_hash":"","model_hashes":{},"prefill_tps_milli":500000,"public_key":"abc","python_hash":"","runtime_hash":"","template_hashes":{},"timestamp":"2026-01-01T00:00:00Z","version":"0.4.0","wallet_address":"0x0"}"#;
        assert_eq!(got, want);
    }
}

//! Sealed (sender-encrypted) request handling for the pilot.

use crate::crypto_keys::CoordinatorKeys;
use base64::Engine;
use serde_json::Value;

/// Extract sealed ciphertext from a request body.
/// Supports `{ "encrypted_body": "<base64>" }` or `{ "sealed": { "ciphertext": "..." } }`.
pub fn extract_sealed_b64(body: &Value) -> Option<String> {
    if let Some(s) = body.get("encrypted_body").and_then(|v| v.as_str()) {
        return Some(s.to_string());
    }
    if let Some(s) = body
        .get("sealed")
        .and_then(|v| v.get("ciphertext"))
        .and_then(|v| v.as_str())
    {
        return Some(s.to_string());
    }
    None
}

pub fn decrypt_request_body(
    keys: &CoordinatorKeys,
    body: &Value,
) -> Result<Value, String> {
    let Some(b64) = extract_sealed_b64(body) else {
        return Ok(body.clone());
    };
    let sealed = base64::engine::general_purpose::STANDARD
        .decode(b64.trim())
        .map_err(|e| format!("invalid sealed base64: {e}"))?;
    let plain = keys.open(&sealed)?;
    serde_json::from_slice(&plain).map_err(|e| format!("sealed plaintext is not JSON: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use darkbloom_protocol::seal_box;
    use serde_json::json;

    #[test]
    fn decrypts_encrypted_body() {
        let keys = CoordinatorKeys::generate("k");
        let sealed = seal_box(&keys.public_key_bytes(), br#"{"model":"m","messages":[]}"#).unwrap();
        let b64 = base64::engine::general_purpose::STANDARD.encode(&sealed);
        let outer = json!({"encrypted_body": b64});
        let inner = decrypt_request_body(&keys, &outer).unwrap();
        assert_eq!(inner["model"], "m");
    }

    #[test]
    fn plaintext_passthrough() {
        let keys = CoordinatorKeys::generate("k");
        let body = json!({"model":"m"});
        let out = decrypt_request_body(&keys, &body).unwrap();
        assert_eq!(out["model"], "m");
    }
}

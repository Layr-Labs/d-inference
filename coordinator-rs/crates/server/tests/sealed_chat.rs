//! Sealed chat request E2E against an in-process coordinator is heavy;
//! this integration test seals a body to CoordinatorKeys and decrypts it
//! the same way the HTTP adapter does.

use darkbloom_coordinator::{decrypt_request_body, CoordinatorKeys};
use darkbloom_protocol::seal_box;
use serde_json::json;

#[test]
fn sealed_chat_body_round_trip() {
    let keys = CoordinatorKeys::generate("pilot");
    let inner = json!({
        "model": "pilot-text-model",
        "messages": [{"role":"user","content":"sealed hi"}],
        "stream": false
    });
    let sealed = seal_box(
        &keys.public_key_bytes(),
        serde_json::to_vec(&inner).unwrap().as_slice(),
    )
    .unwrap();
    let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, sealed);
    let outer = json!({"encrypted_body": b64});
    let parsed = decrypt_request_body(&keys, &outer).unwrap();
    assert_eq!(parsed["model"], "pilot-text-model");
    assert_eq!(parsed["messages"][0]["content"], "sealed hi");
}

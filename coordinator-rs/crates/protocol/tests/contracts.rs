use std::{fs, path::PathBuf};

use base64::{Engine, engine::general_purpose::STANDARD};
use crypto_box::{PublicKey, SalsaBox, SecretKey, aead::Aead};
use serde::Deserialize;

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
    recipient_private_key_base64: String,
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
fn protocol_v1_contracts_are_valid_tagged_json() {
    for (name, direction) in [
        ("provider_to_coordinator.json", "provider_to_coordinator"),
        ("coordinator_to_provider.json", "coordinator_to_provider"),
    ] {
        let fixture: WireContract = read_contract(&format!("protocol/v1/{name}"));
        assert_eq!(fixture.schema_version, 1);
        assert_eq!(fixture.direction, direction);
        assert!(!fixture.cases.is_empty());
        for contract in fixture.cases {
            let wire: serde_json::Value = serde_json::from_str(&contract.wire)
                .unwrap_or_else(|error| panic!("{} is not valid JSON: {error}", contract.name));
            assert_eq!(
                wire.get("type").and_then(serde_json::Value::as_str),
                Some(contract.message_type.as_str()),
                "{} has the wrong discriminator",
                contract.name
            );
            if contract.exact_bytes {
                assert_eq!(
                    darkbloom_coordinator_protocol::raw_json::registration_attestation(
                        &contract.wire
                    )
                    .expect("valid registration JSON"),
                    Some(r#"{"signature":"sig","attestation":{"z":1,"a":[true,false]}}"#),
                    "{} changed signed registration bytes",
                    contract.name
                );
            }
        }
    }
}

#[test]
fn rust_decrypts_go_nacl_box_contract_and_rejects_tamper() {
    let fixture: CryptoContract = read_contract("crypto/nacl_box.json");
    assert_eq!(fixture.schema_version, 1);
    let expected = STANDARD
        .decode(fixture.plaintext_base64)
        .expect("valid plaintext base64");
    let private_key = decode_array::<32>(&fixture.recipient_private_key_base64);

    let plaintext =
        decrypt(&fixture.payload, private_key).expect("Rust decrypts the Go contract vector");
    assert_eq!(plaintext, expected);
    assert!(
        decrypt(&fixture.tampered_payload, private_key).is_err(),
        "tampered contract vector must fail authentication"
    );
    assert_eq!(
        STANDARD
            .decode(fixture.status_canonical.current_base64)
            .expect("current canonical base64"),
        br#"{"active_model_hash":"activemodel","binary_hash":"binhash","model_hashes":{"qwen":"modelhash1","trinity":"modelhash2"},"nonce":"test-nonce","python_hash":"pyhash","rdma_disabled":true,"runtime_hash":"rthash","secure_boot_enabled":true,"sip_enabled":true,"template_hashes":{"chatml":"tmplhash1","gemma":"tmplhash2"},"timestamp":"2026-04-16T12:00:00Z"}"#
    );
    assert_eq!(
        STANDARD
            .decode(fixture.status_canonical.legacy_hypervisor_false_base64)
            .expect("legacy canonical base64"),
        br#"{"active_model_hash":"activemodel","binary_hash":"binhash","hypervisor_active":false,"model_hashes":{"qwen":"modelhash1","trinity":"modelhash2"},"nonce":"test-nonce","python_hash":"pyhash","rdma_disabled":true,"runtime_hash":"rthash","secure_boot_enabled":true,"sip_enabled":true,"template_hashes":{"chatml":"tmplhash1","gemma":"tmplhash2"},"timestamp":"2026-04-16T12:00:00Z"}"#
    );
    assert_eq!(
        STANDARD
            .decode(fixture.status_canonical.explicit_security_false_base64)
            .expect("false canonical base64"),
        br#"{"nonce":"n","sip_enabled":false,"timestamp":"t"}"#
    );
}

fn decrypt(
    payload: &EncryptedPayload,
    private_key: [u8; 32],
) -> Result<Vec<u8>, crypto_box::aead::Error> {
    let sender = PublicKey::from(decode_array::<32>(&payload.ephemeral_public_key));
    let secret = SecretKey::from(private_key);
    let cipher = SalsaBox::new(&sender, &secret);
    let ciphertext = STANDARD
        .decode(&payload.ciphertext)
        .expect("valid ciphertext base64");
    let nonce: [u8; 24] = ciphertext[..24]
        .try_into()
        .expect("ciphertext includes nonce");
    cipher.decrypt(&nonce.into(), &ciphertext[24..])
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

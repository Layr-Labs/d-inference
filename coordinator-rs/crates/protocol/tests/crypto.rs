use base64::{Engine, engine::general_purpose::STANDARD};
use crypto_box::{SecretKey, aead::OsRng};
use darkbloom_coordinator_protocol::{
    CryptoError,
    crypto::{
        BoxPayload, SenderSealEnvelope, open_box, open_sender_request, seal_box,
        seal_sender_request,
    },
};

#[test]
fn box_and_sender_seal_round_trip() {
    let recipient = SecretKey::generate(&mut OsRng);
    let payload =
        seal_box(recipient.public_key().as_bytes(), b"private request").expect("seal NaCl box");
    assert_eq!(
        open_box(&recipient.to_bytes(), &payload).expect("open NaCl box"),
        b"private request"
    );

    let envelope = seal_sender_request(
        "coordinator-key-1",
        recipient.public_key().as_bytes(),
        b"sender sealed",
    )
    .expect("sender seal");
    let wire = serde_json::to_value(&envelope).expect("serialize envelope");
    assert_eq!(wire["kid"], "coordinator-key-1");
    assert!(wire["ephemeral_public_key"].is_string());
    assert!(wire["ciphertext"].is_string());
    assert_eq!(
        open_sender_request(&recipient.to_bytes(), &envelope).expect("open sender seal"),
        b"sender sealed"
    );
}

#[test]
fn tamper_wrong_key_and_invalid_base64_are_rejected() {
    let recipient = SecretKey::generate(&mut OsRng);
    let wrong_recipient = SecretKey::generate(&mut OsRng);
    let payload =
        seal_box(recipient.public_key().as_bytes(), b"authenticated").expect("seal NaCl box");

    assert!(matches!(
        open_box(&wrong_recipient.to_bytes(), &payload),
        Err(CryptoError::AuthenticationFailed)
    ));

    let mut tampered = payload.clone();
    let mut wire_ciphertext = STANDARD
        .decode(&tampered.ciphertext)
        .expect("generated base64");
    *wire_ciphertext
        .last_mut()
        .expect("authenticated ciphertext") ^= 1;
    tampered.ciphertext = STANDARD.encode(wire_ciphertext);
    assert!(matches!(
        open_box(&recipient.to_bytes(), &tampered),
        Err(CryptoError::AuthenticationFailed)
    ));

    let bad_key = BoxPayload {
        ephemeral_public_key: "%%%".into(),
        ciphertext: payload.ciphertext.clone(),
    };
    assert!(matches!(
        open_box(&recipient.to_bytes(), &bad_key),
        Err(CryptoError::InvalidBase64 {
            field: "ephemeral_public_key",
            ..
        })
    ));

    let bad_ciphertext = BoxPayload {
        ephemeral_public_key: payload.ephemeral_public_key,
        ciphertext: "not base64!".into(),
    };
    assert!(matches!(
        open_box(&recipient.to_bytes(), &bad_ciphertext),
        Err(CryptoError::InvalidBase64 {
            field: "ciphertext",
            ..
        })
    ));
}

#[test]
fn sender_seal_accepts_unknown_additive_json_fields() {
    let envelope: SenderSealEnvelope = serde_json::from_str(
        r#"{"kid":"k","ephemeral_public_key":"a","ciphertext":"b","future":true}"#,
    )
    .expect("unknown field compatible");
    assert_eq!(envelope.kid, "k");
}

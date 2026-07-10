//! Registration attestation-blob verification: signature over the raw
//! preserved bytes, minimum security posture, and the encryption-key
//! binding check (plan §15.3).

use serde::Deserialize;

use darkbloom_protocol::crypto::signing;

use crate::contracts::TrustVerdict;

use super::types::untrusted;

/// Wire shape of the signed registration blob (Go `SignedAttestation`):
/// `attestation` is captured as raw JSON so the exact signed bytes survive.
#[derive(Deserialize)]
struct SignedAttestationWire<'a> {
    #[serde(borrow)]
    attestation: Option<&'a serde_json::value::RawValue>,
    #[serde(default)]
    signature: String,
}

/// Typed view of the blob fields the pilot acts on (Go `AttestationBlob`).
/// Decoded from the same raw bytes AFTER signature verification.
#[derive(Deserialize, Default)]
#[serde(default)]
struct AttestationBlobWire {
    #[serde(rename = "publicKey")]
    public_key: String,
    #[serde(rename = "encryptionPublicKey")]
    encryption_public_key: String,
    #[serde(rename = "serialNumber")]
    serial_number: String,
    #[serde(rename = "secureEnclaveAvailable")]
    secure_enclave_available: bool,
    #[serde(rename = "sipEnabled")]
    sip_enabled: bool,
    #[serde(rename = "secureBootEnabled")]
    secure_boot_enabled: bool,
}

/// Blocking-pool body of registration verification.
pub(super) fn verify_registration_blob(
    raw: &str,
    registered_x25519_b64: &str,
) -> (TrustVerdict, Option<String>, Option<String>) {
    let wire: SignedAttestationWire<'_> = match serde_json::from_str(raw) {
        Ok(w) => w,
        Err(_) => return (untrusted("malformed attestation JSON"), None, None),
    };
    let Some(blob_raw) = wire.attestation else {
        return (untrusted("attestation blob missing"), None, None);
    };
    if wire.signature.is_empty() {
        return (untrusted("attestation signature missing"), None, None);
    }
    let blob: AttestationBlobWire = match serde_json::from_str(blob_raw.get()) {
        Ok(b) => b,
        Err(_) => return (untrusted("malformed attestation blob"), None, None),
    };
    if blob.public_key.is_empty() {
        return (untrusted("attestation blob has no public key"), None, None);
    }

    // Signature over SHA-256 of the RAW blob bytes — exactly what the Secure
    // Enclave signed, never a re-encoding.
    if let Err(err) =
        signing::verify_signed_payload(&blob.public_key, &wire.signature, blob_raw.get().as_bytes())
    {
        return (
            untrusted(format!("attestation signature invalid: {err}")),
            None,
            None,
        );
    }

    // Minimum security posture (Go `attestation.Verify` checks 2-4).
    if !blob.secure_enclave_available {
        return (untrusted("Secure Enclave not available"), None, None);
    }
    if !blob.sip_enabled {
        return (untrusted("SIP not enabled"), None, None);
    }
    if !blob.secure_boot_enabled {
        return (untrusted("Secure Boot not enabled"), None, None);
    }

    // Optional binding: the attested encryption key must be the registered
    // X25519 transport key (Go check 5).
    if !blob.encryption_public_key.is_empty()
        && !registered_x25519_b64.is_empty()
        && blob.encryption_public_key != registered_x25519_b64
    {
        return (
            untrusted("attested encryption key does not match registered key"),
            None,
            None,
        );
    }

    let serial = (!blob.serial_number.is_empty()).then(|| blob.serial_number.clone());
    (TrustVerdict::SelfSigned, Some(blob.public_key), serial)
}

#[cfg(test)]
mod tests {
    use super::super::testkit::{se_key, sign_b64, signed_attestation};
    use super::super::TrustVerifier;
    use crate::contracts::TrustVerdict;

    #[tokio::test]
    async fn registration_round_trip_and_tamper() {
        let (key, pub_b64) = se_key();
        let v = TrustVerifier::new();
        let blob = signed_attestation(&key, &pub_b64, "x25519-key");

        let ok = v
            .verify_registration(Some(blob.clone()), "x25519-key".to_owned())
            .await;
        assert!(matches!(ok.verdict, TrustVerdict::SelfSigned));
        assert_eq!(ok.se_public_key.as_deref(), Some(pub_b64.as_str()));
        assert_eq!(ok.serial_number.as_deref(), Some("SER-1"));

        // Any byte flip in the signed blob must fail.
        let tampered = blob.replace("SER-1", "SER-2");
        let bad = v
            .verify_registration(Some(tampered), "x25519-key".to_owned())
            .await;
        assert!(matches!(bad.verdict, TrustVerdict::Untrusted { .. }));

        // Encryption-key binding mismatch must fail.
        let mismatch = v
            .verify_registration(Some(blob), "different-key".to_owned())
            .await;
        assert!(matches!(mismatch.verdict, TrustVerdict::Untrusted { .. }));
    }

    #[tokio::test]
    async fn registration_minimum_posture_enforced() {
        let (key, pub_b64) = se_key();
        let blob = format!(
            concat!(
                r#"{{"publicKey":"{p}","secureBootEnabled":true,"#,
                r#""secureEnclaveAvailable":true,"sipEnabled":false,"#,
                r#""timestamp":"2026-07-09T00:00:00Z"}}"#
            ),
            p = pub_b64,
        );
        let sig = sign_b64(&key, blob.as_bytes());
        let signed = format!(r#"{{"attestation":{blob},"signature":"{sig}"}}"#);
        let out = TrustVerifier::new()
            .verify_registration(Some(signed), String::new())
            .await;
        match out.verdict {
            TrustVerdict::Untrusted { reason } => assert!(reason.contains("SIP")),
            other => panic!("expected untrusted, got {other:?}"),
        }
    }
}

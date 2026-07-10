//! Challenge-response verification: nonce/key echo, challenge signature,
//! canonical status signature, and fresh posture checks (Go
//! `verifyChallengeResponse` parity).

use darkbloom_protocol::crypto::signing::{self, SigningError, StatusCanonicalInput};
use darkbloom_protocol::json_v1::AttestationResponseMessage;

use crate::contracts::TrustVerdict;

use super::types::{untrusted, ChallengeExpectation};

/// Blocking-pool body of challenge verification.
pub(super) fn verify_challenge_response(
    se_public_key_b64: &str,
    registered_x25519_b64: &str,
    expected: &ChallengeExpectation,
    resp: &AttestationResponseMessage,
) -> (TrustVerdict, bool) {
    if resp.nonce != expected.nonce {
        return (untrusted("challenge nonce mismatch"), false);
    }
    // The provider echoes its registered X25519 key; a different key means a
    // different process answered (Go: resp.PublicKey vs provider.PublicKey).
    if !registered_x25519_b64.is_empty()
        && !resp.public_key.is_empty()
        && resp.public_key != registered_x25519_b64
    {
        return (untrusted("challenge public key mismatch"), false);
    }
    if resp.signature.is_empty() {
        return (untrusted("empty challenge signature"), false);
    }
    let data = signing::challenge_data(&expected.nonce, &expected.timestamp);
    if let Err(err) = signing::verify_challenge_signature(se_public_key_b64, &resp.signature, &data)
    {
        return (
            untrusted(format!("challenge signature invalid: {err}")),
            false,
        );
    }

    // Status signature (v0.3.11+). Missing is advisory-only (legacy fleet);
    // a PRESENT-but-wrong signature is tampering and fails hard.
    let status_input = StatusCanonicalInput {
        nonce: expected.nonce.clone(),
        timestamp: expected.timestamp.clone(),
        hypervisor_active: resp.hypervisor_active,
        rdma_disabled: resp.rdma_disabled,
        sip_enabled: resp.sip_enabled,
        secure_boot_enabled: resp.secure_boot_enabled,
        binary_hash: resp.binary_hash.clone(),
        active_model_hash: resp.active_model_hash.clone(),
        python_hash: resp.python_hash.clone(),
        runtime_hash: resp.runtime_hash.clone(),
        template_hashes: resp.template_hashes.clone(),
        grpc_binary_hash: String::new(),
        model_hashes: resp.model_hashes.clone(),
    };
    let status_fields_bound = match signing::verify_status_signature(
        se_public_key_b64,
        &resp.status_signature,
        &status_input,
    ) {
        Ok(()) => true,
        Err(SigningError::StatusSignatureMissing) => false,
        Err(err) => {
            return (untrusted(format!("status signature invalid: {err}")), false);
        }
    };

    // Fresh posture checks (Go: negatives always deroute; omitted mandatory
    // signals fail closed).
    match resp.sip_enabled {
        None => return (untrusted("SIP status not reported"), status_fields_bound),
        Some(false) => return (untrusted("SIP disabled"), status_fields_bound),
        Some(true) => {}
    }
    if resp.secure_boot_enabled == Some(false) {
        return (untrusted("Secure Boot disabled"), status_fields_bound);
    }
    if resp.rdma_disabled.is_none() {
        return (untrusted("RDMA status not reported"), status_fields_bound);
    }
    // RDMA *enabled* is accepted under the registered-buffer RDMA policy.

    (TrustVerdict::SelfSigned, status_fields_bound)
}

#[cfg(test)]
mod tests {
    use darkbloom_protocol::crypto::signing::{self, StatusCanonicalInput};

    use super::super::testkit::{challenge_response, se_key, sign_b64};
    use super::super::types::ChallengeExpectation;
    use super::super::TrustVerifier;
    use crate::contracts::TrustVerdict;

    #[tokio::test]
    async fn challenge_round_trip_and_downgrades() {
        let (key, se_pub) = se_key();
        let v = TrustVerifier::new();
        let expected = ChallengeExpectation {
            nonce: "bm9uY2U=".to_owned(),
            timestamp: "2026-07-09T12:00:00Z".to_owned(),
        };
        let resp = challenge_response(&key, &expected.nonce, &expected.timestamp);

        let ok = v
            .verify_challenge(
                se_pub.clone(),
                "x25519-key".to_owned(),
                expected.clone(),
                resp.clone(),
            )
            .await;
        assert!(matches!(ok.verdict, TrustVerdict::SelfSigned));
        assert!(ok.status_fields_bound);

        // SIP=false always deroutes even when correctly signed.
        let mut sip_off = resp.clone();
        sip_off.sip_enabled = Some(false);
        let input = StatusCanonicalInput {
            nonce: expected.nonce.clone(),
            timestamp: expected.timestamp.clone(),
            rdma_disabled: Some(true),
            sip_enabled: Some(false),
            secure_boot_enabled: Some(true),
            ..Default::default()
        };
        sip_off.status_signature = sign_b64(&key, &signing::build_status_canonical(&input));
        let out = v
            .verify_challenge(
                se_pub.clone(),
                "x25519-key".to_owned(),
                expected.clone(),
                sip_off,
            )
            .await;
        assert!(matches!(out.verdict, TrustVerdict::Untrusted { .. }));

        // Nonce mismatch fails before any crypto.
        let mut wrong_nonce = resp.clone();
        wrong_nonce.nonce = "other".to_owned();
        let out = v
            .verify_challenge(
                se_pub.clone(),
                "x25519-key".to_owned(),
                expected.clone(),
                wrong_nonce,
            )
            .await;
        assert!(matches!(out.verdict, TrustVerdict::Untrusted { .. }));

        // A present-but-wrong status signature is tampering.
        let mut bad_status = resp;
        bad_status.binary_hash = "spoofed".to_owned();
        let out = v
            .verify_challenge(se_pub, "x25519-key".to_owned(), expected, bad_status)
            .await;
        assert!(matches!(out.verdict, TrustVerdict::Untrusted { .. }));
    }
}

//! Canonical serialization, digest, and signature domain for protocol-v2
//! signed terminals (plan §10.6, open decision §29.7 — resolved here).
//!
//! # Canonical form (`darkbloom-terminal-v2`)
//!
//! The canonical bytes are ONE compact JSON object with:
//! - keys sorted alphabetically (byte order), single level, no nesting;
//! - a fixed `"domain": "darkbloom-terminal-v2"` field for domain
//!   separation (a signature over a terminal can never verify as any other
//!   Darkbloom payload);
//! - integers as plain JSON numbers (all counters are u64 — no floats
//!   anywhere, so the encoding is exact and deterministic);
//! - 16-byte ids as canonical lowercase hyphenated UUID strings, 32-byte
//!   digests and the dispatch nonce as lowercase hex strings;
//! - `error_class` OMITTED when absent (omission is distinct from any
//!   present value, mirroring the status-canonical convention);
//! - checkpoint fields flattened with a `checkpoint_` prefix.
//!
//! Covered fields — the origin facts of the attempt:
//! `job_id`, `attempt_id`, `lease_id`, `dispatch_nonce`, `request_digest`,
//! `provider_id`, `model_id`, `origin_session_epoch`, `outcome`,
//! `error_class?`, `prompt_tokens`, `completion_tokens`, `reasoning_tokens`,
//! `generated_tokens`, `response_hash`, `checkpoint_sequence`,
//! `checkpoint_cumulative_completion_tokens`, `checkpoint_rolling_hash`.
//!
//! Deliberately NOT covered: `scope.session_epoch` and
//! `scope.coordinator_epoch`. Those fence *delivery* — a journaled terminal
//! is replayed across reconnects and coordinator epochs with the same
//! signature, so delivery-time values cannot be part of the signed content.
//!
//! The signature is ECDSA P-256 (Secure Enclave) over `SHA-256(canonical
//! bytes)` in ASN.1 DER, base64-encoded into
//! [`TerminalFrame::se_signature`] — the same signing primitive as the v1
//! challenge path. The terminal digest used for replay/conflict detection
//! (plan §12.8) is the same `SHA-256(canonical bytes)`.

use std::collections::BTreeMap;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::signing::{verify_signed_payload, SigningError};
use crate::json_v2::{FrameV2, FrameV2Error, TerminalDigest, TerminalFrame};

/// Domain-separation tag baked into every canonical terminal.
pub const TERMINAL_DOMAIN: &str = "darkbloom-terminal-v2";

/// Serializes the canonical signed content of a terminal. Fails only on the
/// structural violations [`FrameV2::validate`] would also reject (missing
/// lease, incoherent error class) so an invalid terminal can never acquire a
/// valid digest.
pub fn terminal_canonical_bytes(frame: &TerminalFrame) -> Result<Vec<u8>, FrameV2Error> {
    FrameV2::Terminal(frame.clone()).validate()?;
    let lease_id = frame
        .scope
        .lease_id
        .ok_or(FrameV2Error::MissingLease { frame: "terminal" })?;

    let mut m: BTreeMap<&'static str, Value> = BTreeMap::new();
    m.insert("domain", Value::String(TERMINAL_DOMAIN.to_owned()));
    m.insert("job_id", Value::String(frame.scope.job_id.to_string()));
    m.insert(
        "attempt_id",
        Value::String(frame.scope.attempt_id.to_string()),
    );
    m.insert("lease_id", Value::String(lease_id.to_string()));
    m.insert(
        "dispatch_nonce",
        Value::String(frame.scope.dispatch_nonce.to_string()),
    );
    m.insert(
        "request_digest",
        Value::String(frame.scope.request_digest.to_string()),
    );
    m.insert("provider_id", Value::String(frame.provider_id.clone()));
    m.insert("model_id", Value::String(frame.model_id.clone()));
    m.insert(
        "origin_session_epoch",
        Value::from(frame.origin_session_epoch.0),
    );
    m.insert("outcome", Value::String(frame.outcome.as_str().to_owned()));
    if let Some(class) = frame.error_class {
        m.insert("error_class", Value::String(class.as_str().to_owned()));
    }
    m.insert("prompt_tokens", Value::from(frame.usage.prompt_tokens));
    m.insert(
        "completion_tokens",
        Value::from(frame.usage.completion_tokens),
    );
    m.insert(
        "reasoning_tokens",
        Value::from(frame.usage.reasoning_tokens),
    );
    m.insert("generated_tokens", Value::from(frame.generated_tokens));
    m.insert(
        "response_hash",
        Value::String(frame.response_hash.to_string()),
    );
    m.insert(
        "checkpoint_sequence",
        Value::from(frame.checkpoint.sequence),
    );
    m.insert(
        "checkpoint_cumulative_completion_tokens",
        Value::from(frame.checkpoint.cumulative_completion_tokens),
    );
    m.insert(
        "checkpoint_rolling_hash",
        Value::String(frame.checkpoint.rolling_hash.to_string()),
    );
    Ok(serde_json::to_vec(&m).expect("canonical terminal map serialization cannot fail"))
}

/// `SHA-256(canonical bytes)`: the terminal identity used for replay
/// deduplication and conflict detection (plan §12.8).
pub fn terminal_digest(frame: &TerminalFrame) -> Result<TerminalDigest, FrameV2Error> {
    let canonical = terminal_canonical_bytes(frame)?;
    Ok(TerminalDigest(Sha256::digest(&canonical).into()))
}

/// Terminal signature verification failure.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TerminalVerifyError {
    #[error("terminal is structurally invalid: {0}")]
    InvalidFrame(#[from] FrameV2Error),
    #[error(transparent)]
    Signature(#[from] SigningError),
}

/// Verifies `se_signature` against the provider's Secure Enclave public key
/// (base64 raw P-256 point, same format as the v1 attestation path).
pub fn verify_terminal_signature(
    se_public_key_b64: &str,
    frame: &TerminalFrame,
) -> Result<(), TerminalVerifyError> {
    let canonical = terminal_canonical_bytes(frame)?;
    verify_signed_payload(se_public_key_b64, &frame.se_signature, &canonical)?;
    Ok(())
}

/// Signs the canonical terminal, returning the base64 DER signature for
/// [`TerminalFrame::se_signature`]. Provider-side / test-harness helper —
/// production providers sign inside the Secure Enclave.
pub fn sign_terminal(
    signing_key: &SigningKey,
    frame: &TerminalFrame,
) -> Result<String, FrameV2Error> {
    let canonical = terminal_canonical_bytes(frame)?;
    let signature: Signature = signing_key.sign(&canonical);
    Ok(BASE64.encode(signature.to_der().as_bytes()))
}

#[cfg(test)]
mod tests {
    use p256::ecdsa::SigningKey;

    use super::*;
    use crate::json_v2::{
        AttemptId, CoordinatorEpoch, DispatchNonce, ErrorClass, JobId, LeaseId, RequestDigest,
        RequestScope, ResponseHash, RollingHashCheckpoint, SessionEpoch, TerminalOutcome,
        TerminalUsage,
    };

    fn terminal() -> TerminalFrame {
        TerminalFrame {
            scope: RequestScope {
                job_id: JobId([1; 16]),
                attempt_id: AttemptId([2; 16]),
                lease_id: Some(LeaseId([3; 16])),
                session_epoch: SessionEpoch(99),
                coordinator_epoch: CoordinatorEpoch(100),
                dispatch_nonce: DispatchNonce([4; 16]),
                request_digest: RequestDigest([5; 32]),
            },
            provider_id: "prov-1".into(),
            model_id: "qwen-3-8b".into(),
            origin_session_epoch: SessionEpoch(42),
            outcome: TerminalOutcome::Completed,
            error_class: None,
            usage: TerminalUsage {
                prompt_tokens: 128,
                completion_tokens: 256,
                reasoning_tokens: 32,
            },
            generated_tokens: 260,
            response_hash: ResponseHash([6; 32]),
            checkpoint: RollingHashCheckpoint {
                sequence: 17,
                cumulative_completion_tokens: 256,
                rolling_hash: ResponseHash([7; 32]),
            },
            se_signature: String::new(),
        }
    }

    #[test]
    fn canonical_is_deterministic_and_excludes_delivery_epochs() {
        let a = terminal();
        let mut b = terminal();
        // Delivery-time fencing changes across replays…
        b.scope.session_epoch = SessionEpoch(12345);
        b.scope.coordinator_epoch = CoordinatorEpoch(9);
        // …but the canonical bytes (and digest) must not move.
        assert_eq!(
            terminal_canonical_bytes(&a).unwrap(),
            terminal_canonical_bytes(&b).unwrap()
        );
        assert_eq!(terminal_digest(&a).unwrap(), terminal_digest(&b).unwrap());
    }

    #[test]
    fn digest_moves_with_signed_fields() {
        let base = terminal_digest(&terminal()).unwrap();
        let mut changed = terminal();
        changed.usage.completion_tokens += 1;
        assert_ne!(terminal_digest(&changed).unwrap(), base);

        let mut changed = terminal();
        changed.outcome = TerminalOutcome::Cancelled;
        changed.error_class = Some(ErrorClass::Cancelled);
        assert_ne!(terminal_digest(&changed).unwrap(), base);
    }

    #[test]
    fn canonical_shape_is_pinned() {
        // Golden: any change to the canonicalization breaks cross-version
        // signature verification, so pin the exact bytes.
        let bytes = terminal_canonical_bytes(&terminal()).unwrap();
        let expected = concat!(
            r#"{"attempt_id":"02020202-0202-0202-0202-020202020202","#,
            r#""checkpoint_cumulative_completion_tokens":256,"#,
            r#""checkpoint_rolling_hash":"0707070707070707070707070707070707070707070707070707070707070707","#,
            r#""checkpoint_sequence":17,"#,
            r#""completion_tokens":256,"#,
            r#""dispatch_nonce":"04040404040404040404040404040404","#,
            r#""domain":"darkbloom-terminal-v2","#,
            r#""generated_tokens":260,"#,
            r#""job_id":"01010101-0101-0101-0101-010101010101","#,
            r#""lease_id":"03030303-0303-0303-0303-030303030303","#,
            r#""model_id":"qwen-3-8b","#,
            r#""origin_session_epoch":42,"#,
            r#""outcome":"completed","#,
            r#""prompt_tokens":128,"#,
            r#""provider_id":"prov-1","#,
            r#""reasoning_tokens":32,"#,
            r#""request_digest":"0505050505050505050505050505050505050505050505050505050505050505","#,
            r#""response_hash":"0606060606060606060606060606060606060606060606060606060606060606"}"#,
        );
        assert_eq!(std::str::from_utf8(&bytes).unwrap(), expected);
    }

    #[test]
    fn sign_verify_round_trip_and_tamper() {
        let key = SigningKey::from_slice(&[0x2a; 32]).unwrap();
        let pub_b64 = BASE64.encode(key.verifying_key().to_encoded_point(false).as_bytes());

        let mut frame = terminal();
        frame.se_signature = sign_terminal(&key, &frame).unwrap();
        verify_terminal_signature(&pub_b64, &frame).unwrap();

        // Tampering with a signed field after signing must fail.
        frame.generated_tokens += 1;
        assert!(matches!(
            verify_terminal_signature(&pub_b64, &frame).unwrap_err(),
            TerminalVerifyError::Signature(SigningError::VerificationFailed)
        ));
    }

    #[test]
    fn invalid_terminal_cannot_acquire_digest() {
        let mut frame = terminal();
        frame.scope.lease_id = None;
        assert!(matches!(
            terminal_digest(&frame).unwrap_err(),
            FrameV2Error::MissingLease { .. }
        ));
    }
}

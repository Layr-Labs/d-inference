//! Exact-byte registration attestation and SE/X25519 binding.

use std::{fmt, sync::Arc};

use base64::{Engine, engine::general_purpose::STANDARD};
use p256::ecdsa::{DerSignature, VerifyingKey, signature::Verifier};
use serde::Deserialize;
use subtle::ConstantTimeEq;
use thiserror::Error;

use crate::crypto::X25519PublicKey;

use super::TrustLevel;

const P256_PUBLIC_KEY_BASE64_LEN: usize = 88;
const MAX_P256_SIGNATURE_BASE64_LEN: usize = 128;

/// Parsed Secure Enclave P-256 public identity.
#[derive(Clone)]
pub struct P256PublicIdentity {
    encoded: Arc<str>,
    key: VerifyingKey,
}

impl P256PublicIdentity {
    /// Decodes canonical standard base64 containing SEC1 uncompressed P-256.
    pub fn from_base64(encoded: &str) -> Result<Self, RegistrationVerificationError> {
        if encoded.len() != P256_PUBLIC_KEY_BASE64_LEN {
            return Err(RegistrationVerificationError::InvalidSePublicKey);
        }
        let raw = STANDARD
            .decode(encoded)
            .map_err(|_| RegistrationVerificationError::InvalidSePublicKey)?;
        if STANDARD.encode(&raw) != encoded {
            return Err(RegistrationVerificationError::InvalidSePublicKey);
        }
        let uncompressed = match raw.len() {
            64 => {
                let mut point = Vec::with_capacity(65);
                point.push(0x04);
                point.extend_from_slice(&raw);
                point
            }
            65 if raw.first() == Some(&0x04) => raw,
            _ => return Err(RegistrationVerificationError::InvalidSePublicKey),
        };
        let key = VerifyingKey::from_sec1_bytes(&uncompressed)
            .map_err(|_| RegistrationVerificationError::InvalidSePublicKey)?;
        Ok(Self {
            encoded: Arc::from(encoded),
            key,
        })
    }

    /// Original canonical base64 accepted from the signed blob.
    #[must_use]
    pub fn as_base64(&self) -> &str {
        &self.encoded
    }

    /// Constant-time comparison of canonical encoded public identities.
    #[must_use]
    pub fn ct_eq(&self, other: &Self) -> bool {
        bool::from(self.encoded.as_bytes().ct_eq(other.encoded.as_bytes()))
    }
}

impl fmt::Debug for P256PublicIdentity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_tuple("P256PublicIdentity")
            .field(&self.encoded)
            .finish()
    }
}

/// Verified registration trust facts.
#[derive(Clone, Debug)]
pub struct RegistrationTrust {
    /// Initial cryptographic level; external MDM can upgrade it later.
    pub level: TrustLevel,
    /// Secure Enclave signing identity.
    pub se_public_key: P256PublicIdentity,
    /// Transport key signed into the exact attestation blob.
    pub x25519_public_key: X25519PublicKey,
    /// Optional stable hardware serial from valid signed evidence.
    pub serial_number: Option<Arc<str>>,
    /// Provider timestamp text carried by signed evidence.
    pub timestamp: Arc<str>,
}

#[derive(Deserialize)]
struct SignedAttestation<'a> {
    #[serde(borrow)]
    attestation: &'a serde_json::value::RawValue,
    signature: &'a str,
}

#[derive(Deserialize)]
struct AttestationBlob<'a> {
    #[serde(rename = "publicKey")]
    public_key: &'a str,
    #[serde(rename = "encryptionPublicKey")]
    encryption_public_key: &'a str,
    #[serde(default, rename = "serialNumber")]
    serial_number: &'a str,
    #[serde(rename = "secureEnclaveAvailable")]
    secure_enclave_available: bool,
    #[serde(rename = "sipEnabled")]
    sip_enabled: bool,
    #[serde(rename = "secureBootEnabled")]
    secure_boot_enabled: bool,
    timestamp: &'a str,
}

/// Verifies the signature over the nested raw JSON bytes and binds both keys.
pub fn verify_registration(
    exact_signed_attestation: &[u8],
    registered_x25519_key: X25519PublicKey,
) -> Result<RegistrationTrust, RegistrationVerificationError> {
    let signed: SignedAttestation<'_> = serde_json::from_slice(exact_signed_attestation)
        .map_err(|_| RegistrationVerificationError::MalformedAttestation)?;
    let blob: AttestationBlob<'_> = serde_json::from_str(signed.attestation.get())
        .map_err(|_| RegistrationVerificationError::MalformedBlob)?;
    let se_public_key = P256PublicIdentity::from_base64(blob.public_key)?;
    verify_signature(
        &se_public_key,
        signed.signature,
        signed.attestation.get().as_bytes(),
    )?;

    if !blob.secure_enclave_available {
        return Err(RegistrationVerificationError::SecureEnclaveUnavailable);
    }
    if !blob.sip_enabled {
        return Err(RegistrationVerificationError::SipDisabled);
    }
    if !blob.secure_boot_enabled {
        return Err(RegistrationVerificationError::SecureBootDisabled);
    }
    if blob.timestamp.is_empty() {
        return Err(RegistrationVerificationError::MissingTimestamp);
    }
    let attested_x25519 = X25519PublicKey::from_base64(blob.encryption_public_key)
        .map_err(|_| RegistrationVerificationError::InvalidX25519Key)?;
    if !bool::from(
        attested_x25519
            .as_bytes()
            .ct_eq(registered_x25519_key.as_bytes()),
    ) {
        return Err(RegistrationVerificationError::X25519BindingMismatch);
    }

    Ok(RegistrationTrust {
        level: TrustLevel::SelfSigned,
        se_public_key,
        x25519_public_key: attested_x25519,
        serial_number: (!blob.serial_number.is_empty()).then(|| Arc::from(blob.serial_number)),
        timestamp: Arc::from(blob.timestamp),
    })
}

/// Verifies canonical base64 strict-DER P-256 ECDSA over exact message bytes.
pub fn verify_signature(
    public_key: &P256PublicIdentity,
    signature_base64: &str,
    message: &[u8],
) -> Result<(), RegistrationVerificationError> {
    if signature_base64.is_empty() || signature_base64.len() > MAX_P256_SIGNATURE_BASE64_LEN {
        return Err(RegistrationVerificationError::InvalidSignature);
    }
    let signature_raw = STANDARD
        .decode(signature_base64)
        .map_err(|_| RegistrationVerificationError::InvalidSignature)?;
    if STANDARD.encode(&signature_raw) != signature_base64 {
        return Err(RegistrationVerificationError::InvalidSignature);
    }
    let signature = DerSignature::from_bytes(&signature_raw)
        .map_err(|_| RegistrationVerificationError::InvalidSignature)?;
    public_key
        .key
        .verify(message, &signature)
        .map_err(|_| RegistrationVerificationError::SignatureMismatch)
}

/// Registration evidence rejection.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum RegistrationVerificationError {
    /// Outer signed-attestation JSON is not the required shape.
    #[error("malformed signed registration attestation")]
    MalformedAttestation,
    /// Nested raw attestation blob cannot be decoded.
    #[error("malformed registration attestation blob")]
    MalformedBlob,
    /// SE public key is not a valid canonical P-256 point.
    #[error("invalid Secure Enclave P-256 public key")]
    InvalidSePublicKey,
    /// Signature is malformed or noncanonical.
    #[error("invalid Secure Enclave P-256 signature")]
    InvalidSignature,
    /// Signature does not cover the exact nested bytes.
    #[error("registration attestation signature mismatch")]
    SignatureMismatch,
    /// Signed evidence says no SE is available.
    #[error("Secure Enclave is unavailable")]
    SecureEnclaveUnavailable,
    /// Signed evidence says SIP is disabled.
    #[error("SIP is disabled")]
    SipDisabled,
    /// Signed evidence says Secure Boot is disabled.
    #[error("Secure Boot is disabled")]
    SecureBootDisabled,
    /// Freshness cannot be evaluated without provider timestamp text.
    #[error("registration attestation timestamp is missing")]
    MissingTimestamp,
    /// Signed transport key is malformed.
    #[error("invalid attested X25519 public key")]
    InvalidX25519Key,
    /// Registered transport key differs from SE-signed key.
    #[error("registered X25519 key is not bound to the Secure Enclave identity")]
    X25519BindingMismatch,
}

#[cfg(test)]
mod tests {
    use p256::{
        ecdsa::{DerSignature, SigningKey, signature::Signer},
        elliptic_curve::Generate,
    };

    use super::*;

    const X25519: &str = "3p7bfXt9wbTTW2HC7OQ1Nz+DQ8hbeGdNrfx+FG+IK08=";

    fn signed_attestation(key: &SigningKey, blob: &str) -> Vec<u8> {
        let signature: DerSignature = key.sign(blob.as_bytes());
        format!(
            r#"{{"signature":"{}","attestation":{blob}}}"#,
            STANDARD.encode(signature.as_bytes())
        )
        .into_bytes()
    }

    fn blob(public_key: &str, x25519: &str) -> String {
        format!(
            concat!(
                r#"{{ "encryptionPublicKey":"{x25519}", "publicKey":"{public_key}","#,
                r#" "secureBootEnabled":true, "secureEnclaveAvailable":true,"#,
                r#" "serialNumber":"SER-1", "sipEnabled":true,"#,
                r#" "timestamp":"2026-07-11T00:00:00Z" }}"#
            ),
            x25519 = x25519,
            public_key = public_key,
        )
    }

    #[test]
    fn exact_raw_p256_signature_binds_x25519_and_rejects_tamper() {
        let key = SigningKey::generate();
        let public_key = STANDARD.encode(key.verifying_key().to_sec1_point(false));
        let blob = blob(&public_key, X25519);
        let signed = signed_attestation(&key, &blob);
        let x25519 = X25519PublicKey::from_base64(X25519).expect("x25519");
        let trust = verify_registration(&signed, x25519).expect("valid exact bytes");
        assert_eq!(trust.level, TrustLevel::SelfSigned);
        assert_eq!(trust.serial_number.as_deref(), Some("SER-1"));

        let tampered = String::from_utf8(signed)
            .expect("utf8")
            .replace("SER-1", "SER-2");
        assert_eq!(
            verify_registration(tampered.as_bytes(), x25519).expect_err("tamper"),
            RegistrationVerificationError::SignatureMismatch
        );
        let wrong = X25519PublicKey::from_bytes([9; 32]).expect("nonzero");
        assert_eq!(
            verify_registration(&signed_attestation(&key, &blob), wrong).expect_err("key mismatch"),
            RegistrationVerificationError::X25519BindingMismatch
        );
    }
}

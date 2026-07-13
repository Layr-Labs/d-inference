//! Persistent P-256 authority for coordinator replay-fence proofs.

use std::{
    fmt,
    path::{Path, PathBuf},
};

use base64::{Engine, engine::general_purpose::STANDARD};
use darkbloom_coordinator_protocol::v2::{
    CoordinatorReplayFenceProof, Digest, ProviderId, ProviderProcessGenerationId,
    ReplayFenceProofId, SessionEpoch, TerminalSignature,
};
use p256::{
    ecdsa::{
        DerSignature, SigningKey, VerifyingKey,
        signature::{Signer, Verifier},
    },
    elliptic_curve::Generate,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

use super::epoch_store::{DurableFileError, read_json_if_exists, write_json_atomic};

const REPLAY_SIGNER_VERSION: u32 = 1;
const P256_PRIVATE_KEY_BASE64_LEN: usize = 44;
const P256_PUBLIC_KEY_BASE64_LEN: usize = 88;
const MAX_P256_DER_SIGNATURE_LEN: usize = 72;

#[derive(Deserialize, Serialize)]
struct ReplaySignerFile {
    version: u32,
    private_key: String,
}

impl Drop for ReplaySignerFile {
    fn drop(&mut self) {
        self.private_key.zeroize();
    }
}

/// Durable signing key whose public half is advertised in protocol-v2 ACKs.
pub struct ReplayProofSigner {
    path: PathBuf,
    signing_key: SigningKey,
}

impl ReplayProofSigner {
    /// Opens the existing signer or generates and fsyncs one before use.
    pub fn open(path: impl Into<PathBuf>) -> Result<Self, ReplaySignerError> {
        let path = path.into();
        let signing_key = match read_json_if_exists::<ReplaySignerFile>(&path)? {
            Some(file) => {
                if file.version != REPLAY_SIGNER_VERSION {
                    return Err(ReplaySignerError::UnsupportedVersion(file.version));
                }
                if file.private_key.len() != P256_PRIVATE_KEY_BASE64_LEN {
                    return Err(ReplaySignerError::InvalidPrivateKey);
                }
                let raw = Zeroizing::new(
                    STANDARD
                        .decode(&file.private_key)
                        .map_err(|_| ReplaySignerError::InvalidPrivateKey)?,
                );
                if raw.len() != 32 || STANDARD.encode(raw.as_slice()) != file.private_key {
                    return Err(ReplaySignerError::InvalidPrivateKey);
                }
                SigningKey::from_slice(raw.as_slice())
                    .map_err(|_| ReplaySignerError::InvalidPrivateKey)?
            }
            None => {
                let key = SigningKey::generate();
                let file = ReplaySignerFile {
                    version: REPLAY_SIGNER_VERSION,
                    private_key: STANDARD.encode(key.to_bytes()),
                };
                write_json_atomic(&path, &file)?;
                key
            }
        };
        Ok(Self { path, signing_key })
    }

    /// Canonical uncompressed public key for registration ACKs.
    #[must_use]
    pub fn public_key_base64(&self) -> String {
        STANDARD.encode(self.signing_key.verifying_key().to_sec1_point(false))
    }

    /// Creates and signs one provider/generation-scoped replay fence.
    #[must_use]
    pub fn sign(
        &self,
        provider_id: ProviderId,
        provider_process_generation: ProviderProcessGenerationId,
        through_session_epoch: SessionEpoch,
        coordinator_revision: u64,
    ) -> CoordinatorReplayFenceProof {
        let mut proof = CoordinatorReplayFenceProof {
            proof_id: ReplayFenceProofId::new(*Uuid::new_v4().as_bytes()),
            provider_id,
            provider_process_generation,
            through_session_epoch,
            coordinator_revision,
            proof_digest: Digest::default(),
            coordinator_signature: TerminalSignature::default(),
        };
        proof.proof_digest = proof.computed_digest();
        let signature: DerSignature = self.signing_key.sign(proof.proof_digest.as_bytes());
        proof.coordinator_signature = TerminalSignature::new(signature.as_bytes().to_vec());
        proof
    }

    /// Verifies a proof against this signer's public key.
    #[must_use]
    pub fn verify(&self, proof: &CoordinatorReplayFenceProof) -> bool {
        proof.digest_is_valid()
            && verify_replay_proof(&self.public_key_base64(), proof).unwrap_or(false)
    }

    /// Location of the persistent private key.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl fmt::Debug for ReplayProofSigner {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ReplayProofSigner")
            .field("path", &self.path)
            .field("public_key", &self.public_key_base64())
            .finish()
    }
}

/// Verifies a replay proof with a canonical uncompressed P-256 key.
pub fn verify_replay_proof(
    public_key_base64: &str,
    proof: &CoordinatorReplayFenceProof,
) -> Result<bool, ReplaySignerError> {
    if !proof.digest_is_valid() {
        return Ok(false);
    }
    if public_key_base64.len() != P256_PUBLIC_KEY_BASE64_LEN {
        return Err(ReplaySignerError::InvalidPublicKey);
    }
    let raw = STANDARD
        .decode(public_key_base64)
        .map_err(|_| ReplaySignerError::InvalidPublicKey)?;
    if raw.len() != 65 || raw.first() != Some(&0x04) || STANDARD.encode(&raw) != public_key_base64 {
        return Err(ReplaySignerError::InvalidPublicKey);
    }
    let key =
        VerifyingKey::from_sec1_bytes(&raw).map_err(|_| ReplaySignerError::InvalidPublicKey)?;
    if proof.coordinator_signature.is_empty()
        || proof.coordinator_signature.as_bytes().len() > MAX_P256_DER_SIGNATURE_LEN
    {
        return Err(ReplaySignerError::InvalidSignature);
    }
    let signature = DerSignature::from_bytes(proof.coordinator_signature.as_bytes())
        .map_err(|_| ReplaySignerError::InvalidSignature)?;
    Ok(key
        .verify(proof.proof_digest.as_bytes(), &signature)
        .is_ok())
}

/// Persistent replay signer failure.
#[derive(Debug, Error)]
pub enum ReplaySignerError {
    /// Stored private scalar is malformed.
    #[error("invalid replay-fence P-256 private key")]
    InvalidPrivateKey,
    /// Public verification point is malformed or noncanonical.
    #[error("invalid replay-fence P-256 public key")]
    InvalidPublicKey,
    /// Signature is not strict DER.
    #[error("invalid replay-fence P-256 signature")]
    InvalidSignature,
    /// Key file schema is not supported.
    #[error("unsupported replay signer version {0}")]
    UnsupportedVersion(u32),
    /// Durable key operation failed.
    #[error(transparent)]
    Durable(#[from] DurableFileError),
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    fn path() -> PathBuf {
        std::env::temp_dir().join(format!("darkbloom-replay-key-{}.json", Uuid::new_v4()))
    }

    #[test]
    fn p256_proof_survives_signer_restart_and_rejects_tamper() {
        let path = path();
        let signer = ReplayProofSigner::open(&path).expect("signer");
        let public = signer.public_key_base64();
        let proof = signer.sign(
            ProviderId::new([1; 16]),
            ProviderProcessGenerationId::new([2; 16]),
            SessionEpoch(9),
            17,
        );
        assert!(signer.verify(&proof));
        drop(signer);

        let restarted = ReplayProofSigner::open(&path).expect("restart");
        assert_eq!(restarted.public_key_base64(), public);
        assert!(restarted.verify(&proof));

        let mut tampered = proof;
        tampered.coordinator_revision += 1;
        tampered.proof_digest = tampered.computed_digest();
        assert!(!restarted.verify(&tampered));
        let _ = fs::remove_file(path);
    }
}

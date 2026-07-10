use std::collections::BTreeMap;

use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Deserializer, Serialize, Serializer, de};

use crate::{
    error::TerminalError,
    v2::{
        control::StructuredErrorClass,
        identity::{AttemptIdentity, ProviderId, ProviderProcessGenerationId},
    },
};

/// A SHA-256 digest encoded as standard padded base64 in JSON.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Digest([u8; 32]);

impl Digest {
    #[must_use]
    pub const fn new(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    #[must_use]
    pub const fn into_bytes(self) -> [u8; 32] {
        self.0
    }

    #[must_use]
    pub fn of(bytes: &[u8]) -> Self {
        Self(sha256(bytes))
    }
}

impl From<[u8; 32]> for Digest {
    fn from(value: [u8; 32]) -> Self {
        Self::new(value)
    }
}

impl Serialize for Digest {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&STANDARD.encode(self.0))
    }
}

impl<'de> Deserialize<'de> for Digest {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let encoded = String::deserialize(deserializer)?;
        let decoded = STANDARD.decode(encoded).map_err(de::Error::custom)?;
        let bytes: [u8; 32] = decoded.try_into().map_err(|value: Vec<u8>| {
            de::Error::custom(format!("digest has {} bytes", value.len()))
        })?;
        Ok(Self(bytes))
    }
}

/// An opaque provider signature encoded as standard padded base64 in JSON.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TerminalSignature(Vec<u8>);

impl TerminalSignature {
    #[must_use]
    pub fn new(bytes: Vec<u8>) -> Self {
        Self(bytes)
    }

    #[must_use]
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl Serialize for TerminalSignature {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&STANDARD.encode(&self.0))
    }
}

impl<'de> Deserialize<'de> for TerminalSignature {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let encoded = String::deserialize(deserializer)?;
        STANDARD
            .decode(encoded)
            .map(Self)
            .map_err(de::Error::custom)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TerminalOutcome {
    Completed,
    Cancelled,
    Error,
}

/// Canonical signed terminal emitted exactly once per v2 attempt.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderTerminal {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
    pub outcome: TerminalOutcome,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_class: Option<StructuredErrorClass>,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub reasoning_tokens: u64,
    pub response_hash: Digest,
    pub final_generated_tokens: u64,
    #[serde(alias = "rolling_hash_checkpoint")]
    pub rolling_digest: Digest,
    pub model: String,
    pub terminal_digest: Digest,
    #[serde(rename = "se_signature", alias = "signature")]
    pub signature: TerminalSignature,
}

impl ProviderTerminal {
    /// Returns the canonical unsigned bytes covered by `terminal_digest`.
    ///
    /// A sorted map pins field order. Signature and terminal digest are
    /// intentionally excluded, avoiding a recursive digest definition.
    pub fn canonical_bytes(&self) -> Result<Vec<u8>, serde_json::Error> {
        let mut fields = BTreeMap::new();
        fields.insert(
            "attempt_id",
            serde_json::to_value(self.identity.attempt_id)?,
        );
        fields.insert("completion_tokens", self.completion_tokens.into());
        if let Some(error_class) = self.error_class {
            fields.insert("error_class", serde_json::to_value(error_class)?);
        }
        fields.insert("final_generated_tokens", self.final_generated_tokens.into());
        fields.insert("lease_id", serde_json::to_value(self.identity.lease_id)?);
        fields.insert("model", self.model.clone().into());
        fields.insert("outcome", serde_json::to_value(self.outcome)?);
        fields.insert("prompt_tokens", self.prompt_tokens.into());
        fields.insert(
            "provider_id",
            serde_json::to_value(self.identity.provider_id)?,
        );
        fields.insert(
            "provider_process_generation",
            serde_json::to_value(self.identity.provider_process_generation)?,
        );
        if self.reasoning_tokens != 0 {
            fields.insert("reasoning_tokens", self.reasoning_tokens.into());
        }
        fields.insert(
            "request_id",
            serde_json::to_value(self.identity.request_id)?,
        );
        fields.insert(
            "reservation_id",
            serde_json::to_value(self.identity.reservation_id)?,
        );
        fields.insert("response_hash", serde_json::to_value(self.response_hash)?);
        fields.insert("rolling_digest", serde_json::to_value(self.rolling_digest)?);
        fields.insert("session_epoch", self.identity.session_epoch.0.into());
        serde_json::to_vec(&fields)
    }

    pub fn computed_digest(&self) -> Result<Digest, serde_json::Error> {
        self.canonical_bytes().map(|bytes| Digest::of(&bytes))
    }

    /// Validates all attempt identity fields, the canonical digest, and that
    /// the signature verifies for this exact provider process identity.
    pub fn validate_with<F>(
        &self,
        expected: &AttemptIdentity,
        verify_signature: F,
    ) -> Result<(), TerminalError>
    where
        F: FnOnce(ProviderId, ProviderProcessGenerationId, &Digest, &[u8]) -> bool,
    {
        if &self.identity != expected {
            return Err(TerminalError::IdentityMismatch);
        }
        if self.computed_digest().ok().as_ref() != Some(&self.terminal_digest) {
            return Err(TerminalError::DigestMismatch);
        }
        if self.signature.is_empty() {
            return Err(TerminalError::MissingSignature);
        }
        if !verify_signature(
            self.identity.provider_id,
            self.identity.provider_process_generation,
            &self.terminal_digest,
            self.signature.as_bytes(),
        ) {
            return Err(TerminalError::SignatureIdentityMismatch);
        }
        Ok(())
    }
}

pub type ProviderTerminalMessage = ProviderTerminal;
pub type Signature = TerminalSignature;

const fn is_zero(value: &u64) -> bool {
    *value == 0
}

// Small self-contained SHA-256 implementation keeps the protocol digest
// contract independent of application crates and additional dependencies.
fn sha256(input: &[u8]) -> [u8; 32] {
    const INITIAL: [u32; 8] = [
        0x6a09_e667,
        0xbb67_ae85,
        0x3c6e_f372,
        0xa54f_f53a,
        0x510e_527f,
        0x9b05_688c,
        0x1f83_d9ab,
        0x5be0_cd19,
    ];
    const ROUND: [u32; 64] = [
        0x428a_2f98,
        0x7137_4491,
        0xb5c0_fbcf,
        0xe9b5_dba5,
        0x3956_c25b,
        0x59f1_11f1,
        0x923f_82a4,
        0xab1c_5ed5,
        0xd807_aa98,
        0x1283_5b01,
        0x2431_85be,
        0x550c_7dc3,
        0x72be_5d74,
        0x80de_b1fe,
        0x9bdc_06a7,
        0xc19b_f174,
        0xe49b_69c1,
        0xefbe_4786,
        0x0fc1_9dc6,
        0x240c_a1cc,
        0x2de9_2c6f,
        0x4a74_84aa,
        0x5cb0_a9dc,
        0x76f9_88da,
        0x983e_5152,
        0xa831_c66d,
        0xb003_27c8,
        0xbf59_7fc7,
        0xc6e0_0bf3,
        0xd5a7_9147,
        0x06ca_6351,
        0x1429_2967,
        0x27b7_0a85,
        0x2e1b_2138,
        0x4d2c_6dfc,
        0x5338_0d13,
        0x650a_7354,
        0x766a_0abb,
        0x81c2_c92e,
        0x9272_2c85,
        0xa2bf_e8a1,
        0xa81a_664b,
        0xc24b_8b70,
        0xc76c_51a3,
        0xd192_e819,
        0xd699_0624,
        0xf40e_3585,
        0x106a_a070,
        0x19a4_c116,
        0x1e37_6c08,
        0x2748_774c,
        0x34b0_bcb5,
        0x391c_0cb3,
        0x4ed8_aa4a,
        0x5b9c_ca4f,
        0x682e_6ff3,
        0x748f_82ee,
        0x78a5_636f,
        0x84c8_7814,
        0x8cc7_0208,
        0x90be_fffa,
        0xa450_6ceb,
        0xbef9_a3f7,
        0xc671_78f2,
    ];

    let bit_len = (input.len() as u64).wrapping_mul(8);
    let padded_len = input.len().saturating_add(9).div_ceil(64) * 64;
    let mut padded = vec![0_u8; padded_len];
    padded[..input.len()].copy_from_slice(input);
    padded[input.len()] = 0x80;
    padded[padded_len - 8..].copy_from_slice(&bit_len.to_be_bytes());

    let mut state = INITIAL;
    for block in padded.chunks_exact(64) {
        let mut schedule = [0_u32; 64];
        for (index, word) in block.chunks_exact(4).enumerate() {
            schedule[index] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for index in 16..64 {
            let s0 = schedule[index - 15].rotate_right(7)
                ^ schedule[index - 15].rotate_right(18)
                ^ (schedule[index - 15] >> 3);
            let s1 = schedule[index - 2].rotate_right(17)
                ^ schedule[index - 2].rotate_right(19)
                ^ (schedule[index - 2] >> 10);
            schedule[index] = schedule[index - 16]
                .wrapping_add(s0)
                .wrapping_add(schedule[index - 7])
                .wrapping_add(s1);
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = state;
        for index in 0..64 {
            let sum1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choice = (e & f) ^ (!e & g);
            let temp1 = h
                .wrapping_add(sum1)
                .wrapping_add(choice)
                .wrapping_add(ROUND[index])
                .wrapping_add(schedule[index]);
            let sum0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = sum0.wrapping_add(majority);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        for (current, compressed) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *current = current.wrapping_add(compressed);
        }
    }

    let mut output = [0_u8; 32];
    for (chunk, word) in output.chunks_exact_mut(4).zip(state) {
        chunk.copy_from_slice(&word.to_be_bytes());
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_matches_standard_vector() {
        assert_eq!(
            STANDARD.encode(Digest::of(b"abc").as_bytes()),
            "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0="
        );
    }
}

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

pub const CONTRACT_DOMAIN: &[u8] = b"darkbloom.prompt-contract.v1";
pub const NORMALIZATION_VERSION: &str = "darkbloom-request-normalization-v2";
pub const RENDERER_VERSION: &str = "swift-jinja-compatible-v1";
pub const TOKENIZER_VERSION: &str = "huggingface-tokenizer-json-v1";
pub const BLOCK_HASH_VERSION: &str = "darkbloom-block-chain-v1";
pub const BLOCK_SIZE: u32 = 256;
pub const METADATA_FILE: &str = "prompt-contract.json";
pub const PROMPT_ROLES: [&str; 3] = ["config", "template", "tokenizer"];

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PromptArtifact {
    pub path: String,
    pub role: String,
    pub size_bytes: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ContractVersions {
    pub normalization: String,
    pub renderer: String,
    pub tokenizer: String,
    pub block_hash: String,
    pub block_size: u32,
}

impl Default for ContractVersions {
    fn default() -> Self {
        Self {
            normalization: NORMALIZATION_VERSION.to_owned(),
            renderer: RENDERER_VERSION.to_owned(),
            tokenizer: TOKENIZER_VERSION.to_owned(),
            block_hash: BLOCK_HASH_VERSION.to_owned(),
            block_size: BLOCK_SIZE,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ContractMetadata {
    pub schema_version: u32,
    pub prompt_contract_id: String,
    pub model_id: String,
    #[serde(default)]
    pub model_type: Option<String>,
    pub model_aggregate_sha256: String,
    pub artifacts: Vec<PromptArtifact>,
    pub versions: ContractVersions,
}

#[derive(Debug, Error)]
pub enum ContractError {
    #[error("prompt contract contains an invalid artifact role")]
    InvalidRole,
    #[error("prompt contract contains an invalid artifact path")]
    InvalidPath,
    #[error("prompt contract contains an invalid SHA-256 digest")]
    InvalidDigest,
    #[error("prompt contract field is too large")]
    FieldTooLarge,
    #[error("prompt contract contains too many artifacts")]
    TooManyArtifacts,
    #[error("prompt contract contains no prompt artifacts")]
    EmptyArtifacts,
    #[error("prompt contract uses unsupported semantic versions")]
    UnsupportedVersions,
}

pub fn is_prompt_role(role: &str) -> bool {
    PROMPT_ROLES.contains(&role)
}

pub fn validate_relative_path(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.contains('\\')
        && path
            .split('/')
            .all(|component| !component.is_empty() && component != "." && component != "..")
}

pub fn compute_contract_id(
    artifacts: &[PromptArtifact],
    versions: &ContractVersions,
) -> Result<String, ContractError> {
    if versions != &ContractVersions::default() {
        return Err(ContractError::UnsupportedVersions);
    }
    let mut sorted = artifacts.to_vec();
    sorted.sort_by(|a, b| (&a.role, &a.path, &a.sha256).cmp(&(&b.role, &b.path, &b.sha256)));
    if sorted.is_empty() {
        return Err(ContractError::EmptyArtifacts);
    }
    let count = u32::try_from(sorted.len()).map_err(|_| ContractError::TooManyArtifacts)?;

    let mut encoded = Vec::new();
    push_field(&mut encoded, CONTRACT_DOMAIN)?;
    encoded.extend_from_slice(&count.to_be_bytes());
    for artifact in &sorted {
        if !is_prompt_role(&artifact.role) {
            return Err(ContractError::InvalidRole);
        }
        if !validate_relative_path(&artifact.path) {
            return Err(ContractError::InvalidPath);
        }
        push_field(&mut encoded, artifact.role.as_bytes())?;
        push_field(&mut encoded, artifact.path.as_bytes())?;
        let digest = hex::decode(&artifact.sha256).map_err(|_| ContractError::InvalidDigest)?;
        if digest.len() != 32 || artifact.sha256.bytes().any(|b| b.is_ascii_uppercase()) {
            return Err(ContractError::InvalidDigest);
        }
        push_field(&mut encoded, &digest)?;
    }
    for (name, value) in [
        ("normalization", versions.normalization.as_str()),
        ("renderer", versions.renderer.as_str()),
        ("tokenizer", versions.tokenizer.as_str()),
        ("block_hash", versions.block_hash.as_str()),
    ] {
        push_field(&mut encoded, name.as_bytes())?;
        push_field(&mut encoded, value.as_bytes())?;
    }
    push_field(&mut encoded, b"block_size")?;
    encoded.extend_from_slice(&versions.block_size.to_be_bytes());
    Ok(hex::encode(Sha256::digest(encoded)))
}

fn push_field(out: &mut Vec<u8>, value: &[u8]) -> Result<(), ContractError> {
    let len = u32::try_from(value.len()).map_err(|_| ContractError::FieldTooLarge)?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn artifact(path: &str, role: &str, byte: u8) -> PromptArtifact {
        PromptArtifact {
            path: path.into(),
            role: role.into(),
            size_bytes: 1,
            sha256: hex::encode([byte; 32]),
        }
    }

    #[test]
    fn contract_id_is_order_independent_and_semantically_bound() {
        let versions = ContractVersions::default();
        let a = vec![
            artifact("tokenizer.json", "tokenizer", 1),
            artifact("config.json", "config", 2),
        ];
        let b = vec![a[1].clone(), a[0].clone()];
        assert_eq!(
            compute_contract_id(&a, &versions).unwrap(),
            compute_contract_id(&b, &versions).unwrap()
        );

        let mut changed = a;
        changed[0].sha256 = hex::encode([3; 32]);
        assert_ne!(
            compute_contract_id(&changed, &versions).unwrap(),
            compute_contract_id(&b, &versions).unwrap()
        );
    }

    #[test]
    fn rejects_non_prompt_roles_and_unsafe_paths() {
        let versions = ContractVersions::default();
        assert!(matches!(
            compute_contract_id(&[], &versions),
            Err(ContractError::EmptyArtifacts)
        ));
        assert!(matches!(
            compute_contract_id(&[artifact("weights.bin", "weight", 1)], &versions),
            Err(ContractError::InvalidRole)
        ));
        assert!(matches!(
            compute_contract_id(&[artifact("../tokenizer.json", "tokenizer", 1)], &versions),
            Err(ContractError::InvalidPath)
        ));
    }
}

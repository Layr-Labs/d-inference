use promptsidecar::contract::{ContractVersions, PromptArtifact, compute_contract_id};
use promptsidecar::hash;
use serde::{Deserialize, de::DeserializeOwned};
use std::path::PathBuf;

#[derive(Deserialize)]
struct Corpus {
    block_hash_version: String,
    vectors: Vec<Vector>,
}

#[derive(Deserialize)]
struct Vector {
    contract_id: String,
    scope_id: String,
    block_index: u32,
    parent_hash: String,
    token_start: u32,
    token_count: u32,
    expected_hash: String,
}

#[derive(Deserialize)]
struct ContractCorpus {
    vectors: Vec<ContractVector>,
}

#[derive(Deserialize)]
struct ContractVector {
    artifacts: Vec<PromptArtifact>,
    expected_prompt_contract_id: String,
}

#[test]
fn shared_binary_hash_vectors_match() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures/prompt-contract/v1/block_hash_vectors.json");
    let corpus: Corpus = decode_fixture(&std::fs::read(path).unwrap()).unwrap();
    assert_eq!(corpus.block_hash_version, "darkbloom-block-chain-v1");
    for vector in corpus.vectors {
        let parent: [u8; 32] = hex::decode(vector.parent_hash).unwrap().try_into().unwrap();
        let tokens =
            (vector.token_start..vector.token_start + vector.token_count).collect::<Vec<_>>();
        let actual = hash::block_hash(
            vector.contract_id.as_bytes(),
            vector.scope_id.as_bytes(),
            &parent,
            vector.block_index,
            &tokens,
        )
        .unwrap();
        assert_eq!(hex::encode(actual), vector.expected_hash);
    }
}

#[test]
fn shared_contract_vectors_match() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures/prompt-contract/v1/contract_vectors.json");
    let corpus: ContractCorpus = decode_fixture(&std::fs::read(path).unwrap()).unwrap();
    for vector in corpus.vectors {
        assert_eq!(
            compute_contract_id(&vector.artifacts, &ContractVersions::default()).unwrap(),
            vector.expected_prompt_contract_id
        );
    }
}

#[test]
fn shared_vector_fixture_schema_version_is_required() {
    for encoded in [
        br#"{"vectors":[]}"#.as_slice(),
        br#"{"schema_version":2,"vectors":[]}"#.as_slice(),
    ] {
        assert!(decode_fixture::<ContractCorpus>(encoded).is_err());
    }
}

fn decode_fixture<T: DeserializeOwned>(encoded: &[u8]) -> Result<T, String> {
    let value: serde_json::Value =
        serde_json::from_slice(encoded).map_err(|error| error.to_string())?;
    match value
        .get("schema_version")
        .and_then(serde_json::Value::as_u64)
    {
        Some(1) => serde_json::from_value(value).map_err(|error| error.to_string()),
        Some(version) => Err(format!("unsupported fixture schema version {version}")),
        None => Err("fixture schema version is missing".to_owned()),
    }
}

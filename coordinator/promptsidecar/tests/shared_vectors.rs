use promptsidecar::api::PlanResponse;
use promptsidecar::contract::{ContractVersions, PromptArtifact, compute_contract_id};
use promptsidecar::hash;
use serde::Deserialize;
use std::collections::HashSet;
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

#[derive(Deserialize)]
struct ProductionCorpus {
    schema_version: u32,
    models: Vec<ProductionModel>,
}

#[derive(Deserialize)]
struct ProductionModel {
    model_id: String,
    prompt_contract_id: String,
    cache_routing_eligible: bool,
    ineligibility_reason: Option<String>,
    cases: Vec<ProductionCase>,
}

#[derive(Deserialize)]
struct ProductionCase {
    id: String,
    scope_id: String,
    plan: PlanResponse,
    token_ids: Vec<u32>,
}

#[test]
fn shared_binary_hash_vectors_match() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures/prompt-contract/v1/block_hash_vectors.json");
    let corpus: Corpus = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
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
    let corpus: ContractCorpus = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    for vector in corpus.vectors {
        assert_eq!(
            compute_contract_id(&vector.artifacts, &ContractVersions::default()).unwrap(),
            vector.expected_prompt_contract_id
        );
    }
}

#[test]
fn production_plans_match_shared_token_vectors() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures/prompt-contract/v1/production_vectors.json");
    let corpus: ProductionCorpus = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert_eq!(corpus.schema_version, 1);
    assert!(!corpus.models.is_empty());
    let mut model_ids = HashSet::new();
    for model in corpus.models {
        assert!(!model.model_id.is_empty());
        assert!(model_ids.insert(model.model_id.clone()));
        if !model.cache_routing_eligible {
            assert_eq!(model.ineligibility_reason.as_deref(), Some("dynamic_time"));
            assert!(model.cases.is_empty());
            continue;
        }
        assert!(model.ineligibility_reason.is_none());
        assert!(!model.cases.is_empty());
        let mut case_ids = HashSet::new();
        for fixture in model.cases {
            assert!(case_ids.insert(fixture.id));
            assert_eq!(fixture.plan.prompt_contract_id, model.prompt_contract_id);
            assert_eq!(
                fixture.plan.prompt_token_count as usize,
                fixture.token_ids.len()
            );
            let hashes = hash::chain_hashes(
                model.prompt_contract_id.as_bytes(),
                fixture.scope_id.as_bytes(),
                &fixture.token_ids,
                256,
            )
            .unwrap();
            let eligible = fixture.token_ids.len().saturating_sub(1) / 256;
            assert_eq!(fixture.plan.block_boundaries.len(), eligible);
            for (boundary, expected) in fixture.plan.block_boundaries.iter().zip(hashes.iter()) {
                assert_eq!(boundary.chain_hash, hex::encode(expected));
            }
            assert_eq!(
                fixture.plan.last_complete_block_hash,
                hashes
                    .get(eligible.checked_sub(1).unwrap_or(usize::MAX))
                    .map(hex::encode)
            );
        }
    }
}

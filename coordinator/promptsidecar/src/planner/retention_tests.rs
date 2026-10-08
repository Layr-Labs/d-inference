use super::*;
use crate::artifacts::LoadedArtifacts;
use crate::contract::{ContractMetadata, ContractVersions};
use serde_json::{Map, json};

fn contract(label: &str) -> LoadedContract {
    LoadedContract {
        artifacts: LoadedArtifacts {
            metadata: ContractMetadata {
                schema_version: 1,
                prompt_contract_id: label.into(),
                model_id: "test".into(),
                model_type: None,
                model_aggregate_sha256: String::new(),
                artifacts: vec![],
                versions: ContractVersions::default(),
            },
            tokenizer: Tokenizer::new(tokenizers::models::bpe::BPE::default()).into(),
            tokenizer_config: Map::new(),
            model_config: Map::new(),
            chat_template: json!(label),
        },
        templates: render::PreparedTemplates::default(),
    }
}

#[test]
fn compiled_program_retention_follows_contract_lru_and_active_workers() {
    let planner = Planner::new(PathBuf::new(), 1, 1, 1024);
    let request = normalize::normalize(
        json!({"model":"test","messages":[{"role":"user","content":"secret"}]})
            .as_object()
            .unwrap()
            .clone(),
        None,
    )
    .unwrap();
    let (first, _) = planner
        .cache
        .get_or_load("first", || Ok(contract("first")))
        .unwrap();
    assert_eq!(
        first.templates.render(&first.artifacts, &request).unwrap(),
        "first"
    );
    let weak = Arc::downgrade(&first);
    let (second, _) = planner
        .cache
        .get_or_load("second", || Ok(contract("second")))
        .unwrap();
    assert_eq!(planner.status().loaded_contracts, 1);
    // An evicted contract can finish an already admitted worker safely.
    assert_eq!(
        first.templates.render(&first.artifacts, &request).unwrap(),
        "first"
    );
    drop(first);
    assert!(
        weak.upgrade().is_none(),
        "an independent renderer cache retained the evicted contract"
    );
    assert_eq!(
        second
            .templates
            .render(&second.artifacts, &request)
            .unwrap(),
        "second"
    );
    let (reloaded, access) = planner
        .cache
        .get_or_load("first", || Ok(contract("first-new")))
        .unwrap();
    assert_eq!(access, CacheAccess::Cold);
    assert_eq!(
        reloaded
            .templates
            .render(&reloaded.artifacts, &request)
            .unwrap(),
        "first-new"
    );
    let weak = Arc::downgrade(&reloaded);
    drop(reloaded);
    drop(planner);
    assert!(
        weak.upgrade().is_none(),
        "compiled program outlived its final contract owner"
    );
}

use promptsidecar::api::{Endpoint, PlanRequest};
use promptsidecar::contract::{
    ContractMetadata, ContractVersions, PromptArtifact, compute_contract_id,
};
use promptsidecar::planner::Planner;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{fs, path::PathBuf};

#[tokio::test]
#[ignore = "requires NEMOTRON_TEMPLATE_MODEL_DIR with pinned prompt metadata"]
async fn nemotron_edge_corpus_matches_real_planner() {
    let source = PathBuf::from(std::env::var("NEMOTRON_TEMPLATE_MODEL_DIR").unwrap());
    let temp = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(temp.path()).unwrap();
    let mut artifacts = vec![];
    for (path, role) in [
        ("config.json", "config"),
        ("generation_config.json", "config"),
        ("tokenizer.json", "tokenizer"),
        ("tokenizer_config.json", "tokenizer"),
        ("chat_template.jinja", "template"),
    ] {
        let bytes = fs::read(source.join(path)).unwrap();
        artifacts.push(PromptArtifact {
            path: path.into(),
            role: role.into(),
            size_bytes: bytes.len() as u64,
            sha256: hex::encode(Sha256::digest(&bytes)),
        });
    }
    let versions = ContractVersions::default();
    let id = compute_contract_id(&artifacts, &versions).unwrap();
    let directory = root.join(&id);
    fs::create_dir(&directory).unwrap();
    for artifact in &artifacts {
        fs::copy(source.join(&artifact.path), directory.join(&artifact.path)).unwrap();
    }
    let metadata = ContractMetadata {
        schema_version: 1,
        prompt_contract_id: id.clone(),
        model_id: "nvidia-nemotron-3.5-lightning".into(),
        model_type: Some("nemotron_h".into()),
        model_aggregate_sha256: "0".repeat(64),
        artifacts,
        versions,
    };
    fs::write(
        directory.join("prompt-contract.json"),
        serde_json::to_vec(&metadata).unwrap(),
    )
    .unwrap();
    let planner = Planner::new(root, 1, 1, 1_000_000);
    let tokenizer = tokenizers::Tokenizer::from_file(source.join("tokenizer.json")).unwrap();
    let corpus: Value = serde_json::from_str(include_str!(
        "../../../provider-swift/Tests/ProviderCoreTests/Fixtures/nemotron-prompt-edge-corpus.json"
    ))
    .unwrap();
    let cases = corpus["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 7);
    for case in cases {
        let (plan, tokens, _, _) = planner
            .fixture_plan(PlanRequest {
                prompt_contract_id: id.clone(),
                scope_id: "review".into(),
                endpoint: Endpoint::ChatCompletions,
                body: case["body"].clone(),
            })
            .await
            .unwrap();
        let expected: Vec<u32> = serde_json::from_value(case["token_ids"].clone()).unwrap();
        assert_eq!(tokens, expected, "{}", case["name"]);
        assert_eq!(plan.prompt_token_count as usize, expected.len());
        assert_eq!(
            tokenizer.decode(&tokens, false).unwrap(),
            case["prompt"].as_str().unwrap()
        );
    }

    // Swift's typed Int decoder preserves the final digit of the decimal
    // spelling, while serde f64 rounds it down. Do not certify a false plan.
    let body: Value = serde_json::from_str(r#"{"model":"nvidia-nemotron-3.5-lightning",
        "messages":[{"role":"user","content":"number"}],
        "tools":[{"type":"function","function":{"name":"number","parameters":{
            "type":"object","properties":{"value":{"type":"number","enum":[9007199254740993.0]}}}}}]}"#).unwrap();
    let request = PlanRequest {
        prompt_contract_id: id,
        scope_id: "numeric-boundary".into(),
        endpoint: Endpoint::ChatCompletions,
        body,
    };
    assert!(matches!(
        planner.fixture_plan(request.clone()).await,
        Err(promptsidecar::planner::PlanError::Normalize)
    ));
    let mut exact = request;
    exact.body["tools"][0]["function"]["parameters"]["properties"]["value"]["enum"][0] =
        Value::from(9_007_199_254_740_993_i64);
    assert!(planner.fixture_plan(exact).await.is_ok());
}

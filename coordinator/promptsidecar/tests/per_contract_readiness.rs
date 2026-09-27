use promptsidecar::api::{Endpoint, PlanRequest};
use promptsidecar::contract::{
    ContractMetadata, ContractVersions, METADATA_FILE, PromptArtifact, compute_contract_id,
};
use promptsidecar::planner::{PlanError, Planner, Readiness};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use tempfile::TempDir;

// Both inputs have correct content hashes/contract metadata. The failed input
// is verified bytes that cannot construct a runtime tokenizer, not a bad hash.
#[tokio::test]
async fn partial_preload_keeps_healthy_contract_usable() {
    let fixture = ReadinessFixture::new();
    let healthy = fixture.contract("healthy", true);
    let unloadable = fixture.contract("unloadable", false);
    let planner = Planner::new(fixture.root(), 2, 8, 8192);
    planner.mark_starting();
    let report = planner
        .preload_contracts(vec![healthy.clone(), unloadable.clone()])
        .await
        .unwrap();
    assert!(!report.ready);
    assert_eq!(report.requested, 2);
    assert_eq!((report.cold, report.warm, report.failed), (1, 0, 1));
    let good_plan = planner.fixture_plan(fixture.request(&healthy)).await;
    let bad_plan = planner.plan(fixture.request(&unloadable)).await;
    assert!(matches!(bad_plan, Err(PlanError::NotReady)));
    let (plan, tokens, _, _) =
        good_plan.expect("unrelated failure must not suppress acknowledged A");
    assert_eq!(tokens, vec![1, 5, 2, 4, 5]);
    assert_eq!(plan.prompt_token_count, 5);
    assert_eq!(planner.readiness(), Readiness::Ready);
    let status = planner.status();
    assert!(status.ready);
    assert_eq!(status.status, "ok");
    assert_eq!(status.metrics.preloads.runs, 1);
    assert_eq!(status.metrics.preloads.failed, 1);
}

#[tokio::test]
async fn replacement_refuses_a_removed_contract_still_in_lru() {
    let fixture = ReadinessFixture::new();
    let old = fixture.contract("old", true);
    let replacement = fixture.contract("replacement", true);
    let planner = Planner::new(fixture.root(), 2, 8, 8192);
    assert!(
        planner
            .preload_contracts(vec![old.clone()])
            .await
            .unwrap()
            .ready
    );
    planner.plan(fixture.request(&old)).await.unwrap();
    assert!(
        planner
            .preload_contracts(vec![replacement.clone()])
            .await
            .unwrap()
            .ready
    );
    assert_eq!(
        planner.status().loaded_contracts,
        2,
        "fixture must retain old LRU bytes"
    );
    let before = planner.status().metrics.contract_loads;
    assert!(matches!(
        planner.plan(fixture.request(&old)).await,
        Err(PlanError::NotReady)
    ));
    let after = planner.status().metrics.contract_loads;
    assert_eq!(before.cold, after.cold);
    assert_eq!(
        before.warm, after.warm,
        "removed member must not reach its warm LRU entry"
    );
    planner.plan(fixture.request(&replacement)).await.unwrap();
}

struct ReadinessFixture(TempDir);

#[tokio::test]
async fn all_failed_replacement_stays_closed_then_recovers() {
    let fixture = ReadinessFixture::new();
    let healthy = fixture.contract("recoverable", true);
    let unloadable = fixture.contract("unloadable-only", false);
    let planner = Planner::new(fixture.root(), 2, 8, 8192);
    let report = planner
        .preload_contracts(vec![unloadable.clone()])
        .await
        .unwrap();
    assert!(!report.ready);
    assert_eq!((report.requested, report.failed), (1, 1));
    assert_eq!(planner.readiness(), Readiness::Degraded);
    assert_eq!(planner.status().status, "degraded");
    assert!(matches!(
        planner.plan(fixture.request(&healthy)).await,
        Err(PlanError::NotReady)
    ));
    assert!(
        planner
            .preload_contracts(vec![healthy.clone()])
            .await
            .unwrap()
            .ready
    );
    planner.plan(fixture.request(&healthy)).await.unwrap();
    assert!(matches!(
        planner.plan(fixture.request(&unloadable)).await,
        Err(PlanError::NotReady)
    ));
    let metrics = planner.status().metrics;
    assert_eq!((metrics.preloads.runs, metrics.preloads.failed), (2, 1));
}

#[tokio::test]
async fn rejected_requests_preserve_the_acknowledged_set() {
    let fixture = ReadinessFixture::new();
    let healthy = fixture.contract("preserved", true);
    let planner = Planner::new(fixture.root(), 2, 8, 8192);
    assert!(
        planner
            .preload_contracts(vec![healthy.clone()])
            .await
            .unwrap()
            .ready
    );
    for invalid in [
        vec![],
        vec![healthy.clone(), healthy.clone()],
        vec!["not-a-contract".into()],
    ] {
        assert!(planner.preload_contracts(invalid).await.is_err());
        assert_eq!(planner.readiness(), Readiness::Ready);
        planner.plan(fixture.request(&healthy)).await.unwrap();
    }
    assert_eq!(planner.status().metrics.preloads.runs, 1);
    assert_eq!(planner.status().metrics.preloads.failed, 0);
}

#[tokio::test]
async fn full_configured_capacity_accepts_eight_and_rejects_ninth_without_replacement() {
    let fixture = ReadinessFixture::new();
    let ids: Vec<_> = (0..9)
        .map(|i| fixture.contract(&format!("capacity-{i}"), true))
        .collect();
    let planner = Planner::new(fixture.root(), 2, 8, 8192);
    let report = planner.preload_contracts(ids[..8].to_vec()).await.unwrap();
    assert!(report.ready);
    assert_eq!(report.cold, 8);
    assert!(planner.preload_contracts(ids.clone()).await.is_err());
    assert_eq!(planner.status().loaded_contracts, 8);
    assert_eq!(planner.status().metrics.preloads.runs, 1);
    for id in &ids[..8] {
        planner.plan(fixture.request(id)).await.unwrap();
    }
    assert!(matches!(
        planner.plan(fixture.request(&ids[8])).await,
        Err(PlanError::NotReady)
    ));
    assert_eq!(planner.status().loaded_contracts, 8);
}

#[tokio::test]
async fn explicit_start_cannot_reenter_library_lazy_mode() {
    let fixture = ReadinessFixture::new();
    let healthy = fixture.contract("lazy-only-before-start", true);
    let planner = Planner::new(fixture.root(), 2, 8, 8192);
    planner.plan(fixture.request(&healthy)).await.unwrap(); // Library compatibility only.
    planner.mark_starting();
    assert_eq!(planner.readiness(), Readiness::Starting);
    assert!(matches!(
        planner.plan(fixture.request(&healthy)).await,
        Err(PlanError::NotReady)
    ));
    let failed = planner
        .preload_contracts(vec!["f".repeat(64)])
        .await
        .unwrap();
    assert!(!failed.ready);
    assert!(matches!(
        planner.plan(fixture.request(&healthy)).await,
        Err(PlanError::NotReady)
    ));
    assert_eq!(planner.status().metrics.contract_loads.warm, 0);
}

impl ReadinessFixture {
    fn new() -> Self {
        Self(TempDir::new().unwrap())
    }

    fn root(&self) -> PathBuf {
        fs::canonicalize(self.0.path()).unwrap()
    }

    fn contract(&self, variant: &str, loadable: bool) -> String {
        let tokenizer = if loadable {
            br#"{"version":"1.0","truncation":null,"padding":null,"added_tokens":[],"normalizer":null,"pre_tokenizer":{"type":"Whitespace"},"post_processor":null,"decoder":null,"model":{"type":"WordLevel","vocab":{"[UNK]":0,"user":1,"hello":2,"world":3,"assistant":4,":":5},"unk_token":"[UNK]"}}"#.to_vec()
        } else {
            br#"{"not_a_tokenizer":true}"#.to_vec()
        };
        write_contract(&self.root(), variant, tokenizer)
    }

    fn request(&self, contract: &str) -> PlanRequest {
        PlanRequest {
            prompt_contract_id: contract.into(),
            scope_id: "readiness-fixture-account".into(),
            endpoint: Endpoint::ChatCompletions,
            body: json!({"model":"fixture-model", "messages":[{"role":"user","content":"hello"}]}),
        }
    }
}

fn write_contract(root: &Path, variant: &str, tokenizer: Vec<u8>) -> String {
    let contents = [
        ("tokenizer.json", "tokenizer", tokenizer),
        ("tokenizer_config.json", "tokenizer",
            br#"{"chat_template":"{% for message in messages %}{{ message.role }}:{{ message.content }}\n{% endfor %}{% if add_generation_prompt %}assistant:{% endif %}"}"#.to_vec()),
        ("config.json", "config", format!(r#"{{"model_type":"fixture","variant":"{variant}"}}"#).into_bytes()),
    ];
    let artifacts: Vec<PromptArtifact> = contents
        .iter()
        .map(|(path, role, bytes)| PromptArtifact {
            path: (*path).into(),
            role: (*role).into(),
            size_bytes: bytes.len() as u64,
            sha256: hex::encode(Sha256::digest(bytes)),
        })
        .collect();
    let id = compute_contract_id(&artifacts, &ContractVersions::default()).unwrap();
    let directory = root.join(&id);
    fs::create_dir(&directory).unwrap();
    for (path, _, bytes) in contents {
        fs::write(directory.join(path), bytes).unwrap();
    }
    let metadata = ContractMetadata {
        schema_version: 1,
        prompt_contract_id: id.clone(),
        model_id: "fixture-model".into(),
        model_type: Some("fixture".into()),
        model_aggregate_sha256: hex::encode([0; 32]),
        artifacts,
        versions: ContractVersions::default(),
    };
    fs::write(
        directory.join(METADATA_FILE),
        serde_json::to_vec(&metadata).unwrap(),
    )
    .unwrap();
    id
}

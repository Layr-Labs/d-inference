//! Opt-in local performance evidence; no downloads or network services.
//! Set PROMPT_BENCH_MODEL_ROOT to immutable model artifacts and run in release
//! mode with --ignored --nocapture --test-threads=1 on both comparison commits.
use promptsidecar::api::{Endpoint, PlanRequest};
use promptsidecar::contract::{
    ContractMetadata, ContractVersions, METADATA_FILE, PromptArtifact, compute_contract_id,
};
use promptsidecar::planner::Planner;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::alloc::{GlobalAlloc, Layout, System};
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Instant;

struct CountAllocations;
static TRACK_ALLOCATIONS: AtomicBool = AtomicBool::new(true);
static ALLOCATIONS: AtomicU64 = AtomicU64::new(0);
static ALLOCATED_BYTES: AtomicU64 = AtomicU64::new(0);
#[global_allocator]
static ALLOCATOR: CountAllocations = CountAllocations;
unsafe impl GlobalAlloc for CountAllocations {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if TRACK_ALLOCATIONS.load(Ordering::Relaxed) {
            ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
            ALLOCATED_BYTES.fetch_add(layout.size() as u64, Ordering::Relaxed);
        }
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        if TRACK_ALLOCATIONS.load(Ordering::Relaxed) {
            ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
            ALLOCATED_BYTES.fetch_add(size as u64, Ordering::Relaxed);
        }
        unsafe { System.realloc(ptr, layout, size) }
    }
}

#[tokio::test]
#[ignore = "requires opt-in local model artifacts and release mode"]
async fn measure_real_template_planning() {
    let source = PathBuf::from(std::env::var_os("PROMPT_BENCH_MODEL_ROOT").expect("model root"));
    let directory = tempfile::TempDir::new().unwrap();
    let mut files = Vec::new();
    for (path, role) in [
        ("tokenizer.json", "tokenizer"),
        ("tokenizer_config.json", "tokenizer"),
        ("config.json", "config"),
        ("chat_template.jinja", "template"),
    ] {
        let bytes = fs::read(source.join(path)).unwrap();
        files.push((path, bytes, role));
    }
    let artifacts = files
        .iter()
        .map(|(path, bytes, role)| PromptArtifact {
            path: (*path).into(),
            role: (*role).into(),
            size_bytes: bytes.len() as u64,
            sha256: hex::encode(Sha256::digest(bytes)),
        })
        .collect::<Vec<_>>();
    let versions = ContractVersions::default();
    let contract_id = compute_contract_id(&artifacts, &versions).unwrap();
    let config: serde_json::Value = serde_json::from_slice(&files[2].1).unwrap();
    let model_type = config["model_type"].as_str().unwrap().to_owned();
    let model = std::env::var("PROMPT_BENCH_MODEL_ID").unwrap_or_else(|_| model_type.clone());
    let metadata = ContractMetadata {
        schema_version: 1,
        prompt_contract_id: contract_id.clone(),
        model_id: model.clone(),
        model_type: Some(model_type),
        model_aggregate_sha256: "0".repeat(64),
        artifacts,
        versions,
    };
    let root = directory.path().join(&contract_id);
    fs::create_dir(&root).unwrap();
    for (path, bytes, _) in files {
        fs::write(root.join(path), bytes).unwrap();
    }
    fs::write(
        root.join(METADATA_FILE),
        serde_json::to_vec(&metadata).unwrap(),
    )
    .unwrap();
    let planner = Arc::new(Planner::new(
        fs::canonicalize(directory.path()).unwrap(),
        32,
        1,
        200_000,
    ));
    let text = "Review this private synthetic performance fixture. Explain the main idea clearly. ";
    let mut burst_cases = Vec::new();
    for (name, repeats, with_tools) in [
        ("short", 2, false),
        ("tools", 2, true),
        ("long", 512, false),
        ("wide", 4096, false),
    ] {
        let mut body = json!({"model":model, "messages":[{"role":"user","content":text.repeat(repeats)}],
            "reasoning":{"enabled":false}, "_darkbloom_prompt_date":"2026-10-03"});
        if with_tools {
            let mut properties = serde_json::Map::new();
            for i in 0..64 {
                properties.insert(
                    format!("field_{i}"),
                    json!({"type":"string","description":"A synthetic value"}),
                );
            }
            body["tools"] = json!([{"type":"function", "function":{"name":"collect","description":"Collect synthetic values",
                "parameters":{"type":"object","properties":properties}}}]);
        }
        let request = PlanRequest {
            prompt_contract_id: contract_id.clone(),
            scope_id: "local-performance-evidence".into(),
            endpoint: Endpoint::ChatCompletions,
            body,
        };
        let expected = planner.fixture_plan(request.clone()).await.unwrap().0;
        let fingerprint = hex::encode(Sha256::digest(serde_json::to_vec(&expected).unwrap()));
        for _ in 0..20 {
            assert_plan(&planner.plan(request.clone()).await.unwrap(), &expected);
        }
        let count = if name == "wide" { 50 } else { 250 };
        let allocations = ALLOCATIONS.load(Ordering::Relaxed);
        let bytes = ALLOCATED_BYTES.load(Ordering::Relaxed);
        let mut samples = Vec::with_capacity(count);
        for _ in 0..count {
            let start = Instant::now();
            assert_plan(&planner.plan(request.clone()).await.unwrap(), &expected);
            samples.push(start.elapsed());
        }
        let allocations = ALLOCATIONS.load(Ordering::Relaxed) - allocations;
        let bytes = ALLOCATED_BYTES.load(Ordering::Relaxed) - bytes;
        samples.sort();
        eprintln!(
            "planner_perf model={model} case={name} fingerprint={fingerprint} tokens={} samples={count} p50_us={} p95_us={} p99_us={} allocations_per_plan={} allocated_bytes_per_plan={}",
            expected.prompt_token_count,
            samples[count / 2].as_micros(),
            samples[count * 95 / 100].as_micros(),
            samples[count * 99 / 100].as_micros(),
            allocations / count as u64,
            bytes / count as u64
        );
        if name != "wide" {
            burst_cases.push((request, Arc::new(expected)));
        }
    }
    // Measure synchronized mixed bursts without contended allocation counters.
    // This mirrors the Go HTTP gate's 16-way bound, retaining Rust worker limits.
    TRACK_ALLOCATIONS.store(false, Ordering::Relaxed);
    for (request, expected) in &burst_cases {
        assert_plan(&planner.plan(request.clone()).await.unwrap(), expected);
    }
    let mut samples = Vec::new();
    let mut batches = Vec::new();
    for _ in 0..128 {
        let barrier = Arc::new(tokio::sync::Barrier::new(16));
        let start = Instant::now();
        let tasks = (0..16)
            .map(|i| {
                let planner = planner.clone();
                let barrier = barrier.clone();
                let (request, expected) = &burst_cases[i % burst_cases.len()];
                let request = request.clone();
                let expected = expected.clone();
                tokio::spawn(async move {
                    barrier.wait().await;
                    let start = Instant::now();
                    assert_plan(&planner.plan(request).await.unwrap(), &expected);
                    start.elapsed()
                })
            })
            .collect::<Vec<_>>();
        for task in tasks {
            samples.push(task.await.unwrap());
        }
        batches.push(start.elapsed());
    }
    samples.sort();
    batches.sort();
    eprintln!(
        "planner_burst model={model} width=16 mixed=short,tools,long batches=128 p50_us={} p95_us={} p99_us={} batch_p50_us={} batch_p95_us={}",
        samples[samples.len() / 2].as_micros(),
        samples[samples.len() * 95 / 100].as_micros(),
        samples[samples.len() * 99 / 100].as_micros(),
        batches[batches.len() / 2].as_micros(),
        batches[batches.len() * 95 / 100].as_micros()
    );
}

fn assert_plan(
    actual: &promptsidecar::api::PlanResponse,
    expected: &promptsidecar::api::PlanResponse,
) {
    assert_eq!(actual.prompt_contract_id, expected.prompt_contract_id);
    assert_eq!(actual.prompt_token_count, expected.prompt_token_count);
    assert_eq!(
        actual.last_complete_block_hash,
        expected.last_complete_block_hash
    );
    assert_eq!(
        actual.block_boundaries.len(),
        expected.block_boundaries.len()
    );
    for (a, b) in actual
        .block_boundaries
        .iter()
        .zip(&expected.block_boundaries)
    {
        assert_eq!(a.token_count, b.token_count);
        assert_eq!(a.chain_hash, b.chain_hash);
    }
}

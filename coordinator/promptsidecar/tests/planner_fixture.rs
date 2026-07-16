use promptsidecar::api::{Endpoint, PlanRequest};
use promptsidecar::contract::{
    ContractMetadata, ContractVersions, METADATA_FILE, PromptArtifact, compute_contract_id,
};
use promptsidecar::planner::{PlanError, Planner};
use promptsidecar::server::{self, ServerConfig};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tempfile::TempDir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::oneshot;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn plans_with_real_tokenizer_and_bounds_concurrency() {
    let fixture = Fixture::new();
    let planner = Arc::new(Planner::new(fixture.root(), 1, 1, 200_000));
    let request = fixture.request("hello world");
    let plan = planner.plan(request).await.unwrap();
    assert!(plan.prompt_token_count > 0);
    assert!(plan.block_boundaries.is_empty());
    assert!(plan.last_complete_block_hash.is_none());
    assert!(
        !serde_json::to_value(&plan)
            .unwrap()
            .as_object()
            .unwrap()
            .contains_key("token_ids")
    );
    assert!(
        !serde_json::to_value(&plan)
            .unwrap()
            .as_object()
            .unwrap()
            .contains_key("normalized_body")
    );

    let large = fixture.request(&"hello ".repeat(100_000));
    let tasks = (0..16)
        .map(|_| {
            let planner = planner.clone();
            let request = large.clone();
            tokio::spawn(async move { planner.plan(request).await })
        })
        .collect::<Vec<_>>();
    let mut at_capacity = 0;
    for task in tasks {
        if matches!(task.await.unwrap(), Err(PlanError::AtCapacity)) {
            at_capacity += 1;
        }
    }
    assert!(at_capacity > 0);
}

#[tokio::test]
async fn measure_fixture_planning_latency() {
    let fixture = Fixture::new();
    let planner = Planner::new(fixture.root(), 1, 1, 200_000);
    let request = fixture.request(&"hello world ".repeat(128));
    for _ in 0..20 {
        planner.plan(request.clone()).await.unwrap();
    }
    let mut samples = Vec::with_capacity(1_000);
    for _ in 0..1_000 {
        let started = Instant::now();
        planner.plan(request.clone()).await.unwrap();
        samples.push(started.elapsed());
    }
    samples.sort();
    eprintln!(
        "fixture planner latency: samples=1000 p50_us={} p99_us={}",
        samples[500].as_micros(),
        samples[990].as_micros()
    );
    assert_latency_distribution(&samples);
}

#[tokio::test]
async fn measure_fixture_unix_http_latency() {
    let fixture = Fixture::new();
    fs::set_permissions(fixture._temp.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let socket = fixture.root().join("promptsidecar.sock");
    let planner = Planner::new(fixture.root(), 1, 1, 200_000);
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let server = tokio::spawn(server::run(
        ServerConfig {
            socket_path: socket.clone(),
            max_body_bytes: 4 << 20,
            header_read_timeout: Duration::from_secs(1),
            request_timeout: Duration::from_secs(1),
            max_connections: 4,
        },
        planner,
        async move {
            let _ = shutdown_rx.await;
        },
    ));
    let mut stream = loop {
        match UnixStream::connect(&socket).await {
            Ok(stream) => break stream,
            Err(_) if !server.is_finished() => tokio::time::sleep(Duration::from_millis(2)).await,
            Err(error) => panic!("Unix server did not start: {error}"),
        }
    };
    let body = serde_json::to_vec(&fixture.request(&"hello world ".repeat(128))).unwrap();
    for _ in 0..20 {
        let response = unix_plan_roundtrip(&mut stream, &body).await;
        serde_json::from_slice::<promptsidecar::api::PlanResponse>(&response).unwrap();
    }
    let mut samples = Vec::with_capacity(1_000);
    for _ in 0..1_000 {
        let started = Instant::now();
        let response = unix_plan_roundtrip(&mut stream, &body).await;
        serde_json::from_slice::<promptsidecar::api::PlanResponse>(&response).unwrap();
        samples.push(started.elapsed());
    }
    samples.sort();
    eprintln!(
        "fixture Unix HTTP latency: samples=1000 p50_us={} p99_us={}",
        samples[500].as_micros(),
        samples[990].as_micros()
    );
    assert_latency_distribution(&samples);
    drop(stream);
    let _ = shutdown_tx.send(());
    server.await.unwrap().unwrap();
}

fn assert_latency_distribution(samples: &[Duration]) {
    let p50 = samples[500];
    let p99 = samples[990];
    assert!(p50 > Duration::ZERO);
    assert!(
        p99 <= p50.saturating_mul(250),
        "p99 {p99:?} exceeded the distribution bound from p50 {p50:?}"
    );
    assert!(
        Duration::from_secs(1) >= p99.saturating_mul(16),
        "configured 1s deadline has less than a 16x p99 safety factor ({p99:?})"
    );
}

async fn unix_plan_roundtrip(stream: &mut UnixStream, body: &[u8]) -> Vec<u8> {
    let request = format!(
        "POST /v1/plan HTTP/1.1\r\nHost: promptsidecar\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n",
        body.len()
    );
    stream.write_all(request.as_bytes()).await.unwrap();
    stream.write_all(body).await.unwrap();

    let mut response = Vec::with_capacity(4096);
    let mut chunk = [0u8; 8192];
    let (header_end, content_length) = loop {
        let read = stream.read(&mut chunk).await.unwrap();
        assert!(
            read > 0,
            "Unix connection closed before a complete response"
        );
        response.extend_from_slice(&chunk[..read]);
        if let Some(header_end) = response.windows(4).position(|window| window == b"\r\n\r\n") {
            let header_end = header_end + 4;
            let headers = std::str::from_utf8(&response[..header_end]).unwrap();
            assert!(headers.starts_with("HTTP/1.1 200 "));
            let content_length = headers
                .lines()
                .find_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .map(str::trim)
                        .and_then(|value| value.parse::<usize>().ok())
                })
                .expect("response Content-Length");
            break (header_end, content_length);
        }
    };
    while response.len() < header_end + content_length {
        let read = stream.read(&mut chunk).await.unwrap();
        assert!(read > 0, "Unix connection closed during the response body");
        response.extend_from_slice(&chunk[..read]);
    }
    response[header_end..header_end + content_length].to_vec()
}

struct Fixture {
    _temp: TempDir,
    contract_id: String,
}

impl Fixture {
    fn new() -> Self {
        let temp = TempDir::new().unwrap();
        let contents = [
            ("tokenizer.json", "tokenizer", tokenizer_json()),
            (
                "tokenizer_config.json",
                "tokenizer",
                br#"{"chat_template":"{% for message in messages %}{{ message.role }}:{{ message.content }}\n{% endfor %}{% if add_generation_prompt %}assistant:{% endif %}"}"#.to_vec(),
            ),
            (
                "config.json",
                "config",
                br#"{"model_type":"fixture"}"#.to_vec(),
            ),
        ];
        let artifacts = contents
            .iter()
            .map(|(path, role, bytes)| PromptArtifact {
                path: (*path).into(),
                role: (*role).into(),
                size_bytes: bytes.len() as u64,
                sha256: hex::encode(Sha256::digest(bytes)),
            })
            .collect::<Vec<_>>();
        let contract_id = compute_contract_id(&artifacts, &ContractVersions::default()).unwrap();
        let directory = temp.path().join(&contract_id);
        fs::create_dir(&directory).unwrap();
        for (path, _, bytes) in contents {
            fs::write(directory.join(path), bytes).unwrap();
        }
        let metadata = ContractMetadata {
            schema_version: 1,
            prompt_contract_id: contract_id.clone(),
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
        Self {
            _temp: temp,
            contract_id,
        }
    }

    fn root(&self) -> std::path::PathBuf {
        std::fs::canonicalize(self._temp.path()).unwrap()
    }

    fn request(&self, content: &str) -> PlanRequest {
        PlanRequest {
            prompt_contract_id: self.contract_id.clone(),
            scope_id: "fixture-scope".into(),
            endpoint: Endpoint::ChatCompletions,
            body: json!({
                "model": "fixture-model",
                "messages": [{"role": "user", "content": content}]
            }),
        }
    }
}

fn tokenizer_json() -> Vec<u8> {
    br#"{
  "version": "1.0",
  "truncation": null,
  "padding": null,
  "added_tokens": [],
  "normalizer": null,
  "pre_tokenizer": {"type": "Whitespace"},
  "post_processor": null,
  "decoder": null,
  "model": {
    "type": "WordLevel",
    "vocab": {"[UNK]": 0, "user": 1, "hello": 2, "world": 3, "assistant": 4, ":": 5},
    "unk_token": "[UNK]"
  }
}"#
    .to_vec()
}

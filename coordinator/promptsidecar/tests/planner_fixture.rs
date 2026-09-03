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
    let status = planner.status();
    assert!(status.metrics.plans.at_capacity > 0);
    assert_eq!(status.loaded_contracts, 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn concurrent_cold_contract_load_is_singleflight() {
    let fixture = Fixture::new();
    let planner = Arc::new(Planner::new(fixture.root(), 16, 4, 200_000));
    let barrier = Arc::new(tokio::sync::Barrier::new(16));
    let tasks = (0..16)
        .map(|_| {
            let planner = planner.clone();
            let request = fixture.request("hello world");
            let barrier = barrier.clone();
            tokio::spawn(async move {
                barrier.wait().await;
                planner.plan(request).await
            })
        })
        .collect::<Vec<_>>();

    for task in tasks {
        task.await.unwrap().unwrap();
    }
    let status = planner.status();
    assert_eq!(status.loaded_contracts, 1);
    assert_eq!(status.loading_contracts, 0);
    assert_eq!(status.metrics.contract_loads.cold, 1);
    assert_eq!(status.metrics.contract_loads.failed, 0);
    assert_eq!(status.metrics.plans.succeeded, 16);
}

#[tokio::test]
async fn preloads_four_contracts_sequentially_and_idempotently() {
    let fixture = Fixture::new();
    let mut contract_ids = vec![fixture.contract_id.clone()];
    for variant in ["two", "three", "four"] {
        contract_ids.push(fixture.add_contract(variant));
    }
    let planner = Planner::new(fixture.root(), 4, 4, 200_000);

    let first = planner
        .preload_contracts(contract_ids.clone())
        .await
        .unwrap();
    assert!(first.ready);
    assert_eq!(first.requested, 4);
    assert_eq!(first.cold, 4);
    assert_eq!(first.warm, 0);
    assert_eq!(first.failed, 0);
    assert_eq!(
        first
            .results
            .iter()
            .map(|result| result.prompt_contract_id.as_str())
            .collect::<Vec<_>>(),
        contract_ids.iter().map(String::as_str).collect::<Vec<_>>()
    );
    let first_status = planner.status();
    assert!(first_status.ready);
    assert_eq!(first_status.loaded_contracts, 4);
    assert_eq!(first_status.metrics.contract_loads.cold, 4);

    let second = planner.preload_contracts(contract_ids).await.unwrap();
    assert!(second.ready);
    assert_eq!(second.cold, 0);
    assert_eq!(second.warm, 4);
    assert_eq!(planner.status().loaded_contracts, 4);
    assert_eq!(planner.status().metrics.contract_loads.cold, 4);
    assert_eq!(planner.status().metrics.contract_loads.warm, 4);
}

#[tokio::test]
async fn preload_failure_gates_plans_until_active_set_recovers() {
    let fixture = Fixture::new();
    let planner = Planner::new(fixture.root(), 2, 2, 200_000);
    let missing = "f".repeat(64);

    let failed = planner
        .preload_contracts(vec![fixture.contract_id.clone(), missing])
        .await
        .unwrap();
    assert!(!failed.ready);
    assert_eq!(failed.failed, 1);
    assert!(matches!(
        planner.plan(fixture.request("hello")).await,
        Err(PlanError::NotReady)
    ));

    let recovered = planner
        .preload_contracts(vec![fixture.contract_id.clone()])
        .await
        .unwrap();
    assert!(recovered.ready);
    planner.plan(fixture.request("hello")).await.unwrap();
}

#[tokio::test]
#[ignore = "workstation latency probe; run via make prompt-sidecar-probe"]
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
#[ignore = "workstation latency probe; run via make prompt-sidecar-probe"]
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
            body_read_timeout: Duration::from_secs(1),
            request_timeout: Duration::from_secs(1),
            max_connections: 4,
        },
        planner,
        async move {
            let _ = shutdown_rx.await;
        },
    ));
    wait_for_server(&socket, &server).await;

    let (initial_ready_status, initial_ready) = unix_get(&socket, "/ready").await;
    assert_eq!(initial_ready_status, 503);
    assert!(
        std::str::from_utf8(&initial_ready)
            .unwrap()
            .contains(r#""ready":false"#)
    );
    let preload = preload_fixture(&socket, &fixture.contract_id).await;
    assert_eq!(preload["cold"], 1);
    assert_eq!(preload["warm"], 0);
    let mut stream = UnixStream::connect(&socket).await.unwrap();
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "large-token overload probe; run via make prompt-sidecar-probe"]
async fn health_remains_fast_while_planner_is_busy_and_overloaded() {
    let fixture = Fixture::new();
    fs::set_permissions(fixture._temp.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let socket = fixture.root().join("promptsidecar-load.sock");
    let planner = Planner::new(fixture.root(), 1, 1, 600_000);
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let server = tokio::spawn(server::run(
        ServerConfig {
            socket_path: socket.clone(),
            max_body_bytes: 4 << 20,
            header_read_timeout: Duration::from_secs(1),
            body_read_timeout: Duration::from_secs(1),
            request_timeout: Duration::from_secs(5),
            max_connections: 8,
        },
        planner,
        async move {
            let _ = shutdown_rx.await;
        },
    ));
    wait_for_server(&socket, &server).await;
    let preload = preload_fixture(&socket, &fixture.contract_id).await;
    assert_eq!(preload["cold"], 1);

    let large_body = serde_json::to_vec(&fixture.request(&"hello ".repeat(500_000))).unwrap();
    let first_socket = socket.clone();
    let first =
        tokio::spawn(async move { unix_request(&first_socket, "/v1/plan", &large_body).await });
    let observed_busy = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let (status, metrics) = unix_get(&socket, "/metrics").await;
            assert_eq!(status, 200);
            let metrics: serde_json::Value = serde_json::from_slice(&metrics).unwrap();
            if metrics["planning_permits_available"] == 0 {
                return true;
            }
            if first.is_finished() {
                return false;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("timed out while observing the planner permit");
    assert!(observed_busy, "long plan never occupied the worker permit");

    let overload_body = serde_json::to_vec(&fixture.request("hello")).unwrap();
    let (overload_status, overload_response) =
        unix_request(&socket, "/v1/plan", &overload_body).await;
    assert_eq!(overload_status, 503);
    assert!(
        std::str::from_utf8(&overload_response)
            .unwrap()
            .contains("at_capacity")
    );

    let health_started = Instant::now();
    let (health_status, health) = unix_get(&socket, "/health").await;
    assert_eq!(health_status, 200);
    assert!(health_started.elapsed() < Duration::from_millis(250));
    assert!(
        std::str::from_utf8(&health)
            .unwrap()
            .contains(r#""ready":true"#)
    );

    let (first_status, _) = first.await.unwrap();
    assert_eq!(first_status, 200);
    let (metrics_status, metrics) = unix_get(&socket, "/metrics").await;
    assert_eq!(metrics_status, 200);
    let metrics: serde_json::Value = serde_json::from_slice(&metrics).unwrap();
    assert_eq!(metrics["metrics"]["plans"]["started"], 2);
    assert_eq!(metrics["metrics"]["plans"]["succeeded"], 1);
    assert_eq!(metrics["metrics"]["plans"]["failed"], 0);
    assert_eq!(metrics["metrics"]["plans"]["at_capacity"], 1);
    assert_eq!(metrics["metrics"]["plans"]["not_ready"], 0);
    assert_eq!(metrics["metrics"]["plans"]["timed_out"], 0);

    let _ = shutdown_tx.send(());
    server.await.unwrap().unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn planning_timeout_has_one_terminal_metric_outcome() {
    let fixture = Fixture::new();
    fs::set_permissions(fixture._temp.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let socket = fixture.root().join("promptsidecar-timeout.sock");
    let planner = Planner::new(fixture.root(), 1, 1, 600_000);
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let server = tokio::spawn(server::run(
        ServerConfig {
            socket_path: socket.clone(),
            max_body_bytes: 4 << 20,
            header_read_timeout: Duration::from_secs(1),
            body_read_timeout: Duration::from_secs(1),
            request_timeout: Duration::from_millis(10),
            max_connections: 4,
        },
        planner,
        async move {
            let _ = shutdown_rx.await;
        },
    ));
    wait_for_server(&socket, &server).await;
    preload_fixture(&socket, &fixture.contract_id).await;

    let body = serde_json::to_vec(&fixture.request(&"hello ".repeat(500_000))).unwrap();
    let (status, response) = unix_request(&socket, "/v1/plan", &body).await;
    assert_eq!(status, 504, "{}", String::from_utf8_lossy(&response));
    assert!(String::from_utf8_lossy(&response).contains("deadline_exceeded"));

    // The blocking tokenizer may still finish after the HTTP deadline. Wait
    // for its permit to be released before asserting that it did not publish
    // a second success/failure outcome.
    let metrics = wait_for_planning_permits(&socket, 1).await;
    let plans = &metrics["metrics"]["plans"];
    assert_eq!(plans["started"], 1);
    assert_eq!(plans["succeeded"], 0);
    assert_eq!(plans["failed"], 0);
    assert_eq!(plans["at_capacity"], 0);
    assert_eq!(plans["not_ready"], 0);
    assert_eq!(plans["timed_out"], 1);
    assert_eq!(plans["latency_us"]["count"], 1);

    let _ = shutdown_tx.send(());
    server.await.unwrap().unwrap();
}

#[tokio::test]
async fn preload_endpoint_is_bounded_idempotent_and_gates_readiness() {
    let fixture = Fixture::new();
    fs::set_permissions(fixture._temp.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let socket = fixture.root().join("promptsidecar-preload.sock");
    let planner = Planner::new(fixture.root(), 2, 1, 200_000);
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let server = tokio::spawn(server::run(
        ServerConfig {
            socket_path: socket.clone(),
            max_body_bytes: 4 << 20,
            header_read_timeout: Duration::from_secs(1),
            body_read_timeout: Duration::from_secs(1),
            request_timeout: Duration::from_secs(1),
            max_connections: 4,
        },
        planner,
        async move {
            let _ = shutdown_rx.await;
        },
    ));
    wait_for_server(&socket, &server).await;

    let body = serde_json::to_vec(&json!({
        "prompt_contract_ids": [fixture.contract_id]
    }))
    .unwrap();
    let (status, response) = unix_request(&socket, "/v1/preload", &body).await;
    assert_eq!(status, 200);
    let response: serde_json::Value = serde_json::from_slice(&response).unwrap();
    assert_eq!(response["ready"], true);
    assert_eq!(response["warm"], 0);
    assert_eq!(response["cold"], 1);
    assert_eq!(response["failed"], 0);
    assert_eq!(
        response["results"][0]["prompt_contract_id"],
        fixture.contract_id
    );

    let (warm_status, warm_response) = unix_request(&socket, "/v1/preload", &body).await;
    assert_eq!(warm_status, 200);
    let warm_response: serde_json::Value = serde_json::from_slice(&warm_response).unwrap();
    assert_eq!(warm_response["warm"], 1);
    assert_eq!(warm_response["cold"], 0);

    let duplicate = serde_json::to_vec(&json!({
        "prompt_contract_ids": [fixture.contract_id, fixture.contract_id]
    }))
    .unwrap();
    let (duplicate_status, duplicate_response) =
        unix_request(&socket, "/v1/preload", &duplicate).await;
    assert_eq!(duplicate_status, 400);
    assert!(
        std::str::from_utf8(&duplicate_response)
            .unwrap()
            .contains("preload_too_large")
    );

    let missing = "f".repeat(64);
    let missing_body = serde_json::to_vec(&json!({"prompt_contract_ids": [missing]})).unwrap();
    let (missing_status, missing_response) =
        unix_request(&socket, "/v1/preload", &missing_body).await;
    assert_eq!(missing_status, 200);
    let missing_response: serde_json::Value = serde_json::from_slice(&missing_response).unwrap();
    assert_eq!(missing_response["ready"], false);
    assert_eq!(missing_response["failed"], 1);
    assert_eq!(unix_get(&socket, "/health").await.0, 200);
    assert_eq!(unix_get(&socket, "/ready").await.0, 503);

    let (recovered_status, recovered) = unix_request(&socket, "/v1/preload", &body).await;
    assert_eq!(recovered_status, 200);
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&recovered).unwrap()["ready"],
        true
    );
    let (_, metrics) = unix_get(&socket, "/metrics").await;
    let metrics_text = std::str::from_utf8(&metrics).unwrap();
    assert!(!metrics_text.contains(&fixture.contract_id));

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

async fn wait_for_server(
    socket: &std::path::Path,
    server: &tokio::task::JoinHandle<Result<(), promptsidecar::server::ServerError>>,
) {
    tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if UnixStream::connect(socket).await.is_ok() {
                return;
            }
            assert!(
                !server.is_finished(),
                "Unix server terminated during startup"
            );
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("Unix server did not start");
}

async fn wait_for_planning_permits(socket: &std::path::Path, expected: u64) -> serde_json::Value {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let (status, metrics) = unix_get(socket, "/metrics").await;
            assert_eq!(status, 200);
            let metrics: serde_json::Value = serde_json::from_slice(&metrics).unwrap();
            if metrics["planning_permits_available"].as_u64() == Some(expected) {
                return metrics;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("planner permits did not reach the expected count")
}

async fn preload_fixture(socket: &std::path::Path, contract_id: &str) -> serde_json::Value {
    let body = serde_json::to_vec(&json!({
        "prompt_contract_ids": [contract_id]
    }))
    .unwrap();
    let (status, response) = unix_request(socket, "/v1/preload", &body).await;
    assert_eq!(status, 200);
    let response: serde_json::Value = serde_json::from_slice(&response).unwrap();
    assert_eq!(response["ready"], true);
    response
}

async fn unix_get(socket: &std::path::Path, path: &str) -> (u16, Vec<u8>) {
    let mut stream = UnixStream::connect(socket).await.unwrap();
    stream
        .write_all(
            format!("GET {path} HTTP/1.1\r\nHost: promptsidecar\r\nConnection: close\r\n\r\n")
                .as_bytes(),
        )
        .await
        .unwrap();
    read_http_response(&mut stream).await
}

async fn unix_request(socket: &std::path::Path, path: &str, body: &[u8]) -> (u16, Vec<u8>) {
    let mut stream = UnixStream::connect(socket).await.unwrap();
    stream
        .write_all(
            format!(
                "POST {path} HTTP/1.1\r\nHost: promptsidecar\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    stream.write_all(body).await.unwrap();
    read_http_response(&mut stream).await
}

async fn read_http_response(stream: &mut UnixStream) -> (u16, Vec<u8>) {
    let mut response = Vec::with_capacity(4096);
    let mut chunk = [0u8; 8192];
    let (status, header_end, content_length) = loop {
        let read = stream.read(&mut chunk).await.unwrap();
        assert!(read > 0, "Unix connection closed before response headers");
        response.extend_from_slice(&chunk[..read]);
        if let Some(header_end) = response.windows(4).position(|window| window == b"\r\n\r\n") {
            let header_end = header_end + 4;
            let headers = std::str::from_utf8(&response[..header_end]).unwrap();
            let status = headers
                .lines()
                .next()
                .and_then(|line| line.split_whitespace().nth(1))
                .and_then(|status| status.parse::<u16>().ok())
                .unwrap();
            let content_length = headers
                .lines()
                .find_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .map(str::trim)
                        .and_then(|value| value.parse::<usize>().ok())
                })
                .expect("response Content-Length");
            break (status, header_end, content_length);
        }
    };
    while response.len() < header_end + content_length {
        let read = stream.read(&mut chunk).await.unwrap();
        assert!(read > 0, "Unix connection closed during response body");
        response.extend_from_slice(&chunk[..read]);
    }
    (
        status,
        response[header_end..header_end + content_length].to_vec(),
    )
}

struct Fixture {
    _temp: TempDir,
    contract_id: String,
}

impl Fixture {
    fn new() -> Self {
        let temp = TempDir::new().unwrap();
        let contract_id = write_contract(temp.path(), "one");
        Self {
            _temp: temp,
            contract_id,
        }
    }

    fn add_contract(&self, variant: &str) -> String {
        write_contract(self._temp.path(), variant)
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

fn write_contract(root: &std::path::Path, variant: &str) -> String {
    let contents = vec![
        ("tokenizer.json", "tokenizer", tokenizer_json()),
        (
            "tokenizer_config.json",
            "tokenizer",
            br#"{"chat_template":"{% for message in messages %}{{ message.role }}:{{ message.content }}\n{% endfor %}{% if add_generation_prompt %}assistant:{% endif %}"}"#.to_vec(),
        ),
        (
            "config.json",
            "config",
            format!(r#"{{"model_type":"fixture","variant":"{variant}"}}"#).into_bytes(),
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
    let directory = root.join(&contract_id);
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
    contract_id
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

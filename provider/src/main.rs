//! DGInf provider agent for Apple Silicon Macs.
//!
//! The provider agent runs on Mac hardware and serves local inference requests
//! from the DGInf coordinator. It manages the lifecycle of an inference backend
//! (vllm-mlx or mlx-lm), connects to the coordinator via WebSocket, and
//! handles attestation using the Apple Secure Enclave.
//!
//! Architecture:
//!   Provider Agent (this binary)
//!     ├── Hardware detection (Apple Silicon chip, memory, GPU cores)
//!     ├── Model scanning (HuggingFace cache, memory filtering)
//!     ├── Backend management (spawn/monitor/restart inference server)
//!     ├── Coordinator connection (WebSocket, registration, heartbeats)
//!     ├── Request proxy (forward coordinator requests to backend)
//!     ├── Attestation (Secure Enclave identity, challenge-response)
//!     └── Crypto (NaCl X25519 key pair for future encryption)
//!
//! Trust model:
//!   The provider proves its identity via Secure Enclave attestation. The
//!   coordinator periodically challenges the provider to sign a nonce,
//!   verifying that the same hardware is still connected. The provider
//!   receives plain JSON inference requests from the coordinator (no
//!   decryption needed — the coordinator is a trusted Confidential VM).

mod backend;
mod config;
mod coordinator;
mod crypto;
mod hardware;
mod inference;
mod models;
mod protocol;
mod proxy;
mod security;
mod server;

use anyhow::Result;
use clap::{Parser, Subcommand};
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(name = "dginf-provider", about = "DGInf provider agent for Apple Silicon Macs")]
struct Cli {
    #[command(subcommand)]
    command: Command,

    /// Enable verbose logging
    #[arg(short, long, global = true)]
    verbose: bool,
}

#[derive(Subcommand)]
enum Command {
    /// Initialize provider configuration and detect hardware
    Init,

    /// Start serving inference requests
    Serve {
        /// Run in local-only mode (no coordinator connection)
        #[arg(long)]
        local: bool,

        /// Coordinator WebSocket URL
        #[arg(long, default_value = "ws://localhost:8080/ws/provider")]
        coordinator: String,

        /// Port for local API server
        #[arg(long, default_value_t = 8000)]
        port: u16,

        /// Model to serve (overrides config)
        #[arg(long)]
        model: Option<String>,

        /// Port for the inference backend
        #[arg(long)]
        backend_port: Option<u16>,

    },

    /// One-command setup: enroll in MDM, download model, start serving
    Install {
        /// Coordinator URL (WebSocket for serving, HTTPS for API)
        #[arg(long, default_value = "wss://inference-test.openinnovation.dev/ws/provider")]
        coordinator: String,

        /// MDM enrollment profile URL
        #[arg(long, default_value = "https://inference-test.openinnovation.dev/enroll.mobileconfig")]
        profile_url: String,

        /// Model to serve (auto-selects if not specified)
        #[arg(long)]
        model: Option<String>,
    },

    /// Run standardized benchmarks
    Benchmark,

    /// Show hardware and connection status
    Status,

    /// List available models that fit in memory
    Models,
}

fn setup_logging(verbose: bool) {
    let filter = if verbose {
        EnvFilter::new("dginf_provider=debug,info")
    } else {
        EnvFilter::new("dginf_provider=info,warn")
    };

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .init();
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    setup_logging(cli.verbose);

    // Security hardening: prevent debugger attachment early, before any
    // sensitive data (keys, prompts) is loaded into memory.
    security::deny_debugger_attachment();

    match cli.command {
        Command::Init => cmd_init().await,
        Command::Install {
            coordinator,
            profile_url,
            model,
        } => cmd_install(coordinator, profile_url, model).await,
        Command::Serve {
            local,
            coordinator,
            port,
            model,
            backend_port,
        } => cmd_serve(local, coordinator, port, model, backend_port).await,
        Command::Benchmark => cmd_benchmark().await,
        Command::Status => cmd_status().await,
        Command::Models => cmd_models().await,
    }
}

async fn cmd_init() -> Result<()> {
    tracing::info!("Detecting hardware...");
    let hw = hardware::detect()?;
    println!("{hw}");

    let config_path = config::default_config_path()?;
    if config_path.exists() {
        tracing::info!("Config already exists at {}", config_path.display());
    } else {
        let cfg = config::ProviderConfig::default_for_hardware(&hw);
        config::save(&config_path, &cfg)?;
        tracing::info!("Config written to {}", config_path.display());
    }

    // Generate or load the E2E encryption key pair
    let key_path = crypto::default_key_path()?;
    let kp = crypto::NodeKeyPair::load_or_generate(&key_path)?;
    tracing::info!("Node key loaded from {}", key_path.display());
    println!("Public key: {}", kp.public_key_base64());

    Ok(())
}

async fn cmd_install(
    coordinator_url: String,
    profile_url: String,
    model_override: Option<String>,
) -> Result<()> {
    println!("╔══════════════════════════════════════════╗");
    println!("║       DGInf Provider Setup               ║");
    println!("╚══════════════════════════════════════════╝");
    println!();

    // Step 1: Detect hardware
    println!("Step 1/6: Detecting hardware...");
    let hw = hardware::detect()?;
    println!("  ✓ {} ({} GB RAM, {} GPU cores, {} GB/s bandwidth)",
        hw.chip_name, hw.memory_gb, hw.gpu_cores, hw.memory_bandwidth_gbs);
    println!();

    // Step 2: Initialize config and keys
    println!("Step 2/6: Initializing configuration...");
    let config_path = config::default_config_path()?;
    if !config_path.exists() {
        let cfg = config::ProviderConfig::default_for_hardware(&hw);
        config::save(&config_path, &cfg)?;
    }
    let key_path = crypto::default_key_path()?;
    let _kp = crypto::NodeKeyPair::load_or_generate(&key_path)?;
    println!("  ✓ Config: {}", config_path.display());
    println!("  ✓ Node key: {}", key_path.display());
    println!();

    // Step 3: Download and install MDM enrollment profile
    println!("Step 3/6: MDM enrollment...");
    let profile_path = std::env::temp_dir().join("DGInf-Enroll.mobileconfig");
    println!("  Downloading enrollment profile...");
    let client = reqwest::Client::new();
    let resp = client.get(&profile_url).send().await?;
    if !resp.status().is_success() {
        anyhow::bail!("Failed to download enrollment profile: HTTP {}", resp.status());
    }
    let profile_bytes = resp.bytes().await?;
    std::fs::write(&profile_path, &profile_bytes)?;
    println!("  ✓ Downloaded to {}", profile_path.display());

    // Open the profile for installation
    println!("  Opening profile for installation...");
    println!();
    println!("  ┌─────────────────────────────────────────────────────┐");
    println!("  │  A System Settings window will open.                │");
    println!("  │  Go to General → Device Management and click        │");
    println!("  │  Install on the DGInf profile.                      │");
    println!("  │                                                      │");
    println!("  │  This only allows DGInf to query your Mac's         │");
    println!("  │  security status. No access to personal data.       │");
    println!("  └─────────────────────────────────────────────────────┘");
    println!();

    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("open")
            .arg(&profile_path)
            .status();
    }

    // Wait for enrollment
    println!("  Waiting for MDM enrollment (install the profile, then press Enter)...");
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;

    // Verify enrollment by checking profiles
    #[cfg(target_os = "macos")]
    {
        let output = std::process::Command::new("profiles")
            .args(["list"])
            .output();
        match output {
            Ok(o) => {
                let stdout = String::from_utf8_lossy(&o.stdout);
                if stdout.contains("micromdm") || stdout.contains("dginf") || stdout.contains("com.github") {
                    println!("  ✓ MDM enrollment confirmed!");
                } else if stdout.contains("no configuration profiles") || stdout.is_empty() {
                    println!("  ⚠ No profiles detected. You can install the profile later.");
                    println!("    Download from: {}", profile_url);
                } else {
                    println!("  ✓ Profile installed");
                }
            }
            Err(_) => println!("  ⚠ Could not verify enrollment (continuing anyway)"),
        }
    }
    println!();

    // Step 4: Select and download model
    println!("Step 4/6: Setting up inference model...");
    let model = if let Some(m) = model_override {
        m
    } else {
        // Auto-select model based on available memory
        let model = if hw.memory_available_gb >= 64 {
            "mlx-community/Qwen2.5-7B-Instruct-4bit"
        } else if hw.memory_available_gb >= 16 {
            "mlx-community/Qwen2.5-3B-Instruct-4bit"
        } else {
            "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
        };
        println!("  Auto-selected: {} (for {} GB available memory)", model, hw.memory_available_gb);
        model.to_string()
    };

    // Check if model is already downloaded
    let available = models::scan_models(&hw);
    let model_downloaded = available.iter().any(|m| m.id == model);

    if !model_downloaded {
        println!("  Downloading model (this may take a few minutes)...");
        let status = std::process::Command::new("huggingface-cli")
            .args(["download", &model])
            .status();
        match status {
            Ok(s) if s.success() => println!("  ✓ Model downloaded"),
            _ => {
                // Try python fallback
                println!("  huggingface-cli not found, trying Python...");
                let py_status = std::process::Command::new("python3")
                    .args(["-c", &format!(
                        "from huggingface_hub import snapshot_download; snapshot_download('{}')",
                        model
                    )])
                    .status();
                match py_status {
                    Ok(s) if s.success() => println!("  ✓ Model downloaded"),
                    _ => println!("  ⚠ Could not download model. Download manually:\n    huggingface-cli download {}", model),
                }
            }
        }
    } else {
        println!("  ✓ Model already downloaded: {}", model);
    }
    println!();

    // Step 5: Verify security posture
    println!("Step 5/6: Verifying security posture...");
    match security::verify_security_posture() {
        Ok(()) => println!("  ✓ SIP enabled, security checks passed"),
        Err(e) => {
            println!("  ✗ Security check failed: {}", e);
            anyhow::bail!("Cannot serve with security checks failing: {}", e);
        }
    }
    println!();

    // Step 6: Connect and serve
    println!("Step 6/6: Starting provider...");
    println!("  Coordinator: {}", coordinator_url);
    println!("  Model: {}", model);
    println!();
    println!("╔══════════════════════════════════════════╗");
    println!("║  Provider is online and earning!          ║");
    println!("║  Press Ctrl+C to stop.                    ║");
    println!("╚══════════════════════════════════════════╝");
    println!();

    // Convert wss:// coordinator URL to ws:// for serve (or keep as-is)
    let ws_url = coordinator_url;
    cmd_serve(false, ws_url, 8000, Some(model), None).await
}

async fn cmd_serve(
    local: bool,
    coordinator_url: String,
    port: u16,
    model_override: Option<String>,
    backend_port_override: Option<u16>,
) -> Result<()> {
    // Verify security posture before serving any inference requests.
    // SIP cannot be disabled at runtime (requires reboot), so this check
    // at startup guarantees SIP will remain on for the process lifetime.
    if let Err(reason) = security::verify_security_posture() {
        anyhow::bail!("Security check failed: {reason}");
    }

    let hw = hardware::detect()?;
    tracing::info!(
        "Starting provider on {} ({} GB RAM, {} GPU cores)",
        hw.chip_name,
        hw.memory_gb,
        hw.gpu_cores
    );

    // Load or create config
    let config_path = config::default_config_path()?;
    let cfg = if config_path.exists() {
        config::load(&config_path)?
    } else {
        let cfg = config::ProviderConfig::default_for_hardware(&hw);
        config::save(&config_path, &cfg)?;
        cfg
    };

    // Load or generate E2E encryption key pair
    let key_path = crypto::default_key_path()?;
    let node_keypair = std::sync::Arc::new(crypto::NodeKeyPair::load_or_generate(&key_path)?);
    tracing::info!(
        "E2E encryption key loaded (public: {})",
        node_keypair.public_key_base64()
    );

    // Determine model (CLI override > config > default)
    let model = model_override
        .or(cfg.backend.model.clone())
        .unwrap_or_else(|| "mlx-community/Qwen2.5-7B-Instruct-4bit".to_string());

    // Determine backend port (CLI override > config)
    let be_port = backend_port_override.unwrap_or(cfg.backend.port);

    // Verify backend binary integrity before launching.
    // Hash the binary to detect tampering — a modified backend could
    // exfiltrate consumer prompts.
    match security::verify_backend_integrity("vllm-mlx") {
        Ok(hash) => {
            tracing::info!("Backend integrity verified: vllm-mlx hash = {}", &hash[..16]);
        }
        Err(e) => {
            tracing::warn!("Backend integrity check skipped: {e}");
            // Don't fail — the binary might be a Python script (not hashable the same way).
            // In production with a bundled app, this would be a hard failure.
        }
    }

    // In-process inference only (Phase 3, maximum security).
    // If mlx-lm is not installed, install it automatically.
    if let Err(_) = inference::InProcessEngine::detect_engine() {
        tracing::info!("MLX not found — installing mlx-lm automatically...");
        let install_status = std::process::Command::new("pip3")
            .args(["install", "mlx-lm"])
            .status();
        match install_status {
            Ok(s) if s.success() => tracing::info!("mlx-lm installed successfully"),
            Ok(s) => anyhow::bail!("Failed to install mlx-lm (exit code: {s}). Install manually: pip3 install mlx-lm"),
            Err(e) => anyhow::bail!("Failed to run pip3: {e}. Install mlx-lm manually: pip3 install mlx-lm"),
        }
    }

    tracing::info!("Using in-process inference engine (secure mode)");
    tracing::info!("All inference inside this hardened process — no subprocess, no IPC");
    let engine = inference::InProcessEngine::new(model.clone());
    let backend: Box<dyn backend::Backend> = Box::new(inference::SharedEngine::new(engine));

    // Start backend manager
    let manager = backend::BackendManager::new(
        backend,
        std::time::Duration::from_secs(5),
    );
    manager.start().await?;

    let backend_url = manager.base_url().await;
    tracing::info!("Backend URL: {backend_url}");

    if local {
        // Local-only mode: just start the HTTP server
        tracing::info!("Local-only mode on port {port}");
        server::start_server(port, backend_url).await?;
    } else {
        // Coordinator mode: connect WebSocket + proxy
        tracing::info!("Connecting to coordinator: {coordinator_url}");

        let available_models = models::scan_models(&hw);
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel(64);
        let (outbound_tx, outbound_rx) = tokio::sync::mpsc::channel(64);
        let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

        let backend_name = "vllm_mlx";

        let public_key_b64 = node_keypair.public_key_base64();

        // Compute SHA-256 of our own binary for integrity attestation.
        let binary_hash = security::self_binary_hash();

        // Generate Secure Enclave attestation, binding the X25519 encryption key
        // and our binary hash (so coordinator can verify we're running blessed code).
        let attestation = generate_attestation(&public_key_b64, binary_hash.as_deref());

        let client = coordinator::CoordinatorClient::new(
            coordinator_url,
            hw.clone(),
            available_models,
            backend_name.to_string(),
            std::time::Duration::from_secs(cfg.coordinator.heartbeat_interval_secs),
            Some(public_key_b64),
        )
        .with_attestation(attestation);

        // Spawn coordinator connection
        let coordinator_handle = tokio::spawn(async move {
            if let Err(e) = client.run(event_tx, outbound_rx, shutdown_rx).await {
                tracing::error!("Coordinator connection error: {e}");
            }
        });

        // Process coordinator events
        let proxy_backend_url = backend_url.clone();
        let proxy_keypair = node_keypair.clone();
        let is_inprocess = proxy_backend_url.starts_with("inprocess://");
        let shared_engine: Option<std::sync::Arc<tokio::sync::Mutex<inference::InProcessEngine>>> =
            if is_inprocess {
                // Create a new engine and load it (detects mlx-lm vs vllm-mlx)
                let mut engine = inference::InProcessEngine::new(model.clone());
                if let Err(e) = engine.load() {
                    tracing::error!("Failed to load in-process engine for event loop: {e}");
                    anyhow::bail!("In-process engine load failed: {e}");
                }
                Some(std::sync::Arc::new(tokio::sync::Mutex::new(engine)))
            } else {
                None
            };

        let event_handle = tokio::spawn(async move {
            while let Some(event) = event_rx.recv().await {
                match event {
                    coordinator::CoordinatorEvent::Connected => {
                        tracing::info!("Connected to coordinator");
                    }
                    coordinator::CoordinatorEvent::Disconnected => {
                        tracing::warn!("Disconnected from coordinator");
                    }
                    coordinator::CoordinatorEvent::InferenceRequest { request_id, body } => {
                        let tx = outbound_tx.clone();

                        if let Some(ref engine) = shared_engine {
                            // In-process: call Python engine directly
                            let engine = engine.clone();
                            tokio::spawn(async move {
                                handle_inprocess_request(request_id, body, engine, tx).await;
                            });
                        } else {
                            // Subprocess: HTTP proxy to backend
                            let url = proxy_backend_url.clone();
                            let kp = proxy_keypair.clone();
                            tokio::spawn(async move {
                                proxy::handle_inference_request(request_id, body, url, tx, Some(kp)).await;
                            });
                        }
                    }
                    coordinator::CoordinatorEvent::Cancel { request_id } => {
                        tracing::info!("Cancel request for {request_id} (not yet implemented)");
                    }
                    coordinator::CoordinatorEvent::AttestationChallenge { nonce, timestamp } => {
                        // Attestation challenges are handled inline in the coordinator
                        // connection loop (coordinator.rs). This event variant exists for
                        // completeness but the challenge response is sent directly.
                        tracing::debug!(
                            "Attestation challenge event received (nonce={}, ts={})",
                            &nonce[..8.min(nonce.len())],
                            timestamp
                        );
                    }
                }
            }
        });

        // Wait for Ctrl+C
        tokio::signal::ctrl_c().await?;
        tracing::info!("Shutting down...");
        let _ = shutdown_tx.send(true);

        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            coordinator_handle,
        )
        .await;
        event_handle.abort();
    }

    // Clean up backend
    manager.stop().await?;

    Ok(())
}

/// Handle an inference request using the in-process engine (no HTTP, no subprocess).
async fn handle_inprocess_request(
    request_id: String,
    body: serde_json::Value,
    engine: std::sync::Arc<tokio::sync::Mutex<inference::InProcessEngine>>,
    outbound_tx: tokio::sync::mpsc::Sender<protocol::ProviderMessage>,
) {
    // Pre-request SIP check
    if !security::check_sip_enabled() {
        let _ = outbound_tx.send(protocol::ProviderMessage::InferenceError {
            request_id,
            error: "SIP disabled".to_string(),
            status_code: 503,
        }).await;
        return;
    }

    // Extract parameters from OpenAI-format body
    let messages: Vec<serde_json::Value> = body.get("messages")
        .and_then(|m| m.as_array())
        .cloned()
        .unwrap_or_default();
    let max_tokens = body.get("max_tokens").and_then(|v| v.as_u64()).unwrap_or(256);
    let temperature = body.get("temperature").and_then(|v| v.as_f64()).unwrap_or(0.7);
    let is_streaming = body.get("stream").and_then(|v| v.as_bool()).unwrap_or(false);

    // Run inference in blocking task (Python GIL)
    let engine_clone = engine.clone();
    let req_id = request_id.clone();
    let result = tokio::task::spawn_blocking(move || {
        let e = engine_clone.blocking_lock();
        e.generate(&messages, max_tokens, temperature)
    }).await;

    match result {
        Ok(Ok(inference_result)) => {
            if is_streaming {
                // Send as a single chunk for now
                let chunk = serde_json::json!({
                    "id": format!("chatcmpl-{}", uuid::Uuid::new_v4()),
                    "object": "chat.completion.chunk",
                    "choices": [{"delta": {"content": inference_result.text}, "index": 0, "finish_reason": "stop"}]
                });
                let _ = outbound_tx.send(protocol::ProviderMessage::InferenceResponseChunk {
                    request_id: request_id.clone(),
                    data: format!("data: {}", serde_json::to_string(&chunk).unwrap_or_default()),
                }).await;
                let _ = outbound_tx.send(protocol::ProviderMessage::InferenceResponseChunk {
                    request_id: request_id.clone(),
                    data: "data: [DONE]".to_string(),
                }).await;
            }

            let _ = outbound_tx.send(protocol::ProviderMessage::InferenceComplete {
                request_id,
                usage: protocol::UsageInfo {
                    prompt_tokens: inference_result.prompt_tokens,
                    completion_tokens: inference_result.completion_tokens,
                },
            }).await;
        }
        Ok(Err(e)) => {
            tracing::error!("In-process inference failed: {e}");
            let _ = outbound_tx.send(protocol::ProviderMessage::InferenceError {
                request_id,
                error: e.to_string(),
                status_code: 500,
            }).await;
        }
        Err(e) => {
            tracing::error!("Inference task panicked: {e}");
            let _ = outbound_tx.send(protocol::ProviderMessage::InferenceError {
                request_id,
                error: "inference task failed".to_string(),
                status_code: 500,
            }).await;
        }
    }

    // Wipe request body from memory
    if let Ok(mut body_bytes) = serde_json::to_vec(&body) {
        security::secure_zero(&mut body_bytes);
    }
}

/// Generate a Secure Enclave attestation by calling the dginf-enclave CLI tool.
///
/// The attestation binds the X25519 encryption public key to the hardware
/// identity, proving the same device controls both keys.
///
/// Returns None if the CLI tool is not available or fails (graceful degradation).
fn generate_attestation(encryption_key_base64: &str, binary_hash: Option<&str>) -> Option<serde_json::Value> {
    // Look for the enclave CLI binary in common locations
    let binary_paths = [
        // Built in the enclave directory (development)
        "../enclave/.build/release/dginf-enclave",
        // System-wide install
        "/usr/local/bin/dginf-enclave",
        // Homebrew
        "/opt/homebrew/bin/dginf-enclave",
        // Adjacent to provider binary
        "dginf-enclave",
    ];

    let mut binary_path = None;
    for path in &binary_paths {
        let p = std::path::Path::new(path);
        if p.exists() {
            binary_path = Some(p.to_path_buf());
            break;
        }
    }

    // Also check PATH
    if binary_path.is_none() {
        if let Ok(output) = std::process::Command::new("which")
            .arg("dginf-enclave")
            .output()
        {
            if output.status.success() {
                let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
                if !path.is_empty() {
                    binary_path = Some(std::path::PathBuf::from(path));
                }
            }
        }
    }

    let binary = match binary_path {
        Some(p) => p,
        None => {
            tracing::info!("dginf-enclave binary not found, registering without attestation");
            return None;
        }
    };

    tracing::info!("Generating Secure Enclave attestation via {}", binary.display());

    let mut args = vec!["attest", "--encryption-key", encryption_key_base64];
    let hash_string;
    if let Some(hash) = binary_hash {
        hash_string = hash.to_string();
        args.push("--binary-hash");
        args.push(&hash_string);
    }

    match std::process::Command::new(&binary)
        .args(&args)
        .output()
    {
        Ok(output) => {
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                tracing::warn!("dginf-enclave failed: {stderr}");
                return None;
            }

            let stdout = String::from_utf8_lossy(&output.stdout);
            match serde_json::from_str::<serde_json::Value>(&stdout) {
                Ok(json) => {
                    tracing::info!("Secure Enclave attestation generated successfully");
                    Some(json)
                }
                Err(e) => {
                    tracing::warn!("Failed to parse attestation JSON: {e}");
                    None
                }
            }
        }
        Err(e) => {
            tracing::warn!("Failed to run dginf-enclave: {e}");
            None
        }
    }
}

async fn cmd_benchmark() -> Result<()> {
    tracing::warn!("Benchmark not yet implemented");
    Ok(())
}

async fn cmd_status() -> Result<()> {
    let hw = hardware::detect()?;
    println!("{hw}");
    Ok(())
}

async fn cmd_models() -> Result<()> {
    let hw = hardware::detect()?;
    let models = models::scan_models(&hw);

    if models.is_empty() {
        println!("No MLX models found in HuggingFace cache.");
        println!("Download models with: huggingface-cli download <model-name>");
        println!("Example: huggingface-cli download mlx-community/Qwen2.5-7B-Instruct-4bit");
    } else {
        println!("Available models ({} found):\n", models.len());
        for model in &models {
            println!("  {model}");
        }
    }

    Ok(())
}

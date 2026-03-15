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
mod models;
mod protocol;
mod proxy;
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

        /// Backend to use (overrides config): mlx-lm or vllm-mlx
        #[arg(long)]
        backend: Option<String>,

        /// Port for the inference backend
        #[arg(long)]
        backend_port: Option<u16>,
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

    match cli.command {
        Command::Init => cmd_init().await,
        Command::Serve {
            local,
            coordinator,
            port,
            model,
            backend,
            backend_port,
        } => cmd_serve(local, coordinator, port, model, backend, backend_port).await,
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

async fn cmd_serve(
    local: bool,
    coordinator_url: String,
    port: u16,
    model_override: Option<String>,
    backend_override: Option<String>,
    backend_port_override: Option<u16>,
) -> Result<()> {
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

    // Determine backend type (CLI override > config)
    let backend_type = match backend_override.as_deref() {
        Some("mlx-lm") => config::BackendType::MlxLm,
        Some("vllm-mlx") => config::BackendType::VllmMlx,
        _ => cfg.backend.primary.clone(),
    };

    // Create the backend
    let backend: Box<dyn backend::Backend> = match backend_type {
        config::BackendType::VllmMlx => Box::new(backend::vllm_mlx::VllmMlxBackend::new(
            model.clone(),
            be_port,
            cfg.backend.continuous_batching,
        )),
        config::BackendType::MlxLm => Box::new(backend::mlx_lm::MlxLmBackend::new(
            model.clone(),
            be_port,
        )),
    };

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

        let backend_name = match cfg.backend.primary {
            config::BackendType::VllmMlx => "vllm_mlx",
            config::BackendType::MlxLm => "mlx_lm",
        };

        let public_key_b64 = node_keypair.public_key_base64();

        // Generate Secure Enclave attestation, binding the X25519 encryption key.
        let attestation = generate_attestation(&public_key_b64);

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
                        let url = proxy_backend_url.clone();
                        let kp = proxy_keypair.clone();
                        tokio::spawn(async move {
                            proxy::handle_inference_request(request_id, body, url, tx, Some(kp)).await;
                        });
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

/// Generate a Secure Enclave attestation by calling the dginf-enclave CLI tool.
///
/// The attestation binds the X25519 encryption public key to the hardware
/// identity, proving the same device controls both keys.
///
/// Returns None if the CLI tool is not available or fails (graceful degradation).
fn generate_attestation(encryption_key_base64: &str) -> Option<serde_json::Value> {
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

    match std::process::Command::new(&binary)
        .args(["attest", "--encryption-key", encryption_key_base64])
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

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
#[cfg(feature = "python")]
mod inference;
mod models;
mod protocol;
mod proxy;
mod security;
mod server;
mod wallet;

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
        #[arg(long, default_value = "wss://inference-test.openinnovation.dev/ws/provider")]
        coordinator: String,

        /// Port for local API server
        #[arg(long, default_value_t = 8000)]
        port: u16,

        /// Model to serve (serves largest downloaded model if not specified)
        /// Can specify multiple: --model model1 --model model2
        #[arg(long)]
        model: Option<String>,

        /// Port for the inference backend
        #[arg(long)]
        backend_port: Option<u16>,

        /// Serve all downloaded models that fit in memory
        #[arg(long)]
        all_models: bool,
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

    /// Enroll this Mac in DGInf MDM (without starting to serve)
    Enroll {
        /// MDM enrollment profile URL
        #[arg(long, default_value = "https://inference-test.openinnovation.dev/enroll.mobileconfig")]
        profile_url: String,
    },

    /// Remove MDM enrollment and clean up DGInf data
    Unenroll,

    /// Run standardized benchmarks
    Benchmark,

    /// Show hardware and connection status
    Status,

    /// List, download, or remove models
    Models {
        /// Action: list (default), download, or remove
        #[arg(default_value = "list")]
        action: String,
    },

    /// Show earnings and usage history
    Earnings {
        /// Coordinator API URL
        #[arg(long, default_value = "https://inference-test.openinnovation.dev")]
        coordinator: String,
    },

    /// Diagnose issues: check SIP, Secure Enclave, MDM, models, connectivity
    Doctor {
        /// Coordinator URL to test connectivity
        #[arg(long, default_value = "https://inference-test.openinnovation.dev")]
        coordinator: String,
    },

    /// Start the provider in the background (uses existing config)
    Start {
        /// Coordinator WebSocket URL
        #[arg(long, default_value = "wss://inference-test.openinnovation.dev/ws/provider")]
        coordinator: String,

        /// Model to serve
        #[arg(long)]
        model: Option<String>,
    },

    /// Stop the provider gracefully
    Stop,

    /// Show provider logs
    Logs {
        /// Number of lines to show
        #[arg(long, default_value_t = 50)]
        lines: usize,

        /// Watch logs in real-time (like tail -f)
        #[arg(short, long)]
        watch: bool,
    },

    /// Show or create provider wallet (stored in macOS Keychain)
    Wallet,
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
            all_models,
        } => cmd_serve(local, coordinator, port, model, backend_port, all_models).await,
        Command::Enroll { profile_url } => cmd_enroll(profile_url).await,
        Command::Unenroll => cmd_unenroll().await,
        Command::Benchmark => cmd_benchmark().await,
        Command::Status => cmd_status().await,
        Command::Models { action } => cmd_models(action).await,
        Command::Earnings { coordinator } => cmd_earnings(coordinator).await,
        Command::Doctor { coordinator } => cmd_doctor(coordinator).await,
        Command::Start { coordinator, model } => cmd_start(coordinator, model).await,
        Command::Stop => cmd_stop().await,
        Command::Logs { lines, watch } => cmd_logs(lines, watch).await,
        Command::Wallet => cmd_wallet().await,
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

    // Step 2: Initialize config, keys, and wallet
    println!("Step 2/6: Initializing configuration...");
    let config_path = config::default_config_path()?;
    if !config_path.exists() {
        let cfg = config::ProviderConfig::default_for_hardware(&hw);
        config::save(&config_path, &cfg)?;
    }
    let key_path = crypto::default_key_path()?;
    let _kp = crypto::NodeKeyPair::load_or_generate(&key_path)?;
    let w = wallet::Wallet::load_or_create()?;
    println!("  ✓ Config: {}", config_path.display());
    println!("  ✓ Node key: {}", key_path.display());
    println!("  ✓ Wallet: {} (stored in Keychain)", w.address());
    println!();

    // Step 3: MDM enrollment (skip if already enrolled)
    println!("Step 3/6: MDM enrollment...");

    let already_enrolled = security::check_mdm_enrolled();

    if already_enrolled {
        println!("  ✓ Already enrolled in MDM — skipping");
    } else {
        let profile_path = std::env::temp_dir().join("DGInf-Enroll.mobileconfig");
        println!("  Downloading enrollment profile...");
        let client = reqwest::Client::new();
        let resp = client.get(&profile_url).send().await?;
        if !resp.status().is_success() {
            println!("  ⚠ Could not download profile (HTTP {}). Skipping MDM enrollment.", resp.status());
            println!("    You can enroll later: dginf-provider enroll");
        } else {
            let profile_bytes = resp.bytes().await?;
            std::fs::write(&profile_path, &profile_bytes)?;

            #[cfg(target_os = "macos")]
            {
                println!("  Opening enrollment profile...");
                println!("  Install it in System Settings → General → Device Management");
                println!("  (Only queries security status — no access to personal data)");
                println!();
                let _ = std::process::Command::new("open").arg(&profile_path).status();
            }

            println!("  Press Enter after installing (or to skip)...");
            let mut input = String::new();
            std::io::stdin().read_line(&mut input)?;
        }
    }
    println!();

    // Step 4: Select and download model
    println!("Step 4/6: Setting up inference model...");
    println!("  Available memory: {} GB", hw.memory_available_gb);
    println!();

    let catalog = [
        ("mlx-community/Qwen2.5-0.5B-4bit",          "Qwen2.5-0.5B-4bit",          "Qwen2.5 0.5B",     0.4,  "0.5B dense",          "Tiny (testing)"),
        ("mlx-community/Qwen2.5-1.5B-4bit",          "Qwen2.5-1.5B-4bit",          "Qwen2.5 1.5B",     1.0,  "1.5B dense",          "Very light"),
        ("mlx-community/Qwen2.5-3B-4bit",            "Qwen2.5-3B-4bit",            "Qwen2.5 3B",       2.0,  "3B dense",            "Light"),
        ("mlx-community/Llama-3.2-3B-Instruct-4bit", "Llama-3.2-3B-Instruct-4bit", "Llama 3.2 3B",     2.0,  "3B dense",            "Meta Llama"),
        ("mlx-community/Qwen3.5-9B-MLX-4bit",        "Qwen3.5-9B-MLX-4bit",        "Qwen3.5 9B",       6.0,  "9B dense",            "Balanced"),
        ("mlx-community/Qwen3.5-27B-4bit",           "Qwen3.5-27B-4bit",           "Qwen3.5 27B",     17.0,  "27B dense",           "High quality"),
        ("mlx-community/Qwen3.5-35B-A3B-4bit",       "Qwen3.5-35B-A3B-4bit",       "Qwen3.5 35B-A3B", 22.0,  "35B MoE, 3B active",  "Fast + smart"),
        ("mlx-community/Qwen3.5-122B-A10B-4bit",     "Qwen3.5-122B-A10B-4bit",     "Qwen3.5 122B",    76.0,  "122B MoE, 10B active", "Best quality"),
    ];

    // Check which models are already downloaded
    let available = models::scan_models(&hw);

    let mut selectable: Vec<usize> = Vec::new();
    for (i, (id, _s3_name, name, size_gb, arch, desc)) in catalog.iter().enumerate() {
        let fits = hw.memory_available_gb as f64 >= *size_gb;
        let downloaded = available.iter().any(|m| m.id == *id);
        let status = if downloaded { "✓ ready" } else if fits { "  fits" } else { "✗ too large" };
        if fits {
            selectable.push(i);
            println!("  [{}] {} {:>5.1} GB  {:25} {}  {}", selectable.len(), name, size_gb, arch, desc, status);
        } else {
            println!("  [-] {} {:>5.1} GB  {:25} {}  {}", name, size_gb, arch, desc, status);
        }
    }
    println!();

    let model = if let Some(m) = model_override {
        m
    } else if selectable.is_empty() {
        anyhow::bail!("No models fit in {} GB available memory", hw.memory_available_gb);
    } else {
        println!("  Select a model [1-{}] (or press Enter for [{}]):", selectable.len(), selectable.len());
        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
        let input = input.trim();

        let choice = if input.is_empty() {
            selectable.len() - 1 // default to largest that fits
        } else {
            input.parse::<usize>().unwrap_or(selectable.len()).saturating_sub(1)
        };

        let idx = selectable.get(choice.min(selectable.len() - 1)).copied().unwrap_or(0);
        let (id, _, name, _, _, _) = &catalog[idx];
        println!("  → Selected: {} ({})", name, id);
        id.to_string()
    };

    // Check if already downloaded
    let model_downloaded = available.iter().any(|m| m.id == model);

    if !model_downloaded {
        // Find S3 name for this model
        let s3_name = catalog.iter()
            .find(|(id, _, _, _, _, _)| *id == model)
            .map(|(_, s3, _, _, _, _)| *s3)
            .unwrap_or("");

        let s3_url = format!("https://dginf-models.s3.amazonaws.com/{}", s3_name);
        let cache_dir = dirs::home_dir().unwrap_or_default()
            .join(".cache/huggingface/hub")
            .join(format!("models--{}", model.replace('/', "--")))
            .join("snapshots/main");

        println!("  Downloading model from DGInf CDN...");
        std::fs::create_dir_all(&cache_dir)?;

        // Download model files from S3
        let status = std::process::Command::new("curl")
            .args(["-fsSL", &format!("{}/config.json", s3_url), "-o", &cache_dir.join("config.json").to_string_lossy()])
            .status();

        if status.map(|s| s.success()).unwrap_or(false) {
            // Use aws s3 sync if available, otherwise curl individual files
            let aws_status = std::process::Command::new("aws")
                .args(["s3", "sync", &format!("s3://dginf-models/{}/", s3_name), &cache_dir.to_string_lossy(), "--region", "us-east-1", "--no-sign-request"])
                .status();

            match aws_status {
                Ok(s) if s.success() => println!("  ✓ Model downloaded from DGInf CDN"),
                _ => {
                    println!("  AWS CLI not available. Trying HuggingFace...");
                    let hf_status = std::process::Command::new("python3")
                        .args(["-c", &format!(
                            "from huggingface_hub import snapshot_download; snapshot_download('{}')",
                            model
                        )])
                        .status();
                    match hf_status {
                        Ok(s) if s.success() => println!("  ✓ Model downloaded from HuggingFace"),
                        _ => println!("  ⚠ Could not download model. Download manually:\n    aws s3 sync s3://dginf-models/{}/ ~/.cache/huggingface/hub/models--{}--/snapshots/main/ --no-sign-request", s3_name, model.replace('/', "--")),
                    }
                }
            }
        } else {
            println!("  Model not yet available on DGInf CDN. Trying HuggingFace...");
            let hf_status = std::process::Command::new("python3")
                .args(["-c", &format!(
                    "from huggingface_hub import snapshot_download; snapshot_download('{}')",
                    model
                )])
                .status();
            match hf_status {
                Ok(s) if s.success() => println!("  ✓ Model downloaded from HuggingFace"),
                _ => println!("  ⚠ Could not download model. It may require HuggingFace authentication.\n    Run: huggingface-cli login\n    Then: huggingface-cli download {}", model),
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

    // Step 6: Launch provider in background
    println!("Step 6/6: Starting provider...");
    println!("  Coordinator: {}", coordinator_url);
    println!("  Model: {}", model);
    println!();

    // Get the path to our own binary
    let exe = std::env::current_exe()?;
    let log_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".dginf/provider.log");

    // Launch ourselves in the background with `serve`
    let log_file = std::fs::File::create(&log_path)?;
    let log_err = log_file.try_clone()?;

    let child = std::process::Command::new(&exe)
        .args([
            "serve",
            "--coordinator", &coordinator_url,
            "--model", &model,
            "--all-models",
        ])
        .stdout(log_file)
        .stderr(log_err)
        .stdin(std::process::Stdio::null())
        .spawn()?;

    // Save PID for graceful stop
    let pid_path = dirs::home_dir().unwrap_or_default().join(".dginf/provider.pid");
    std::fs::write(&pid_path, child.id().to_string())?;

    println!("╔══════════════════════════════════════════╗");
    println!("║  Provider is running in the background!   ║");
    println!("╚══════════════════════════════════════════╝");
    println!();
    println!("  PID:  {}", child.id());
    println!("  Logs: {}", log_path.display());
    println!();
    println!("Commands:");
    println!("  dginf-provider status     Show provider status");
    println!("  dginf-provider logs       View logs");
    println!("  dginf-provider stop       Stop the provider");
    println!("  dginf-provider doctor     Run diagnostics");
    println!();

    Ok(())
}

async fn cmd_serve(
    local: bool,
    coordinator_url: String,
    port: u16,
    model_override: Option<String>,
    backend_port_override: Option<u16>,
    _all_models: bool,
) -> Result<()> {
    // Kill any existing provider/mlx_lm processes to avoid "address already in use"
    #[cfg(unix)]
    {
        let _ = std::process::Command::new("pkill").args(["-f", "mlx_lm.server"]).status();
        let _ = std::process::Command::new("pkill").args(["-f", "vllm_mlx"]).status();
        // Small delay to let ports free up
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }

    // Verify security posture before serving any inference requests.
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

    // Determine backend port (CLI override > config)
    let be_port = backend_port_override.unwrap_or(cfg.backend.port);

    // Determine models to serve
    let available_models = models::scan_models(&hw);
    let model = if let Some(m) = model_override {
        m
    } else if let Some(m) = cfg.backend.model.clone() {
        m
    } else if let Some(m) = available_models.last() {
        // Default to largest model that fits
        m.id.clone()
    } else {
        "mlx-community/Qwen3.5-9B-MLX-4bit".to_string()
    };

    // Log all available models
    if !available_models.is_empty() {
        tracing::info!("Available models ({}):", available_models.len());
        for m in &available_models {
            tracing::info!("  {} ({:.1} GB)", m.id, m.estimated_memory_gb);
        }
    }
    tracing::info!("Primary model: {}", model);

    // Kill any existing process on our backend port to avoid EADDRINUSE
    if let Ok(output) = std::process::Command::new("lsof")
        .args(["-ti", &format!(":{}", be_port)])
        .output()
    {
        let pids = String::from_utf8_lossy(&output.stdout);
        for pid in pids.split_whitespace() {
            if let Ok(pid_num) = pid.parse::<u32>() {
                if pid_num != std::process::id() {
                    tracing::info!("Killing existing process on port {}: PID {}", be_port, pid_num);
                    let _ = std::process::Command::new("kill").arg(pid).output();
                }
            }
        }
        if !pids.trim().is_empty() {
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
    }

    // Find bundled Python at ~/.dginf/python (standalone Python 3.12 + vllm-mlx)
    let dginf_dir = dirs::home_dir().unwrap_or_default().join(".dginf");
    let bundled_python = dginf_dir.join("python/bin/python3.12");
    let python_cmd = if bundled_python.exists() {
        tracing::info!("Using bundled Python: {}", bundled_python.display());
        unsafe { std::env::set_var("PYTHONHOME", dginf_dir.join("python")); }
        bundled_python.to_string_lossy().to_string()
    } else {
        tracing::info!("Using system Python (bundled Python not found at ~/.dginf/python)");
        "python3".to_string()
    };

    // Start inference backend via bundled Python
    tracing::info!("Starting inference backend for model: {}", model);

    let serve_result = std::process::Command::new(&python_cmd)
        .args(["-m", "vllm_mlx.server", "--model", &model, "--port", &be_port.to_string()])
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .spawn();

    let backend_name = match serve_result {
        Ok(child) => {
            tracing::info!("vllm-mlx started (PID: {:?}) on port {}", child.id(), be_port);
            "vllm-mlx"
        }
        Err(e) => {
            tracing::info!("vllm-mlx CLI failed ({e}), falling back to mlx_lm.server");
            let mlx_serve = std::process::Command::new(&python_cmd)
                .args(["-m", "mlx_lm.server", "--model", &model, "--port", &be_port.to_string()])
                .stdout(std::process::Stdio::inherit())
                .stderr(std::process::Stdio::inherit())
                .spawn();
            match mlx_serve {
                Ok(child) => {
                    tracing::info!("mlx_lm.server started (PID: {:?}) on port {}", child.id(), be_port);
                    "mlx_lm"
                }
                Err(e) => anyhow::bail!(
                    "Failed to start inference backend: {e}.\n\
                     Reinstall: curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash"
                ),
            }
        }
    };
    tracing::info!("Backend: {} on port {}", backend_name, be_port);

    // Wait for model to load
    tracing::info!("Waiting for model to load...");
    let backend_url_str = format!("http://127.0.0.1:{}", be_port);
    for i in 0..30 {
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        if backend::check_health(&backend_url_str).await {
            tracing::info!("Backend ready after {}s", (i + 1) * 2);
            break;
        }
        if i == 29 {
            tracing::warn!("Backend health check timed out after 60s — continuing anyway");
        }
    }

    let backend_url = backend_url_str.clone();
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
        .with_attestation(attestation)
        .with_wallet_address(
            wallet::Wallet::load_or_create()
                .ok()
                .map(|w| w.address.clone())
        );

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

        #[cfg(feature = "python")]
        let shared_engine: Option<std::sync::Arc<tokio::sync::Mutex<inference::InProcessEngine>>> =
            if is_inprocess {
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

                        #[cfg(feature = "python")]
                        if let Some(ref engine) = shared_engine {
                            let engine = engine.clone();
                            tokio::spawn(async move {
                                handle_inprocess_request(request_id, body, engine, tx).await;
                            });
                        } else {
                            let url = proxy_backend_url.clone();
                            let kp = proxy_keypair.clone();
                            tokio::spawn(async move {
                                proxy::handle_inference_request(request_id, body, url, tx, Some(kp)).await;
                            });
                        }

                        #[cfg(not(feature = "python"))]
                        {
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

    // Clean up mlx_lm.server
    #[cfg(unix)]
    { let _ = std::process::Command::new("pkill").args(["-f", "mlx_lm.server"]).status();
        let _ = std::process::Command::new("pkill").args(["-f", "vllm_mlx"]).status(); }

    Ok(())
}

/// Handle an inference request using the in-process engine (no HTTP, no subprocess).
#[cfg(feature = "python")]
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
/// If the existing enclave key produces an invalid signature (stale key from
/// OS update or enclave reset), the key file is automatically deleted and
/// regenerated. This avoids providers registering with unverifiable attestations.
///
/// Returns None if the CLI tool is not available or fails (graceful degradation).
fn generate_attestation(encryption_key_base64: &str, binary_hash: Option<&str>) -> Option<Box<serde_json::value::RawValue>> {
    // Look for the enclave CLI binary in common locations
    // Check ~/.dginf/bin first (standard install location)
    let home_bin = dirs::home_dir()
        .unwrap_or_default()
        .join(".dginf/bin/dginf-enclave");
    let home_bin_str = home_bin.to_string_lossy().to_string();

    let binary_paths = [
        // Standard install location
        home_bin_str.as_str(),
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

    // Try up to 2 times: first with existing key, then with fresh key if stale
    for attempt in 0..2 {
        if attempt == 1 {
            // Delete stale enclave key and retry
            let home = dirs::home_dir().unwrap_or_default();
            let key_path = home.join(".dginf/enclave_key.data");
            if key_path.exists() {
                tracing::warn!("Deleting stale enclave key at {}", key_path.display());
                let _ = std::fs::remove_file(&key_path);
            }
        }

        tracing::info!("Generating Secure Enclave attestation via {} (attempt {})", binary.display(), attempt + 1);

        let mut args = vec!["attest", "--encryption-key", encryption_key_base64];
        let hash_string;
        if let Some(hash) = binary_hash {
            hash_string = hash.to_string();
            args.push("--binary-hash");
            args.push(&hash_string);
        }

        let output = match std::process::Command::new(&binary).args(&args).output() {
            Ok(o) => o,
            Err(e) => {
                tracing::warn!("Failed to run dginf-enclave: {e}");
                return None;
            }
        };

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            tracing::warn!("dginf-enclave failed: {stderr}");
            if attempt == 0 {
                tracing::info!("Retrying with fresh enclave key...");
                continue;
            }
            return None;
        }

        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();

        // Validate it's valid JSON with a signature field
        let check: serde_json::Value = match serde_json::from_str(&stdout) {
            Ok(j) => j,
            Err(e) => {
                tracing::warn!("Failed to parse attestation JSON: {e}");
                return None;
            }
        };

        if let Some(sig) = check.get("signature").and_then(|s| s.as_str()) {
            if sig.is_empty() {
                tracing::warn!("Attestation has empty signature");
                if attempt == 0 {
                    tracing::info!("Retrying with fresh enclave key...");
                    continue;
                }
            }
        }

        // Return as RawValue to preserve exact Swift JSON encoding.
        // This is critical: the signature was computed over Swift's specific
        // JSON byte encoding. Re-serializing through serde_json::Value
        // changes the bytes and breaks signature verification.
        match serde_json::value::RawValue::from_string(stdout) {
            Ok(raw) => {
                tracing::info!("Secure Enclave attestation generated successfully (raw bytes preserved)");
                return Some(raw);
            }
            Err(e) => {
                tracing::warn!("Failed to create RawValue: {e}");
                return None;
            }
        }
    }

    None
}

/// Self-verify an attestation's P-256 ECDSA signature using macOS security tools.
/// Returns true if the signature is valid, false if stale/invalid.
fn self_verify_attestation(attestation_json: &serde_json::Value) -> bool {
    use base64::Engine;

    let signature_b64 = match attestation_json.get("signature").and_then(|s| s.as_str()) {
        Some(s) if !s.is_empty() => s,
        _ => return false,
    };

    let attestation_blob = match attestation_json.get("attestation") {
        Some(blob) => blob,
        None => return false,
    };

    let public_key_b64 = match attestation_blob.get("publicKey").and_then(|p| p.as_str()) {
        Some(p) => p,
        None => return false,
    };

    // Re-encode the attestation blob as sorted JSON (matching what was signed)
    let blob_json = match serde_json::to_string(attestation_blob) {
        Ok(j) => j,
        Err(_) => return false,
    };

    // Decode base64 values
    let sig_bytes = match base64::engine::general_purpose::STANDARD.decode(signature_b64) {
        Ok(b) => b,
        Err(_) => return false,
    };
    let pubkey_bytes = match base64::engine::general_purpose::STANDARD.decode(public_key_b64) {
        Ok(b) => b,
        Err(_) => return false,
    };

    // Write temp files for openssl verification
    let tmp_dir = std::env::temp_dir();
    let sig_path = tmp_dir.join("dginf-verify-sig.der");
    let data_path = tmp_dir.join("dginf-verify-data.bin");
    let pubkey_path = tmp_dir.join("dginf-verify-pubkey.der");

    // Write signature and raw data (openssl dgst will hash it)
    if std::fs::write(&sig_path, &sig_bytes).is_err() { return false; }
    if std::fs::write(&data_path, blob_json.as_bytes()).is_err() { return false; }

    // Build DER-encoded SubjectPublicKeyInfo for P-256
    // ASN.1: SEQUENCE { SEQUENCE { OID ecPublicKey, OID prime256v1 }, BIT STRING { pubkey } }
    let mut spki = vec![
        0x30, 0x59, // SEQUENCE, length 89
        0x30, 0x13, // SEQUENCE, length 19
        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, // OID 1.2.840.10045.2.1 (ecPublicKey)
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, // OID 1.2.840.10045.3.1.7 (prime256v1)
        0x03, 0x42, 0x00, // BIT STRING, length 66, no unused bits
    ];
    // pubkey_bytes should be 65 bytes (0x04 + 32 X + 32 Y) or 64 bytes (raw X||Y)
    if pubkey_bytes.len() == 64 {
        spki.push(0x04); // uncompressed point prefix
    }
    spki.extend_from_slice(&pubkey_bytes);
    // Fix SPKI length if pubkey was 64 bytes (we added 0x04, total = 90)
    if pubkey_bytes.len() == 64 {
        spki[1] = 0x5a; // outer SEQUENCE length = 90
        spki[24] = 0x43; // BIT STRING length = 67
    }

    if std::fs::write(&pubkey_path, &spki).is_err() { return false; }

    // Verify with openssl
    let result = std::process::Command::new("/usr/bin/openssl")
        .args([
            "dgst", "-sha256", "-verify", &pubkey_path.to_string_lossy(),
            "-signature", &sig_path.to_string_lossy(),
            "-keyform", "DER",
            &data_path.to_string_lossy().into_owned(),
        ])
        .output();

    // Cleanup
    let _ = std::fs::remove_file(&sig_path);
    let _ = std::fs::remove_file(&data_path);
    let _ = std::fs::remove_file(&pubkey_path);

    match result {
        Ok(output) => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            stdout.contains("Verified OK")
        }
        Err(_) => false,
    }
}

async fn cmd_enroll(profile_url: String) -> Result<()> {
    println!("DGInf MDM Enrollment");
    println!();

    // Download profile
    let profile_path = std::env::temp_dir().join("DGInf-Enroll.mobileconfig");
    println!("Downloading enrollment profile...");
    let client = reqwest::Client::new();
    let resp = client.get(&profile_url).send().await?;
    if !resp.status().is_success() {
        anyhow::bail!("Failed to download profile: HTTP {}", resp.status());
    }
    let bytes = resp.bytes().await?;
    std::fs::write(&profile_path, &bytes)?;
    println!("  Downloaded to {}", profile_path.display());

    // Open for install
    #[cfg(target_os = "macos")]
    {
        println!();
        println!("Opening System Settings → Profiles...");
        println!("Click Install on the DGInf profile.");
        println!();
        let _ = std::process::Command::new("open").arg(&profile_path).status();
    }

    println!("After installing, verify with: dginf-provider doctor");
    Ok(())
}

async fn cmd_unenroll() -> Result<()> {
    println!("DGInf Unenrollment");
    println!();

    if security::check_mdm_enrolled() {
        println!("MDM profile found. To remove:");
        println!("  System Settings → General → Device Management");
        println!("  Click on the DGInf profile → Remove");
        println!();
        #[cfg(target_os = "macos")]
        {
            println!("Opening System Settings...");
            let _ = std::process::Command::new("open")
                .arg("x-apple.systempreferences:com.apple.preferences.configurationprofiles")
                .status();
        }
    } else {
        println!("No DGInf MDM profile found. Nothing to remove.");
    }

    // Clean up local data
    println!();
    println!("Clean up local DGInf data? This removes:");
    println!("  - Config: ~/.config/dginf/");
    println!("  - Node key: ~/.dginf/node_key");
    println!("  - Enclave key: ~/.dginf/enclave_key.data");
    println!("  - Wallet key from Keychain");
    println!();
    println!("Type 'yes' to confirm:");
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    if input.trim() == "yes" {
        let home = dirs::home_dir().unwrap_or_default();
        let _ = std::fs::remove_dir_all(home.join(".config/dginf"));
        let _ = std::fs::remove_file(home.join(".dginf/node_key"));
        let _ = std::fs::remove_file(home.join(".dginf/enclave_key.data"));
        let _ = wallet::Wallet::delete();
        println!("  ✓ Local data and wallet cleaned up");
    } else {
        println!("  Skipped cleanup");
    }

    Ok(())
}

async fn cmd_benchmark() -> Result<()> {
    let hw = hardware::detect()?;
    println!("DGInf Benchmark — {}", hw.chip_name);
    println!();

    // Check if mlx-lm is available
    let has_mlx = std::process::Command::new("python3")
        .args(["-c", "import mlx_lm; print('ok')"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if !has_mlx {
        println!("mlx-lm not installed. Install with: pip3 install mlx-lm");
        return Ok(());
    }

    // Scan available models
    let models = models::scan_models(&hw);
    if models.is_empty() {
        println!("No models downloaded. Download one first:");
        println!("  huggingface-cli download mlx-community/Qwen3.5-9B-MLX-4bit");
        return Ok(());
    }

    // Benchmark each available model
    for model in &models {
        println!("Benchmarking: {} ({:.1} GB)", model.id, model.estimated_memory_gb);
        let output = std::process::Command::new("python3")
            .args(["-c", &format!(
                "import mlx_lm, time\n\
                 m, t = mlx_lm.load('{}')\n\
                 prompt = '<|im_start|>user\\nWrite a short poem about the ocean.<|im_end|>\\n<|im_start|>assistant\\n'\n\
                 start = time.time()\n\
                 result = mlx_lm.generate(m, t, prompt=prompt, max_tokens=100)\n\
                 elapsed = time.time() - start\n\
                 tokens = len(result.split())\n\
                 print(f'  Tokens: {{tokens}}, Time: {{elapsed:.2f}}s, Speed: {{tokens/elapsed:.1f}} tok/s')",
                model.id
            )])
            .output();
        match output {
            Ok(o) if o.status.success() => {
                print!("{}", String::from_utf8_lossy(&o.stdout));
            }
            _ => println!("  Failed to benchmark this model"),
        }
        println!();
    }

    Ok(())
}

async fn cmd_status() -> Result<()> {
    let hw = hardware::detect()?;
    println!("DGInf Provider Status");
    println!();

    // Hardware
    println!("Hardware:");
    println!("  Chip:       {}", hw.chip_name);
    println!("  Memory:     {} GB total, {} GB available", hw.memory_gb, hw.memory_available_gb);
    println!("  GPU:        {} cores", hw.gpu_cores);
    println!("  Bandwidth:  {} GB/s", hw.memory_bandwidth_gbs);
    println!();

    // Security
    println!("Security:");
    let sip = security::check_sip_enabled();
    println!("  SIP:              {}", if sip { "✓ Enabled" } else { "✗ DISABLED" });
    println!("  Secure Enclave:   ✓ Available (Apple Silicon)");

    println!("  MDM enrolled:     {}", if security::check_mdm_enrolled() { "✓ Yes" } else { "✗ No" });
    println!();

    // Config
    let config_path = config::default_config_path()?;
    println!("Config:");
    println!("  Config file:  {}", if config_path.exists() { config_path.display().to_string() } else { "Not created (run: dginf-provider init)".to_string() });
    let key_path = crypto::default_key_path()?;
    println!("  Node key:     {}", if key_path.exists() { "✓ Generated" } else { "✗ Not generated" });

    let home = dirs::home_dir().unwrap_or_default();
    let enclave_key = home.join(".dginf/enclave_key.data");
    println!("  Enclave key:  {}", if enclave_key.exists() { "✓ Generated" } else { "✗ Not generated" });
    println!();

    // Models
    let models = models::scan_models(&hw);
    println!("Models: {} downloaded", models.len());
    for m in &models {
        println!("  {} ({:.1} GB)", m.id, m.estimated_memory_gb);
    }

    Ok(())
}

async fn cmd_models(action: String) -> Result<()> {
    let hw = hardware::detect()?;
    let downloaded = models::scan_models(&hw);

    let catalog: Vec<(&str, f64, &str)> = vec![
        ("Qwen2.5-0.5B",     0.4,  "mlx-community/Qwen2.5-0.5B-4bit"),
        ("Qwen2.5-1.5B",     1.0,  "mlx-community/Qwen2.5-1.5B-4bit"),
        ("Qwen2.5-3B",       2.0,  "mlx-community/Qwen2.5-3B-4bit"),
        ("Llama-3.2-3B",     2.0,  "mlx-community/Llama-3.2-3B-Instruct-4bit"),
        ("Qwen3.5-9B",       6.0,  "mlx-community/Qwen3.5-9B-MLX-4bit"),
        ("Qwen3.5-27B",     17.0,  "mlx-community/Qwen3.5-27B-4bit"),
        ("Qwen3.5-35B-A3B", 22.0,  "mlx-community/Qwen3.5-35B-A3B-4bit"),
        ("Qwen3.5-122B",    76.0,  "mlx-community/Qwen3.5-122B-A10B-4bit"),
    ];

    match action.as_str() {
        "list" | "ls" => {
            println!("Models for {} ({} GB available):", hw.chip_name, hw.memory_available_gb);
            println!();
            for (name, size, id) in &catalog {
                let fits = hw.memory_available_gb as f64 >= *size;
                let is_downloaded = downloaded.iter().any(|m| m.id == *id);
                let status = if is_downloaded { "✓" } else if fits { " " } else { "✗" };
                let label = if is_downloaded { "downloaded" } else if fits { "available" } else { "too large" };
                println!("  {} {:>5.1} GB  {:15} {:10} {}", status, size, name, label, id);
            }
            // Show any downloaded models not in catalog
            for m in &downloaded {
                let in_catalog = catalog.iter().any(|(_, _, id)| *id == m.id);
                if !in_catalog {
                    println!("  ✓ {:>5.1} GB  {:15} {:10} {}", m.estimated_memory_gb, "", "downloaded", m.id);
                }
            }
        }

        "download" | "add" => {
            println!("Select models to download ({} GB available):", hw.memory_available_gb);
            println!();

            let mut available: Vec<(usize, &str, f64, &str)> = Vec::new();
            for (name, size, id) in &catalog {
                let fits = hw.memory_available_gb as f64 >= *size;
                let is_downloaded = downloaded.iter().any(|m| m.id == *id);
                if is_downloaded {
                    println!("  [✓] {:>5.1} GB  {} (already downloaded)", size, name);
                } else if fits {
                    available.push((available.len() + 1, name, *size, id));
                    println!("  [{}] {:>5.1} GB  {}", available.len(), size, name);
                } else {
                    println!("  [✗] {:>5.1} GB  {} (too large)", size, name);
                }
            }

            if available.is_empty() {
                println!();
                println!("All available models are already downloaded!");
                return Ok(());
            }

            println!();
            println!("  Enter numbers to download (comma-separated, e.g. 1,3):");
            let mut input = String::new();
            std::io::stdin().read_line(&mut input)?;

            let selections: Vec<usize> = input.trim()
                .split(',')
                .filter_map(|s| s.trim().parse::<usize>().ok())
                .collect();

            let dginf_dir = dirs::home_dir().unwrap_or_default().join(".dginf");
            let bundled_python = dginf_dir.join("python/bin/python3");
            let python_cmd = if bundled_python.exists() {
                bundled_python.to_string_lossy().to_string()
            } else {
                "python3".to_string()
            };

            for sel in selections {
                if let Some((_, name, _, id)) = available.iter().find(|(i, _, _, _)| *i == sel) {
                    println!();
                    println!("  Downloading {}...", name);

                    // Try S3 first, then HuggingFace
                    let s3_name = id.split('/').last().unwrap_or(id);
                    let s3_sync = std::process::Command::new("aws")
                        .args(["s3", "sync",
                            &format!("s3://dginf-models/{}/", s3_name),
                            &format!("{}/.cache/huggingface/hub/models--{}/snapshots/main/",
                                dirs::home_dir().unwrap_or_default().display(),
                                id.replace('/', "--")),
                            "--region", "us-east-1", "--no-sign-request"])
                        .status();

                    match s3_sync {
                        Ok(s) if s.success() => println!("  ✓ {} downloaded from DGInf CDN", name),
                        _ => {
                            // Fallback to HuggingFace
                            let hf = std::process::Command::new(&python_cmd)
                                .args(["-c", &format!(
                                    "from huggingface_hub import snapshot_download; snapshot_download('{}')", id
                                )])
                                .status();
                            match hf {
                                Ok(s) if s.success() => println!("  ✓ {} downloaded", name),
                                _ => println!("  ✗ Failed to download {}", name),
                            }
                        }
                    }
                }
            }
        }

        "remove" | "rm" | "delete" => {
            if downloaded.is_empty() {
                println!("No models downloaded.");
                return Ok(());
            }

            println!("Select models to remove:");
            println!();
            for (i, m) in downloaded.iter().enumerate() {
                println!("  [{}] {:.1} GB  {}", i + 1, m.estimated_memory_gb, m.id);
            }
            println!();
            println!("  Enter numbers to remove (comma-separated, e.g. 1,3):");

            let mut input = String::new();
            std::io::stdin().read_line(&mut input)?;

            let selections: Vec<usize> = input.trim()
                .split(',')
                .filter_map(|s| s.trim().parse::<usize>().ok())
                .collect();

            for sel in selections {
                if let Some(m) = downloaded.get(sel.saturating_sub(1)) {
                    let cache_dir = dirs::home_dir().unwrap_or_default()
                        .join(".cache/huggingface/hub")
                        .join(format!("models--{}", m.id.replace('/', "--")));
                    if cache_dir.exists() {
                        std::fs::remove_dir_all(&cache_dir)?;
                        println!("  ✓ Removed {}", m.id);
                    }
                }
            }
        }

        _ => {
            println!("Usage: dginf-provider models [list|download|remove]");
        }
    }

    Ok(())
}

async fn cmd_earnings(coordinator_url: String) -> Result<()> {
    println!("DGInf Earnings");
    println!();

    // Load wallet
    let w = wallet::Wallet::load_or_create()?;
    println!("Wallet: {}", w.address());
    println!();

    // Query coordinator for balance
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()?;

    let health = client.get(format!("{}/health", coordinator_url)).send().await;
    match health {
        Ok(resp) if resp.status().is_success() => {
            let body: serde_json::Value = resp.json().await?;
            println!("Coordinator: online ({} providers connected)", body["providers"]);
        }
        _ => {
            println!("Coordinator: offline or unreachable ({})", coordinator_url);
            println!();
            println!("Cannot fetch earnings while coordinator is offline.");
            return Ok(());
        }
    }

    // Query provider earnings from the coordinator's ledger
    // Uses the provider-specific endpoint that looks up by wallet address
    let earnings_url = format!("{}/v1/provider/earnings?wallet={}", coordinator_url, w.address());
    let earnings_resp = client.get(&earnings_url).send().await;

    println!();
    match earnings_resp {
        Ok(resp) if resp.status().is_success() => {
            let body: serde_json::Value = resp.json().await?;
            let balance_usd = body["balance_usd"].as_str().unwrap_or("0.000000");
            let total_earned_usd = body["total_earned_usd"].as_str().unwrap_or("0.000000");
            let total_jobs = body["total_jobs"].as_i64().unwrap_or(0);

            println!("Earnings:");
            println!("  Balance:       ${}", balance_usd);
            println!("  Total earned:  ${}", total_earned_usd);
            println!("  Jobs served:   {}", total_jobs);

            // Show recent payouts
            if let Some(payouts) = body["payouts"].as_array() {
                let recent: Vec<_> = payouts.iter().rev().take(5).collect();
                if !recent.is_empty() {
                    println!();
                    println!("Recent payouts:");
                    for p in recent {
                        let amount = p["amount_micro_usd"].as_i64().unwrap_or(0);
                        let model = p["model"].as_str().unwrap_or("unknown");
                        let amount_usd = amount as f64 / 1_000_000.0;
                        println!("  ${:.6}  {}", amount_usd, model);
                    }
                }
            }
        }
        Ok(resp) => {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            println!("Earnings: could not fetch (HTTP {})", status);
            if !body.is_empty() {
                println!("  {}", body);
            }
        }
        Err(e) => {
            println!("Earnings: not yet available ({})", e);
            println!("  Earnings accumulate as you serve inference requests.");
            println!("  The coordinator credits your wallet after each job.");
        }
    }

    println!();
    println!("Payout: earnings are settled to your wallet address");
    println!("  via Stripe (USD) or Tempo blockchain (pathUSD) in the future.");

    Ok(())
}

async fn cmd_doctor(coordinator_url: String) -> Result<()> {
    println!("DGInf Doctor — System Diagnostics");
    println!();

    let mut issues: Vec<String> = Vec::new();
    let mut passed = 0;

    // 1. Hardware
    print!("1. Hardware detection........... ");
    match hardware::detect() {
        Ok(hw) => {
            println!("✓ {} ({} GB, {} GPU cores)", hw.chip_name, hw.memory_gb, hw.gpu_cores);
            passed += 1;
        }
        Err(e) => {
            println!("✗ Failed: {e}");
            issues.push("Hardware detection failed".to_string());
        }
    }

    // 2. SIP
    print!("2. System Integrity Protection.. ");
    if security::check_sip_enabled() {
        println!("✓ Enabled");
        passed += 1;
    } else {
        println!("✗ DISABLED — provider cannot serve safely");
        issues.push("SIP is disabled. Enable via Recovery Mode: csrutil enable".to_string());
    }

    // 3. Secure Enclave
    print!("3. Secure Enclave.............. ");
    #[cfg(target_os = "macos")]
    {
        let enclave_ok = std::process::Command::new("dginf-enclave")
            .args(["info"])
            .output()
            .or_else(|_| {
                let home = dirs::home_dir().unwrap_or_default();
                std::process::Command::new(home.join(".dginf/bin/dginf-enclave"))
                    .args(["info"])
                    .output()
            })
            .map(|o| o.status.success())
            .unwrap_or(false);
        if enclave_ok {
            println!("✓ Available");
            passed += 1;
        } else {
            println!("✗ dginf-enclave not found");
            issues.push("Install dginf-enclave binary".to_string());
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        println!("- Not applicable (non-macOS)");
        passed += 1;
    }

    // 4. MDM enrollment
    print!("4. MDM enrollment.............. ");
    if security::check_mdm_enrolled() {
        println!("✓ Enrolled");
        passed += 1;
    } else {
        #[cfg(target_os = "macos")]
        {
            println!("✗ Not enrolled");
            issues.push("Run: dginf-provider enroll".to_string());
        }
        #[cfg(not(target_os = "macos"))]
        {
            println!("- Not applicable (non-macOS)");
            passed += 1;
        }
    }

    // 5. Python + MLX
    print!("5. Python + mlx-lm............. ");
    let mlx_ok = std::process::Command::new("python3")
        .args(["-c", "import mlx_lm; print(mlx_lm.__version__)"])
        .output();
    match mlx_ok {
        Ok(o) if o.status.success() => {
            let ver = String::from_utf8_lossy(&o.stdout).trim().to_string();
            println!("✓ mlx-lm {ver}");
            passed += 1;
        }
        _ => {
            println!("✗ Not installed");
            issues.push("Install: pip3 install mlx-lm".to_string());
        }
    }

    // 6. Models
    print!("6. Downloaded models........... ");
    let hw = hardware::detect().unwrap_or_else(|_| hardware::HardwareInfo {
        machine_model: "unknown".into(), chip_name: "unknown".into(),
        chip_family: hardware::ChipFamily::Unknown, chip_tier: hardware::ChipTier::Unknown,
        memory_gb: 0, memory_available_gb: 0,
        cpu_cores: hardware::CpuCores { total: 0, performance: 0, efficiency: 0 },
        gpu_cores: 0, memory_bandwidth_gbs: 0,
    });
    let model_count = models::scan_models(&hw).len();
    if model_count > 0 {
        println!("✓ {} model(s) found", model_count);
        passed += 1;
    } else {
        println!("✗ No models");
        issues.push("Download: huggingface-cli download mlx-community/Qwen3.5-9B-MLX-4bit".to_string());
    }

    // 7. Node key
    print!("7. Node encryption key......... ");
    let key_path = crypto::default_key_path().unwrap_or_default();
    if key_path.exists() {
        println!("✓ Generated");
        passed += 1;
    } else {
        println!("✗ Not generated");
        issues.push("Run: dginf-provider init".to_string());
    }

    // 8. Coordinator connectivity
    print!("8. Coordinator connectivity.... ");
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()?;
    match client.get(format!("{}/health", coordinator_url)).send().await {
        Ok(resp) if resp.status().is_success() => {
            let body: serde_json::Value = resp.json().await.unwrap_or_default();
            println!("✓ Online ({} providers)", body["providers"]);
            passed += 1;
        }
        Ok(resp) => {
            println!("✗ HTTP {}", resp.status());
            issues.push(format!("Coordinator returned HTTP {}", resp.status()));
        }
        Err(e) => {
            println!("✗ Unreachable: {e}");
            issues.push(format!("Cannot reach coordinator at {coordinator_url}"));
        }
    }

    // Summary
    println!();
    println!("Result: {passed}/8 checks passed");
    if issues.is_empty() {
        println!();
        println!("All good! Start serving with: dginf-provider serve");
    } else {
        println!();
        println!("Issues to fix:");
        for (i, issue) in issues.iter().enumerate() {
            println!("  {}. {}", i + 1, issue);
        }
    }

    Ok(())
}

async fn cmd_start(coordinator_url: String, model_override: Option<String>) -> Result<()> {
    // Stop any existing provider first
    cmd_stop().await?;

    let hw = hardware::detect()?;
    let downloaded = models::scan_models(&hw);

    if downloaded.is_empty() {
        anyhow::bail!("No models downloaded. Run: dginf-provider install");
    }

    // Interactive model selection if no --model specified
    let model = if let Some(m) = model_override {
        m
    } else {
        println!("Select a model to serve (available memory: {} GB):", hw.memory_available_gb);
        println!();

        let mut total_mem = 0.0_f64;
        for (i, m) in downloaded.iter().enumerate() {
            let fits = (total_mem + m.estimated_memory_gb) <= hw.memory_available_gb as f64;
            let marker = if fits { "  " } else { "✗ " };
            println!("  {}[{}] {} ({:.1} GB)", marker, i + 1, m.id, m.estimated_memory_gb);
        }

        println!();
        println!("  Enter number [1-{}] (or press Enter for [{}] - largest):",
            downloaded.len(), downloaded.len());

        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
        let input = input.trim();

        let idx = if input.is_empty() {
            downloaded.len() - 1
        } else {
            input.parse::<usize>().unwrap_or(downloaded.len()).saturating_sub(1)
        };

        let idx = idx.min(downloaded.len() - 1);
        let selected = &downloaded[idx];
        println!("  → {}", selected.id);
        selected.id.clone()
    };

    let exe = std::env::current_exe()?;
    let log_path = dirs::home_dir().unwrap_or_default().join(".dginf/provider.log");
    let pid_path = dirs::home_dir().unwrap_or_default().join(".dginf/provider.pid");

    let log_file = std::fs::File::create(&log_path)?;
    let log_err = log_file.try_clone()?;

    let child = std::process::Command::new(&exe)
        .args(["serve", "--coordinator", &coordinator_url, "--model", &model, "--all-models"])
        .stdout(log_file)
        .stderr(log_err)
        .stdin(std::process::Stdio::null())
        .spawn()?;

    std::fs::write(&pid_path, child.id().to_string())?;

    println!("Provider started in background");
    println!("  PID:   {}", child.id());
    println!("  Model: {}", model);
    println!("  Logs:  {}", log_path.display());
    println!();
    println!("  dginf-provider stop    Stop the provider");
    println!("  dginf-provider logs    View logs");
    println!("  dginf-provider status  Check status");

    Ok(())
}

async fn cmd_stop() -> Result<()> {
    let pid_path = dirs::home_dir().unwrap_or_default().join(".dginf/provider.pid");

    if pid_path.exists() {
        let pid_str = std::fs::read_to_string(&pid_path)?.trim().to_string();
        if let Ok(pid) = pid_str.parse::<i32>() {
            // Send SIGTERM for graceful shutdown
            #[cfg(unix)]
            {
                let result = unsafe { libc::kill(pid, libc::SIGTERM) };
                if result == 0 {
                    println!("Stopping provider (PID: {})...", pid);
                    // Wait up to 5 seconds for it to stop
                    for _ in 0..10 {
                        std::thread::sleep(std::time::Duration::from_millis(500));
                        if unsafe { libc::kill(pid, 0) } != 0 {
                            break;
                        }
                    }
                    // Kill mlx_lm.server too
                    let _ = std::process::Command::new("pkill").args(["-f", "mlx_lm.server"]).status();
        let _ = std::process::Command::new("pkill").args(["-f", "vllm_mlx"]).status();
                    let _ = std::fs::remove_file(&pid_path);
                    println!("Provider stopped.");
                    return Ok(());
                }
            }
        }
        // PID file exists but process isn't running
        let _ = std::fs::remove_file(&pid_path);
    }

    // Fallback: try pkill
    #[cfg(unix)]
    {
        let _ = std::process::Command::new("pkill").args(["-f", "dginf-provider serve"]).status();
        let _ = std::process::Command::new("pkill").args(["-f", "mlx_lm.server"]).status();
        let _ = std::process::Command::new("pkill").args(["-f", "vllm_mlx"]).status();
    }

    println!("Provider stopped.");
    Ok(())
}

async fn cmd_wallet() -> Result<()> {
    println!("DGInf Provider Wallet");
    println!();

    let w = wallet::Wallet::load_or_create()?;
    println!("Address:  {}", w.address());
    println!("Storage:  macOS Keychain (io.dginf.provider)");
    println!();
    println!("This wallet receives your inference earnings.");
    println!("The private key is stored securely in the macOS Keychain");
    println!("and never leaves your machine.");
    println!();
    println!("To delete: dginf-provider unenroll (removes wallet + all data)");

    Ok(())
}

async fn cmd_logs(lines: usize, watch: bool) -> Result<()> {
    let log_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".dginf/provider.log");

    if !log_path.exists() {
        println!("No log file found at {}", log_path.display());
        println!("Start the provider first: dginf-provider start");
        return Ok(());
    }

    if watch {
        // Use tail -f for real-time watching
        let status = std::process::Command::new("tail")
            .args(["-f", "-n", &lines.to_string(), &log_path.to_string_lossy()])
            .status()?;
        if !status.success() {
            anyhow::bail!("tail exited with: {status}");
        }
    } else {
        let content = std::fs::read_to_string(&log_path)?;
        let all_lines: Vec<&str> = content.lines().collect();
        let start = all_lines.len().saturating_sub(lines);
        for line in &all_lines[start..] {
            println!("{line}");
        }
    }

    Ok(())
}

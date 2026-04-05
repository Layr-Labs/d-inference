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
mod hypervisor;
#[cfg(feature = "python")]
mod inference;
mod models;
mod protocol;
mod proxy;
mod security;
mod server;
mod service;
mod wallet;

use anyhow::Result;
use clap::{Parser, Subcommand};
use tracing_subscriber::EnvFilter;

/// A model from the coordinator's supported model catalog.
#[derive(Debug, Clone, serde::Deserialize)]
struct CatalogModel {
    id: String,
    s3_name: String,
    display_name: String,
    #[serde(default = "default_model_type")]
    model_type: String,
    size_gb: f64,
    architecture: String,
    description: String,
    min_ram_gb: i32,
}

fn default_model_type() -> String {
    "text".into()
}

/// Hardcoded fallback catalog used when the coordinator is unreachable.
fn fallback_catalog() -> Vec<CatalogModel> {
    vec![
        CatalogModel {
            id: "CohereLabs/cohere-transcribe-03-2026".into(),
            s3_name: "cohere-transcribe-03-2026".into(),
            display_name: "Cohere Transcribe".into(),
            model_type: "transcription".into(),
            size_gb: 4.2,
            architecture: "2B conformer".into(),
            description: "Best-in-class STT".into(),
            min_ram_gb: 8,
        },
        CatalogModel {
            id: "flux_2_klein_4b_q8p.ckpt".into(),
            s3_name: "flux-klein-4b-q8".into(),
            display_name: "FLUX.2 Klein 4B".into(),
            model_type: "image".into(),
            size_gb: 8.1,
            architecture: "4B diffusion".into(),
            description: "Fast image gen".into(),
            min_ram_gb: 16,
        },
        CatalogModel {
            id: "flux_2_klein_9b_q8p.ckpt".into(),
            s3_name: "flux-klein-9b-q8".into(),
            display_name: "FLUX.2 Klein 9B".into(),
            model_type: "image".into(),
            size_gb: 13.0,
            architecture: "9B diffusion".into(),
            description: "Higher quality image gen".into(),
            min_ram_gb: 24,
        },
        CatalogModel {
            id: "qwen3.5-27b-claude-opus-8bit".into(),
            s3_name: "qwen35-27b-claude-opus-8bit".into(),
            display_name: "Qwen3.5 27B Claude Opus".into(),
            model_type: "text".into(),
            size_gb: 27.0,
            architecture: "27B dense, Claude Opus distilled".into(),
            description: "Frontier quality reasoning".into(),
            min_ram_gb: 36,
        },
        CatalogModel {
            id: "mlx-community/Trinity-Mini-8bit".into(),
            s3_name: "Trinity-Mini-8bit".into(),
            display_name: "Trinity Mini".into(),
            model_type: "text".into(),
            size_gb: 26.0,
            architecture: "27B Adaptive MoE".into(),
            description: "Fast agentic inference".into(),
            min_ram_gb: 48,
        },
        CatalogModel {
            id: "mlx-community/Qwen3.5-122B-A10B-8bit".into(),
            s3_name: "Qwen3.5-122B-A10B-8bit".into(),
            display_name: "Qwen3.5 122B".into(),
            model_type: "text".into(),
            size_gb: 122.0,
            architecture: "122B MoE, 10B active".into(),
            description: "Best quality".into(),
            min_ram_gb: 128,
        },
        CatalogModel {
            id: "mlx-community/MiniMax-M2.5-8bit".into(),
            s3_name: "MiniMax-M2.5-8bit".into(),
            display_name: "MiniMax M2.5".into(),
            model_type: "text".into(),
            size_gb: 243.0,
            architecture: "239B MoE, 11B active".into(),
            description: "SOTA coding, 100 tok/s".into(),
            min_ram_gb: 256,
        },
    ]
}

/// Get available disk space in GB for the home directory.
fn get_available_disk_gb() -> f64 {
    #[cfg(unix)]
    {
        let home = dirs::home_dir().unwrap_or_else(|| std::path::PathBuf::from("/"));
        let path = std::ffi::CString::new(home.to_string_lossy().as_bytes()).unwrap_or_default();
        unsafe {
            let mut stat: libc::statvfs = std::mem::zeroed();
            if libc::statvfs(path.as_ptr(), &mut stat) == 0 {
                return (stat.f_bavail as f64 * stat.f_frsize as f64) / (1024.0 * 1024.0 * 1024.0);
            }
        }
    }
    0.0
}

/// Download a model from the CDN (R2) into the given cache directory.
///
/// Handles text models (safetensors) and image models (.ckpt) from R2.
fn download_model_from_cdn(s3_name: &str, cache_dir: &std::path::Path, display_name: &str) -> bool {
    let base = format!(
        "https://9e92221750c162ade0f2730f63f4963d.r2.cloudflarestorage.com/d-inf-models/{}",
        s3_name
    );

    // Check if this is an image model (.ckpt files, no config.json)
    let is_image_model = s3_name.contains("flux") || s3_name.contains("klein");

    if is_image_model {
        return download_ckpt_model_from_cdn(&base, cache_dir, display_name);
    }

    // 1. Download config.json to verify the model exists on CDN
    let config_ok = std::process::Command::new("curl")
        .args([
            "-fsSL",
            &format!("{}/config.json", base),
            "-o",
            &cache_dir.join("config.json").to_string_lossy(),
        ])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    if !config_ok {
        println!("  ⚠ {} not available on CDN", display_name);
        return false;
    }

    // 2. Download tokenizer files
    for f in &[
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
    ] {
        let _ = std::process::Command::new("curl")
            .args([
                "-fsSL",
                &format!("{}/{}", base, f),
                "-o",
                &cache_dir.join(f).to_string_lossy(),
            ])
            .status();
    }

    // 3. Try single weight file first
    let single_ok = std::process::Command::new("curl")
        .args(["-fsSL", "--head", &format!("{}/model.safetensors", base)])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    if single_ok {
        println!("  Downloading {} weights...", display_name);
        let ok = std::process::Command::new("curl")
            .args([
                "-f#L",
                &format!("{}/model.safetensors", base),
                "-o",
                &cache_dir.join("model.safetensors").to_string_lossy(),
            ])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if ok {
            println!("  ✓ {} downloaded", display_name);
            return true;
        }
    }

    // 4. Sharded model: download index, parse shard names, download each
    let index_path = cache_dir.join("model.safetensors.index.json");
    let index_ok = std::process::Command::new("curl")
        .args([
            "-fsSL",
            &format!("{}/model.safetensors.index.json", base),
            "-o",
            &index_path.to_string_lossy(),
        ])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    if !index_ok {
        println!("  ⚠ Could not download {} weights", display_name);
        return false;
    }

    // Parse the index to get unique shard filenames
    let index_data = match std::fs::read_to_string(&index_path) {
        Ok(d) => d,
        Err(_) => {
            println!("  ⚠ Could not read weight index");
            return false;
        }
    };
    let index_json: serde_json::Value = match serde_json::from_str(&index_data) {
        Ok(v) => v,
        Err(_) => {
            println!("  ⚠ Could not parse weight index");
            return false;
        }
    };

    let mut shards: Vec<String> = Vec::new();
    if let Some(weight_map) = index_json.get("weight_map").and_then(|m| m.as_object()) {
        for filename in weight_map.values() {
            if let Some(f) = filename.as_str() {
                if !shards.contains(&f.to_string()) {
                    shards.push(f.to_string());
                }
            }
        }
    }
    shards.sort();

    if shards.is_empty() {
        println!("  ⚠ No weight shards found in index");
        return false;
    }

    println!(
        "  Downloading {} ({} shards)...",
        display_name,
        shards.len()
    );
    let mut all_ok = true;
    for (i, shard) in shards.iter().enumerate() {
        println!("  [{}/{}] {}", i + 1, shards.len(), shard);
        let ok = std::process::Command::new("curl")
            .args([
                "-f#L",
                &format!("{}/{}", base, shard),
                "-o",
                &cache_dir.join(shard).to_string_lossy(),
            ])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !ok {
            println!("  ⚠ Failed to download {}", shard);
            all_ok = false;
            break;
        }
    }

    if all_ok {
        println!("  ✓ {} downloaded ({} shards)", display_name, shards.len());
    }
    all_ok
}

/// Download image model .ckpt files from R2.
/// Image models have .ckpt weight files instead of safetensors.
fn download_ckpt_model_from_cdn(
    base_url: &str,
    cache_dir: &std::path::Path,
    display_name: &str,
) -> bool {
    // List known .ckpt files for FLUX models
    let ckpt_files: &[&str] = if base_url.contains("9b") {
        &["flux_2_klein_9b_q8p.ckpt"]
    } else if base_url.contains("4b") {
        &["flux_2_klein_4b_q8p.ckpt", "flux_2_vae_f16.ckpt"]
    } else {
        &[]
    };

    if ckpt_files.is_empty() {
        println!("  ⚠ Unknown image model format for {}", display_name);
        return false;
    }

    println!(
        "  Downloading {} ({} files)...",
        display_name,
        ckpt_files.len()
    );

    let mut all_ok = true;
    for (i, f) in ckpt_files.iter().enumerate() {
        println!("  [{}/{}] {}", i + 1, ckpt_files.len(), f);
        let ok = std::process::Command::new("curl")
            .args([
                "-f#L",
                &format!("{}/{}", base_url, f),
                "-o",
                &cache_dir.join(f).to_string_lossy(),
            ])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !ok {
            println!("  ⚠ Failed to download {}", f);
            all_ok = false;
            break;
        }
    }

    if all_ok {
        println!("  ✓ {} downloaded", display_name);
    }
    all_ok
}

/// Ensure a model's tokenizer_config.json contains a chat_template.
///
/// vllm-mlx calls `tokenizer.apply_chat_template()` which requires this field.
/// If missing (common with custom quantizations or stripped configs), inject the
/// standard ChatML template used by Qwen/Llama-family models.
fn ensure_chat_template(model_path: &str) {
    let config_path = std::path::Path::new(model_path).join("tokenizer_config.json");
    if !config_path.exists() {
        return;
    }

    let content = match std::fs::read_to_string(&config_path) {
        Ok(c) => c,
        Err(_) => return,
    };

    let mut config: serde_json::Value = match serde_json::from_str(&content) {
        Ok(v) => v,
        Err(_) => return,
    };

    if config.get("chat_template").is_some() {
        return;
    }

    // Standard ChatML template (compatible with Qwen, Llama, and most instruction-tuned models)
    let chatml_template = concat!(
        "{%- if messages[0]['role'] == 'system' %}",
        "{{- '<|im_start|>system\\n' + messages[0]['content'] + '<|im_end|>\\n' }}",
        "{%- else %}",
        "{{- '<|im_start|>system\\nYou are a helpful assistant.<|im_end|>\\n' }}",
        "{%- endif %}",
        "{%- for message in messages %}",
        "{%- if (message.role == 'user') or (message.role == 'system' and not loop.first) or (message.role == 'assistant') %}",
        "{{- '<|im_start|>' + message.role + '\\n' + message.content + '<|im_end|>' + '\\n' }}",
        "{%- endif %}",
        "{%- endfor %}",
        "{%- if add_generation_prompt %}",
        "{{- '<|im_start|>assistant\\n' }}",
        "{%- endif %}"
    );

    if let Some(obj) = config.as_object_mut() {
        obj.insert(
            "chat_template".to_string(),
            serde_json::Value::String(chatml_template.to_string()),
        );
    }

    match std::fs::write(
        &config_path,
        serde_json::to_string_pretty(&config).unwrap_or_default(),
    ) {
        Ok(()) => tracing::info!("Injected default ChatML template into tokenizer_config.json"),
        Err(e) => tracing::warn!("Failed to write chat_template to tokenizer config: {e}"),
    }
}

/// Fetch the model catalog from the coordinator. Falls back to hardcoded list on failure.
async fn fetch_catalog(coordinator_url: &str) -> Vec<CatalogModel> {
    let base_url = coordinator_url
        .replace("wss://", "https://")
        .replace("ws://", "http://")
        .replace("/ws/provider", "");

    let url = format!("{}/v1/models/catalog", base_url);
    match reqwest::Client::new()
        .get(&url)
        .timeout(std::time::Duration::from_secs(5))
        .send()
        .await
    {
        Ok(resp) if resp.status().is_success() => {
            #[derive(serde::Deserialize)]
            struct CatalogResponse {
                models: Vec<CatalogModel>,
            }
            match resp.json::<CatalogResponse>().await {
                Ok(cr) if !cr.models.is_empty() => cr.models,
                _ => {
                    eprintln!("  ⚠ Empty catalog from coordinator, using defaults");
                    fallback_catalog()
                }
            }
        }
        _ => {
            eprintln!("  ⚠ Could not fetch model catalog from coordinator, using defaults");
            fallback_catalog()
        }
    }
}

#[derive(Parser)]
#[command(name = "dginf-provider", about = "DGInf provider agent for Apple Silicon Macs", version = env!("CARGO_PKG_VERSION"))]
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
        #[arg(
            long,
            default_value = "wss://inference-test.openinnovation.dev/ws/provider"
        )]
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

        /// Image model to serve (e.g. "flux-klein-4b")
        #[arg(long)]
        image_model: Option<String>,

        /// Path to the image model directory for gRPCServerCLI
        #[arg(long)]
        image_model_path: Option<String>,
    },

    /// One-command setup: enroll in MDM, download model, start serving
    Install {
        /// Coordinator URL (WebSocket for serving, HTTPS for API)
        #[arg(
            long,
            default_value = "wss://inference-test.openinnovation.dev/ws/provider"
        )]
        coordinator: String,

        /// MDM enrollment profile URL
        #[arg(
            long,
            default_value = "https://inference-test.openinnovation.dev/enroll.mobileconfig"
        )]
        profile_url: String,

        /// Model to serve (auto-selects if not specified)
        #[arg(long)]
        model: Option<String>,
    },

    /// Enroll this Mac in DGInf MDM (without starting to serve)
    Enroll {
        /// Coordinator URL for device attestation enrollment
        #[arg(long, default_value = "https://inference-test.openinnovation.dev")]
        coordinator: String,
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

        /// Coordinator URL to fetch model catalog
        #[arg(long, default_value = "https://inference-test.openinnovation.dev")]
        coordinator: String,
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
        #[arg(
            long,
            default_value = "wss://inference-test.openinnovation.dev/ws/provider"
        )]
        coordinator: String,

        /// Model to serve
        #[arg(long)]
        model: Option<String>,

        /// Image model to serve (e.g. "flux-klein-4b")
        #[arg(long)]
        image_model: Option<String>,

        /// Path to the image model directory for gRPCServerCLI
        #[arg(long)]
        image_model_path: Option<String>,
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

    /// Show or create provider wallet (stored in ~/.dginf/wallet_key)
    Wallet,

    /// Check for updates and install the latest version
    Update {
        /// Coordinator URL to check for latest version
        #[arg(long, default_value = "https://inference-test.openinnovation.dev")]
        coordinator: String,
    },

    /// Link this machine to your EigenInference account
    Login {
        /// Coordinator URL
        #[arg(long, default_value = "https://inference-test.openinnovation.dev")]
        coordinator: String,
    },

    /// Unlink this machine from your account
    Logout,
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

    // Check for updates in the background — non-blocking, 2s timeout.
    // Shows a one-line alert if a newer version is available.
    check_for_update_alert().await;

    // NOTE: deny_debugger_attachment() is called AFTER subprocess spawning
    // in cmd_serve, not here. PT_DENY_ATTACH poisons mach_task_self_ in
    // the process memory space, causing child processes (Python backend)
    // to crash with SIGBUS when they try to call mach_task_self_.

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
            image_model,
            image_model_path,
        } => {
            // CLI flags override env vars for image model
            if let Some(ref im) = image_model {
                // SAFETY: single-threaded at this point, before tokio runtime starts
                unsafe {
                    std::env::set_var("DGINF_IMAGE_MODEL", im);
                    std::env::set_var("DGINF_IMAGE_MODEL_ID", im);
                }
            }
            if let Some(ref imp) = image_model_path {
                unsafe {
                    std::env::set_var("DGINF_IMAGE_MODEL_PATH", imp);
                }
            }
            cmd_serve(local, coordinator, port, model, backend_port, all_models).await
        }
        Command::Enroll { coordinator } => cmd_enroll(coordinator).await,
        Command::Unenroll => cmd_unenroll().await,
        Command::Benchmark => cmd_benchmark().await,
        Command::Status => cmd_status().await,
        Command::Models {
            action,
            coordinator,
        } => cmd_models(action, coordinator).await,
        Command::Earnings { coordinator } => cmd_earnings(coordinator).await,
        Command::Doctor { coordinator } => cmd_doctor(coordinator).await,
        Command::Start {
            coordinator,
            model,
            image_model,
            image_model_path,
        } => cmd_start(coordinator, model, image_model, image_model_path).await,
        Command::Stop => cmd_stop().await,
        Command::Logs { lines, watch } => cmd_logs(lines, watch).await,
        Command::Wallet => cmd_wallet().await,
        Command::Update { coordinator } => cmd_update(coordinator).await,
        Command::Login { coordinator } => cmd_login(coordinator).await,
        Command::Logout => cmd_logout().await,
    }
}

/// Non-blocking update check. Hits /api/version with a short timeout.
/// If a newer version exists, prints a one-line alert with changelog.
async fn check_for_update_alert() {
    let current = env!("CARGO_PKG_VERSION");

    // Determine coordinator URL from config or default.
    let coordinator_url = config::load(&config::default_config_path().unwrap_or_default())
        .ok()
        .map(|c| {
            c.coordinator
                .url
                .replace("ws://", "http://")
                .replace("wss://", "https://")
                .replace("/ws/provider", "")
        })
        .unwrap_or_else(|| "https://inference-test.openinnovation.dev".to_string());

    let client = match reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(2))
        .build()
    {
        Ok(c) => c,
        Err(_) => return,
    };

    let resp = match client
        .get(format!("{coordinator_url}/api/version"))
        .send()
        .await
    {
        Ok(r) if r.status().is_success() => r,
        _ => return,
    };

    let info: serde_json::Value = match resp.json().await {
        Ok(v) => v,
        Err(_) => return,
    };

    let latest = match info["version"].as_str() {
        Some(v) if v != current && is_newer_version(current, v) => v,
        _ => return,
    };

    let changelog = info["changelog"].as_str().unwrap_or("");

    eprintln!();
    eprintln!("  ╭──────────────────────────────────────────────╮");
    eprintln!("  │  Update available: {current} → {:<17} │", latest);
    if !changelog.is_empty() {
        // Show first 2 lines of changelog.
        for line in changelog.lines().take(2) {
            let truncated = if line.len() > 42 {
                format!("{}...", &line[..39])
            } else {
                line.to_string()
            };
            eprintln!("  │  {:<44}│", truncated);
        }
    }
    eprintln!("  │                                              │");
    eprintln!("  │  Run: dginf-provider update                  │");
    eprintln!("  ╰──────────────────────────────────────────────╯");
    eprintln!();
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
    println!(
        "  ✓ {} ({} GB RAM, {} GPU cores, {} GB/s bandwidth)",
        hw.chip_name, hw.memory_gb, hw.gpu_cores, hw.memory_bandwidth_gbs
    );
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
    println!(
        "  ✓ Wallet: {} (stored in ~/.dginf/wallet_key)",
        w.address()
    );
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
            println!(
                "  ⚠ Could not download profile (HTTP {}). Skipping MDM enrollment.",
                resp.status()
            );
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
                let _ = std::process::Command::new("open")
                    .arg(&profile_path)
                    .status();
            }

            println!("  Press Enter after installing (or to skip)...");
            let mut input = String::new();
            std::io::stdin().read_line(&mut input)?;
        }
    }
    println!();

    // Step 4: Select and download models
    println!("Step 4/6: Setting up inference models...");

    // Fetch supported models from coordinator
    let catalog = fetch_catalog(&coordinator_url).await;

    // Check which models are already downloaded
    let available = models::scan_models(&hw);

    // Check available disk space
    let disk_available_gb = get_available_disk_gb();

    println!("  System: {} ({} GB RAM)", hw.chip_name, hw.memory_gb);
    println!("  Available disk: {:.0} GB", disk_available_gb);
    println!();

    let ram = hw.memory_gb;

    // Determine default and optional models based on RAM tier.
    // Defaults are auto-selected; optionals are everything else that fits.
    let mut defaults: Vec<&CatalogModel> = Vec::new();

    let find_model = |id_contains: &str| -> Option<&CatalogModel> {
        catalog.iter().find(|m| m.id.contains(id_contains))
    };

    if ram >= 256 {
        if let Some(m) = find_model("MiniMax-M2.5") {
            defaults.push(m);
        }
    } else if ram >= 128 {
        if let Some(m) = find_model("Qwen3.5-122B") {
            defaults.push(m);
        }
    } else if ram >= 48 {
        if let Some(m) = find_model("qwen3.5-27b-claude-opus") {
            defaults.push(m);
        }
    } else if ram >= 36 {
        if let Some(m) = find_model("qwen3.5-27b-claude-opus") {
            defaults.push(m);
        }
    } else if ram >= 24 {
        if let Some(m) = find_model("flux_2_klein_9b") {
            defaults.push(m);
        }
    } else if ram >= 16 {
        if let Some(m) = find_model("flux_2_klein_4b") {
            defaults.push(m);
        }
    } else {
        if let Some(m) = find_model("cohere-transcribe") {
            defaults.push(m);
        }
    }

    // Optionals: every catalog model that fits in RAM but isn't already a default
    let default_ids: Vec<&str> = defaults.iter().map(|m| m.id.as_str()).collect();
    let optionals: Vec<&CatalogModel> = catalog
        .iter()
        .filter(|m| m.min_ram_gb <= ram as i32)
        .filter(|m| !default_ids.contains(&m.id.as_str()))
        .collect();

    // Allow explicit model override
    let model = if let Some(m) = model_override {
        m
    } else {
        // Show defaults
        println!("  Default models for your hardware:");
        let mut total_default_size = 0.0_f64;
        for m in &defaults {
            let downloaded = available.iter().any(|a| a.id == m.id);
            let status = if downloaded { "✓ ready" } else { "  " };
            println!(
                "    {} {:30} {:>5.1} GB  {:6}  {}",
                status, m.display_name, m.size_gb, m.model_type, m.description
            );
            if !downloaded {
                total_default_size += m.size_gb;
            }
        }
        println!();

        // Download defaults (ask Y/n)
        let mut models_to_download: Vec<String> = Vec::new();

        if total_default_size > 0.0 {
            if total_default_size > disk_available_gb {
                println!(
                    "  ⚠ Not enough disk space ({:.0} GB needed, {:.0} GB available)",
                    total_default_size, disk_available_gb
                );
                println!("  Free up disk space and retry: dginf-provider install");
            } else {
                use std::io::Write;
                print!(
                    "  Download default models? ({:.0} GB) [Y/n]: ",
                    total_default_size
                );
                std::io::stdout().flush()?;
                let mut input = String::new();
                std::io::stdin().read_line(&mut input)?;
                let input = input.trim().to_lowercase();
                if input.is_empty() || input == "y" || input == "yes" {
                    for m in &defaults {
                        let downloaded = available.iter().any(|a| a.id == m.id);
                        if !downloaded {
                            models_to_download.push(m.id.clone());
                        }
                    }
                }
            }
        } else {
            println!("  All default models already downloaded!");
        }

        // Show and handle optionals (only for 36 GB+ machines)
        if !optionals.is_empty() {
            println!();
            println!("  Optional models (your hardware can also run):");
            for (i, m) in optionals.iter().enumerate() {
                let downloaded = available.iter().any(|a| a.id == m.id);
                let status = if downloaded { "✓" } else { " " };
                println!(
                    "    [{}] {} {:30} {:>5.1} GB  {:6}  {}",
                    i + 1,
                    status,
                    m.display_name,
                    m.size_gb,
                    m.model_type,
                    m.description
                );
            }
            println!();
            use std::io::Write;
            print!("  Download optional models? Enter numbers (e.g. 1,2) or press Enter to skip: ");
            std::io::stdout().flush()?;
            let mut input = String::new();
            std::io::stdin().read_line(&mut input)?;
            let input = input.trim();
            if !input.is_empty() {
                for part in input.split(',') {
                    if let Ok(n) = part.trim().parse::<usize>() {
                        if n >= 1 && n <= optionals.len() {
                            let m = optionals[n - 1];
                            let downloaded = available.iter().any(|a| a.id == m.id);
                            if !downloaded {
                                models_to_download.push(m.id.clone());
                            }
                        }
                    }
                }
            }
        }

        // Download all selected models
        let base_url = coordinator_url
            .replace("wss://", "https://")
            .replace("ws://", "http://")
            .replace("/ws/provider", "");

        for model_id in &models_to_download {
            let s3_name = catalog
                .iter()
                .find(|cm| cm.id == *model_id)
                .map(|cm| cm.s3_name.as_str())
                .unwrap_or_else(|| model_id.split('/').last().unwrap_or(model_id));

            let display = catalog
                .iter()
                .find(|cm| cm.id == *model_id)
                .map(|cm| cm.display_name.as_str())
                .unwrap_or(model_id);

            println!();
            println!("  Downloading {}...", display);

            let cache_dir = dirs::home_dir()
                .unwrap_or_default()
                .join(".cache/huggingface/hub")
                .join(format!("models--{}", model_id.replace('/', "--")))
                .join("snapshots/main");
            std::fs::create_dir_all(&cache_dir)?;

            // Try pre-packaged tarball first (fastest)
            let tarball_url = format!("{}/dl/models/{}.tar.gz", base_url, s3_name);
            let tar_status = std::process::Command::new("bash")
                .args([
                    "-c",
                    &format!(
                        "set -o pipefail; curl -f#L '{}' | tar xz -C '{}'",
                        tarball_url,
                        cache_dir.display()
                    ),
                ])
                .status();

            match tar_status {
                Ok(s) if s.success() => println!("  ✓ {} downloaded", display),
                _ => {
                    download_model_from_cdn(s3_name, &cache_dir, display);
                }
            }
        }

        // Determine primary model for serving (the first default model)
        if !defaults.is_empty() {
            defaults[0].id.clone()
        } else {
            catalog
                .iter()
                .filter(|m| hw.memory_available_gb as f64 >= m.size_gb)
                .last()
                .map(|m| m.id.clone())
                .unwrap_or_default()
        }
    };
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

    // Step 6: Install and start as launchd service
    println!("Step 6/6: Starting provider...");
    println!("  Coordinator: {}", coordinator_url);
    println!("  Model: {}", model);
    println!();

    service::install_and_start(&coordinator_url, &model, None, None)?;

    let log_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".dginf/provider.log");

    println!("╔══════════════════════════════════════════╗");
    println!("║  Provider is running as a system service! ║");
    println!("╚══════════════════════════════════════════╝");
    println!();
    println!("  Service: io.dginf.provider (launchd)");
    println!("  Auto-restart: enabled (KeepAlive)");
    println!("  Logs: {}", log_path.display());
    println!();
    // Prompt to link account if not already logged in.
    if load_auth_token().is_none() {
        println!("╔══════════════════════════════════════════╗");
        println!("║  Link to your account to earn rewards     ║");
        println!("╚══════════════════════════════════════════╝");
        println!();
        println!("  Run this command to connect your provider");
        println!("  to your EigenInference account:");
        println!();
        println!("    dginf-provider login");
        println!();
        println!("  Without linking, earnings go to a local");
        println!("  wallet and cannot be withdrawn.");
        println!();
    }

    println!("Commands:");
    println!("  dginf-provider login      Link to your account");
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
        let _ = std::process::Command::new("pkill")
            .args(["-f", "mlx_lm.server"])
            .status();
        let _ = std::process::Command::new("pkill")
            .args(["-f", "vllm_mlx"])
            .status();
        // Small delay to let ports free up
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }

    // Create the hypervisor VM (no pool yet — we don't know the model
    // size). The pool is created after model selection below.
    match hypervisor::create_vm(0) {
        Ok(()) => {}
        Err(e) => tracing::warn!(
            "Hypervisor not available: {e} — \
             running with software-only memory protection"
        ),
    }

    // Verify security posture before serving any inference requests.
    if let Err(reason) = security::verify_security_posture() {
        anyhow::bail!("Security check failed: {reason}");
    }

    // Prevent system sleep while serving. caffeinate watches our own PID and
    // exits when we die — launchd restarts us, and we spawn a new caffeinate.
    #[cfg(target_os = "macos")]
    {
        let our_pid = std::process::id().to_string();
        match std::process::Command::new("/usr/bin/caffeinate")
            .args(["-s", "-i", "-w", &our_pid])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
        {
            Ok(_) => tracing::info!(
                "Sleep prevention active (caffeinate watching PID {})",
                our_pid
            ),
            Err(e) => tracing::warn!("Could not prevent sleep: {e}"),
        }
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

    // Now that we know the model, size and allocate the hypervisor
    // memory pool. Pool = 2x model file size to cover weights +
    // activations + KV cache. If the pool can't be allocated, the
    // provider continues with software-only protection (but will
    // refuse to serve if RDMA is enabled — fail closed).
    if hypervisor::is_active() {
        let model_bytes = available_models
            .iter()
            .find(|m| m.id == model)
            .map(|m| m.size_bytes)
            .unwrap_or(0);

        if model_bytes > 0 {
            let pool_bytes = model_bytes as usize * 2;
            match hypervisor::allocate_pool(pool_bytes) {
                Ok(()) => {
                    let cap_gb = hypervisor::pool_capacity() as f64 / (1024.0 * 1024.0 * 1024.0);
                    tracing::info!(
                        "Hypervisor memory pool: {:.1} GB (2x model size {:.1} GB)",
                        cap_gb,
                        model_bytes as f64 / (1024.0 * 1024.0 * 1024.0)
                    );
                }
                Err(e) => tracing::warn!("Hypervisor pool allocation failed: {e}"),
            }
        }
    }

    // Backend URL is deterministic — set it early so coordinator and proxy
    // can reference it before the backend process is actually running.
    let backend_url_str = format!("http://127.0.0.1:{}", be_port);
    let backend_url = backend_url_str.clone();
    tracing::info!("Backend URL: {backend_url}");

    // Kill any existing process on our backend port to avoid EADDRINUSE
    if let Ok(output) = std::process::Command::new("lsof")
        .args(["-ti", &format!(":{}", be_port)])
        .output()
    {
        let pids = String::from_utf8_lossy(&output.stdout);
        for pid in pids.split_whitespace() {
            if let Ok(pid_num) = pid.parse::<u32>() {
                if pid_num != std::process::id() {
                    tracing::info!(
                        "Killing existing process on port {}: PID {}",
                        be_port,
                        pid_num
                    );
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
        // Only set PYTHONHOME if this is a real standalone Python install
        // (not a symlink to uv/pyenv/system Python). Wrong PYTHONHOME causes
        // Python to fail to find its stdlib and crash silently.
        let is_standalone =
            !bundled_python.is_symlink() && dginf_dir.join("python/lib/python3.12/os.py").exists();
        if is_standalone {
            tracing::info!("Using bundled Python: {}", bundled_python.display());
            unsafe {
                std::env::set_var("PYTHONHOME", dginf_dir.join("python"));
            }
        } else {
            tracing::info!("Using Python at: {}", bundled_python.display());
        }
        bundled_python.to_string_lossy().to_string()
    } else {
        tracing::info!("Using system Python (bundled Python not found at ~/.dginf/python)");
        "python3".to_string()
    };

    // =========================================================================
    // Phase 1: Connect to coordinator IMMEDIATELY with ALL downloaded models.
    //
    // The provider registers with every model it has cached locally. The
    // backend loads in the background — requests will fail with 503 until the
    // backend is healthy, which is fine because the coordinator won't route
    // traffic until it sees a healthy heartbeat.
    // =========================================================================
    if !local {
        tracing::info!("Connecting to coordinator: {coordinator_url}");
    }

    // Advertise downloaded models. If enabled_models is set in config,
    // only those are offered to the network. Otherwise all downloaded models.
    let all_scanned = models::scan_models(&hw);
    let mut advertised_models = if cfg.backend.enabled_models.is_empty() {
        all_scanned
    } else {
        let enabled = &cfg.backend.enabled_models;
        let filtered: Vec<_> = all_scanned
            .into_iter()
            .filter(|m| {
                enabled
                    .iter()
                    .any(|e| m.id.contains(e) || e.contains(&m.id))
            })
            .collect();
        if filtered.is_empty() {
            tracing::warn!("No enabled_models matched downloaded models — advertising all");
            models::scan_models(&hw)
        } else {
            tracing::info!(
                "Advertising {} of {} downloaded models (filtered by enabled_models)",
                filtered.len(),
                models::scan_models(&hw).len()
            );
            filtered
        }
    };

    // STT model env vars (needed for both advertising and backend startup)
    let stt_port = be_port + 1;
    let stt_model_path = std::env::var("DGINF_STT_MODEL").unwrap_or_default();
    let stt_model_id = std::env::var("DGINF_STT_MODEL_ID")
        .unwrap_or_else(|_| "CohereLabs/cohere-transcribe-03-2026".to_string());

    // Image model env vars (needed for both advertising and backend startup)
    let image_port = be_port + 2;
    let image_model = std::env::var("DGINF_IMAGE_MODEL").unwrap_or_default();
    let image_model_id =
        std::env::var("DGINF_IMAGE_MODEL_ID").unwrap_or_else(|_| image_model.clone());
    let image_model_path = std::env::var("DGINF_IMAGE_MODEL_PATH").unwrap_or_default();

    // Advertise STT model if configured (backend starts later)
    if !stt_model_path.is_empty() && !stt_model_id.is_empty() {
        advertised_models.push(models::ModelInfo {
            id: stt_model_id.clone(),
            model_type: Some("stt".to_string()),
            parameters: None,
            quantization: None,
            size_bytes: 0,
            estimated_memory_gb: 4.0,
            weight_hash: None,
        });
        tracing::info!("Advertising STT model: {stt_model_id}");
    }

    // Advertise image model if configured (backend starts later)
    if !image_model.is_empty() && !image_model_id.is_empty() {
        advertised_models.push(models::ModelInfo {
            id: image_model_id.clone(),
            model_type: Some("image".to_string()),
            parameters: None,
            quantization: None,
            size_bytes: 0,
            estimated_memory_gb: 8.0,
            weight_hash: None,
        });
        tracing::info!("Advertising image model: {image_model_id}");
    }

    // Set up coordinator connection (spawned before backend loading)
    let coordinator_handle;
    let event_rx_opt;
    let outbound_tx_opt;
    let shutdown_tx_opt;
    let inference_active_opt;
    let health_inference_active_opt;
    let provider_stats_opt;

    if !local {
        let (event_tx, event_rx) = tokio::sync::mpsc::channel(64);
        let (outbound_tx, outbound_rx) = tokio::sync::mpsc::channel(64);
        let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

        let backend_name = "vllm_mlx";

        let public_key_b64 = node_keypair.public_key_base64();

        // Compute SHA-256 of our own binary for integrity attestation.
        let binary_hash = security::self_binary_hash();

        // Generate Secure Enclave attestation, binding the X25519 encryption key
        // and our binary hash (so coordinator can verify we're running blessed code).
        let attestation = generate_attestation(&public_key_b64, binary_hash.as_deref());

        // Load device auth token if the provider has been linked to an account.
        let auth_token = load_auth_token();
        if auth_token.is_some() {
            tracing::info!("Provider linked to account (auth token loaded)");
        }

        // Shared flag: true when inference is in progress. Health monitor
        // skips crash detection while the backend is busy generating tokens,
        // because the Python GIL blocks /health during inference.
        let inference_active = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let health_inference_active = inference_active.clone();

        // Shared atomic counters for stats reported in heartbeats.
        let provider_stats = std::sync::Arc::new(coordinator::AtomicProviderStats::new());

        // Shared current model name for heartbeat reporting.
        let current_model: std::sync::Arc<std::sync::Mutex<Option<String>>> =
            std::sync::Arc::new(std::sync::Mutex::new(Some(model.clone())));

        // Shared current model weight hash (cached at load time for challenge responses).
        let initial_model_hash = advertised_models
            .iter()
            .find(|m| m.id == model)
            .and_then(|m| m.weight_hash.clone());
        let current_model_hash: std::sync::Arc<std::sync::Mutex<Option<String>>> =
            std::sync::Arc::new(std::sync::Mutex::new(initial_model_hash));

        let client = coordinator::CoordinatorClient::new(
            coordinator_url,
            hw.clone(),
            advertised_models,
            backend_name.to_string(),
            std::time::Duration::from_secs(cfg.coordinator.heartbeat_interval_secs),
            Some(public_key_b64),
        )
        .with_attestation(attestation)
        .with_wallet_address(
            wallet::Wallet::load_or_create()
                .ok()
                .map(|w| w.address.clone()),
        )
        .with_auth_token(auth_token)
        .with_stats(provider_stats.clone())
        .with_inference_active(inference_active.clone())
        .with_current_model(current_model)
        .with_current_model_hash(current_model_hash);

        // Spawn coordinator connection — this connects immediately while
        // the backend is still loading below.
        let handle = tokio::spawn(async move {
            if let Err(e) = client.run(event_tx, outbound_rx, shutdown_rx).await {
                tracing::error!("Coordinator connection error: {e}");
            }
        });

        coordinator_handle = Some(handle);
        event_rx_opt = Some(event_rx);
        outbound_tx_opt = Some(outbound_tx);
        shutdown_tx_opt = Some(shutdown_tx);
        inference_active_opt = Some(inference_active);
        health_inference_active_opt = Some(health_inference_active);
        provider_stats_opt = Some(provider_stats);
    } else {
        coordinator_handle = None;
        event_rx_opt = None;
        outbound_tx_opt = None;
        shutdown_tx_opt = None;
        inference_active_opt = None;
        health_inference_active_opt = None;
        provider_stats_opt = None;
    }

    // =========================================================================
    // Phase 2: Start backend processes in background.
    //
    // The coordinator is already connected and advertising our models.
    // Backend loading happens concurrently — the provider is visible to the
    // network immediately, and becomes ready to serve once health checks pass.
    // =========================================================================

    // Resolve model ID to local path on disk so the backend loads from disk
    // directly instead of trying to download from HuggingFace.
    let model_path = models::resolve_local_path(&model)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| {
            tracing::warn!("Could not resolve local path for {model} — using ID directly");
            model.clone()
        });
    tracing::info!(
        "Starting inference backend for model: {} (path: {})",
        model,
        model_path
    );

    // Ensure the model's tokenizer_config.json has a chat_template.
    // Some models (especially custom quantizations) ship without one,
    // which causes vllm-mlx to crash with "tokenizer.chat_template is not set".
    ensure_chat_template(&model_path);

    // Backend stdout/stderr is suppressed to prevent prompt content from
    // leaking into provider logs. Some backends log request previews at INFO
    // level, which would expose user prompts to the provider operator.
    // Health/crash detection uses HTTP health checks, not log parsing.
    let backend_module = preferred_inference_backend_module();

    let child = spawn_inference_backend(&python_cmd, backend_module, &model_path, be_port)
        .map_err(|e| {
            anyhow::anyhow!(
                "Failed to start {backend_module}: {e}.\n\
             Reinstall: curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash"
            )
        })?;

    let backend_name = backend_name_for_module(backend_module);
    tracing::info!(
        "{} started (PID: {:?}) on port {}",
        backend_module,
        child.id(),
        be_port
    );
    tracing::info!("Backend: {} on port {}", backend_name, be_port);

    // Wait for model to load
    tracing::info!("Waiting for model to load...");
    let mut backend_ready = false;
    for i in 0..150 {
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        if backend::check_health(&backend_url_str).await {
            tracing::info!("Backend ready after {}s", (i + 1) * 2);
            backend_ready = true;
            break;
        }
    }

    if !backend_ready {
        tracing::error!(
            "Backend {} failed to become healthy after 300s. \
             The provider will stay registered but cannot serve requests. \
             The coordinator will route to other providers.",
            backend_name
        );
    }

    // Start STT backend (continuous-batching stt_server.py) on be_port + 1 if available.
    // DGINF_STT_MODEL: local path or HuggingFace repo ID for the STT model.
    // DGINF_STT_MODEL_ID: clean model name for coordinator registration (optional,
    //   defaults to "CohereLabs/cohere-transcribe-03-2026").
    let _stt_available = if !stt_model_path.is_empty() {
        tracing::info!("Starting STT backend on port {stt_port} for model: {stt_model_path}");

        // Find stt_server.py relative to the binary or in standard locations
        let stt_server_script = find_stt_server_script();
        if stt_server_script.is_none() {
            tracing::warn!("stt_server.py not found — STT will not be available");
            false
        } else {
            let script = stt_server_script.unwrap();
            let stt_result = std::process::Command::new(&python_cmd)
                .args([
                    &script,
                    "--model",
                    &stt_model_path,
                    "--port",
                    &stt_port.to_string(),
                    "--host",
                    "127.0.0.1",
                    "--max-batch-size",
                    "16",
                    "--max-wait-ms",
                    "100",
                ])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn();
            match stt_result {
                Ok(child) => {
                    tracing::info!(
                        "STT server started (PID: {:?}) on port {stt_port}",
                        child.id()
                    );
                    // Wait for STT backend to be ready (model loading can take a few seconds)
                    let stt_url = format!("http://127.0.0.1:{stt_port}");
                    for i in 0..150 {
                        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                        if backend::check_health(&stt_url).await {
                            tracing::info!("STT backend ready after {}s", (i + 1) * 2);
                            break;
                        }
                        if i == 29 {
                            tracing::warn!("STT backend health check timed out after 60s");
                        }
                    }
                    true
                }
                Err(e) => {
                    tracing::warn!("Failed to start STT backend: {e} — STT will not be available");
                    false
                }
            }
        }
    } else {
        tracing::info!("No STT model configured (set DGINF_STT_MODEL to enable)");
        false
    };

    // Start image generation bridge on be_port + 2 if configured.
    // DGINF_IMAGE_MODEL: model ID for the image bridge (e.g. "flux-klein-4b").
    // DGINF_IMAGE_MODEL_PATH: model directory for gRPCServerCLI (optional).
    let _image_available = if !image_model.is_empty() {
        tracing::info!("Starting image bridge on port {image_port} for model: {image_model}");

        let mut bridge_cmd = std::process::Command::new(&python_cmd);

        // Set PYTHONPATH so the image bridge package is importable.
        // Look for it next to the binary, in ~/.dginf, or in the source tree.
        let bridge_paths: Vec<String> = [
            std::env::current_exe().ok().and_then(|p| {
                p.parent()
                    .map(|d| d.join("image-bridge").to_string_lossy().to_string())
            }),
            dirs::home_dir().map(|d| d.join(".dginf/image-bridge").to_string_lossy().to_string()),
        ]
        .iter()
        .filter_map(|p| p.clone())
        .collect();

        if let Ok(existing) = std::env::var("PYTHONPATH") {
            let mut all = bridge_paths;
            all.push(existing);
            bridge_cmd.env("PYTHONPATH", all.join(":"));
        } else if !bridge_paths.is_empty() {
            bridge_cmd.env("PYTHONPATH", bridge_paths.join(":"));
        }

        bridge_cmd.args([
            "-m",
            "dginf_image_bridge",
            "--port",
            &image_port.to_string(),
            "--model",
            &image_model,
            "--system-memory-gb",
            &hw.memory_gb.to_string(),
        ]);
        if !image_model_path.is_empty() {
            bridge_cmd.args(["--model-path", &image_model_path]);
        }
        bridge_cmd
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());

        match bridge_cmd.spawn() {
            Ok(_child) => {
                let mut ready = false;
                for _ in 0..60 {
                    if std::net::TcpStream::connect(format!("127.0.0.1:{image_port}")).is_ok() {
                        ready = true;
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_secs(1));
                }
                if ready {
                    tracing::info!("Image bridge ready on port {image_port}");
                    true
                } else {
                    tracing::error!("Image bridge failed to start within 60s");
                    false
                }
            }
            Err(e) => {
                tracing::error!("Failed to spawn image bridge: {e}");
                false
            }
        }
    } else {
        tracing::info!("No image model configured (set DGINF_IMAGE_MODEL to enable)");
        false
    };

    // Security hardening: prevent debugger attachment AFTER all subprocesses
    // are spawned. PT_DENY_ATTACH poisons mach_task_self_ in the process
    // memory, which causes child Python processes to crash with SIGBUS.
    security::deny_debugger_attachment();

    // =========================================================================
    // Phase 3: Run the main event loop.
    // =========================================================================
    if local {
        // Local-only mode: just start the HTTP server
        tracing::info!("Local-only mode on port {port}");
        server::start_server(port, backend_url).await?;
    } else {
        // Unwrap coordinator state — guaranteed to be Some in non-local mode.
        let mut event_rx = event_rx_opt.unwrap();
        let outbound_tx = outbound_tx_opt.unwrap();
        let shutdown_tx = shutdown_tx_opt.unwrap();
        let inference_active = inference_active_opt.unwrap();
        let health_inference_active = health_inference_active_opt.unwrap();
        let provider_stats = provider_stats_opt.unwrap();
        let coordinator_handle = coordinator_handle.unwrap();

        let backend_name = "vllm_mlx";

        // Spawn backend health monitor — detects crashes and auto-restarts.
        let health_url = backend_url_str.clone();
        let health_python = python_cmd.clone();
        let health_backend = backend_name.to_string();
        let health_model = model_path.clone();
        let health_port = be_port;
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(15));
            let mut consecutive_failures = 0u32;
            loop {
                interval.tick().await;

                // Skip crash detection while inference is active — the Python
                // GIL blocks /health while generating tokens, causing false
                // positives that trigger unnecessary restarts.
                if health_inference_active.load(std::sync::atomic::Ordering::Relaxed) {
                    consecutive_failures = 0;
                    continue;
                }

                if backend::check_health(&health_url).await {
                    if consecutive_failures > 0 {
                        tracing::info!(
                            "Backend recovered after {} failed health checks",
                            consecutive_failures
                        );
                        consecutive_failures = 0;
                    }
                } else {
                    consecutive_failures += 1;
                    tracing::warn!(
                        "Backend health check failed ({consecutive_failures} consecutive)"
                    );
                    if consecutive_failures >= 3 {
                        tracing::error!("Backend appears crashed — restarting...");
                        // Kill any zombie processes
                        #[cfg(unix)]
                        {
                            let _ = std::process::Command::new("pkill")
                                .args(["-f", "vllm_mlx"])
                                .status();
                            let _ = std::process::Command::new("pkill")
                                .args(["-f", "mlx_lm.server"])
                                .status();
                        }
                        tokio::time::sleep(std::time::Duration::from_secs(2)).await;

                        match reload_backend(
                            &health_python,
                            &health_backend,
                            &health_model,
                            health_port,
                        )
                        .await
                        {
                            Ok(()) => {
                                tracing::info!("Backend auto-restarted successfully");
                                consecutive_failures = 0;
                            }
                            Err(e) => {
                                tracing::error!("Backend auto-restart failed: {e}");
                            }
                        }
                    }
                }
            }
        });

        // Process coordinator events
        let proxy_backend_url = backend_url.clone();
        let proxy_keypair = node_keypair.clone();
        let is_inprocess = proxy_backend_url.starts_with("inprocess://");
        let idle_model = model_path.clone();
        let idle_python_cmd = python_cmd.clone();
        let idle_be_port = be_port;
        let idle_backend_name = backend_name.to_string();
        let proxy_stats = provider_stats.clone();
        // The backend knows the model by its local path (e.g. /Users/.../.cache/.../snapshots/main/)
        // but consumer requests use the short model ID (e.g. "qwen3.5-27b-claude-opus-8bit").
        // We need to rewrite the model field before forwarding to the backend.
        let backend_model_name = model_path.clone();

        #[cfg(feature = "python")]
        let shared_engine: Option<
            std::sync::Arc<tokio::sync::Mutex<inference::InProcessEngine>>,
        > = if is_inprocess {
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
            use std::collections::HashMap;
            use tokio_util::sync::CancellationToken;

            // Track in-flight inference tasks so we can cancel them on
            // coordinator disconnect or explicit cancel messages.
            let mut inflight: HashMap<String, (CancellationToken, tokio::task::JoinHandle<()>)> =
                HashMap::new();
            let (done_tx, mut done_rx) = tokio::sync::mpsc::channel::<String>(64);

            // Idle timeout: shut down the backend after 10 minutes of no
            // requests to free GPU memory. Lazy-reload on next request.
            const IDLE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60 * 60);
            let mut last_request_time = tokio::time::Instant::now();
            let mut backend_running = true;

            loop {
                let idle_sleep = async {
                    if backend_running && inflight.is_empty() {
                        tokio::time::sleep_until(last_request_time + IDLE_TIMEOUT).await;
                    } else {
                        std::future::pending::<()>().await;
                    }
                };

                tokio::select! {
                    event = event_rx.recv() => {
                        let Some(event) = event else { break };
                        match event {
                            coordinator::CoordinatorEvent::Connected => {
                                tracing::info!("Connected to coordinator");
                            }
                            coordinator::CoordinatorEvent::Disconnected => {
                                let count = inflight.len();
                                if count > 0 {
                                    tracing::warn!(
                                        "Disconnected from coordinator — aborting {count} in-flight request(s)"
                                    );
                                    for (rid, (token, handle)) in inflight.drain() {
                                        tracing::info!("Aborting request {rid} (coordinator disconnected)");
                                        token.cancel();
                                        handle.abort();
                                    }
                                    inference_active.store(false, std::sync::atomic::Ordering::Relaxed);
                                } else {
                                    tracing::warn!("Disconnected from coordinator");
                                }
                            }
                            coordinator::CoordinatorEvent::InferenceRequest { request_id, body } => {
                                last_request_time = tokio::time::Instant::now();
                                inference_active.store(true, std::sync::atomic::Ordering::Relaxed);

                                // Reload backend if it was idle-shutdown
                                if !backend_running {
                                    tracing::info!("Backend idle-shutdown — reloading for incoming request");
                                    match reload_backend(
                                        &idle_python_cmd,
                                        &idle_backend_name,
                                        &idle_model,
                                        idle_be_port,
                                    ).await {
                                        Ok(()) => {
                                            backend_running = true;
                                        }
                                        Err(e) => {
                                            tracing::error!("Failed to reload backend: {e}");
                                            let _ = outbound_tx.send(
                                                protocol::ProviderMessage::InferenceError {
                                                    request_id,
                                                    error: format!("backend reload failed: {e}"),
                                                    status_code: 503,
                                                }
                                            ).await;
                                            continue;
                                        }
                                    }
                                }

                                // Rewrite the model field to match what the backend expects
                                // (local path instead of short model ID).
                                let mut body = body;
                                if let Some(obj) = body.as_object_mut() {
                                    obj.insert("model".to_string(), serde_json::json!(backend_model_name));
                                }

                                let tx = outbound_tx.clone();
                                let cancel_token = CancellationToken::new();
                                let token_clone = cancel_token.clone();
                                let done_tx = done_tx.clone();
                                let rid = request_id.clone();

                                let handle = {
                                    #[cfg(feature = "python")]
                                    if let Some(ref engine) = shared_engine {
                                        let engine = engine.clone();
                                        let rid2 = rid.clone();
                                        let stats = proxy_stats.clone();
                                        tokio::spawn(async move {
                                            handle_inprocess_request(rid2, body, engine, tx, Some(stats)).await;
                                            let _ = done_tx.send(rid).await;
                                        })
                                    } else {
                                        let url = proxy_backend_url.clone();
                                        let kp = proxy_keypair.clone();
                                        let rid2 = rid.clone();
                                        let stats = proxy_stats.clone();
                                        tokio::spawn(async move {
                                            proxy::handle_inference_request(rid2, body, url, tx, Some(kp), token_clone, Some(stats)).await;
                                            let _ = done_tx.send(rid).await;
                                        })
                                    }

                                    #[cfg(not(feature = "python"))]
                                    {
                                        let url = proxy_backend_url.clone();
                                        let kp = proxy_keypair.clone();
                                        let rid2 = rid.clone();
                                        let stats = proxy_stats.clone();
                                        tokio::spawn(async move {
                                            proxy::handle_inference_request(rid2, body, url, tx, Some(kp), token_clone, Some(stats)).await;
                                            let _ = done_tx.send(rid).await;
                                        })
                                    }
                                };

                                inflight.insert(request_id, (cancel_token, handle));
                            }
                            coordinator::CoordinatorEvent::TranscriptionRequest { request_id, body } => {
                                last_request_time = tokio::time::Instant::now();
                                inference_active.store(true, std::sync::atomic::Ordering::Relaxed);

                                let tx = outbound_tx.clone();
                                let cancel_token = CancellationToken::new();
                                let token_clone = cancel_token.clone();
                                let done_tx = done_tx.clone();
                                let rid = request_id.clone();
                                let stt_url = proxy_backend_url.clone().replace(
                                    &format!(":{}", be_port),
                                    &format!(":{}", be_port + 1),
                                );

                                let handle = tokio::spawn(async move {
                                    proxy::handle_transcription_request(
                                        rid.clone(), body, stt_url, tx, token_clone,
                                    ).await;
                                    let _ = done_tx.send(rid).await;
                                });

                                inflight.insert(request_id, (cancel_token, handle));
                            }
                            coordinator::CoordinatorEvent::ImageGenerationRequest { request_id, body, upload_url } => {
                                last_request_time = tokio::time::Instant::now();

                                let tx = outbound_tx.clone();
                                let cancel_token = CancellationToken::new();
                                let token_clone = cancel_token.clone();
                                let done_tx = done_tx.clone();
                                let rid = request_id.clone();
                                let image_url = proxy_backend_url.clone().replace(
                                    &format!(":{}", be_port),
                                    &format!(":{}", be_port + 2),
                                );

                                let handle = tokio::spawn(async move {
                                    proxy::handle_image_generation_request(
                                        rid.clone(), body, image_url, upload_url, tx, token_clone,
                                    ).await;
                                    let _ = done_tx.send(rid).await;
                                });

                                inflight.insert(request_id, (cancel_token, handle));
                            }
                            coordinator::CoordinatorEvent::Cancel { request_id } => {
                                if let Some((token, _handle)) = inflight.remove(&request_id) {
                                    tracing::info!("Cancelling request {request_id}");
                                    token.cancel();
                                    if inflight.is_empty() {
                                        inference_active.store(false, std::sync::atomic::Ordering::Relaxed);
                                    }
                                } else {
                                    tracing::warn!("Cancel for unknown request {request_id}");
                                }
                            }
                            coordinator::CoordinatorEvent::AttestationChallenge { nonce, timestamp } => {
                                tracing::debug!(
                                    "Attestation challenge event received (nonce={}, ts={})",
                                    &nonce[..8.min(nonce.len())],
                                    timestamp
                                );
                            }
                        }
                    }
                    Some(rid) = done_rx.recv() => {
                        if inflight.remove(&rid).is_some() {
                            tracing::debug!("Request {rid} completed, removed from tracker ({} in-flight)", inflight.len());
                            if inflight.is_empty() {
                                inference_active.store(false, std::sync::atomic::Ordering::Relaxed);
                            }
                        }
                    }
                    _ = idle_sleep => {
                        tracing::info!(
                            "No requests for 10 minutes — shutting down backend to free GPU memory. \
                             Next request will reload and warmup the model (~30-60s cold start)."
                        );
                        shutdown_backend().await;
                        backend_running = false;
                    }
                }
            }
        });

        // Wait for Ctrl+C
        tokio::signal::ctrl_c().await?;
        tracing::info!("Shutting down...");
        let _ = shutdown_tx.send(true);

        let _ = tokio::time::timeout(std::time::Duration::from_secs(5), coordinator_handle).await;
        event_handle.abort();
    }

    // Clean up mlx_lm.server
    #[cfg(unix)]
    {
        let _ = std::process::Command::new("pkill")
            .args(["-f", "mlx_lm.server"])
            .status();
        let _ = std::process::Command::new("pkill")
            .args(["-f", "vllm_mlx"])
            .status();
    }

    Ok(())
}

/// Kill the inference backend process to free GPU memory.
async fn shutdown_backend() {
    #[cfg(unix)]
    {
        let _ = std::process::Command::new("pkill")
            .args(["-f", "vllm_mlx"])
            .status();
        let _ = std::process::Command::new("pkill")
            .args(["-f", "mlx_lm.server"])
            .status();
    }
    // Give processes time to exit and release GPU memory
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    tracing::info!("Backend processes terminated — GPU memory freed");
}

/// Restart the inference backend and wait for it to become healthy.
fn preferred_inference_backend_module() -> &'static str {
    match std::env::var("DGINF_INFERENCE_BACKEND").ok().as_deref() {
        Some("vllm-mlx") | Some("vllm_mlx") | Some("vllm_mlx.server") => "vllm_mlx.server",
        Some("mlx_lm") | Some("mlx_lm.server") => "mlx_lm.server",
        _ => "vllm_mlx.server",
    }
}

fn backend_name_for_module(module: &str) -> &'static str {
    match module {
        "vllm_mlx.server" => "vllm-mlx",
        "mlx_lm.server" => "mlx_lm",
        _ => "unknown",
    }
}

fn spawn_inference_backend(
    python_cmd: &str,
    module: &str,
    model: &str,
    port: u16,
) -> std::io::Result<std::process::Child> {
    let mut cmd = std::process::Command::new(python_cmd);
    cmd.args(["-m", module, "--model", model, "--port", &port.to_string()]);
    cmd.stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
}

async fn reload_backend(
    python_cmd: &str,
    backend_name: &str,
    model: &str,
    port: u16,
) -> anyhow::Result<()> {
    let module = if backend_name == "vllm-mlx" || backend_name == "vllm_mlx" {
        "vllm_mlx.server"
    } else {
        "mlx_lm.server"
    };

    tracing::info!("Reloading backend: {module} for model {model} on port {port}");

    let child = spawn_inference_backend(python_cmd, module, model, port)
        .map_err(|e| anyhow::anyhow!("failed to spawn backend: {e}"))?;

    tracing::info!(
        "Backend process started (PID: {:?}), waiting for model to load...",
        child.id()
    );

    let backend_url = format!("http://127.0.0.1:{}", port);

    // Phase 1: Wait for HTTP server to start listening
    let mut server_up = false;
    for i in 0..150 {
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        if backend::check_health(&backend_url).await {
            tracing::info!(
                "Backend HTTP server ready after {}s, waiting for model load...",
                (i + 1) * 2
            );
            server_up = true;
            break;
        }
    }
    if !server_up {
        anyhow::bail!("backend HTTP server did not start within 300s after reload");
    }

    // Phase 2: Wait for model to be fully loaded into GPU memory
    for i in 0..150 {
        if backend::check_model_loaded(&backend_url).await {
            tracing::info!("Model loaded into GPU memory after {}s total", i * 2);
            break;
        }
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }

    // Phase 3: Warmup — run a single-token inference to prime GPU caches
    tracing::info!("Running warmup inference to prime GPU caches...");
    let warmup_start = std::time::Instant::now();
    backend::warmup_backend(&backend_url).await;
    tracing::info!(
        "Backend fully warm and ready (warmup took {:?})",
        warmup_start.elapsed()
    );

    Ok(())
}

/// Handle an inference request using the in-process engine (no HTTP, no subprocess).
#[cfg(feature = "python")]
async fn handle_inprocess_request(
    request_id: String,
    body: serde_json::Value,
    engine: std::sync::Arc<tokio::sync::Mutex<inference::InProcessEngine>>,
    outbound_tx: tokio::sync::mpsc::Sender<protocol::ProviderMessage>,
    stats: Option<std::sync::Arc<coordinator::AtomicProviderStats>>,
) {
    // Pre-request SIP check
    if !security::check_sip_enabled() {
        let _ = outbound_tx
            .send(protocol::ProviderMessage::InferenceError {
                request_id,
                error: "SIP disabled".to_string(),
                status_code: 503,
            })
            .await;
        return;
    }

    // Extract parameters from OpenAI-format body
    let messages: Vec<serde_json::Value> = body
        .get("messages")
        .and_then(|m| m.as_array())
        .cloned()
        .unwrap_or_default();
    let max_tokens = body
        .get("max_tokens")
        .and_then(|v| v.as_u64())
        .unwrap_or(256);
    let temperature = body
        .get("temperature")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.7);
    let is_streaming = body
        .get("stream")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    // Run inference in blocking task (Python GIL)
    let engine_clone = engine.clone();
    let req_id = request_id.clone();
    let result = tokio::task::spawn_blocking(move || {
        let e = engine_clone.blocking_lock();
        e.generate(&messages, max_tokens, temperature)
    })
    .await;

    match result {
        Ok(Ok(inference_result)) => {
            if is_streaming {
                // Send as a single chunk for now
                let chunk = serde_json::json!({
                    "id": format!("chatcmpl-{}", uuid::Uuid::new_v4()),
                    "object": "chat.completion.chunk",
                    "choices": [{"delta": {"content": inference_result.text}, "index": 0, "finish_reason": "stop"}]
                });
                let _ = outbound_tx
                    .send(protocol::ProviderMessage::InferenceResponseChunk {
                        request_id: request_id.clone(),
                        data: format!(
                            "data: {}",
                            serde_json::to_string(&chunk).unwrap_or_default()
                        ),
                    })
                    .await;
                let _ = outbound_tx
                    .send(protocol::ProviderMessage::InferenceResponseChunk {
                        request_id: request_id.clone(),
                        data: "data: [DONE]".to_string(),
                    })
                    .await;
            }

            let sign_data = format!(
                "{}:{}:{}",
                request_id, inference_result.completion_tokens, "inprocess"
            );
            let response_hash = security::sha256_hex(sign_data.as_bytes());
            let se_signature = security::se_sign(response_hash.as_bytes());

            let completion_tokens = inference_result.completion_tokens;
            let _ = outbound_tx
                .send(protocol::ProviderMessage::InferenceComplete {
                    request_id,
                    usage: protocol::UsageInfo {
                        prompt_tokens: inference_result.prompt_tokens,
                        completion_tokens,
                    },
                    se_signature,
                    response_hash: Some(response_hash),
                })
                .await;
            // Increment shared stats counters for heartbeat reporting.
            if let Some(s) = &stats {
                s.requests_served
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                s.tokens_generated
                    .fetch_add(completion_tokens, std::sync::atomic::Ordering::Relaxed);
            }
        }
        Ok(Err(e)) => {
            tracing::error!("In-process inference failed: {e}");
            let _ = outbound_tx
                .send(protocol::ProviderMessage::InferenceError {
                    request_id,
                    error: e.to_string(),
                    status_code: 500,
                })
                .await;
        }
        Err(e) => {
            tracing::error!("Inference task panicked: {e}");
            let _ = outbound_tx
                .send(protocol::ProviderMessage::InferenceError {
                    request_id,
                    error: "inference task failed".to_string(),
                    status_code: 500,
                })
                .await;
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
/// Find the stt_server.py script in standard locations.
fn find_stt_server_script() -> Option<String> {
    let candidates = [
        // Next to the binary
        std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.join("stt_server.py")))
            .unwrap_or_default(),
        // In the provider source directory (development)
        std::path::PathBuf::from("stt_server.py"),
        // In ~/.dginf
        dirs::home_dir()
            .unwrap_or_default()
            .join(".dginf/stt_server.py"),
    ];

    for path in &candidates {
        if path.exists() {
            return Some(path.to_string_lossy().to_string());
        }
    }
    None
}

fn generate_attestation(
    encryption_key_base64: &str,
    binary_hash: Option<&str>,
) -> Option<Box<serde_json::value::RawValue>> {
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

        tracing::info!(
            "Generating Secure Enclave attestation via {} (attempt {})",
            binary.display(),
            attempt + 1
        );

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
                tracing::info!(
                    "Secure Enclave attestation generated successfully (raw bytes preserved)"
                );
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
    if std::fs::write(&sig_path, &sig_bytes).is_err() {
        return false;
    }
    if std::fs::write(&data_path, blob_json.as_bytes()).is_err() {
        return false;
    }

    // Build DER-encoded SubjectPublicKeyInfo for P-256
    // ASN.1: SEQUENCE { SEQUENCE { OID ecPublicKey, OID prime256v1 }, BIT STRING { pubkey } }
    let mut spki = vec![
        0x30, 0x59, // SEQUENCE, length 89
        0x30, 0x13, // SEQUENCE, length 19
        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
        0x01, // OID 1.2.840.10045.2.1 (ecPublicKey)
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01,
        0x07, // OID 1.2.840.10045.3.1.7 (prime256v1)
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

    if std::fs::write(&pubkey_path, &spki).is_err() {
        return false;
    }

    // Verify with openssl
    let result = std::process::Command::new("/usr/bin/openssl")
        .args([
            "dgst",
            "-sha256",
            "-verify",
            &pubkey_path.to_string_lossy(),
            "-signature",
            &sig_path.to_string_lossy(),
            "-keyform",
            "DER",
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

async fn cmd_enroll(coordinator_url: String) -> Result<()> {
    println!("DGInf Device Attestation Enrollment");
    println!();

    // Check if already enrolled
    if security::check_mdm_enrolled() {
        println!("✓ Already enrolled — no action needed.");
        println!();
        println!("  Verify with: dginf-provider doctor");
        return Ok(());
    }

    // Read serial number from hardware
    let serial = get_serial_number()?;
    println!("→ Device serial: {serial}");

    // Request per-device ACME profile from coordinator
    println!("→ Requesting attestation profile from coordinator...");
    let enroll_url = format!("{coordinator_url}/v1/enroll");
    let client = reqwest::Client::new();
    let resp = client
        .post(&enroll_url)
        .json(&serde_json::json!({"serial_number": serial}))
        .send()
        .await?;

    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to get enrollment profile: {body}");
    }

    let bytes = resp.bytes().await?;
    let profile_path = std::env::temp_dir().join(format!("DGInf-Enroll-{serial}.mobileconfig"));
    std::fs::write(&profile_path, &bytes)?;

    // Open for install
    #[cfg(target_os = "macos")]
    {
        println!("→ Opening attestation profile...");
        println!();
        println!("  Install it in System Settings → General → Device Management");
        println!("  This will:");
        println!("    1. Enroll in MDM for security verification");
        println!("    2. Generate a key in your Secure Enclave");
        println!("    3. Apple verifies your device is genuine hardware");
        println!("    4. A certificate is issued binding the SE key to your device");
        println!();
        let _ = std::process::Command::new("open")
            .arg(&profile_path)
            .status();
    }

    println!("After installing, verify with: dginf-provider doctor");
    Ok(())
}

/// Read the hardware serial number via ioreg.
fn get_serial_number() -> Result<String> {
    let output = std::process::Command::new("ioreg")
        .args(["-c", "IOPlatformExpertDevice", "-d", "2"])
        .output()
        .map_err(|e| anyhow::anyhow!("failed to run ioreg: {e}"))?;

    let text = String::from_utf8_lossy(&output.stdout);
    for line in text.lines() {
        if line.contains("IOPlatformSerialNumber") {
            if let Some(serial) = line.split('"').nth(3) {
                return Ok(serial.to_string());
            }
        }
    }
    anyhow::bail!("could not read serial number from ioreg")
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
    println!("  - Wallet key from Secure Enclave (or ~/.dginf/wallet_key fallback)");
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
        println!(
            "Benchmarking: {} ({:.1} GB)",
            model.id, model.estimated_memory_gb
        );
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
    println!(
        "  Memory:     {} GB total, {} GB available",
        hw.memory_gb, hw.memory_available_gb
    );
    println!("  GPU:        {} cores", hw.gpu_cores);
    println!("  Bandwidth:  {} GB/s", hw.memory_bandwidth_gbs);
    println!();

    // Security
    println!("Security:");
    let sip = security::check_sip_enabled();
    println!(
        "  SIP:              {}",
        if sip { "✓ Enabled" } else { "✗ DISABLED" }
    );
    println!("  Secure Enclave:   ✓ Available (Apple Silicon)");

    println!(
        "  MDM enrolled:     {}",
        if security::check_mdm_enrolled() {
            "✓ Yes"
        } else {
            "✗ No"
        }
    );
    println!();

    // Config
    let config_path = config::default_config_path()?;
    println!("Config:");
    println!(
        "  Config file:  {}",
        if config_path.exists() {
            config_path.display().to_string()
        } else {
            "Not created (run: dginf-provider init)".to_string()
        }
    );
    let key_path = crypto::default_key_path()?;
    println!(
        "  Node key:     {}",
        if key_path.exists() {
            "✓ Generated"
        } else {
            "✗ Not generated"
        }
    );

    let home = dirs::home_dir().unwrap_or_default();
    let enclave_key = home.join(".dginf/enclave_key.data");
    println!(
        "  Enclave key:  {}",
        if enclave_key.exists() {
            "✓ Generated"
        } else {
            "✗ Not generated"
        }
    );
    println!();

    // Models
    let models = models::scan_models(&hw);
    println!("Models: {} downloaded", models.len());
    for m in &models {
        println!("  {} ({:.1} GB)", m.id, m.estimated_memory_gb);
    }

    Ok(())
}

async fn cmd_models(action: String, coordinator_url: String) -> Result<()> {
    let hw = hardware::detect()?;
    let downloaded = models::scan_models(&hw);

    // Fetch model catalog from coordinator
    let catalog = fetch_catalog(&coordinator_url).await;

    match action.as_str() {
        "list" | "ls" => {
            println!(
                "Models for {} ({} GB available):",
                hw.chip_name, hw.memory_available_gb
            );
            println!();
            for cm in &catalog {
                let fits = hw.memory_available_gb as f64 >= cm.size_gb;
                let is_downloaded = downloaded.iter().any(|m| m.id == cm.id);
                let status = if is_downloaded {
                    "✓"
                } else if fits {
                    " "
                } else {
                    "✗"
                };
                let label = if is_downloaded {
                    "downloaded"
                } else if fits {
                    "available"
                } else {
                    "too large"
                };
                println!(
                    "  {} {:>5.1} GB  {:15} {:10} {}",
                    status, cm.size_gb, cm.display_name, label, cm.id
                );
            }
            // Show any downloaded models not in catalog
            for m in &downloaded {
                let in_catalog = catalog.iter().any(|cm| cm.id == m.id);
                if !in_catalog {
                    println!(
                        "  ✓ {:>5.1} GB  {:15} {:10} {}",
                        m.estimated_memory_gb, "", "downloaded", m.id
                    );
                }
            }
        }

        "download" | "add" => {
            println!(
                "Select models to download ({} GB available):",
                hw.memory_available_gb
            );
            println!();

            let mut downloadable: Vec<(usize, &CatalogModel)> = Vec::new();
            for cm in &catalog {
                let fits = hw.memory_available_gb as f64 >= cm.size_gb;
                let is_downloaded = downloaded.iter().any(|m| m.id == cm.id);
                if is_downloaded {
                    println!(
                        "  [✓] {:>5.1} GB  {} (already downloaded)",
                        cm.size_gb, cm.display_name
                    );
                } else if fits {
                    downloadable.push((downloadable.len() + 1, cm));
                    println!(
                        "  [{}] {:>5.1} GB  {}",
                        downloadable.len(),
                        cm.size_gb,
                        cm.display_name
                    );
                } else {
                    println!(
                        "  [✗] {:>5.1} GB  {} (too large)",
                        cm.size_gb, cm.display_name
                    );
                }
            }

            if downloadable.is_empty() {
                println!();
                println!("All available models are already downloaded!");
                return Ok(());
            }

            println!();
            println!("  Enter numbers to download (comma-separated, e.g. 1,3):");
            let mut input = String::new();
            std::io::stdin().read_line(&mut input)?;

            let selections: Vec<usize> = input
                .trim()
                .split(',')
                .filter_map(|s| s.trim().parse::<usize>().ok())
                .collect();

            let base_url = coordinator_url
                .replace("wss://", "https://")
                .replace("ws://", "http://")
                .trim_end_matches('/')
                .to_string();

            for sel in selections {
                if let Some((_, cm)) = downloadable.iter().find(|(i, _)| *i == sel) {
                    println!();
                    println!("  Downloading {}...", cm.display_name);

                    let s3_name = &cm.s3_name;
                    let is_image = cm.model_type == "image";
                    let cache_dir = if is_image {
                        dirs::home_dir()
                            .unwrap_or_default()
                            .join(".dginf/models")
                            .join(s3_name)
                    } else {
                        dirs::home_dir()
                            .unwrap_or_default()
                            .join(".cache/huggingface/hub")
                            .join(format!("models--{}", cm.id.replace('/', "--")))
                            .join("snapshots/main")
                    };
                    let _ = std::fs::create_dir_all(&cache_dir);

                    // Try pre-packaged tarball from CDN first
                    let tarball_url = format!("{}/dl/models/{}.tar.gz", base_url, s3_name);
                    let tar_status = std::process::Command::new("bash")
                        .args([
                            "-c",
                            &format!(
                                "set -o pipefail; curl -f#L '{}' | tar xz -C '{}'",
                                tarball_url,
                                cache_dir.display()
                            ),
                        ])
                        .status();

                    match tar_status {
                        Ok(s) if s.success() => println!("  ✓ {} downloaded", cm.display_name),
                        _ => {
                            download_model_from_cdn(s3_name, &cache_dir, &cm.display_name);
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

            let selections: Vec<usize> = input
                .trim()
                .split(',')
                .filter_map(|s| s.trim().parse::<usize>().ok())
                .collect();

            for sel in selections {
                if let Some(m) = downloaded.get(sel.saturating_sub(1)) {
                    let cache_dir = dirs::home_dir()
                        .unwrap_or_default()
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

    let health = client
        .get(format!("{}/health", coordinator_url))
        .send()
        .await;
    match health {
        Ok(resp) if resp.status().is_success() => {
            let body: serde_json::Value = resp.json().await?;
            println!(
                "Coordinator: online ({} providers connected)",
                body["providers"]
            );
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
    let earnings_url = format!(
        "{}/v1/provider/earnings?wallet={}",
        coordinator_url,
        w.address()
    );
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
            println!(
                "✓ {} ({} GB, {} GPU cores)",
                hw.chip_name, hw.memory_gb, hw.gpu_cores
            );
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
        issues.push(
            "SIP is disabled. To enable:\n\
             \x20    1. Shut down your Mac completely\n\
             \x20    2. Press and hold the power button until \"Loading startup options\" appears\n\
             \x20    3. Select Options → Continue → Utilities → Terminal\n\
             \x20    4. Type: csrutil enable\n\
             \x20    5. Restart your Mac"
                .to_string(),
        );
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

    // 5. Inference runtime (vllm-mlx / mlx-lm)
    print!("5. Inference runtime........... ");
    let dginf_dir = dirs::home_dir().unwrap_or_default().join(".dginf");
    let bundled_python = dginf_dir.join("python/bin/python3.12");
    let (python_cmd, python_home) = if bundled_python.exists() {
        (
            bundled_python.to_string_lossy().to_string(),
            Some(dginf_dir.join("python")),
        )
    } else {
        ("python3".to_string(), None)
    };

    let mut mlx_check = std::process::Command::new(&python_cmd);
    mlx_check.args([
        "-c",
        "import vllm_mlx; print(f'vllm-mlx {vllm_mlx.__version__}')",
    ]);
    if let Some(ref home) = python_home {
        mlx_check.env("PYTHONHOME", home);
    }
    let mlx_ok = mlx_check.output();
    match mlx_ok {
        Ok(o) if o.status.success() => {
            let ver = String::from_utf8_lossy(&o.stdout).trim().to_string();
            println!("✓ {ver}");
            passed += 1;
        }
        _ => {
            // Fallback: try mlx_lm
            let mut fallback = std::process::Command::new(&python_cmd);
            fallback.args(["-c", "import mlx_lm; print(f'mlx-lm {mlx_lm.__version__}')"]);
            if let Some(ref home) = python_home {
                fallback.env("PYTHONHOME", home);
            }
            match fallback.output() {
                Ok(o) if o.status.success() => {
                    let ver = String::from_utf8_lossy(&o.stdout).trim().to_string();
                    println!("✓ {ver}");
                    passed += 1;
                }
                _ => {
                    println!("✗ Not installed");
                    issues.push(
                        "Inference runtime not found. Reinstall:\n\
                         \x20    curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash"
                            .to_string(),
                    );
                }
            }
        }
    }

    // 6. Models
    print!("6. Downloaded models........... ");
    let hw = hardware::detect().unwrap_or_else(|_| hardware::HardwareInfo {
        machine_model: "unknown".into(),
        chip_name: "unknown".into(),
        chip_family: hardware::ChipFamily::Unknown,
        chip_tier: hardware::ChipTier::Unknown,
        memory_gb: 0,
        memory_available_gb: 0,
        cpu_cores: hardware::CpuCores {
            total: 0,
            performance: 0,
            efficiency: 0,
        },
        gpu_cores: 0,
        memory_bandwidth_gbs: 0,
    });
    let model_count = models::scan_models(&hw).len();
    if model_count > 0 {
        println!("✓ {} model(s) found", model_count);
        passed += 1;
    } else {
        println!("✗ No models downloaded");
        issues.push("Download a model: dginf-provider models download".to_string());
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
    match client
        .get(format!("{}/health", coordinator_url))
        .send()
        .await
    {
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

async fn cmd_start(
    coordinator_url: String,
    model_override: Option<String>,
    image_model: Option<String>,
    image_model_path: Option<String>,
) -> Result<()> {
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
        println!(
            "Select a model to serve (available memory: {} GB):",
            hw.memory_available_gb
        );
        println!();

        let mut total_mem = 0.0_f64;
        for (i, m) in downloaded.iter().enumerate() {
            let fits = (total_mem + m.estimated_memory_gb) <= hw.memory_available_gb as f64;
            let marker = if fits { "  " } else { "✗ " };
            println!(
                "  {}[{}] {} ({:.1} GB)",
                marker,
                i + 1,
                m.id,
                m.estimated_memory_gb
            );
        }

        println!();
        println!(
            "  Enter number [1-{}] (or press Enter for [{}] - largest):",
            downloaded.len(),
            downloaded.len()
        );

        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
        let input = input.trim();

        let idx = if input.is_empty() {
            downloaded.len() - 1
        } else {
            input
                .parse::<usize>()
                .unwrap_or(downloaded.len())
                .saturating_sub(1)
        };

        let idx = idx.min(downloaded.len() - 1);
        let selected = &downloaded[idx];
        println!("  → {}", selected.id);
        selected.id.clone()
    };

    let log_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".dginf/provider.log");

    // Install as launchd user agent (auto-restarts on crash)
    service::install_and_start(
        &coordinator_url,
        &model,
        image_model.as_deref(),
        image_model_path.as_deref(),
    )?;

    println!("Provider installed as system service");
    println!("  Model:   {}", model);
    if let Some(ref im) = image_model {
        println!("  Image:   {}", im);
    }
    println!("  Logs:    {}", log_path.display());
    println!("  Service: io.dginf.provider (launchd)");
    println!("  Auto-restart: enabled (KeepAlive)");
    println!();
    println!("  dginf-provider stop    Stop the provider");
    println!("  dginf-provider logs    View logs");
    println!("  dginf-provider status  Check status");

    Ok(())
}

async fn cmd_stop() -> Result<()> {
    let dginf_dir = dirs::home_dir().unwrap_or_default().join(".dginf");
    let pid_path = dginf_dir.join("provider.pid");
    let caffeinate_pid_path = dginf_dir.join("caffeinate.pid");

    // Unload launchd service (stops the process and prevents auto-restart)
    if service::is_loaded() {
        println!("Stopping launchd service...");
        service::stop()?;
    }

    // Clean up legacy PID files from pre-launchd installs
    if caffeinate_pid_path.exists() {
        if let Ok(pid_str) = std::fs::read_to_string(&caffeinate_pid_path) {
            if let Ok(pid) = pid_str.trim().parse::<i32>() {
                #[cfg(unix)]
                unsafe {
                    libc::kill(pid, libc::SIGTERM);
                }
            }
        }
        let _ = std::fs::remove_file(&caffeinate_pid_path);
    }

    if pid_path.exists() {
        let pid_str = std::fs::read_to_string(&pid_path)?.trim().to_string();
        if let Ok(pid) = pid_str.parse::<i32>() {
            #[cfg(unix)]
            {
                let result = unsafe { libc::kill(pid, libc::SIGTERM) };
                if result == 0 {
                    println!("Stopping legacy provider (PID: {})...", pid);
                    for _ in 0..10 {
                        std::thread::sleep(std::time::Duration::from_millis(500));
                        if unsafe { libc::kill(pid, 0) } != 0 {
                            break;
                        }
                    }
                }
            }
        }
        let _ = std::fs::remove_file(&pid_path);
    }

    // Kill any lingering backend processes
    #[cfg(unix)]
    {
        let _ = std::process::Command::new("pkill")
            .args(["-f", "mlx_lm.server"])
            .status();
        let _ = std::process::Command::new("pkill")
            .args(["-f", "vllm_mlx"])
            .status();
    }

    println!("Provider stopped.");
    Ok(())
}

async fn cmd_wallet() -> Result<()> {
    println!("DGInf Provider Wallet");
    println!();

    let w = wallet::Wallet::load_or_create()?;
    println!("Address:  {}", w.address());
    println!("Storage:  ~/.dginf/wallet_key");
    println!();
    println!("This wallet receives your inference earnings.");
    println!();
    println!("To delete: dginf-provider unenroll (removes wallet + all data)");

    Ok(())
}

async fn cmd_update(coordinator: String) -> Result<()> {
    let current_version = env!("CARGO_PKG_VERSION");
    println!("DGInf Provider Update");
    println!();
    println!("  Current version: {current_version}");

    // Check coordinator for latest version
    let base_url = coordinator.trim_end_matches('/');
    let version_url = format!("{base_url}/api/version");

    print!("  Checking for updates... ");
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;

    let resp = match client.get(&version_url).send().await {
        Ok(r) => r,
        Err(e) => {
            println!("failed");
            anyhow::bail!("Could not reach coordinator: {e}");
        }
    };

    if !resp.status().is_success() {
        println!("failed");
        anyhow::bail!("Coordinator returned {}", resp.status());
    }

    let info: serde_json::Value = resp.json().await?;
    let latest = info["version"].as_str().unwrap_or("unknown");
    let download_url = info["download_url"].as_str().unwrap_or("");

    println!("done");
    println!("  Latest version:  {latest}");

    if latest == current_version {
        println!();
        println!("  Already up to date!");
        return Ok(());
    }

    // Compare versions: simple semver check
    if !is_newer_version(current_version, latest) {
        println!();
        println!("  Already up to date!");
        return Ok(());
    }

    println!();
    println!("  Update available: {current_version} → {latest}");

    // Show changelog if available.
    let changelog = info["changelog"].as_str().unwrap_or("");
    if !changelog.is_empty() {
        println!();
        println!("  What's new:");
        for line in changelog.lines() {
            println!("    {line}");
        }
    }

    if download_url.is_empty() {
        println!();
        println!("  To update, run:");
        println!("    curl -fsSL {base_url}/install.sh | bash");
        return Ok(());
    }

    // Download the bundle
    println!("  Downloading update...");
    let tmp_path = "/tmp/dginf-bundle.tar.gz";
    let download = client.get(download_url).send().await?;
    if !download.status().is_success() {
        anyhow::bail!("Download failed: {}", download.status());
    }
    let bytes = download.bytes().await?;
    std::fs::write(tmp_path, &bytes)?;
    println!("  Downloaded {} MB", bytes.len() / 1_048_576);

    // Verify bundle hash if provided by the coordinator.
    let expected_hash = info["bundle_hash"].as_str().unwrap_or("");
    if !expected_hash.is_empty() {
        let actual_hash = security::sha256_hex(&bytes);
        if actual_hash != expected_hash {
            std::fs::remove_file(tmp_path).ok();
            anyhow::bail!(
                "Bundle hash mismatch — download may be compromised!\n  Expected: {expected_hash}\n  Got:      {actual_hash}"
            );
        }
        println!("  Hash verified ✓");
    }

    // Extract and install
    let dginf_dir = dirs::home_dir()
        .ok_or_else(|| anyhow::anyhow!("cannot find home directory"))?
        .join(".dginf");
    let bin_dir = dginf_dir.join("bin");

    println!("  Installing...");
    let status = std::process::Command::new("tar")
        .args(["xzf", tmp_path, "-C", &dginf_dir.to_string_lossy()])
        .status()?;
    if !status.success() {
        anyhow::bail!("tar extraction failed");
    }

    // Move binaries to bin dir
    let _ = std::fs::rename(
        dginf_dir.join("dginf-provider"),
        bin_dir.join("dginf-provider"),
    );
    let _ = std::fs::rename(
        dginf_dir.join("dginf-enclave"),
        bin_dir.join("dginf-enclave"),
    );

    // Make executable
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for name in &["dginf-provider", "dginf-enclave"] {
            let path = bin_dir.join(name);
            if path.exists() {
                let mut perms = std::fs::metadata(&path)?.permissions();
                perms.set_mode(0o755);
                std::fs::set_permissions(&path, perms)?;
            }
        }
    }

    std::fs::remove_file(tmp_path).ok();

    println!();
    println!("  Updated to {latest}!");
    println!();
    println!("  If the provider is running, restart it:");
    println!("    dginf-provider stop && dginf-provider start");

    Ok(())
}

/// Compare two semver strings: returns true if `latest` is newer than `current`.
fn is_newer_version(current: &str, latest: &str) -> bool {
    let parse = |v: &str| -> (u32, u32, u32) {
        let parts: Vec<&str> = v.split('.').collect();
        let major = parts.first().and_then(|s| s.parse().ok()).unwrap_or(0);
        let minor = parts.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);
        let patch = parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(0);
        (major, minor, patch)
    };
    parse(latest) > parse(current)
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

// --- Device auth token storage ---

/// Path to the stored auth token file.
fn auth_token_path() -> std::path::PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("dginf")
        .join("auth_token")
}

/// Load the saved auth token, if any.
fn load_auth_token() -> Option<String> {
    let path = auth_token_path();
    std::fs::read_to_string(&path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Save the auth token to disk.
fn save_auth_token(token: &str) -> Result<()> {
    let path = auth_token_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, token)?;
    // Restrict permissions (owner read/write only).
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

/// Delete the auth token.
fn delete_auth_token() -> Result<()> {
    let path = auth_token_path();
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    Ok(())
}

// --- Login / Logout ---

async fn cmd_login(coordinator_url: String) -> Result<()> {
    // Check if already logged in.
    if let Some(token) = load_auth_token() {
        println!(
            "Already logged in (token: {}...)",
            &token[..std::cmp::min(20, token.len())]
        );
        println!("Run 'dginf-provider logout' first to unlink.");
        return Ok(());
    }

    println!("╔══════════════════════════════════════════╗");
    println!("║     Link to EigenInference Account       ║");
    println!("╚══════════════════════════════════════════╝");
    println!();

    // Step 1: Request a device code from the coordinator.
    let client = reqwest::Client::new();
    let code_url = format!("{}/v1/device/code", coordinator_url);

    let resp = client
        .post(&code_url)
        .timeout(std::time::Duration::from_secs(10))
        .send()
        .await
        .map_err(|e| anyhow::anyhow!("Failed to reach coordinator: {e}"))?;

    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("Failed to get device code: {body}");
    }

    #[derive(serde::Deserialize)]
    struct DeviceCodeResponse {
        device_code: String,
        user_code: String,
        verification_uri: String,
        expires_in: u64,
        interval: u64,
    }

    let dc: DeviceCodeResponse = resp.json().await?;

    println!("  To link this machine, open this URL in your browser:");
    println!();
    println!("    {}", dc.verification_uri);
    println!();
    println!("  Then enter this code:");
    println!();
    println!("    ┌──────────────┐");
    println!("    │  {}  │", dc.user_code);
    println!("    └──────────────┘");
    println!();
    println!(
        "  Waiting for approval (expires in {} minutes)...",
        dc.expires_in / 60
    );

    // Try to open the browser automatically.
    let _ = std::process::Command::new("open")
        .arg(&dc.verification_uri)
        .status();

    // Step 2: Poll for approval.
    let token_url = format!("{}/v1/device/token", coordinator_url);
    let poll_interval = std::time::Duration::from_secs(dc.interval);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(dc.expires_in);

    loop {
        if std::time::Instant::now() > deadline {
            anyhow::bail!("Device code expired. Run 'dginf-provider login' again.");
        }

        tokio::time::sleep(poll_interval).await;

        let poll_resp = client
            .post(&token_url)
            .json(&serde_json::json!({ "device_code": dc.device_code }))
            .timeout(std::time::Duration::from_secs(10))
            .send()
            .await;

        let resp = match poll_resp {
            Ok(r) => r,
            Err(_) => continue, // Network error, retry
        };

        let body: serde_json::Value = match resp.json().await {
            Ok(v) => v,
            Err(_) => continue,
        };

        let status = body["status"].as_str().unwrap_or("");
        match status {
            "authorization_pending" => {
                // Still waiting — keep polling.
                print!(".");
                use std::io::Write;
                let _ = std::io::stdout().flush();
            }
            "authorized" => {
                let token = body["token"]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!("Missing token in response"))?;

                save_auth_token(token)?;

                println!();
                println!();
                println!("  Account linked successfully!");
                println!("  Your provider will now be connected to your account.");
                println!("  Earnings will be credited to your account wallet.");
                println!();
                println!("  Start serving with: dginf-provider serve");
                return Ok(());
            }
            _ => {
                // expired or error
                let msg = body["error"]["message"]
                    .as_str()
                    .unwrap_or("Device code expired or invalid");
                anyhow::bail!("{msg}");
            }
        }
    }
}

async fn cmd_logout() -> Result<()> {
    if load_auth_token().is_none() {
        println!("Not currently logged in.");
        return Ok(());
    }

    delete_auth_token()?;
    println!("Logged out. This machine is no longer linked to an account.");
    println!("Provider earnings will use the local wallet until you log in again.");
    Ok(())
}

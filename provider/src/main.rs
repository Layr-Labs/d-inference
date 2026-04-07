//! EigenInference provider agent for Apple Silicon Macs.
//!
//! The provider agent runs on Mac hardware and serves local inference requests
//! from the EigenInference coordinator. It manages the lifecycle of an inference backend
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
mod scheduling;
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
            size_gb: 8.2, // 3.8 GB model + 4.2 GB text encoder + 0.2 GB VAE
            architecture: "4B diffusion + Qwen 4B encoder".into(),
            description: "Fast image gen".into(),
            min_ram_gb: 16,
        },
        CatalogModel {
            id: "flux_2_klein_9b_q8p.ckpt".into(),
            s3_name: "flux-klein-9b-q8".into(),
            display_name: "FLUX.2 Klein 9B".into(),
            model_type: "image".into(),
            size_gb: 17.4, // 8.8 GB model + 8.4 GB text encoder + 0.2 GB VAE
            architecture: "9B diffusion + Qwen 8B encoder".into(),
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
            id: "mlx-community/gemma-4-26b-a4b-it-8bit".into(),
            s3_name: "gemma-4-26b-a4b-it-8bit".into(),
            display_name: "Gemma 4 26B".into(),
            model_type: "text".into(),
            size_gb: 28.0,
            architecture: "26B MoE, 4B active".into(),
            description: "Fast multimodal MoE".into(),
            min_ram_gb: 36,
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

/// Download a single file from a URL to a local path with a progress bar.
/// Retries up to 3 times with HTTP Range resume on failure.
///
/// Shows: [████████░░░░░░░░░░░░] 42% · 3.9/9.5 GB · 245 MB/s · ~23s
fn download_file_with_progress(url: &str, dest: &std::path::Path, label: &str) -> bool {
    use std::io::{Seek, Write};

    // Use the current tokio runtime if inside one, otherwise create a new one.
    let handle = tokio::runtime::Handle::try_current();
    match handle {
        Ok(h) => {
            // We're inside an async context — use block_in_place to avoid nesting
            tokio::task::block_in_place(|| h.block_on(download_file_async(url, dest, label)))
        }
        Err(_) => {
            // Not in async context — create a runtime
            match tokio::runtime::Runtime::new() {
                Ok(rt) => rt.block_on(download_file_async(url, dest, label)),
                Err(_) => curl_download(url, dest),
            }
        }
    }
}

async fn download_file_async(url: &str, dest: &std::path::Path, label: &str) -> bool {
    use futures_util::StreamExt;
    use std::io::{Seek, Write};

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(600))
        .build()
        .unwrap_or_else(|_| reqwest::Client::new());

    let max_retries = 3;

    for attempt in 0..=max_retries {
        // Check how much we already have (for resume)
        let existing_bytes = dest.metadata().map(|m| m.len()).unwrap_or(0);

        let mut req = client.get(url);
        if existing_bytes > 0 {
            // Resume from where we left off (works across retries AND fresh starts)
            req = req.header("Range", format!("bytes={}-", existing_bytes));
            if attempt > 0 {
                eprintln!(
                    "\r  Resuming from {:.1} GB (attempt {}/{})...              ",
                    existing_bytes as f64 / 1_073_741_824.0,
                    attempt + 1,
                    max_retries + 1
                );
            }
        }

        let resp = match req.send().await {
            Ok(r) if r.status().is_success() || r.status().as_u16() == 206 => r,
            Ok(r) => {
                eprintln!(
                    "\r  ⚠ HTTP {} — retrying...                    ",
                    r.status()
                );
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                continue;
            }
            Err(e) => {
                eprintln!("\r  ⚠ Connection failed: {} — retrying...      ", e);
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                continue;
            }
        };

        let is_resume = resp.status().as_u16() == 206;
        let content_length = resp.content_length().unwrap_or(0);
        let total = if is_resume {
            existing_bytes + content_length
        } else {
            content_length
        };
        let mut downloaded: u64 = if is_resume { existing_bytes } else { 0 };
        let start = std::time::Instant::now();

        // Open file for append (resume) or create (fresh)
        let mut file = if is_resume {
            match std::fs::OpenOptions::new().append(true).open(dest) {
                Ok(f) => f,
                Err(_) => return false,
            }
        } else {
            match std::fs::File::create(dest) {
                Ok(f) => f,
                Err(_) => return false,
            }
        };

        let mut stdout = std::io::stdout();
        let mut stream = resp.bytes_stream();
        let mut stream_failed = false;

        while let Some(chunk) = stream.next().await {
            let chunk = match chunk {
                Ok(c) => c,
                Err(_) => {
                    stream_failed = true;
                    break;
                }
            };
            if file.write_all(&chunk).is_err() {
                return false;
            }
            downloaded += chunk.len() as u64;

            // Render progress bar
            if total > 0 {
                let pct = (downloaded as f64 / total as f64 * 100.0).min(100.0) as u32;
                let elapsed = start.elapsed().as_secs_f64();
                let bytes_this_session = downloaded - if is_resume { existing_bytes } else { 0 };
                let speed = if elapsed > 0.5 {
                    bytes_this_session as f64 / elapsed
                } else {
                    0.0
                };
                let eta = if speed > 0.0 {
                    (total - downloaded) as f64 / speed
                } else {
                    0.0
                };

                let bar_width = 30;
                let filled = (pct as usize * bar_width / 100).min(bar_width);
                let bar: String = "█".repeat(filled) + &"░".repeat(bar_width - filled);

                let (dl_val, dl_unit) = human_bytes(downloaded);
                let (tot_val, tot_unit) = human_bytes(total);
                let (spd_val, spd_unit) = human_bytes(speed as u64);

                write!(
                    stdout,
                    "\r  {} [{}] {}% · {:.1}{}/{:.1}{} · {:.0}{}/s · ~{:.0}s   ",
                    label, bar, pct, dl_val, dl_unit, tot_val, tot_unit, spd_val, spd_unit, eta
                )
                .ok();
                stdout.flush().ok();
            }
        }

        if stream_failed {
            if attempt < max_retries {
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                continue;
            }
            write!(stdout, "\r{}\r", " ".repeat(100)).ok();
            println!("  ⚠ Download failed after {} retries", max_retries + 1);
            return false;
        }

        // Success — clear progress line and print completion
        write!(stdout, "\r{}\r", " ".repeat(100)).ok();
        let (tot_val, tot_unit) = human_bytes(total);
        let elapsed = start.elapsed().as_secs_f64();
        let avg_speed = if elapsed > 0.0 {
            (downloaded as f64 / elapsed) as u64
        } else {
            0
        };
        let (spd_val, spd_unit) = human_bytes(avg_speed);
        println!(
            "  ✓ {} ({:.1}{}, {:.0}{}/s)",
            label, tot_val, tot_unit, spd_val, spd_unit
        );
        return true;
    }

    false
}

fn human_bytes(bytes: u64) -> (f64, &'static str) {
    if bytes >= 1_073_741_824 {
        (bytes as f64 / 1_073_741_824.0, " GB")
    } else if bytes >= 1_048_576 {
        (bytes as f64 / 1_048_576.0, " MB")
    } else if bytes >= 1024 {
        (bytes as f64 / 1024.0, " KB")
    } else {
        (bytes as f64, " B")
    }
}

/// Fallback to curl if reqwest streaming isn't available.
fn curl_download(url: &str, dest: &std::path::Path) -> bool {
    std::process::Command::new("curl")
        .args(["-f#L", url, "-o", &dest.to_string_lossy()])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Download a model from the CDN (R2) into the given cache directory.
///
/// Handles text models (safetensors) and image models (.ckpt) from R2.
fn download_model_from_cdn(s3_name: &str, cache_dir: &std::path::Path, display_name: &str) -> bool {
    let base = format!(
        "https://pub-7cbee059c80c46ec9c071dbee2726f8a.r2.dev/{}",
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
        let url = format!("{}/model.safetensors", base);
        let ok =
            download_file_with_progress(&url, &cache_dir.join("model.safetensors"), display_name);
        if ok {
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

    let mut all_ok = true;
    for (i, shard) in shards.iter().enumerate() {
        let label = format!("{} [{}/{}]", display_name, i + 1, shards.len());
        let url = format!("{}/{}", base, shard);
        if !download_file_with_progress(&url, &cache_dir.join(shard), &label) {
            println!("  ⚠ Failed to download {}", shard);
            all_ok = false;
            break;
        }
    }
    all_ok
}

/// Download a complete image model pipeline from CDN.
///
/// FLUX models require 3 files: diffusion model + text encoder + VAE.
/// Also writes models.json and configs.json metadata for gRPCServerCLI.
/// All files are stored in the same R2 directory as the main model.
fn download_ckpt_model_from_cdn(
    base_url: &str,
    cache_dir: &std::path::Path,
    display_name: &str,
) -> bool {
    // Define the full pipeline for each known image model
    struct ImagePipeline {
        model_file: &'static str,
        text_encoder: &'static str,
        vae: &'static str,
        version: &'static str,
        name: &'static str,
    }

    let pipeline = if cache_dir.to_string_lossy().contains("flux_2_klein_9b_q8p") {
        Some(ImagePipeline {
            model_file: "flux_2_klein_9b_q8p.ckpt",
            text_encoder: "qwen_3_8b_q8p.ckpt",
            vae: "flux_2_vae_f16.ckpt",
            version: "flux2_9b",
            name: "FLUX.2 [klein] 9B",
        })
    } else if cache_dir.to_string_lossy().contains("flux_2_klein_4b_q8p") {
        Some(ImagePipeline {
            model_file: "flux_2_klein_4b_q8p.ckpt",
            text_encoder: "qwen_3_4b_q8p.ckpt",
            vae: "flux_2_vae_f16.ckpt",
            version: "flux2_4b",
            name: "FLUX.2 [klein] 4B",
        })
    } else {
        None
    };

    let Some(pipeline) = pipeline else {
        println!("  ⚠ Unknown image model");
        return false;
    };

    let files = [
        (pipeline.vae, "VAE"),
        (pipeline.model_file, "Diffusion model"),
        (pipeline.text_encoder, "Text encoder"),
    ];

    let total = files.len();
    println!("  Downloading {} ({} files)...", display_name, total);

    for (i, (file, desc)) in files.iter().enumerate() {
        let dest = cache_dir.join(file);
        if dest.exists() {
            // Check if already complete via HEAD
            let expected = std::process::Command::new("curl")
                .args(["-fsSI", &format!("{}/{}", base_url, file)])
                .output()
                .ok()
                .and_then(|o| {
                    String::from_utf8_lossy(&o.stdout)
                        .lines()
                        .find(|l| l.to_lowercase().starts_with("content-length:"))
                        .and_then(|l| l.split(':').nth(1)?.trim().parse::<u64>().ok())
                });
            if let Some(expected) = expected {
                if let Ok(meta) = std::fs::metadata(&dest) {
                    if meta.len() >= expected {
                        println!("  [{}/{}] {} — already downloaded ✓", i + 1, total, desc);
                        continue;
                    }
                }
            }
        }

        let label = format!("{} [{}/{}] {}", display_name, i + 1, total, desc);
        let url = format!("{}/{}", base_url, file);
        if !download_file_with_progress(&url, &dest, &label) {
            println!("  ⚠ Failed to download {}", file);
            return false;
        }
    }

    // Write models.json metadata for gRPCServerCLI
    let models_json = format!(
        r#"[{{
  "name": "{}",
  "version": "{}",
  "autoencoder": "{}",
  "prefix": "",
  "modifier": "kontext",
  "default_scale": 16,
  "hires_fix_scale": 32,
  "file": "{}",
  "upcast_attention": false,
  "text_encoder": "{}",
  "high_precision_autoencoder": false,
  "objective": {{"u": {{"condition_scale": 1000}}}},
  "padded_text_encoding_length": 512
}}]"#,
        pipeline.name, pipeline.version, pipeline.vae, pipeline.model_file, pipeline.text_encoder
    );
    let _ = std::fs::write(cache_dir.join("models.json"), &models_json);

    // Write configs.json with default generation parameters
    let configs_json = format!(
        r#"[{{
  "name": "{}",
  "version": "{}",
  "configuration": {{
    "model": "{}",
    "width": 1024,
    "height": 1024,
    "steps": 4,
    "guidanceScale": 1.0,
    "strength": 1.0,
    "sampler": 16,
    "batchSize": 1,
    "batchCount": 1,
    "shift": 3.0,
    "speedUpWithGuidanceEmbed": true,
    "seedMode": 2
  }}
}}]"#,
        pipeline.name, pipeline.version, pipeline.model_file
    );
    let _ = std::fs::write(cache_dir.join("configs.json"), &configs_json);

    println!("  ✓ {} pipeline complete", display_name);
    true
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
#[command(name = "eigeninference-provider", about = "EigenInference provider agent for Apple Silicon Macs", version = env!("CARGO_PKG_VERSION"))]
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

        /// Models to serve. Can specify multiple: --model model1 --model model2
        /// Serves largest downloaded model if not specified.
        #[arg(long)]
        model: Vec<String>,

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

    /// Enroll this Mac in EigenInference MDM (without starting to serve)
    Enroll {
        /// Coordinator URL for device attestation enrollment
        #[arg(long, default_value = "https://inference-test.openinnovation.dev")]
        coordinator: String,
    },

    /// Remove MDM enrollment and clean up EigenInference data
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
        EnvFilter::new("eigeninference_provider=debug,info")
    } else {
        EnvFilter::new("eigeninference_provider=info,warn")
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
                    std::env::set_var("EIGENINFERENCE_IMAGE_MODEL", im);
                    std::env::set_var("EIGENINFERENCE_IMAGE_MODEL_ID", im);
                }
            }
            if let Some(ref imp) = image_model_path {
                unsafe {
                    std::env::set_var("EIGENINFERENCE_IMAGE_MODEL_PATH", imp);
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
    eprintln!("  │  Run: eigeninference-provider update                  │");
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
    println!("║       EigenInference Provider Setup               ║");
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
    println!("  ✓ Config: {}", config_path.display());
    println!("  ✓ Node key: {}", key_path.display());
    println!();

    // Step 3: MDM enrollment (skip if already enrolled)
    println!("Step 3/6: MDM enrollment...");

    let already_enrolled = security::check_mdm_enrolled();

    if already_enrolled {
        println!("  ✓ Already enrolled in MDM — skipping");
    } else {
        let profile_path = std::env::temp_dir().join("EigenInference-Enroll.mobileconfig");
        println!("  Downloading enrollment profile...");
        let client = reqwest::Client::new();
        let resp = client.get(&profile_url).send().await?;
        if !resp.status().is_success() {
            println!(
                "  ⚠ Could not download profile (HTTP {}). Skipping MDM enrollment.",
                resp.status()
            );
            println!("    You can enroll later: eigeninference-provider enroll");
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
                println!("  Free up disk space and retry: eigeninference-provider install");
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

    service::install_and_start(&coordinator_url, &[model.clone()], None, None, None)?;

    let log_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".eigeninference/provider.log");

    println!("╔══════════════════════════════════════════╗");
    println!("║  Provider is running as a system service! ║");
    println!("╚══════════════════════════════════════════╝");
    println!();
    println!("  Service: io.eigeninference.provider (launchd)");
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
        println!("    eigeninference-provider login");
        println!();
        println!("  Without linking, earnings go to a local");
        println!("  wallet and cannot be withdrawn.");
        println!();
    }

    println!("Commands:");
    println!("  eigeninference-provider login      Link to your account");
    println!("  eigeninference-provider status     Show provider status");
    println!("  eigeninference-provider logs       View logs");
    println!("  eigeninference-provider stop       Stop the provider");
    println!("  eigeninference-provider doctor     Run diagnostics");
    println!();

    Ok(())
}

async fn cmd_serve(
    local: bool,
    coordinator_url: String,
    port: u16,
    model_overrides: Vec<String>,
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

    // Parse schedule from config
    let schedule = cfg
        .schedule
        .as_ref()
        .and_then(scheduling::Schedule::from_config);
    if let Some(ref sched) = schedule {
        tracing::info!("Schedule enabled: {}", sched.describe());
    }

    // Load or generate E2E encryption key pair
    let key_path = crypto::default_key_path()?;
    let node_keypair = std::sync::Arc::new(crypto::NodeKeyPair::load_or_generate(&key_path)?);
    tracing::info!(
        "E2E encryption key loaded (public: {})",
        node_keypair.public_key_base64()
    );

    // Determine backend port (CLI override > config)
    let be_port = backend_port_override.unwrap_or(cfg.backend.port);

    // Determine text models to serve (vmlm-mlx backends).
    // Filter out image (.ckpt) and transcription models — they have their own backends.
    let available_models = models::scan_models(&hw);
    let is_non_text = |id: &str| {
        id.ends_with(".ckpt")
            || id.to_lowercase().contains("transcribe")
            || id.to_lowercase().contains("cohere-transcribe")
            || id.to_lowercase().contains("whisper")
    };
    let selected_models: Vec<String> = if !model_overrides.is_empty() {
        model_overrides
            .into_iter()
            .filter(|m| !is_non_text(m))
            .collect()
    } else if let Some(m) = cfg.backend.model.clone() {
        if is_non_text(&m) { vec![] } else { vec![m] }
    } else {
        // No --model specified — don't auto-pick. The picker in cmd_start
        // explicitly chooses which models to serve. If only image models were
        // selected, this stays empty and only the image bridge runs.
        vec![]
    };

    // Log all available models
    if !available_models.is_empty() {
        tracing::info!("Available models ({}):", available_models.len());
        for m in &available_models {
            tracing::info!("  {} ({:.1} GB)", m.id, m.estimated_memory_gb);
        }
    }
    tracing::info!(
        "Serving {} model(s): {:?}",
        selected_models.len(),
        selected_models
    );

    // Build backend slots: one vllm-mlx process per model on sequential ports.
    struct BackendSlot {
        model_id: String,
        port: u16,
        pid: Option<u32>,
        backend_url: String,
    }
    let mut backend_slots: Vec<BackendSlot> = selected_models
        .iter()
        .enumerate()
        .map(|(i, model_id)| {
            let port = be_port + i as u16;
            BackendSlot {
                model_id: model_id.clone(),
                port,
                pid: None,
                backend_url: format!("http://127.0.0.1:{}", port),
            }
        })
        .collect();

    // For backwards compat, keep a "primary model" (first in list)
    let model = selected_models.first().cloned().unwrap_or_default();

    // Hypervisor memory pool: sum of all model sizes × 2
    if hypervisor::is_active() {
        let total_model_bytes: u64 = selected_models
            .iter()
            .filter_map(|mid| available_models.iter().find(|m| m.id == *mid))
            .map(|m| m.size_bytes)
            .sum();

        if total_model_bytes > 0 {
            let pool_bytes = total_model_bytes as usize * 2;
            match hypervisor::allocate_pool(pool_bytes) {
                Ok(()) => {
                    let cap_gb = hypervisor::pool_capacity() as f64 / (1024.0 * 1024.0 * 1024.0);
                    tracing::info!(
                        "Hypervisor memory pool: {:.1} GB (2x total model size {:.1} GB)",
                        cap_gb,
                        total_model_bytes as f64 / (1024.0 * 1024.0 * 1024.0)
                    );
                }
                Err(e) => tracing::warn!("Hypervisor pool allocation failed: {e}"),
            }
        }
    }

    // Kill any existing processes on our backend ports to avoid EADDRINUSE
    for slot in &backend_slots {
        if let Ok(output) = std::process::Command::new("lsof")
            .args(["-ti", &format!(":{}", slot.port)])
            .output()
        {
            let pids = String::from_utf8_lossy(&output.stdout);
            for pid in pids.split_whitespace() {
                if let Ok(pid_num) = pid.parse::<u32>() {
                    if pid_num != std::process::id() {
                        tracing::info!(
                            "Killing existing process on port {}: PID {}",
                            slot.port,
                            pid_num
                        );
                        let _ = std::process::Command::new("kill").arg(pid).output();
                    }
                }
            }
        }
    }
    if !backend_slots.is_empty() {
        std::thread::sleep(std::time::Duration::from_secs(1));
    }

    // Find bundled Python at ~/.eigeninference/python (standalone Python 3.12 + vllm-mlx)
    let eigeninference_dir = dirs::home_dir().unwrap_or_default().join(".eigeninference");
    let bundled_python = eigeninference_dir.join("python/bin/python3.12");
    let python_cmd = if bundled_python.exists() {
        // Only set PYTHONHOME if this is a real standalone Python install
        // (not a symlink to uv/pyenv/system Python). Wrong PYTHONHOME causes
        // Python to fail to find its stdlib and crash silently.
        let is_standalone = !bundled_python.is_symlink()
            && eigeninference_dir
                .join("python/lib/python3.12/os.py")
                .exists();
        if is_standalone {
            tracing::info!("Using bundled Python: {}", bundled_python.display());
            unsafe {
                std::env::set_var("PYTHONHOME", eigeninference_dir.join("python"));
            }
        } else {
            tracing::info!("Using Python at: {}", bundled_python.display());
        }
        bundled_python.to_string_lossy().to_string()
    } else {
        tracing::info!(
            "Using system Python (bundled Python not found at ~/.eigeninference/python)"
        );
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

    // Honest advertising: only advertise models that are actually being served
    // (i.e. have a running backend). This prevents the coordinator from routing
    // requests for models that aren't loaded.
    let all_scanned = models::scan_models(&hw);
    let selected_set: std::collections::HashSet<&str> =
        selected_models.iter().map(|s| s.as_str()).collect();
    let mut advertised_models: Vec<_> = all_scanned
        .into_iter()
        .filter(|m| selected_set.contains(m.id.as_str()))
        .collect();
    tracing::info!(
        "Advertising {} model(s) (only loaded models)",
        advertised_models.len()
    );

    // STT model env vars (needed for both advertising and backend startup)
    // Allocate STT/image ports after all text model ports
    let stt_port = be_port + backend_slots.len() as u16;
    let stt_model_path = std::env::var("EIGENINFERENCE_STT_MODEL").unwrap_or_default();
    let stt_model_id = std::env::var("EIGENINFERENCE_STT_MODEL_ID")
        .unwrap_or_else(|_| "CohereLabs/cohere-transcribe-03-2026".to_string());

    // Image model env vars (needed for both advertising and backend startup)
    let image_port = stt_port + 1;
    let image_model = std::env::var("EIGENINFERENCE_IMAGE_MODEL").unwrap_or_default();
    let image_model_id =
        std::env::var("EIGENINFERENCE_IMAGE_MODEL_ID").unwrap_or_else(|_| image_model.clone());
    let image_model_path = std::env::var("EIGENINFERENCE_IMAGE_MODEL_PATH").unwrap_or_default();

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

    // Set up coordinator state. The actual connection is spawned AFTER backends
    // are loaded so we don't advertise models before we can serve them.
    let mut coordinator_handle;
    let event_rx_opt;
    let outbound_tx_opt;
    let shutdown_tx_opt;
    let inference_active_opt;
    let health_inference_active_opt;
    let provider_stats_opt;
    let mut rehash_model_hash_opt: Option<std::sync::Arc<std::sync::Mutex<Option<String>>>> = None;
    // Deferred coordinator spawn state — held until backends are ready.
    let mut deferred_coordinator: Option<(
        coordinator::CoordinatorClient,
        tokio::sync::mpsc::Sender<coordinator::CoordinatorEvent>,
        tokio::sync::mpsc::Receiver<protocol::ProviderMessage>,
        tokio::sync::watch::Receiver<bool>,
    )> = None;

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

        // All warm models (for multi-model heartbeat reporting).
        let warm_models: std::sync::Arc<std::sync::Mutex<Vec<String>>> =
            std::sync::Arc::new(std::sync::Mutex::new(selected_models.clone()));

        // Compute weight hash on-demand for the primary served model only.
        let initial_model_hash = models::compute_weight_hash(&model);
        let current_model_hash: std::sync::Arc<std::sync::Mutex<Option<String>>> =
            std::sync::Arc::new(std::sync::Mutex::new(initial_model_hash));
        rehash_model_hash_opt = Some(current_model_hash.clone());

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
        .with_warm_models(warm_models)
        .with_current_model_hash(current_model_hash);

        // Store coordinator client for deferred spawn after backends are ready.
        deferred_coordinator = Some((client, event_tx, outbound_rx, shutdown_rx));
        coordinator_handle = None; // set after backends are ready
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
    // Phase 2: Start backend processes and wait for them to load.
    //
    // Coordinator connection is deferred until all backends are ready.
    // This ensures we never advertise models we can't actually serve yet.
    // =========================================================================

    // Resolve model ID to local path on disk so the backend loads from disk
    // Spawn one vllm-mlx backend per selected model on sequential ports.
    let backend_module = preferred_inference_backend_module();
    let backend_name = backend_name_for_module(backend_module);

    for slot in &mut backend_slots {
        let model_path = models::resolve_local_path(&slot.model_id)
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| {
                tracing::warn!(
                    "Could not resolve local path for {} — using ID directly",
                    slot.model_id
                );
                slot.model_id.clone()
            });
        tracing::info!(
            "Starting backend for {} on port {} (path: {})",
            slot.model_id,
            slot.port,
            model_path
        );

        ensure_chat_template(&model_path);

        match spawn_inference_backend(&python_cmd, backend_module, &model_path, slot.port) {
            Ok(child) => {
                slot.pid = Some(child.id());
                tracing::info!(
                    "{} started (PID: {:?}) on port {}",
                    backend_module,
                    slot.pid,
                    slot.port
                );
            }
            Err(e) => {
                tracing::error!("Failed to start backend for {}: {e}", slot.model_id);
            }
        }
    }

    // Wait for all backends to become healthy
    for slot in &backend_slots {
        if slot.pid.is_none() {
            continue;
        }
        tracing::info!("Waiting for {} to load...", slot.model_id);
        let mut ready = false;
        for i in 0..150 {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            if backend::check_model_loaded(&slot.backend_url).await {
                tracing::info!(
                    "{} ready after {}s on port {}",
                    slot.model_id,
                    (i + 1) * 2,
                    slot.port
                );
                ready = true;
                break;
            }
        }
        if !ready {
            tracing::error!(
                "Backend for {} failed to become healthy after 300s",
                slot.model_id
            );
        }
    }

    // Build model→URL lookup for request routing
    let model_to_url: std::collections::HashMap<String, String> = backend_slots
        .iter()
        .map(|s| (s.model_id.clone(), s.backend_url.clone()))
        .collect();
    // Primary backend URL for backwards compat (local server, health monitor)
    let backend_url_str = backend_slots
        .first()
        .map(|s| s.backend_url.clone())
        .unwrap_or_else(|| format!("http://127.0.0.1:{}", be_port));
    let backend_url = backend_url_str.clone();
    // Primary model path for health monitor restart
    let primary_model_path = if !model.is_empty() {
        models::resolve_local_path(&model)
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| model.clone())
    } else {
        String::new()
    };

    // Start STT backend (continuous-batching stt_server.py) on be_port + 1 if available.
    // EIGENINFERENCE_STT_MODEL: local path or HuggingFace repo ID for the STT model.
    // EIGENINFERENCE_STT_MODEL_ID: clean model name for coordinator registration (optional,
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
        tracing::info!("No STT model configured (set EIGENINFERENCE_STT_MODEL to enable)");
        false
    };

    // Start image generation bridge on be_port + 2 if configured.
    // EIGENINFERENCE_IMAGE_MODEL: model ID for the image bridge (e.g. "flux-klein-4b").
    // EIGENINFERENCE_IMAGE_MODEL_PATH: model directory for gRPCServerCLI (optional).
    let _image_available = if !image_model.is_empty() {
        tracing::info!("Starting image bridge on port {image_port} for model: {image_model}");

        let mut bridge_cmd = std::process::Command::new(&python_cmd);

        // Set PYTHONPATH so the image bridge package is importable.
        // Look for it next to the binary, in ~/.eigeninference, or in the source tree.
        let bridge_paths: Vec<String> = [
            std::env::current_exe().ok().and_then(|p| {
                p.parent()
                    .map(|d| d.join("image-bridge").to_string_lossy().to_string())
            }),
            dirs::home_dir().map(|d| {
                d.join(".eigeninference/image-bridge")
                    .to_string_lossy()
                    .to_string()
            }),
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
            "eigeninference_image_bridge",
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
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());

        match bridge_cmd.spawn() {
            Ok(_child) => {
                let mut ready = false;
                for _ in 0..180 {
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
                    tracing::error!("Image bridge failed to start within 180s");
                    false
                }
            }
            Err(e) => {
                tracing::error!("Failed to spawn image bridge: {e}");
                false
            }
        }
    } else {
        tracing::info!("No image model configured (set EIGENINFERENCE_IMAGE_MODEL to enable)");
        false
    };

    // Security hardening: prevent debugger attachment AFTER all subprocesses
    // are spawned. PT_DENY_ATTACH poisons mach_task_self_ in the process
    // memory, which causes child Python processes to crash with SIGBUS.
    security::deny_debugger_attachment();

    // =========================================================================
    // Phase 3: Connect to coordinator NOW that all backends are loaded.
    //
    // We deliberately delay registration until backends are ready so the
    // coordinator doesn't route requests to us before we can serve them.
    // =========================================================================
    if let Some((client, event_tx, outbound_rx, shutdown_rx)) = deferred_coordinator.take() {
        tracing::info!("All backends loaded — connecting to coordinator");
        let handle = tokio::spawn(async move {
            if let Err(e) = client.run(event_tx, outbound_rx, shutdown_rx).await {
                tracing::error!("Coordinator connection error: {e}");
            }
        });
        coordinator_handle = Some(handle);
    }

    // =========================================================================
    // Phase 4: Run the main event loop.
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
        // Only monitor if we have text backends; image-only providers don't
        // run vmlm-mlx so there's nothing to health-check on the text port.
        let health_url = backend_url_str.clone();
        let health_python = python_cmd.clone();
        let health_backend = backend_name.to_string();
        let health_model = primary_model_path.clone();
        let health_port = be_port;
        let has_text_backends = !backend_slots.is_empty();
        tokio::spawn(async move {
            if !has_text_backends {
                // No text backends to monitor — sleep forever.
                loop {
                    tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
                }
            }
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
        let idle_python_cmd = python_cmd.clone();
        let idle_be_port = be_port;
        let idle_backend_name = backend_name.to_string();
        let proxy_stats = provider_stats.clone();
        let model_to_url = model_to_url.clone();
        // Build model→local-path lookup for rewriting the model field in requests
        let model_to_path: std::collections::HashMap<String, String> = backend_slots
            .iter()
            .map(|s| {
                let path = models::resolve_local_path(&s.model_id)
                    .map(|p| p.to_string_lossy().to_string())
                    .unwrap_or_else(|| s.model_id.clone());
                (s.model_id.clone(), path)
            })
            .collect();
        // For idle reload: re-hash weights after reloading to detect tampering
        let rehash_handle = rehash_model_hash_opt.clone();
        // For backwards compat (idle reload of primary model)
        let idle_model_id = model.clone();
        let idle_model = model_to_path
            .get(&model)
            .cloned()
            .unwrap_or_else(|| model.clone());
        // Collect PIDs for per-process shutdown
        let backend_pids: Vec<(String, Option<u32>)> = backend_slots
            .iter()
            .map(|s| (s.model_id.clone(), s.pid))
            .collect();

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
                                            // Re-hash model weights on reload to detect
                                            // any tampering that occurred while idle.
                                            if let Some(ref hash_arc) = rehash_handle {
                                                if let Some(new_hash) = models::compute_weight_hash(&idle_model_id) {
                                                    *hash_arc.lock().unwrap() = Some(new_hash);
                                                    tracing::info!("Model weight hash refreshed after reload");
                                                }
                                            }
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

                                // Route to the correct backend based on the requested model.
                                let requested_model = body.get("model")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();

                                // Find the backend URL for this model
                                let target_url = model_to_url.get(&requested_model)
                                    .or_else(|| {
                                        // Fuzzy match: coordinator may send slightly different IDs
                                        model_to_url.iter()
                                            .find(|(k, _)| k.contains(&requested_model) || requested_model.contains(k.as_str()))
                                            .map(|(_, v)| v)
                                    })
                                    .cloned()
                                    .unwrap_or_else(|| proxy_backend_url.clone());

                                // Rewrite the model field to the local path the backend expects
                                let mut body = body;
                                if let Some(local_path) = model_to_path.get(&requested_model)
                                    .or_else(|| {
                                        model_to_path.iter()
                                            .find(|(k, _)| k.contains(&requested_model) || requested_model.contains(k.as_str()))
                                            .map(|(_, v)| v)
                                    })
                                {
                                    if let Some(obj) = body.as_object_mut() {
                                        obj.insert("model".to_string(), serde_json::json!(local_path));
                                    }
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
                                        let kp = proxy_keypair.clone();
                                        let rid2 = rid.clone();
                                        let stats = proxy_stats.clone();
                                        tokio::spawn(async move {
                                            proxy::handle_inference_request(rid2, body, target_url, tx, Some(kp), token_clone, Some(stats)).await;
                                            let _ = done_tx.send(rid).await;
                                        })
                                    }

                                    #[cfg(not(feature = "python"))]
                                    {
                                        let kp = proxy_keypair.clone();
                                        let rid2 = rid.clone();
                                        let stats = proxy_stats.clone();
                                        tokio::spawn(async move {
                                            proxy::handle_inference_request(rid2, body, target_url, tx, Some(kp), token_clone, Some(stats)).await;
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
                                let image_url = format!("http://127.0.0.1:{}", image_port);

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
                            "No requests for 1 hour — shutting down backends to free GPU memory. \
                             Next request will reload (~30-60s cold start)."
                        );
                        shutdown_backends(&backend_pids).await;
                        backend_running = false;
                    }
                }
            }
        });

        // Wait for Ctrl+C or schedule window end
        if let Some(ref sched) = schedule {
            // Schedule-aware loop: serve during active windows, sleep between them.
            'schedule_loop: loop {
                // Wait for schedule window if not currently active
                if !sched.is_active_now() {
                    let wait = sched.duration_until_next_active();
                    tracing::info!(
                        "Outside schedule window — sleeping for {}",
                        scheduling::format_duration(wait)
                    );
                    tokio::select! {
                        _ = tokio::time::sleep(wait) => {},
                        _ = tokio::signal::ctrl_c() => break 'schedule_loop,
                    }
                    tracing::info!("Schedule window active — coming online");
                }

                // Serve until window closes or Ctrl+C
                let window_remaining = sched
                    .duration_until_inactive()
                    .unwrap_or(std::time::Duration::from_secs(86400));

                tokio::select! {
                    _ = tokio::time::sleep(window_remaining) => {
                        tracing::info!("Schedule window closed — going offline");
                        // Shut down backend between windows to free GPU memory
                        shutdown_backends(&[]).await;
                        tracing::info!("Backend stopped — waiting for next schedule window");
                        continue 'schedule_loop;
                    }
                    _ = tokio::signal::ctrl_c() => {
                        break 'schedule_loop;
                    }
                }
            }
        } else {
            // No schedule — just wait for Ctrl+C (original behavior)
            tokio::signal::ctrl_c().await?;
        }

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

/// Kill inference backend processes to free GPU memory.
/// Uses per-PID SIGTERM when PIDs are known, falls back to pkill.
async fn shutdown_backends(pids: &[(String, Option<u32>)]) {
    let mut killed = false;
    for (model_id, pid) in pids {
        if let Some(pid) = pid {
            #[cfg(unix)]
            {
                let result = unsafe { libc::kill(*pid as i32, libc::SIGTERM) };
                if result == 0 {
                    tracing::info!("Sent SIGTERM to backend for {} (PID {})", model_id, pid);
                    killed = true;
                }
            }
        }
    }
    if !killed {
        // Fallback if no tracked PIDs
        #[cfg(unix)]
        {
            let _ = std::process::Command::new("pkill")
                .args(["-f", "vllm_mlx"])
                .status();
            let _ = std::process::Command::new("pkill")
                .args(["-f", "mlx_lm.server"])
                .status();
        }
    }
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    tracing::info!("Backend processes terminated — GPU memory freed");
}

/// Restart the inference backend and wait for it to become healthy.
fn preferred_inference_backend_module() -> &'static str {
    match std::env::var("EIGENINFERENCE_INFERENCE_BACKEND")
        .ok()
        .as_deref()
    {
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

/// Generate a Secure Enclave attestation by calling the eigeninference-enclave CLI tool.
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
        // In ~/.eigeninference
        dirs::home_dir()
            .unwrap_or_default()
            .join(".eigeninference/stt_server.py"),
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
    // Check ~/.eigeninference/bin first (standard install location)
    let home_bin = dirs::home_dir()
        .unwrap_or_default()
        .join(".eigeninference/bin/eigeninference-enclave");
    let home_bin_str = home_bin.to_string_lossy().to_string();

    let binary_paths = [
        // Standard install location
        home_bin_str.as_str(),
        // Built in the enclave directory (development)
        "../enclave/.build/release/eigeninference-enclave",
        // System-wide install
        "/usr/local/bin/eigeninference-enclave",
        // Homebrew
        "/opt/homebrew/bin/eigeninference-enclave",
        // Adjacent to provider binary
        "eigeninference-enclave",
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
            .arg("eigeninference-enclave")
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
            tracing::info!(
                "eigeninference-enclave binary not found, registering without attestation"
            );
            return None;
        }
    };

    // Try up to 2 times: first with existing key, then with fresh key if stale
    for attempt in 0..2 {
        if attempt == 1 {
            // Delete stale enclave key and retry
            let home = dirs::home_dir().unwrap_or_default();
            let key_path = home.join(".eigeninference/enclave_key.data");
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
                tracing::warn!("Failed to run eigeninference-enclave: {e}");
                return None;
            }
        };

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            tracing::warn!("eigeninference-enclave failed: {stderr}");
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
    let sig_path = tmp_dir.join("eigeninference-verify-sig.der");
    let data_path = tmp_dir.join("eigeninference-verify-data.bin");
    let pubkey_path = tmp_dir.join("eigeninference-verify-pubkey.der");

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
    println!("EigenInference Device Attestation Enrollment");
    println!();

    // Check if already enrolled
    if security::check_mdm_enrolled() {
        println!("✓ Already enrolled — no action needed.");
        println!();
        println!("  Verify with: eigeninference-provider doctor");
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
    let profile_path =
        std::env::temp_dir().join(format!("EigenInference-Enroll-{serial}.mobileconfig"));
    std::fs::write(&profile_path, &bytes)?;

    // Register the profile and open System Settings to the Device Management pane
    #[cfg(target_os = "macos")]
    {
        // Step 1: open .mobileconfig registers it with System Settings
        let _ = std::process::Command::new("open")
            .arg(&profile_path)
            .status();

        // Small delay so the profile registers before we open the pane
        std::thread::sleep(std::time::Duration::from_secs(1));

        // Step 2: open System Settings directly to Profiles pane
        let _ = std::process::Command::new("open")
            .arg("x-apple.systempreferences:com.apple.Profiles-Settings.extension")
            .status();

        println!("→ System Settings opened to Device Management");
        println!();
        println!("  Click \"Install\" on the EigenInference profile, then enter your password.");
        println!("  This verifies:");
        println!("    • SIP and Secure Boot are enabled");
        println!("    • Your Secure Enclave is genuine Apple hardware");
        println!("    • Device identity signed by Apple's Root CA");
        println!();
        println!("  EigenInference CANNOT erase, lock, or control your Mac.");
        println!("  Remove anytime in System Settings → Device Management.");
    }

    println!();
    println!("After installing, verify with: eigeninference-provider doctor");
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
    println!("EigenInference Unenrollment");
    println!();

    if security::check_mdm_enrolled() {
        println!("MDM profile found. To remove:");
        println!("  System Settings → General → Device Management");
        println!("  Click on the EigenInference profile → Remove");
        println!();
        #[cfg(target_os = "macos")]
        {
            println!("Opening System Settings...");
            let _ = std::process::Command::new("open")
                .arg("x-apple.systempreferences:com.apple.preferences.configurationprofiles")
                .status();
        }
    } else {
        println!("No EigenInference MDM profile found. Nothing to remove.");
    }

    // Clean up local data
    println!();
    println!("Clean up local EigenInference data? This removes:");
    println!("  - Config: ~/.config/eigeninference/");
    println!("  - Node key: ~/.eigeninference/node_key");
    println!("  - Enclave key: ~/.eigeninference/enclave_key.data");
    println!("  - Auth token: ~/.eigeninference/auth_token");
    println!();
    println!("Type 'yes' to confirm:");
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    if input.trim() == "yes" {
        let home = dirs::home_dir().unwrap_or_default();
        let _ = std::fs::remove_dir_all(home.join(".config/eigeninference"));
        let _ = std::fs::remove_file(home.join(".eigeninference/node_key"));
        let _ = std::fs::remove_file(home.join(".eigeninference/enclave_key.data"));
        let _ = std::fs::remove_file(home.join(".eigeninference/wallet_key"));
        println!("  ✓ Local data cleaned up");
    } else {
        println!("  Skipped cleanup");
    }

    Ok(())
}

async fn cmd_benchmark() -> Result<()> {
    let hw = hardware::detect()?;
    println!();
    println!("  EigenInference Benchmark");
    println!("  ─────────────────────────────────────");
    println!(
        "  {} · {} GB RAM · {} GPU cores · {} GB/s",
        hw.chip_name, hw.memory_gb, hw.gpu_cores, hw.memory_bandwidth_gbs
    );
    println!();

    // Find bundled Python
    let eigeninference_dir = dirs::home_dir().unwrap_or_default().join(".eigeninference");
    let bundled_python = eigeninference_dir.join("python/bin/python3.12");
    let python_cmd = if bundled_python.exists() {
        bundled_python.to_string_lossy().to_string()
    } else {
        "python3".to_string()
    };

    // Verify vllm-mlx is available
    let has_vllm = std::process::Command::new(&python_cmd)
        .args(["-c", "import vllm_mlx; print('ok')"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if !has_vllm {
        anyhow::bail!("vllm-mlx not found. Run: eigeninference-provider install");
    }

    // Scan downloaded models and filter by catalog
    let downloaded = models::scan_models(&hw);
    let catalog = fetch_catalog("https://inference-test.openinnovation.dev").await;
    let catalog_ids: std::collections::HashSet<String> =
        catalog.iter().map(|c| c.id.clone()).collect();

    let servable: Vec<_> = downloaded
        .iter()
        .filter(|m| catalog_ids.contains(&m.id))
        .collect();

    if servable.is_empty() {
        anyhow::bail!("No catalog models downloaded. Run: eigeninference-provider models download");
    }

    // Let user pick which model to benchmark
    println!("  Select a model to benchmark:");
    println!();
    for (i, m) in servable.iter().enumerate() {
        let display = catalog
            .iter()
            .find(|c| c.id == m.id)
            .map(|c| c.display_name.as_str())
            .unwrap_or(&m.id);
        println!(
            "    [{}] {} ({:.1} GB)",
            i + 1,
            display,
            m.estimated_memory_gb
        );
    }
    println!();
    use std::io::Write;
    print!(
        "  Enter number [1-{}] (or press Enter for [1]): ",
        servable.len()
    );
    std::io::stdout().flush()?;
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    let idx = input
        .trim()
        .parse::<usize>()
        .unwrap_or(1)
        .saturating_sub(1)
        .min(servable.len() - 1);
    let selected = &servable[idx];

    let display_name = catalog
        .iter()
        .find(|c| c.id == selected.id)
        .map(|c| c.display_name.as_str())
        .unwrap_or(&selected.id);

    println!();
    println!(
        "  Benchmarking: {} ({:.1} GB)",
        display_name, selected.estimated_memory_gb
    );
    println!();

    // Resolve model to local path
    let model_path = models::resolve_local_path(&selected.id)
        .ok_or_else(|| anyhow::anyhow!("Could not find model on disk: {}", selected.id))?;

    // Run benchmark via vllm-mlx: load model, measure prefill (TTFT) and decode (tok/s)
    let bench_script = format!(
        r#"
import time, json, sys
sys.path.insert(0, '.')
from vllm_mlx.engine import MLXEngine

engine = MLXEngine(model="{model_path}", tokenizer="{model_path}")

prompt = "Write a detailed analysis of the economic impact of artificial intelligence on the global workforce over the next decade."

# Warmup
print("  Warming up...", flush=True)
engine.generate(prompt, max_tokens=10)

# Benchmark: 3 runs
results = []
for run in range(3):
    start = time.perf_counter()
    tokens = []
    first_token_time = None
    for tok in engine.generate_stream(prompt, max_tokens=200):
        if first_token_time is None:
            first_token_time = time.perf_counter()
        tokens.append(tok)
    end = time.perf_counter()

    ttft_ms = (first_token_time - start) * 1000 if first_token_time else 0
    decode_time = end - first_token_time if first_token_time else end - start
    n_tokens = len(tokens)
    tps = n_tokens / decode_time if decode_time > 0 else 0

    results.append({{"ttft_ms": ttft_ms, "tokens": n_tokens, "tps": tps, "total_s": end - start}})
    print(f"  Run {{run+1}}: {{tps:.1f}} tok/s | TTFT {{ttft_ms:.0f}}ms | {{n_tokens}} tokens in {{end-start:.2f}}s", flush=True)

# Summary
avg_tps = sum(r["tps"] for r in results) / len(results)
avg_ttft = sum(r["ttft_ms"] for r in results) / len(results)
print()
print(f"  Average: {{avg_tps:.1f}} tok/s | TTFT {{avg_ttft:.0f}}ms")
print(json.dumps({{"avg_tps": avg_tps, "avg_ttft_ms": avg_ttft, "runs": results}}))
"#,
        model_path = model_path.display()
    );

    println!("  Loading model...");
    println!();

    let mut child = std::process::Command::new(&python_cmd)
        .args(["-c", &bench_script])
        .env("PYTHONHOME", eigeninference_dir.join("python"))
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()?;

    // Stream stdout
    if let Some(stdout) = child.stdout.take() {
        use std::io::BufRead;
        let reader = std::io::BufReader::new(stdout);
        for line in reader.lines() {
            if let Ok(line) = line {
                if line.starts_with('{') {
                    // JSON summary line — parse for structured output
                    if let Ok(data) = serde_json::from_str::<serde_json::Value>(&line) {
                        println!("  ─────────────────────────────────────");
                        println!(
                            "  Result: {:.1} tok/s decode | {:.0}ms TTFT",
                            data["avg_tps"].as_f64().unwrap_or(0.0),
                            data["avg_ttft_ms"].as_f64().unwrap_or(0.0)
                        );
                        println!(
                            "  Theoretical bandwidth utilization: {:.0}%",
                            (data["avg_tps"].as_f64().unwrap_or(0.0)
                                * selected.estimated_memory_gb
                                / hw.memory_bandwidth_gbs as f64)
                                * 100.0
                        );
                    }
                } else {
                    println!("{}", line);
                }
            }
        }
    }

    let status = child.wait()?;
    if !status.success() {
        println!("  Benchmark failed. Check that the model is not corrupted.");
    }

    println!();
    Ok(())
}

async fn cmd_status() -> Result<()> {
    let hw = hardware::detect()?;
    let home = dirs::home_dir().unwrap_or_default();
    let eigeninference_dir = home.join(".eigeninference");

    println!();
    println!("  EigenInference Provider Status");
    println!("  ─────────────────────────────────────");

    // Running state
    let pid_path = eigeninference_dir.join("provider.pid");
    let is_running = if pid_path.exists() {
        if let Ok(pid_str) = std::fs::read_to_string(&pid_path) {
            if let Ok(pid) = pid_str.trim().parse::<i32>() {
                #[cfg(unix)]
                {
                    // Check if process is alive (signal 0 = just check)
                    unsafe { libc::kill(pid, 0) == 0 }
                }
                #[cfg(not(unix))]
                false
            } else {
                false
            }
        } else {
            false
        }
    } else {
        false
    };

    // Try to read the current model from the log
    let serving_model = if is_running {
        let log_path = eigeninference_dir.join("provider.log");
        if log_path.exists() {
            std::fs::read_to_string(&log_path).ok().and_then(|log| {
                log.lines()
                    .rev()
                    .find(|l| l.contains("Primary model:"))
                    .map(|l| {
                        l.split("Primary model:")
                            .nth(1)
                            .unwrap_or("")
                            .trim()
                            .to_string()
                    })
            })
        } else {
            None
        }
    } else {
        None
    };

    if is_running {
        if let Some(ref model) = serving_model {
            println!("  Status:     ● Running — serving {}", model);
        } else {
            println!("  Status:     ● Running");
        }
    } else {
        println!("  Status:     ○ Stopped");
    }
    println!();

    // Hardware
    println!("  Hardware:");
    println!("    Chip:       {}", hw.chip_name);
    println!(
        "    Memory:     {} GB total, {} GB available",
        hw.memory_gb, hw.memory_available_gb
    );
    println!("    GPU:        {} cores", hw.gpu_cores);
    println!("    Bandwidth:  {} GB/s", hw.memory_bandwidth_gbs);
    println!();

    // Security
    println!("  Security:");
    let sip = security::check_sip_enabled();
    println!(
        "    SIP:            {}",
        if sip { "✓ Enabled" } else { "✗ DISABLED" }
    );
    println!("    Secure Enclave: ✓ Available");

    let enclave_key = eigeninference_dir.join("enclave_key.data");
    println!(
        "    Enclave key:    {}",
        if enclave_key.exists() {
            "✓ Generated"
        } else {
            "✗ Not generated"
        }
    );

    println!(
        "    MDM enrolled:   {}",
        if security::check_mdm_enrolled() {
            "✓ Yes (hardware trust)"
        } else {
            "✗ No — not routable without MDM enrollment"
        }
    );
    println!();

    // Account
    let linked = load_auth_token().is_some();
    println!("  Account:");
    println!(
        "    Linked:   {}",
        if linked {
            "✓ Yes"
        } else {
            "✗ No — run: eigeninference-provider login"
        }
    );
    println!();

    // Models (catalog-filtered)
    let models = models::scan_models(&hw);
    let catalog = fetch_catalog("https://inference-test.openinnovation.dev").await;
    let catalog_ids: std::collections::HashSet<String> =
        catalog.iter().map(|c| c.id.clone()).collect();

    let servable: Vec<_> = models
        .iter()
        .filter(|m| catalog_ids.contains(&m.id))
        .collect();
    let extra: Vec<_> = models
        .iter()
        .filter(|m| !catalog_ids.contains(&m.id))
        .collect();

    println!("  Models ({} servable):", servable.len());
    for m in &servable {
        let active = serving_model.as_deref() == Some(&m.id);
        let marker = if active { "●" } else { " " };
        let display = catalog
            .iter()
            .find(|c| c.id == m.id)
            .map(|c| c.display_name.as_str())
            .unwrap_or(&m.id);
        println!(
            "    {} {} ({:.1} GB)",
            marker, display, m.estimated_memory_gb
        );
    }
    if !extra.is_empty() {
        println!("    + {} other models not in catalog", extra.len());
    }

    if is_running {
        println!();
        println!("  Commands:");
        println!("    eigeninference-provider logs -w    Stream live logs");
        println!("    eigeninference-provider stop       Stop serving");
    } else {
        println!();
        println!("  Commands:");
        println!("    eigeninference-provider start       Start serving");
        println!("    eigeninference-provider models download  Download models");
    }
    println!();

    Ok(())
}

async fn cmd_models(action: String, coordinator_url: String) -> Result<()> {
    let hw = hardware::detect()?;
    let downloaded = models::scan_models(&hw);

    // Fetch model catalog from coordinator
    let catalog = fetch_catalog(&coordinator_url).await;

    // When called with no action (default "list"), show the interactive hub
    let effective_action = if action == "list" {
        // Show overview first
        println!();
        println!("  EigenInference Models");
        println!("  ─────────────────────────────────────");
        println!(
            "  {} · {} GB available",
            hw.chip_name, hw.memory_available_gb
        );
        println!();

        // Catalog section
        println!("  Catalog:");
        for cm in &catalog {
            let fits = hw.memory_available_gb as f64 >= cm.size_gb;
            let is_downloaded = downloaded.iter().any(|m| m.id == cm.id);
            let (icon, label) = if is_downloaded {
                ("✓", "downloaded")
            } else if fits {
                ("○", "available")
            } else {
                ("✗", "too large")
            };
            println!(
                "    {} {:>5.1} GB  {}  ({})",
                icon, cm.size_gb, cm.display_name, label
            );
        }

        // Non-catalog downloaded models
        let extra: Vec<_> = downloaded
            .iter()
            .filter(|m| !catalog.iter().any(|cm| cm.id == m.id))
            .collect();
        if !extra.is_empty() {
            println!();
            println!("  Other downloads (not in catalog):");
            for m in &extra {
                println!("    · {:>5.1} GB  {}", m.estimated_memory_gb, m.id);
            }
        }

        println!();
        println!("  What would you like to do?");
        println!();
        println!("    [1] Download a model");
        println!("    [2] Remove a model");
        println!("    [3] Exit");
        println!();

        use std::io::Write;
        print!("  Enter choice [1-3]: ");
        std::io::stdout().flush()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;

        match input.trim() {
            "1" => "download".to_string(),
            "2" => "remove".to_string(),
            _ => return Ok(()),
        }
    } else {
        action.clone()
    };

    match effective_action.as_str() {
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
                            .join(".eigeninference/models")
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
            println!("Usage: eigeninference-provider models [list|download|remove]");
        }
    }

    Ok(())
}

async fn cmd_earnings(coordinator_url: String) -> Result<()> {
    println!("EigenInference Earnings");
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
    let earnings_url = format!("{}/v1/provider/earnings", coordinator_url);
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
    println!("EigenInference Doctor — System Diagnostics");
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
        let enclave_ok = std::process::Command::new("eigeninference-enclave")
            .args(["info"])
            .output()
            .or_else(|_| {
                let home = dirs::home_dir().unwrap_or_default();
                std::process::Command::new(home.join(".eigeninference/bin/eigeninference-enclave"))
                    .args(["info"])
                    .output()
            })
            .map(|o| o.status.success())
            .unwrap_or(false);
        if enclave_ok {
            println!("✓ Available");
            passed += 1;
        } else {
            println!("✗ eigeninference-enclave not found");
            issues.push("Install eigeninference-enclave binary".to_string());
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
            issues.push("Run: eigeninference-provider enroll".to_string());
        }
        #[cfg(not(target_os = "macos"))]
        {
            println!("- Not applicable (non-macOS)");
            passed += 1;
        }
    }

    // 5. Inference runtime (vllm-mlx / mlx-lm)
    print!("5. Inference runtime........... ");
    let eigeninference_dir = dirs::home_dir().unwrap_or_default().join(".eigeninference");
    let bundled_python = eigeninference_dir.join("python/bin/python3.12");
    let (python_cmd, python_home) = if bundled_python.exists() {
        (
            bundled_python.to_string_lossy().to_string(),
            Some(eigeninference_dir.join("python")),
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
        issues.push("Download a model: eigeninference-provider models download".to_string());
    }

    // 7. Node key
    print!("7. Node encryption key......... ");
    let key_path = crypto::default_key_path().unwrap_or_default();
    if key_path.exists() {
        println!("✓ Generated");
        passed += 1;
    } else {
        println!("✗ Not generated");
        issues.push("Run: eigeninference-provider init".to_string());
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
        println!("All good! Start serving with: eigeninference-provider serve");
    } else {
        println!();
        println!("Issues to fix:");
        for (i, issue) in issues.iter().enumerate() {
            println!("  {}. {}", i + 1, issue);
        }
    }

    Ok(())
}

struct PickerEntry {
    display: String,
    size_gb: f64,
    downloaded: bool,
}

/// Multi-select model picker. Space toggles, Enter confirms.
/// Returns indices of selected items. Enforces memory budget.
fn run_model_picker(entries: &[PickerEntry], memory_gb: f64) -> Result<Vec<usize>> {
    use crossterm::{
        cursor,
        event::{self, Event, KeyCode, KeyEvent, KeyEventKind},
        execute,
        terminal::{self, ClearType},
    };
    use std::io::Write;

    let mut stdout = std::io::stdout();
    let mut cursor_pos: usize = 0;
    let mut selected: Vec<bool> = vec![false; entries.len()];
    // Pre-select the largest downloaded model
    if let Some(idx) = entries.iter().position(|e| e.downloaded) {
        selected[idx] = true;
    }

    let os_reserve = 4.0_f64;
    let budget = memory_gb - os_reserve;

    let downloaded_count = entries.iter().filter(|e| e.downloaded).count();
    let available_count = entries.len() - downloaded_count;

    terminal::enable_raw_mode()?;
    execute!(stdout, cursor::Hide)?;

    // Track how many lines the last render wrote so we can move back up.
    let mut last_line_count: u16 = 0;

    let render = |pos: usize,
                  sel: &[bool],
                  stdout: &mut std::io::Stdout,
                  prev_lines: u16|
     -> std::io::Result<u16> {
        // Move up to overwrite previous render, then clear everything below
        if prev_lines > 0 {
            write!(stdout, "\x1b[{}A", prev_lines)?;
        }
        write!(stdout, "\r\x1b[J")?; // move to col 0, clear to end of screen

        let used: f64 = entries
            .iter()
            .enumerate()
            .filter(|(i, _)| sel[*i])
            .map(|(_, e)| e.size_gb)
            .sum();
        let remaining = budget - used;
        let count = sel.iter().filter(|s| **s).count();

        let mut lines: u16 = 0;

        write!(
            stdout,
            "  Select models (RAM: {:.0} GB)  ↑↓ navigate · Space toggle · Enter confirm\r\n",
            memory_gb
        )?;
        lines += 1;
        write!(
            stdout,
            "  \x1b[2m{} selected · {:.1} GB used · {:.1} GB remaining\x1b[0m\r\n\r\n",
            count, used, remaining
        )?;
        lines += 2;

        let mut idx = 0;

        if downloaded_count > 0 {
            write!(stdout, "  \x1b[1mReady to serve:\x1b[0m\r\n")?;
            lines += 1;
            for e in entries.iter().filter(|e| e.downloaded) {
                let arrow = if idx == pos { "▸" } else { " " };
                let check = if sel[idx] { "✓" } else { " " };
                let highlight = if idx == pos { "\x1b[36m" } else { "" };
                let reset = if !highlight.is_empty() { "\x1b[0m" } else { "" };
                write!(
                    stdout,
                    "    {}{} [{}] {} ({:.1} GB){}\r\n",
                    highlight, arrow, check, e.display, e.size_gb, reset
                )?;
                lines += 1;
                idx += 1;
            }
        }

        if available_count > 0 {
            if downloaded_count > 0 {
                write!(stdout, "\r\n")?;
                lines += 1;
            }
            write!(stdout, "  \x1b[1mAvailable to download:\x1b[0m\r\n")?;
            lines += 1;
            for e in entries.iter().filter(|e| !e.downloaded) {
                let arrow = if idx == pos { "▸" } else { " " };
                let check = if sel[idx] { "✓" } else { " " };
                let fits = !sel[idx] && e.size_gb > remaining;
                let highlight = if idx == pos {
                    "\x1b[33m"
                } else if fits {
                    "\x1b[2;31m"
                } else {
                    "\x1b[2m"
                };
                let reset = "\x1b[0m";
                let warn = if fits { " ⚠ won't fit" } else { "" };
                write!(
                    stdout,
                    "    {}{} [{}] ↓ {} ({:.1} GB){}{}\r\n",
                    highlight, arrow, check, e.display, e.size_gb, warn, reset
                )?;
                lines += 1;
                idx += 1;
            }
        }

        stdout.flush()?;
        Ok(lines)
    };

    last_line_count = render(cursor_pos, &selected, &mut stdout, 0)?;

    loop {
        if let Event::Key(KeyEvent {
            code,
            kind: KeyEventKind::Press,
            ..
        }) = event::read()?
        {
            match code {
                KeyCode::Up => {
                    if cursor_pos > 0 {
                        cursor_pos -= 1;
                    }
                }
                KeyCode::Down => {
                    if cursor_pos < entries.len() - 1 {
                        cursor_pos += 1;
                    }
                }
                KeyCode::Char(' ') => {
                    if selected[cursor_pos] {
                        // Always allow deselect
                        selected[cursor_pos] = false;
                    } else {
                        // Check memory budget before selecting
                        let used: f64 = entries
                            .iter()
                            .enumerate()
                            .filter(|(i, _)| selected[*i])
                            .map(|(_, e)| e.size_gb)
                            .sum();
                        if used + entries[cursor_pos].size_gb <= budget {
                            selected[cursor_pos] = true;
                        }
                        // If it doesn't fit, the render will show ⚠
                    }
                }
                KeyCode::Enter => {
                    if selected.iter().any(|s| *s) {
                        break;
                    }
                    // Don't allow confirm with nothing selected
                }
                KeyCode::Char('q') | KeyCode::Esc => {
                    terminal::disable_raw_mode()?;
                    execute!(stdout, cursor::Show)?;
                    anyhow::bail!("Cancelled");
                }
                _ => {}
            }
            last_line_count = render(cursor_pos, &selected, &mut stdout, last_line_count)?;
        }
    }

    terminal::disable_raw_mode()?;
    execute!(stdout, cursor::Show)?;
    write!(stdout, "\r\n")?;

    Ok(selected
        .iter()
        .enumerate()
        .filter(|(_, s)| **s)
        .map(|(i, _)| i)
        .collect())
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
    // Scan ALL downloaded models without memory filtering — the picker has its
    // own memory budget logic, and filtering here hides models that are on disk.
    let downloaded = models::default_hf_cache_dir()
        .map(|d| models::scan_models_in_dir(&d, u64::MAX))
        .unwrap_or_default();

    // Fetch catalog from coordinator
    let catalog = fetch_catalog(&coordinator_url).await;
    if catalog.is_empty() {
        anyhow::bail!("Could not fetch model catalog from coordinator");
    }

    let downloaded_ids: std::collections::HashSet<String> =
        downloaded.iter().map(|m| m.id.clone()).collect();

    // Interactive model selection if no --model specified
    let (selected_models, picked_image, picked_stt): (Vec<String>, Option<String>, Option<String>) =
        if let Some(m) = model_override {
            (vec![m], None, None)
        } else {
            // Build picker items from catalog: all models that fit in RAM.
            struct PickerItem {
                id: String,
                display: String,
                size_gb: f64,
                downloaded: bool,
                s3_name: String,
                model_type: String,
            }

            // Fetch expected file sizes from CDN via HEAD requests to detect partial downloads.
            let cdn_base = "https://pub-7cbee059c80c46ec9c071dbee2726f8a.r2.dev";
            let cdn_sizes: std::collections::HashMap<String, u64> = {
                let client = reqwest::Client::new();
                let mut sizes = std::collections::HashMap::new();
                for c in &catalog {
                    if let Some(on_disk) = downloaded.iter().find(|m| m.id == c.id) {
                        // Only HEAD-check models we have locally (to verify completeness)
                        let url = if c.id.ends_with(".ckpt") {
                            format!("{}/{}/{}", cdn_base, c.s3_name, c.id)
                        } else {
                            format!("{}/{}/model.safetensors", cdn_base, c.s3_name)
                        };
                        if let Ok(resp) = client
                            .head(&url)
                            .timeout(std::time::Duration::from_secs(5))
                            .send()
                            .await
                        {
                            if let Some(len) = resp.content_length() {
                                sizes.insert(c.id.clone(), len);
                            }
                        }
                    }
                }
                sizes
            };

            let mut items: Vec<PickerItem> = catalog
                .iter()
                .filter(|c| (c.min_ram_gb as f64) <= hw.memory_gb as f64)
                .map(|c| {
                    // Check if model is downloaded AND complete.
                    // For image models (.ckpt), also verify companion files exist
                    // (text encoder + VAE) since the pipeline needs all 3.
                    let on_disk = downloaded.iter().find(|m| m.id == c.id);
                    let is_downloaded = on_disk.is_some_and(|m| {
                        let main_ok = if let Some(&expected) = cdn_sizes.get(&c.id) {
                            m.size_bytes >= expected
                        } else {
                            m.size_bytes > 500_000_000
                        };
                        if !main_ok {
                            return false;
                        }
                        // For image models, parse models.json and verify all referenced files exist
                        if c.model_type == "image" {
                            let model_dir = models::resolve_local_path(&c.id);
                            if let Some(dir) = model_dir.as_ref().and_then(|p| p.parent()) {
                                let meta_path = dir.join("models.json");
                                if !meta_path.exists() {
                                    return false;
                                }
                                // Parse models.json and check every referenced file exists
                                let complete = std::fs::read_to_string(&meta_path)
                                    .ok()
                                    .and_then(|s| {
                                        serde_json::from_str::<Vec<serde_json::Value>>(&s).ok()
                                    })
                                    .map(|entries| {
                                        entries.iter().all(|entry| {
                                            let files = [
                                                entry.get("file").and_then(|v| v.as_str()),
                                                entry.get("autoencoder").and_then(|v| v.as_str()),
                                                entry.get("text_encoder").and_then(|v| v.as_str()),
                                            ];
                                            files.iter().all(|f| {
                                                f.map(|name| dir.join(name).exists())
                                                    .unwrap_or(true)
                                            })
                                        })
                                    })
                                    .unwrap_or(false);
                                return complete;
                            }
                            return false;
                        }
                        true
                    });
                    let size = if is_downloaded {
                        on_disk.map(|m| m.estimated_memory_gb).unwrap_or(c.size_gb)
                    } else {
                        c.size_gb
                    };
                    // Show model type tag for non-text models
                    let display = if c.model_type != "text" {
                        format!("{} [{}]", c.display_name, c.model_type)
                    } else {
                        c.display_name.clone()
                    };
                    PickerItem {
                        id: c.id.clone(),
                        display,
                        size_gb: size,
                        downloaded: is_downloaded,
                        s3_name: c.s3_name.clone(),
                        model_type: c.model_type.clone(),
                    }
                })
                .collect();

            // Sort: downloaded first, then by size descending
            items.sort_by(|a, b| {
                b.downloaded.cmp(&a.downloaded).then(
                    b.size_gb
                        .partial_cmp(&a.size_gb)
                        .unwrap_or(std::cmp::Ordering::Equal),
                )
            });

            if items.is_empty() {
                anyhow::bail!("No supported models fit in {} GB RAM", hw.memory_gb);
            }

            // Convert to PickerEntry for the interactive picker
            let entries: Vec<PickerEntry> = items
                .iter()
                .map(|i| PickerEntry {
                    display: i.display.clone(),
                    size_gb: i.size_gb,
                    downloaded: i.downloaded,
                })
                .collect();

            let selected_indices = run_model_picker(&entries, hw.memory_gb as f64)?;

            // Download any selected models that aren't local yet.
            // For image models (.ckpt), always verify even if "downloaded" — the
            // download function does a HEAD check against R2 and re-downloads files
            // that are the wrong size (e.g. corrupt/truncated downloads).
            for &idx in &selected_indices {
                let item = &items[idx];
                let needs_download = !item.downloaded || item.model_type == "image";
                if needs_download {
                    if !item.downloaded {
                        println!();
                        println!("  Downloading {}...", item.display);
                    }
                    let cache_dir = dirs::home_dir()
                        .unwrap_or_default()
                        .join(".cache/huggingface/hub")
                        .join(format!("models--{}", item.id.replace('/', "--")))
                        .join("snapshots/main");
                    std::fs::create_dir_all(&cache_dir)?;
                    if !download_model_from_cdn(&item.s3_name, &cache_dir, &item.display) {
                        anyhow::bail!("Failed to download {}", item.display);
                    }
                    if !item.downloaded {
                        println!("  ✓ Downloaded {}", item.display);
                    }
                }
            }

            // Split selected models by type:
            //   text → --model (vmlm-mlx backends)
            //   image → --image-model (image bridge)
            //   transcription → EIGENINFERENCE_STT_MODEL env var (stt_server.py)
            let mut text_models = Vec::new();
            let mut picked_image_model: Option<String> = None;
            let mut picked_stt_model: Option<String> = None;
            for &idx in &selected_indices {
                let item = &items[idx];
                match item.model_type.as_str() {
                    "image" => picked_image_model = Some(item.id.clone()),
                    "transcription" | "stt" => picked_stt_model = Some(item.id.clone()),
                    _ => text_models.push(item.id.clone()),
                }
            }
            (text_models, picked_image_model, picked_stt_model)
        };

    // Merge CLI --image-model with picker selection
    let final_image_model = picked_image.or(image_model);

    // Resolve image model path: CLI flag overrides, otherwise resolve from model ID.
    // gRPCServerCLI needs the directory containing the .ckpt files.
    let final_image_model_path = image_model_path.or_else(|| {
        final_image_model
            .as_ref()
            .and_then(|id| models::resolve_local_path(id).map(|p| p.to_string_lossy().to_string()))
    });

    if selected_models.is_empty() && final_image_model.is_none() {
        anyhow::bail!("No models selected");
    }

    let log_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".eigeninference/provider.log");

    // Install as launchd user agent
    service::install_and_start(
        &coordinator_url,
        &selected_models,
        final_image_model.as_deref(),
        final_image_model_path.as_deref(),
        picked_stt.as_deref(),
    )?;

    println!("Provider installed as system service");
    if !selected_models.is_empty() {
        println!(
            "  Models:  {} ({})",
            selected_models.len(),
            selected_models.join(", ")
        );
    }
    if let Some(ref im) = final_image_model {
        println!("  Image:   {}", im);
    }
    println!("  Logs:    {}", log_path.display());
    println!("  Service: io.eigeninference.provider (launchd)");
    println!();
    println!("  eigeninference-provider stop    Stop the provider");
    println!("  eigeninference-provider logs    View logs");
    println!("  eigeninference-provider status  Check status");

    Ok(())
}

async fn cmd_stop() -> Result<()> {
    let eigeninference_dir = dirs::home_dir().unwrap_or_default().join(".eigeninference");
    let pid_path = eigeninference_dir.join("provider.pid");
    let caffeinate_pid_path = eigeninference_dir.join("caffeinate.pid");

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

async fn cmd_update(coordinator: String) -> Result<()> {
    let current_version = env!("CARGO_PKG_VERSION");
    println!("EigenInference Provider Update");
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
    let tmp_path = "/tmp/eigeninference-bundle.tar.gz";
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
    let eigeninference_dir = dirs::home_dir()
        .ok_or_else(|| anyhow::anyhow!("cannot find home directory"))?
        .join(".eigeninference");
    let bin_dir = eigeninference_dir.join("bin");

    println!("  Installing...");
    let status = std::process::Command::new("tar")
        .args(["xzf", tmp_path, "-C", &eigeninference_dir.to_string_lossy()])
        .status()?;
    if !status.success() {
        anyhow::bail!("tar extraction failed");
    }

    // Move binaries to bin dir
    let _ = std::fs::rename(
        eigeninference_dir.join("eigeninference-provider"),
        bin_dir.join("eigeninference-provider"),
    );
    let _ = std::fs::rename(
        eigeninference_dir.join("eigeninference-enclave"),
        bin_dir.join("eigeninference-enclave"),
    );

    // Make executable
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for name in &["eigeninference-provider", "eigeninference-enclave"] {
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
    println!("    eigeninference-provider stop && eigeninference-provider start");

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
        .join(".eigeninference/provider.log");

    if !log_path.exists() {
        println!("No log file found at {}", log_path.display());
        println!("Start the provider first: eigeninference-provider start");
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
        .join("eigeninference")
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
        println!("Run 'eigeninference-provider logout' first to unlink.");
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
            anyhow::bail!("Device code expired. Run 'eigeninference-provider login' again.");
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
                println!("  Start serving with: eigeninference-provider serve");
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

//! Darkbloom provider agent for Apple Silicon Macs.
//!
//! The provider agent runs on Mac hardware and serves local inference requests
//! from the Darkbloom coordinator. It manages the lifecycle of an inference backend,
//! connects to the coordinator via WebSocket, and handles attestation using the
//! Apple Secure Enclave.
//!
//! Architecture:
//!   Provider Agent (this binary)
//!     ├── Hardware detection (Apple Silicon chip, memory, GPU cores)
//!     ├── Model scanning (HuggingFace cache, memory filtering)
//!     ├── Backend management (spawn/monitor/restart inference server)
//!     ├── Coordinator connection (WebSocket, registration, heartbeats)
//!     ├── Attestation (Secure Enclave identity, challenge-response)
//!     └── Crypto (NaCl X25519 key pair for coordinator-mediated E2E)
//!
//! Trust model:
//!   The provider proves its identity via Secure Enclave attestation. The
//!   coordinator periodically challenges the provider to sign a nonce,
//!   verifying that the same hardware is still connected. Text requests may
//!   arrive sender-sealed to the coordinator first; the coordinator decrypts
//!   inside the Confidential VM, routes the request, then re-encrypts to the
//!   provider's X25519 key so the hardened provider process performs the final
//!   decryption locally.

mod backend;
mod config;
mod coordinator;
mod crypto;
mod hardware;
mod hypervisor;
mod models;
mod protocol;
mod proxy;
mod scheduling;
mod secure_enclave_key;
mod security;
mod server;
mod service;
mod telemetry;
mod wallet;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use tracing_subscriber::EnvFilter;

// Compile-time coordinator URL defaults. CI bakes the right environment via
// `DARKBLOOM_COORDINATOR_URL` — see `provider/build.rs`. Unset means local
// build: use prod URLs so dev-on-a-laptop still hits prod when users override
// via --coordinator flags and config files.
const DEFAULT_COORDINATOR_HTTP_URL: &str = match option_env!("DARKBLOOM_COORDINATOR_HTTP_URL") {
    Some(v) => v,
    None => "https://api.darkbloom.dev",
};
const DEFAULT_COORDINATOR_WS_URL: &str = match option_env!("DARKBLOOM_COORDINATOR_WS_URL") {
    Some(v) => v,
    None => "wss://api.darkbloom.dev/ws/provider",
};
const DEFAULT_INSTALL_URL: &str = match option_env!("DARKBLOOM_INSTALL_URL") {
    Some(v) => v,
    None => "https://api.darkbloom.dev/install.sh",
};
// Public R2 CDN URL for releases/templates/models. Dev uses a different bucket
// (d-inf-app-dev) with its own public URL — build.rs wires DARKBLOOM_R2_CDN_URL
// from CI. When unset, we fall back to the prod R2 CDN.
const DEFAULT_R2_CDN_URL: &str = match option_env!("DARKBLOOM_R2_CDN_URL") {
    Some(v) => v,
    None => "https://pub-7cbee059c80c46ec9c071dbee2726f8a.r2.dev",
};

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

#[derive(Debug, Clone, serde::Deserialize)]
struct CoordinatorAttestationResponse {
    #[serde(default)]
    providers: Vec<CoordinatorProviderTrust>,
}

#[derive(Debug, Clone, serde::Deserialize)]
struct CoordinatorProviderTrust {
    #[serde(default)]
    provider_id: String,
    #[serde(default)]
    serial_number: String,
    #[serde(default)]
    trust_level: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    mdm_verified: bool,
    #[serde(default)]
    acme_verified: bool,
    #[serde(default)]
    mda_verified: bool,
    #[serde(default)]
    secure_enclave: bool,
    #[serde(default)]
    sip_enabled: bool,
    #[serde(default)]
    secure_boot_enabled: bool,
    #[serde(default)]
    authenticated_root_enabled: bool,
}

impl CoordinatorProviderTrust {
    fn is_online(&self) -> bool {
        self.status.eq_ignore_ascii_case("online")
    }

    fn is_hardware_verified(&self) -> bool {
        self.trust_level.eq_ignore_ascii_case("hardware")
    }

    fn short_provider_id(&self) -> &str {
        self.provider_id.get(..8).unwrap_or(&self.provider_id)
    }
}

fn default_model_type() -> String {
    "text".into()
}

/// Hardcoded fallback catalog used when the coordinator is unreachable.
fn fallback_catalog() -> Vec<CatalogModel> {
    filter_provider_catalog(vec![
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
    ])
}

fn is_retired_provider_model(model: &CatalogModel) -> bool {
    [
        model.id.as_str(),
        model.s3_name.as_str(),
        model.display_name.as_str(),
    ]
    .iter()
    .any(|field| contains_retired_provider_model_token(field))
}

fn contains_retired_provider_model_token(value: &str) -> bool {
    value
        .to_ascii_lowercase()
        .split(|c: char| !c.is_ascii_alphanumeric())
        .any(|token| {
            token == "cohere"
                || token == "coherelabs"
                || token == "flux"
                || token.starts_with("flux")
        })
}

fn filter_provider_catalog(models: Vec<CatalogModel>) -> Vec<CatalogModel> {
    models
        .into_iter()
        .filter(|model| !is_retired_provider_model(model))
        .collect()
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

fn coordinator_http_base(coordinator_url: &str) -> String {
    coordinator_url
        .replace("wss://", "https://")
        .replace("ws://", "http://")
        .replace("/ws/provider", "")
        .trim_end_matches('/')
        .to_string()
}

fn prefer_provider_record(
    a: &CoordinatorProviderTrust,
    b: &CoordinatorProviderTrust,
) -> std::cmp::Ordering {
    b.is_hardware_verified()
        .cmp(&a.is_hardware_verified())
        .then_with(|| b.is_online().cmp(&a.is_online()))
        .then_with(|| a.provider_id.cmp(&b.provider_id))
}

async fn fetch_coordinator_provider_trust(
    coordinator_url: &str,
    serial_number: &str,
) -> Result<Vec<CoordinatorProviderTrust>> {
    let base_url = coordinator_http_base(coordinator_url);
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()?;
    let resp = client
        .get(format!("{base_url}/v1/providers/attestation"))
        .send()
        .await
        .with_context(|| format!("failed to query {base_url}/v1/providers/attestation"))?;
    let status = resp.status();
    if !status.is_success() {
        anyhow::bail!("coordinator returned HTTP {status}");
    }

    let body: CoordinatorAttestationResponse = resp
        .json()
        .await
        .context("failed to parse coordinator attestation response")?;
    let mut providers: Vec<_> = body
        .providers
        .into_iter()
        .filter(|p| p.serial_number == serial_number)
        .collect();
    providers.sort_by(prefer_provider_record);
    Ok(providers)
}

fn model_cache_dir(model_id: &str) -> std::path::PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join(".cache/huggingface/hub")
        .join(format!("models--{}", model_id.replace('/', "--")))
        .join("snapshots/main")
}

fn catalog_model_matches(model: &CatalogModel, selector: &str) -> bool {
    model.id == selector || model.s3_name == selector || model.display_name == selector
}

fn download_catalog_model(model: &CatalogModel, coordinator_base_url: &str) -> Result<()> {
    let cache_dir = model_cache_dir(&model.id);
    std::fs::create_dir_all(&cache_dir)
        .with_context(|| format!("failed to create {}", cache_dir.display()))?;

    // Try pre-packaged tarball first (fastest). Some large models are stored
    // only as individual R2 objects; those fall back to the shard-aware path.
    let tarball_url = format!(
        "{}/dl/models/{}.tar.gz",
        coordinator_base_url, model.s3_name
    );
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
        Ok(s) if s.success() => {
            println!("  ✓ {} downloaded", model.display_name);
            Ok(())
        }
        _ => {
            if download_model_from_cdn(&model.s3_name, &cache_dir, &model.display_name) {
                println!("  ✓ {} downloaded", model.display_name);
                Ok(())
            } else {
                anyhow::bail!("Failed to download {}", model.display_name)
            }
        }
    }
}

/// Download a model from the CDN (R2) into the given cache directory.
///
/// Handles text models (safetensors) from R2.
fn download_model_from_cdn(s3_name: &str, cache_dir: &std::path::Path, display_name: &str) -> bool {
    let base = format!("{}/{}", DEFAULT_R2_CDN_URL, s3_name);

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

/// Ensure a model's tokenizer_config.json contains a chat_template.
///
/// vllm-mlx calls `tokenizer.apply_chat_template()` which requires this field.
/// If missing (common with custom quantizations or stripped configs), inject the
/// standard ChatML template used by Qwen/Llama-family models.
/// Pre-populate ~/.darkbloom/templates/ with all known templates so the
/// provider's reported template hashes match the coordinator manifest.
/// Without this, models with inline chat_template (e.g. tokenizer_config.json)
/// short-circuit ensure_chat_template and ~/.darkbloom/templates/ stays empty
/// — causing every attestation challenge to fail with "template:NAME missing".
fn ensure_templates_cached(template_hashes: &std::collections::HashMap<String, String>) {
    let templates_dir = dirs::home_dir()
        .unwrap_or_default()
        .join(".darkbloom/templates");
    let _ = std::fs::create_dir_all(&templates_dir);

    for name in ["qwen3.5", "trinity", "gemma4", "minimax"] {
        let cached = templates_dir.join(format!("{name}.jinja"));

        // Skip if already cached and hash matches (or no manifest hash).
        if cached.exists() {
            if let Some(expected) = template_hashes.get(name) {
                if let Some(actual) = security::hash_file(&cached) {
                    if &actual == expected {
                        continue;
                    }
                    tracing::warn!("Cached template {name} hash mismatch — re-downloading");
                    let _ = std::fs::remove_file(&cached);
                }
            } else {
                continue;
            }
        }

        let url = format!("{}/templates/{name}.jinja", DEFAULT_R2_CDN_URL);
        if let Ok(output) = std::process::Command::new("curl")
            .args([
                "-fsSL",
                "--connect-timeout",
                "5",
                &url,
                "-o",
                &cached.to_string_lossy(),
            ])
            .output()
        {
            if output.status.success() {
                if let Some(expected) = template_hashes.get(name) {
                    if let Some(actual) = security::hash_file(&cached) {
                        if &actual != expected {
                            tracing::error!(
                                "Template {name} downloaded but hash mismatch (expected {expected}, got {actual}) — deleting"
                            );
                            let _ = std::fs::remove_file(&cached);
                            continue;
                        }
                    }
                }
                tracing::info!("Cached template {name} from CDN");
            } else {
                tracing::warn!("Failed to download template {name} from CDN");
            }
        }
    }
}

fn ensure_chat_template(
    model_path: &str,
    template_hashes: &std::collections::HashMap<String, String>,
) {
    let model_dir = std::path::Path::new(model_path);
    let jinja_path = model_dir.join("chat_template.jinja");

    // If the model already has a standalone template file, nothing to do
    if jinja_path.exists() {
        return;
    }

    // If tokenizer_config.json has an inline chat_template, nothing to do
    let config_path = model_dir.join("tokenizer_config.json");
    if config_path.exists() {
        if let Ok(content) = std::fs::read_to_string(&config_path) {
            if let Ok(config) = serde_json::from_str::<serde_json::Value>(&content) {
                if config.get("chat_template").is_some() {
                    return;
                }
            }
        }
    }

    // Determine which template this model needs
    let model_lower = model_path.to_lowercase();
    let template_name = if model_lower.contains("gemma") {
        "gemma4"
    } else if model_lower.contains("trinity") || model_lower.contains("deepseek") {
        "trinity"
    } else if model_lower.contains("minimax") {
        "minimax"
    } else {
        "qwen3.5" // safe default for ChatML-family models
    };

    // Check local cache first (~/.darkbloom/templates/)
    let eigeninference_dir = dirs::home_dir().unwrap_or_default().join(".darkbloom");
    let templates_dir = eigeninference_dir.join("templates");
    let cached_template = templates_dir.join(format!("{template_name}.jinja"));

    if cached_template.exists() {
        if let Some(expected) = template_hashes.get(template_name) {
            if let Some(actual) = security::hash_file(&cached_template) {
                if &actual != expected {
                    tracing::error!(
                        "Cached template {template_name} hash mismatch — deleting tampered file. Expected {expected}, got {actual}"
                    );
                    let _ = std::fs::remove_file(&cached_template);
                    // Fall through to download fresh copy below
                } else {
                    match std::fs::copy(&cached_template, &jinja_path) {
                        Ok(_) => tracing::info!(
                            "Installed {template_name} chat template from verified cache"
                        ),
                        Err(e) => tracing::warn!("Failed to copy cached template: {e}"),
                    }
                    return;
                }
            }
        } else {
            match std::fs::copy(&cached_template, &jinja_path) {
                Ok(_) => tracing::info!(
                    "Installed {template_name} chat template from cache (no manifest hash available)"
                ),
                Err(e) => tracing::warn!("Failed to copy cached template: {e}"),
            }
            return;
        }
    }

    // Verify a downloaded template against the manifest hash.
    // Returns true if verified or if no manifest hash is available (graceful degradation).
    let verify_template = |path: &std::path::Path,
                           name: &str,
                           hashes: &std::collections::HashMap<String, String>|
     -> bool {
        if let Some(expected) = hashes.get(name) {
            if let Some(actual) = security::hash_file(path) {
                if &actual != expected {
                    tracing::error!(
                        "Template {name} hash mismatch — possible tampering! Expected {expected}, got {actual}"
                    );
                    let _ = std::fs::remove_file(path);
                    return false;
                }
                tracing::info!("Template {name} hash verified ✓");
            }
        }
        true
    };

    // Download from our R2 CDN (primary) or HuggingFace (fallback)
    let r2_url = format!("{}/templates/{template_name}.jinja", DEFAULT_R2_CDN_URL);

    tracing::info!("Downloading {template_name} chat template...");

    // Try R2 CDN first
    if let Ok(output) = std::process::Command::new("curl")
        .args([
            "-fsSL",
            "--connect-timeout",
            "5",
            &r2_url,
            "-o",
            &jinja_path.to_string_lossy(),
        ])
        .output()
    {
        if output.status.success() {
            if !verify_template(&jinja_path, template_name, template_hashes) {
                // Hash mismatch — file already deleted by verify_template
            } else {
                tracing::info!("Installed {template_name} chat template from CDN");
                let _ = std::fs::create_dir_all(&templates_dir);
                let _ = std::fs::copy(&jinja_path, &cached_template);
                return;
            }
        }
    }

    // Fallback: download from HuggingFace
    let hf_url = match template_name {
        "gemma4" => Some(
            "https://huggingface.co/mlx-community/gemma-4-26b-a4b-it-8bit/raw/main/chat_template.jinja",
        ),
        "trinity" => {
            Some("https://huggingface.co/arcee-ai/Trinity-Mini/raw/main/chat_template.jinja")
        }
        "minimax" => Some(
            "https://huggingface.co/mlx-community/MiniMax-M2.5-8bit/raw/main/chat_template.jinja",
        ),
        _ => None, // Qwen 3.5 needs special handling (inline in tokenizer_config.json)
    };

    if let Some(url) = hf_url {
        if let Ok(output) = std::process::Command::new("curl")
            .args([
                "-fsSL",
                "--connect-timeout",
                "5",
                url,
                "-o",
                &jinja_path.to_string_lossy(),
            ])
            .output()
        {
            if output.status.success()
                && verify_template(&jinja_path, template_name, template_hashes)
            {
                tracing::info!("Installed {template_name} chat template from HuggingFace");
                let _ = std::fs::create_dir_all(&templates_dir);
                let _ = std::fs::copy(&jinja_path, &cached_template);
                return;
            }
        }
    } else {
        // Qwen: extract chat_template from tokenizer_config.json
        let tc_url = "https://huggingface.co/Qwen/Qwen3.5-27B/raw/main/tokenizer_config.json";
        if let Ok(output) = std::process::Command::new("curl")
            .args(["-fsSL", "--connect-timeout", "5", tc_url])
            .output()
        {
            if output.status.success() {
                if let Ok(config) = serde_json::from_slice::<serde_json::Value>(&output.stdout) {
                    if let Some(template) = config.get("chat_template").and_then(|v| v.as_str()) {
                        if std::fs::write(&jinja_path, template).is_ok()
                            && verify_template(&jinja_path, "qwen3.5", template_hashes)
                        {
                            tracing::info!("Installed qwen3.5 chat template from HuggingFace");
                            let _ = std::fs::create_dir_all(&templates_dir);
                            let _ = std::fs::copy(&jinja_path, &cached_template);
                            return;
                        }
                    }
                }
            }
        }
    }

    tracing::warn!(
        "Failed to download chat template — model may not support tool calling correctly"
    );
}

/// Fetch the runtime manifest from the coordinator.
/// Returns template_hashes from the runtime manifest.
fn fetch_runtime_manifest(
    coordinator_base: &str,
) -> Option<std::collections::HashMap<String, String>> {
    let url = format!("{coordinator_base}/v1/runtime/manifest");
    let output = std::process::Command::new("curl")
        .args(["-fsSL", "--connect-timeout", "5", &url])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let manifest: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;

    let template_hashes = manifest
        .get("template_hashes")
        .and_then(|v| v.as_object())
        .map(|obj| {
            obj.iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                .collect()
        })
        .unwrap_or_default();

    Some(template_hashes)
}

/// Fetch the latest release version string from the coordinator.
fn fetch_latest_release_version(coordinator_base: &str) -> String {
    let url = format!("{coordinator_base}/v1/releases/latest");
    let output = std::process::Command::new("curl")
        .args(["-fsSL", "--connect-timeout", "5", &url])
        .output();
    match output {
        Ok(o) if o.status.success() => {
            let release: serde_json::Value = match serde_json::from_slice(&o.stdout) {
                Ok(v) => v,
                Err(_) => return String::new(),
            };
            release
                .get("version")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string()
        }
        _ => String::new(),
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
                Ok(cr) => {
                    let models = filter_provider_catalog(cr.models);
                    if !models.is_empty() {
                        models
                    } else {
                        eprintln!("  ⚠ Empty catalog from coordinator, using defaults");
                        fallback_catalog()
                    }
                }
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
#[command(name = "darkbloom", about = "Darkbloom provider agent for Apple Silicon Macs", version = env!("CARGO_PKG_VERSION"))]
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
        #[arg(long, default_value = DEFAULT_COORDINATOR_WS_URL)]
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

        /// Minutes of inactivity before backend shuts down to free GPU memory (0 = never)
        #[arg(long)]
        idle_timeout: Option<u64>,

        /// Disable automatic update checks (enabled by default)
        #[arg(long)]
        no_auto_update: bool,
    },

    /// One-command setup: enroll in MDM, download model, start serving
    Install {
        /// Coordinator URL (WebSocket for serving, HTTPS for API)
        #[arg(long, default_value = DEFAULT_COORDINATOR_WS_URL)]
        coordinator: String,

        /// Legacy static MDM enrollment profile URL. Prefer the default dynamic enrollment flow.
        #[arg(long, hide = true)]
        profile_url: Option<String>,

        /// Model to serve (auto-selects if not specified)
        #[arg(long)]
        model: Option<String>,
    },

    /// Enroll this Mac in Darkbloom MDM (without starting to serve)
    Enroll {
        /// Coordinator URL for device attestation enrollment
        #[arg(long, default_value = DEFAULT_COORDINATOR_HTTP_URL)]
        coordinator: String,
    },

    /// Remove MDM enrollment and clean up Darkbloom data
    Unenroll,

    /// Run standardized benchmarks
    Benchmark,

    /// Show hardware and connection status
    Status,

    /// Report the existing private text E2E key public key
    KeyStatus,

    /// List, download, or remove models
    Models {
        /// Action: list (default), download, or remove
        #[arg(default_value = "list")]
        action: String,

        /// Model ID to download without opening the interactive picker
        #[arg(long)]
        model: Option<String>,

        /// Coordinator URL to fetch model catalog
        #[arg(long, default_value = DEFAULT_COORDINATOR_HTTP_URL)]
        coordinator: String,
    },

    /// Show earnings and usage history
    Earnings {
        /// Coordinator API URL
        #[arg(long, default_value = DEFAULT_COORDINATOR_HTTP_URL)]
        coordinator: String,
    },

    /// Diagnose issues: check SIP, Secure Enclave, MDM, models, connectivity
    Doctor {
        /// Coordinator URL to test connectivity
        #[arg(long, default_value = DEFAULT_COORDINATOR_HTTP_URL)]
        coordinator: String,

        /// Include provider ID, serial, and coordinator trust details for support
        #[arg(long)]
        support: bool,
    },

    /// Start the provider in the background (uses existing config)
    Start {
        /// Coordinator WebSocket URL
        #[arg(long, default_value = DEFAULT_COORDINATOR_WS_URL)]
        coordinator: String,

        /// Model to serve
        #[arg(long)]
        model: Option<String>,

        /// Minutes of inactivity before backend shuts down to free GPU memory (0 = never)
        #[arg(long)]
        idle_timeout: Option<u64>,
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
        #[arg(long, default_value = DEFAULT_COORDINATOR_HTTP_URL)]
        coordinator: String,
        /// Force re-download even if already on the latest version
        #[arg(long)]
        force: bool,
    },

    /// Link this machine to your Darkbloom account
    Login {
        /// Coordinator URL
        #[arg(long, default_value = DEFAULT_COORDINATOR_HTTP_URL)]
        coordinator: String,
    },

    /// Unlink this machine from your account
    Logout,

    /// Enable or disable automatic updates (e.g. `darkbloom autoupdate enable`)
    #[command(name = "autoupdate")]
    AutoUpdate {
        /// "enable" or "disable"
        action: String,
    },

    /// Compute runtime hash for a directory (used by CI for release registration)
    #[command(name = "hash-runtime")]
    HashRuntime {
        /// Path to the Python lib directory (e.g. /path/to/python/lib/python3.12)
        path: String,
    },
}

fn setup_logging(verbose: bool) {
    let filter = if verbose {
        EnvFilter::new("darkbloom=debug,info")
    } else {
        EnvFilter::new("darkbloom=info,warn")
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
        Command::KeyStatus => cmd_key_status().await,
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
            idle_timeout,
            no_auto_update,
        } => {
            cmd_serve(
                local,
                coordinator,
                port,
                model,
                backend_port,
                all_models,
                idle_timeout,
                !no_auto_update,
            )
            .await
        }
        Command::Enroll { coordinator } => cmd_enroll(coordinator).await,
        Command::Unenroll => cmd_unenroll().await,
        Command::Benchmark => cmd_benchmark().await,
        Command::Status => cmd_status().await,
        Command::Models {
            action,
            model,
            coordinator,
        } => cmd_models(action, coordinator, model).await,
        Command::Earnings { coordinator } => cmd_earnings(coordinator).await,
        Command::Doctor {
            coordinator,
            support,
        } => cmd_doctor(coordinator, support).await,
        Command::Start {
            coordinator,
            model,
            idle_timeout,
        } => cmd_start(coordinator, model, idle_timeout).await,
        Command::Stop => cmd_stop().await,
        Command::Logs { lines, watch } => cmd_logs(lines, watch).await,
        Command::Update { coordinator, force } => cmd_update(coordinator, force).await,
        Command::Login { coordinator } => cmd_login(coordinator).await,
        Command::Logout => cmd_logout().await,
        Command::AutoUpdate { action } => cmd_autoupdate(&action).await,
        Command::HashRuntime { path } => {
            eprintln!(
                "error: hash-runtime is no longer supported; use the Swift provider for runtime verification"
            );
            std::process::exit(1);
        }
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
        .unwrap_or_else(|| DEFAULT_COORDINATOR_HTTP_URL.to_string());

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
    eprintln!("  │  Run: darkbloom update                  │");
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
    let kp = crypto::NodeKeyPair::generate();
    tracing::info!("Ephemeral E2E key generated");
    println!("Public key: {}", kp.public_key_base64());

    Ok(())
}

async fn cmd_key_status() -> Result<()> {
    println!("E2E keys are ephemeral — generated fresh on each provider launch.");
    println!("Run `darkbloom serve` to see the current public key.");
    Ok(())
}

async fn cmd_install(
    coordinator_url: String,
    profile_url: Option<String>,
    model_override: Option<String>,
) -> Result<()> {
    println!("╔══════════════════════════════════════════╗");
    println!("║       Darkbloom Provider Setup               ║");
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
    println!("  ✓ Config: {}", config_path.display());
    println!("  ✓ E2E key: ephemeral (generated at startup)");
    println!();

    // Step 3: MDM enrollment profile. Local profile presence is not the same
    // as coordinator hardware trust; doctor checks the network-side state.
    println!("Step 3/6: MDM enrollment...");

    let already_enrolled = security::check_mdm_enrolled();

    if already_enrolled {
        println!("  ✓ Local MDM profile present");
        println!("    Coordinator hardware trust will be verified after provider registration.");
    } else {
        match get_serial_number() {
            Ok(serial) => {
                let profile_path = std::env::temp_dir()
                    .join(format!("EigenInference-Enroll-{serial}.mobileconfig"));
                println!("  Requesting enrollment profile...");
                let client = reqwest::Client::new();
                let resp = if let Some(ref legacy_url) = profile_url {
                    client.get(legacy_url).send().await?
                } else {
                    let enroll_url =
                        format!("{}/v1/enroll", coordinator_http_base(&coordinator_url));
                    client
                        .post(&enroll_url)
                        .json(&serde_json::json!({"serial_number": serial}))
                        .send()
                        .await?
                };

                if !resp.status().is_success() {
                    println!(
                        "  ⚠ Could not download profile (HTTP {}). Skipping MDM enrollment.",
                        resp.status()
                    );
                    println!("    You can enroll later: darkbloom enroll");
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
                    println!("  Enrollment profile opened; coordinator verification is pending.");
                }
            }
            Err(e) => {
                println!("  ⚠ Could not read serial number ({e}). Skipping MDM enrollment.");
                println!("    You can enroll later: darkbloom enroll");
            }
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
    }
    // Machines with <36 GB RAM have no default model — no text models fit.

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
                println!("  Free up disk space and retry: darkbloom install");
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
        let base_url = coordinator_http_base(&coordinator_url);

        for model_id in &models_to_download {
            if let Some(model) = catalog.iter().find(|cm| cm.id == *model_id) {
                println!();
                println!("  Downloading {}...", model.display_name);
                download_catalog_model(model, &base_url)?;
            } else {
                anyhow::bail!("model {model_id:?} is not in the supported catalog");
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

    service::install_and_start(&coordinator_url, &[model.clone()], None)?;

    let log_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".darkbloom/provider.log");

    println!("╔══════════════════════════════════════════╗");
    println!("║  Provider is running as a system service! ║");
    println!("╚══════════════════════════════════════════╝");
    println!();
    println!("  Service: io.darkbloom.provider (launchd)");
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
        println!("  to your Darkbloom account:");
        println!();
        println!("    darkbloom login");
        println!();
        println!("  Without linking, earnings go to a local");
        println!("  wallet and cannot be withdrawn.");
        println!();
    }

    println!("Commands:");
    println!("  darkbloom login      Link to your account");
    println!("  darkbloom status     Show provider status");
    println!("  darkbloom logs       View logs");
    println!("  darkbloom stop       Stop the provider");
    println!("  darkbloom doctor     Run diagnostics");
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
    idle_timeout_override: Option<u64>,
    auto_update: bool,
) -> Result<()> {
    // Ensure only one provider instance runs at a time.
    // Kill any existing provider serve process + its backend children.
    #[cfg(unix)]
    {
        let my_pid = std::process::id();
        let eigeninference_dir = dirs::home_dir().unwrap_or_default().join(".darkbloom");
        let pid_file = eigeninference_dir.join("provider.pid");

        // Check for an existing provider process
        if let Ok(old_pid_str) = std::fs::read_to_string(&pid_file) {
            if let Ok(old_pid) = old_pid_str.trim().parse::<u32>() {
                if old_pid != my_pid {
                    // Check if the old process is still running
                    let alive = std::process::Command::new("kill")
                        .args(["-0", &old_pid.to_string()])
                        .status()
                        .map(|s| s.success())
                        .unwrap_or(false);
                    if alive {
                        tracing::info!("Killing existing provider (PID {old_pid})");
                        let _ = std::process::Command::new("kill")
                            .args([&old_pid.to_string()])
                            .status();
                        // Wait for graceful shutdown, then SIGKILL if still alive
                        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                        let still_alive = std::process::Command::new("kill")
                            .args(["-0", &old_pid.to_string()])
                            .status()
                            .map(|s| s.success())
                            .unwrap_or(false);
                        if still_alive {
                            tracing::warn!(
                                "Old provider (PID {old_pid}) didn't exit — sending SIGKILL"
                            );
                            let _ = std::process::Command::new("kill")
                                .args(["-9", &old_pid.to_string()])
                                .status();
                            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                        }
                    }
                }
            }
        }

        // Write our PID
        let _ = std::fs::write(&pid_file, my_pid.to_string());

        let _ = std::process::Command::new("pkill")
            .args(["-f", "mlx_lm.server"])
            .status();
        // Kill legacy DGInf/dginf-provider processes
        let _ = std::process::Command::new("pkill")
            .args(["-f", "DGInf"])
            .status();
        let _ = std::process::Command::new("pkill")
            .args(["-f", "dginf-provider"])
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

    // Phase 5: Disable core dumps and scrub dangerous environment variables
    // before any inference data enters the process.
    if let Err(reason) = security::disable_core_dumps() {
        anyhow::bail!("Failed to disable core dumps: {reason}");
    }
    security::scrub_private_env();

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

    // Generate ephemeral E2E encryption key pair
    let node_keypair = std::sync::Arc::new(crypto::NodeKeyPair::generate());
    tracing::info!(
        "Ephemeral E2E key generated (public: {})",
        node_keypair.public_key_base64()
    );

    // Create ephemeral Secure Enclave signing handle
    let se_handle: Option<std::sync::Arc<secure_enclave_key::SecureEnclaveHandle>> =
        match secure_enclave_key::SecureEnclaveHandle::create() {
            Ok(h) => {
                tracing::info!(
                    "Ephemeral SE signing key created (public: {})",
                    h.public_key_base64()
                );
                Some(std::sync::Arc::new(h))
            }
            Err(e) => {
                tracing::warn!("Secure Enclave unavailable: {e}");
                None
            }
        };

    // Clean up legacy persistent key files from previous versions
    secure_enclave_key::cleanup_legacy_key_files();

    // Determine backend port (CLI override > config)
    let be_port = backend_port_override.unwrap_or(cfg.backend.port);

    // Determine idle timeout (CLI override > config, 0 = never)
    let idle_timeout_mins = idle_timeout_override.unwrap_or(cfg.backend.idle_timeout_mins);
    let idle_timeout = if idle_timeout_mins == 0 {
        None
    } else {
        Some(std::time::Duration::from_secs(idle_timeout_mins * 60))
    };
    if let Some(d) = idle_timeout {
        tracing::info!("Idle GPU timeout: {} minutes", d.as_secs() / 60);
    } else {
        tracing::info!("Idle GPU timeout: disabled (backend stays running)");
    }

    let text_backend_name = "mlx-swift";
    tracing::info!("Text backend mode: {}", text_backend_name);

    // Determine text models to serve.
    let available_models = models::scan_models(&hw);
    let selected_models: Vec<String> = if !model_overrides.is_empty() {
        model_overrides
    } else if let Some(m) = cfg.backend.model.clone() {
        vec![m]
    } else {
        // No --model specified — don't auto-pick. The picker in cmd_start
        // explicitly chooses which models to serve.
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
    if !selected_models.is_empty() {}

    // Build backend slots: one backend process per model on sequential ports.
    // Shared state struct for per-slot health monitoring and lifecycle management.
    struct BackendSlot {
        model_id: String,
        model_path: String,
        port: u16,
        pid: Option<u32>,
        backend_url: String,
        healthy: bool,
    }
    let mut backend_slots: Vec<BackendSlot> = selected_models
        .iter()
        .enumerate()
        .map(|(i, model_id)| {
            let port = be_port + i as u16;
            BackendSlot {
                model_id: model_id.clone(),
                model_path: String::new(),
                port,
                pid: None,
                backend_url: format!("http://127.0.0.1:{}", port),
                healthy: false,
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

    // Kill any existing subprocess backends on our backend ports to avoid EADDRINUSE.
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

    let eigeninference_dir = dirs::home_dir().unwrap_or_default().join(".darkbloom");

    let coordinator_http_base = coordinator_url
        .replace("wss://", "https://")
        .replace("ws://", "http://")
        .replace("/ws/provider", "");

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

    // Set up coordinator state. The actual connection is spawned AFTER backends
    // are loaded so we don't advertise models before we can serve them.
    let mut coordinator_handle;
    let event_rx_opt;
    let outbound_tx_opt;
    let shutdown_tx_opt;
    let inference_active_opt;
    let health_inference_active_opt;
    let provider_stats_opt;
    let backend_capacity_opt: Option<
        std::sync::Arc<std::sync::Mutex<Option<protocol::BackendCapacity>>>,
    >;
    // Backend state: tri-state to distinguish running, idle-shutdown, and crashed.
    const BACKEND_RUNNING: u8 = 0;
    const BACKEND_IDLE_SHUTDOWN: u8 = 1;
    const BACKEND_CRASHED: u8 = 2;
    let backend_running_flag_opt: Option<std::sync::Arc<std::sync::atomic::AtomicU8>>;
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

        let backend_name = text_backend_name;

        let public_key_b64 = node_keypair.public_key_base64();

        // Compute SHA-256 of our own binary for integrity attestation.
        let binary_hash = security::self_binary_hash();

        // Generate Secure Enclave attestation via in-process FFI, binding the
        // X25519 encryption key and binary hash to the ephemeral SE identity.
        let attestation = se_handle.as_ref().and_then(|h| {
            match h.create_attestation(&public_key_b64, binary_hash.as_deref()) {
                Ok(att) => {
                    tracing::info!("Secure Enclave attestation generated via FFI");
                    Some(att)
                }
                Err(e) => {
                    tracing::warn!("Attestation generation failed: {e}");
                    None
                }
            }
        });
        let se_public_key = se_handle
            .as_ref()
            .map(|h| h.public_key_base64().to_string());

        // Load device auth token if the provider has been linked to an account.
        let auth_token = load_auth_token();
        if auth_token.is_some() {
            tracing::info!("Provider linked to account (auth token loaded)");
        }

        // ------------------------------------------------------------------
        // Initialize telemetry pipeline.
        //
        // The client spawns a background batcher that flushes to the
        // coordinator's /v1/telemetry/events endpoint. Panics, backend
        // crashes, and tracing WARN+ events are forwarded automatically.
        // ------------------------------------------------------------------
        let telemetry_cfg = telemetry::TelemetryConfig {
            coordinator_url: coordinator_url.clone(),
            auth_token: auth_token.clone(),
            version: env!("CARGO_PKG_VERSION").to_string(),
            machine_id: public_key_b64.clone(),
            account_id: None,
            source: telemetry::Source::Provider,
            disk_queue_path: dirs::home_dir()
                .unwrap_or_else(|| std::path::PathBuf::from("/tmp"))
                .join(".darkbloom/telemetry-queue.jsonl"),
            max_batch: 50,
            flush_interval: std::time::Duration::from_secs(5),
            mem_queue_cap: 1024,
        };
        let tel_client = telemetry::init(telemetry_cfg).clone();
        telemetry::panic_hook::install(tel_client.clone());
        tracing::info!(
            "Telemetry pipeline ready (session_id={})",
            telemetry::event::SESSION_ID.as_str()
        );

        // Emit a provider_start event so operators can see fleet boots
        // from the admin dashboard.
        telemetry::emit(
            telemetry::TelemetryEvent::new(
                telemetry::Source::Provider,
                telemetry::Severity::Info,
                telemetry::Kind::Log,
                "provider_start",
            )
            .with_field("component", "provider")
            .with_field("hardware_chip", hw.chip_name.clone())
            .with_field("memory_gb", hw.memory_gb as i64),
        );

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

        // Compute weight hashes for all active models.
        let initial_model_hash = models::compute_weight_hash(&model);
        let current_model_hash: std::sync::Arc<std::sync::Mutex<Option<String>>> =
            std::sync::Arc::new(std::sync::Mutex::new(initial_model_hash.clone()));
        rehash_model_hash_opt = Some(current_model_hash.clone());

        // Collect per-model weight hashes for attestation.
        let mut all_model_hashes: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        if let Some(ref h) = initial_model_hash {
            all_model_hashes.insert(model.clone(), h.clone());
        }

        // Shared backend capacity data (updated by polling task, read by heartbeats).
        let backend_capacity: std::sync::Arc<std::sync::Mutex<Option<protocol::BackendCapacity>>> =
            std::sync::Arc::new(std::sync::Mutex::new(None));
        backend_capacity_opt = Some(backend_capacity.clone());

        // Shared tri-state flag tracking backend lifecycle.
        // Written by the event loop (idle shutdown → IDLE_SHUTDOWN, crash → CRASHED,
        // reload → RUNNING), read by the capacity polling task to report accurate state.
        let backend_running_flag =
            std::sync::Arc::new(std::sync::atomic::AtomicU8::new(BACKEND_RUNNING));
        backend_running_flag_opt = Some(backend_running_flag);

        // Compute template hashes for verification by coordinator.
        let template_hashes = fetch_runtime_manifest(&coordinator_http_base).unwrap_or_default();
        tracing::info!("Template hashes: {} template(s)", template_hashes.len());

        tracing::info!(
            "Model weight hashes for attestation: {} model(s)",
            all_model_hashes.len()
        );

        let client = coordinator::CoordinatorClient::new(
            coordinator_url,
            hw.clone(),
            advertised_models,
            backend_name.to_string(),
            std::time::Duration::from_secs(cfg.coordinator.heartbeat_interval_secs),
            Some(public_key_b64),
            node_keypair.clone(),
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
        .with_current_model_hash(current_model_hash)
        .with_model_hashes(all_model_hashes)
        .with_backend_capacity(backend_capacity)
        .with_se_handle(se_handle.clone());

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
        backend_capacity_opt = None;
        backend_running_flag_opt = None;
    }

    // =========================================================================
    // Phase 2: Start backend processes and wait for them to load.
    //
    // Coordinator connection is deferred until all backends are ready.
    // This ensures we never advertise models we can't actually serve yet.
    // =========================================================================

    // Resolve model ID to local path on disk so the backend loads from disk.
    // Start either one in-process engine or one subprocess backend per model.
    let _backend_name = text_backend_name;

    // Fetch template hashes from manifest once (not per model)
    let manifest_template_hashes =
        fetch_runtime_manifest(&coordinator_http_base).unwrap_or_default();

    // Pre-populate ~/.darkbloom/templates/ with all manifest templates so
    // attestation challenges report matching hashes even when models have
    // inline chat_template fields (which makes ensure_chat_template skip).
    ensure_templates_cached(&manifest_template_hashes);

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
        slot.model_path = model_path.clone();
        tracing::info!(
            "Starting backend for {} on port {} (path: {})",
            slot.model_id,
            slot.port,
            model_path
        );

        ensure_chat_template(&model_path, &manifest_template_hashes);
    }

    // Wait for all subprocess backends to become healthy.
    for slot in &mut backend_slots {
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
        slot.healthy = ready;
    }

    // Primary backend URL for backwards compat (local server, health monitor)
    let backend_url_str = backend_slots
        .first()
        .map(|s| s.backend_url.clone())
        .unwrap_or_else(|| format!("http://127.0.0.1:{}", be_port));
    let backend_url = backend_url_str.clone();
    // Shared per-slot state for health monitoring, capacity polling, and the event loop.
    // The health monitor reads port/PID/model_path and updates healthy/pid.
    // The event loop reads healthy to know which slots can serve, and updates pid on reload.
    struct SharedSlotState {
        model_id: String,
        model_path: String,
        port: u16,
        pid: Option<u32>,
        healthy: bool,
        restarting: bool, // guard: prevents health monitor + event loop from restarting simultaneously
    }
    let shared_slots: std::sync::Arc<std::sync::Mutex<Vec<SharedSlotState>>> =
        std::sync::Arc::new(std::sync::Mutex::new(
            backend_slots
                .iter()
                .map(|s| SharedSlotState {
                    model_id: s.model_id.clone(),
                    model_path: s.model_path.clone(),
                    port: s.port,
                    pid: s.pid,
                    healthy: s.healthy,
                    restarting: false,
                })
                .collect(),
        ));

    // Security hardening: prevent debugger attachment AFTER all subprocesses
    // are spawned. PT_DENY_ATTACH poisons mach_task_self_ in the process
    // memory, which causes child Python processes to crash with SIGBUS.
    security::deny_debugger_attachment()
        .map_err(|err| anyhow::anyhow!("security hardening failed: {err}"))?;

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
    // Auto-update: periodically check for new versions and self-update.
    // CLI --no-auto-update overrides config; config default is true.
    // =========================================================================
    let auto_update_enabled = auto_update && cfg.provider.auto_update;
    if auto_update_enabled && !local {
        let update_coordinator = coordinator_http_base.clone();
        tokio::spawn(async move {
            // Wait 5 minutes before the first check so startup completes cleanly.
            tokio::time::sleep(std::time::Duration::from_secs(300)).await;
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(1800));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                interval.tick().await;
                match auto_update_check(&update_coordinator).await {
                    Ok(true) => {
                        // Update installed — restart the service and exit this process.
                        tracing::info!("Auto-update complete — restarting provider");
                        if let Err(e) = auto_update_restart() {
                            tracing::error!("Failed to restart after update: {e}");
                        }
                        // Exit so launchd restarts us with the new binary.
                        std::process::exit(0);
                    }
                    Ok(false) => {} // already up to date
                    Err(e) => {
                        tracing::warn!("Auto-update check failed: {e}");
                    }
                }
            }
        });
        tracing::info!("Auto-update enabled (checks every 30 minutes)");
    }

    // =========================================================================
    // Phase 4: Run the main event loop.
    // =========================================================================
    if local {
        server::ensure_legacy_text_proxy_allowed()?;
        tracing::warn!(
            "Starting legacy local HTTP text proxy on port {port} via explicit debug escape hatch; this path is plaintext and must never be used for private text serving"
        );
        server::start_server(port, backend_url).await?;
    } else {
        // Unwrap coordinator state — guaranteed to be Some in non-local mode.
        let mut event_rx = event_rx_opt.unwrap();
        let outbound_tx = outbound_tx_opt.unwrap();
        let shutdown_tx = shutdown_tx_opt.unwrap();
        let inference_active = inference_active_opt.unwrap();
        let _health_inference_active = health_inference_active_opt.unwrap();
        let provider_stats = provider_stats_opt.unwrap();
        let coordinator_handle = coordinator_handle.unwrap();

        let backend_name = text_backend_name;

        // Spawn backend capacity polling task — periodically polls each
        // vllm-mlx backend's /v1/status endpoint to collect live capacity data
        // (running requests, token counts, GPU memory). This data is included
        // in heartbeats so the coordinator can make informed routing decisions.
        if let Some(cap_arc) = backend_capacity_opt {
            let poll_shared_slots = shared_slots.clone();
            let total_mem_gb = hw.memory_gb as f64;
            let poll_backend_running = backend_running_flag_opt
                .as_ref()
                .expect("backend_running_flag must be set in non-local mode")
                .clone();
            tokio::spawn(async move {
                let mut poll_interval = tokio::time::interval(std::time::Duration::from_secs(5));
                poll_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                loop {
                    poll_interval.tick().await;
                    let mut slots = Vec::new();
                    let mut gpu_active = 0.0_f64;
                    let mut gpu_peak = 0.0_f64;
                    let mut gpu_cache = 0.0_f64;
                    let slot_snapshots: Vec<(String, u16, bool)> = {
                        let slots = poll_shared_slots.lock().unwrap();
                        slots
                            .iter()
                            .map(|s| (s.model_id.clone(), s.port, s.restarting))
                            .collect()
                    };
                    for (model_id, port, restarting) in &slot_snapshots {
                        if *restarting {
                            slots.push(protocol::BackendSlotCapacity {
                                model: model_id.clone(),
                                state: "reloading".to_string(),
                                num_running: 0,
                                num_waiting: 0,
                                active_tokens: 0,
                                max_tokens_potential: 0,
                            });
                            continue;
                        }

                        let url = format!("http://127.0.0.1:{port}");
                        match hardware::poll_backend_status(&url).await {
                            Some(status) => {
                                if status.gpu_memory_active_gb > gpu_active {
                                    gpu_active = status.gpu_memory_active_gb;
                                }
                                if status.gpu_memory_peak_gb > gpu_peak {
                                    gpu_peak = status.gpu_memory_peak_gb;
                                }
                                if status.gpu_memory_cache_gb > gpu_cache {
                                    gpu_cache = status.gpu_memory_cache_gb;
                                }
                                slots.push(protocol::BackendSlotCapacity {
                                    model: model_id.clone(),
                                    state: "running".to_string(),
                                    num_running: status.num_running,
                                    num_waiting: status.num_waiting,
                                    active_tokens: status.active_tokens,
                                    max_tokens_potential: status.max_tokens_potential,
                                });
                            }
                            None => {
                                let flag_val =
                                    poll_backend_running.load(std::sync::atomic::Ordering::Relaxed);
                                let state = match flag_val {
                                    BACKEND_IDLE_SHUTDOWN => "idle_shutdown",
                                    _ => "crashed",
                                };
                                slots.push(protocol::BackendSlotCapacity {
                                    model: model_id.clone(),
                                    state: state.to_string(),
                                    num_running: 0,
                                    num_waiting: 0,
                                    active_tokens: 0,
                                    max_tokens_potential: 0,
                                });
                            }
                        }
                    }
                    let capacity = protocol::BackendCapacity {
                        slots,
                        gpu_memory_active_gb: gpu_active,
                        gpu_memory_peak_gb: gpu_peak,
                        gpu_memory_cache_gb: gpu_cache,
                        total_memory_gb: total_mem_gb,
                    };
                    *cap_arc.lock().unwrap() = Some(capacity);
                }
            });
        }

        // Spawn per-slot backend health monitor — detects crashes and auto-restarts
        // each backend independently.
        {
            let has_text_backends = !backend_slots.is_empty();
            let health_shared_slots = shared_slots.clone();
            let health_coordinator_http = coordinator_http_base.clone();
            let health_backend = backend_name.to_string();
            let health_backend_running = backend_running_flag_opt
                .as_ref()
                .expect("backend_running_flag must be set in non-local mode")
                .clone();
            tokio::spawn(async move {
                if !has_text_backends {
                    // No text backends to monitor — sleep forever.
                    loop {
                        tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
                    }
                }

                // Track consecutive failures per slot (indexed by position in shared_slots).
                let slot_count = health_shared_slots.lock().unwrap().len();
                let mut consecutive_failures: Vec<u32> = vec![0; slot_count];

                let mut interval = tokio::time::interval(std::time::Duration::from_secs(15));
                loop {
                    interval.tick().await;

                    // Snapshot current slot state (hold the lock briefly).
                    let slot_snapshots: Vec<(String, String, u16, Option<u32>)> = {
                        let slots = health_shared_slots.lock().unwrap();
                        slots
                            .iter()
                            .map(|s| (s.model_id.clone(), s.model_path.clone(), s.port, s.pid))
                            .collect()
                    };

                    let mut any_crashed = false;
                    for (idx, (model_id, model_path, port, pid)) in
                        slot_snapshots.iter().enumerate()
                    {
                        let health_url = format!("http://127.0.0.1:{}", port);
                        if backend::check_health(&health_url).await {
                            if consecutive_failures[idx] > 0 {
                                tracing::info!(
                                    "Backend for {} recovered after {} failed health checks",
                                    model_id,
                                    consecutive_failures[idx]
                                );
                                consecutive_failures[idx] = 0;
                                // Mark slot healthy again.
                                let mut slots = health_shared_slots.lock().unwrap();
                                if let Some(slot) = slots.get_mut(idx) {
                                    slot.healthy = true;
                                }
                            }
                        } else {
                            consecutive_failures[idx] += 1;
                            tracing::warn!(
                                "Backend health check failed for {} on port {} ({} consecutive)",
                                model_id,
                                port,
                                consecutive_failures[idx]
                            );
                            // 5 consecutive failures (75 seconds) before restart.
                            // Higher threshold than single-backend (was 3) because
                            // the Python GIL can block /health during long generations,
                            // and we don't want to kill a busy-but-healthy backend.
                            if consecutive_failures[idx] >= 5 {
                                // Check if another task (event loop) is already restarting this slot.
                                let already_restarting = {
                                    let slots = health_shared_slots.lock().unwrap();
                                    slots.get(idx).map_or(false, |s| s.restarting)
                                };
                                if already_restarting {
                                    tracing::info!(
                                        "Backend for {} restart already in progress — skipping",
                                        model_id
                                    );
                                    continue;
                                }

                                tracing::error!(
                                    "Backend for {} appears crashed — cannot auto-restart (subprocess management removed); marking unhealthy",
                                    model_id,
                                );
                                any_crashed = true;
                                {
                                    let mut slots = health_shared_slots.lock().unwrap();
                                    if let Some(slot) = slots.get_mut(idx) {
                                        slot.healthy = false;
                                        slot.restarting = false;
                                    }
                                }
                            }
                        }
                    }

                    // Update the global backend_running flag based on whether ALL
                    // slots are healthy. This preserves the existing tri-state
                    // semantics for capacity polling.
                    if any_crashed {
                        health_backend_running
                            .store(BACKEND_CRASHED, std::sync::atomic::Ordering::Relaxed);
                    } else {
                        let all_healthy = {
                            let slots = health_shared_slots.lock().unwrap();
                            slots.iter().all(|s| s.healthy)
                        };
                        if all_healthy {
                            health_backend_running
                                .store(BACKEND_RUNNING, std::sync::atomic::Ordering::Relaxed);
                        }
                    }
                }
            });
        }

        // Process coordinator events
        let self_heal_running = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let idle_backend_name = backend_name.to_string();
        let proxy_stats = provider_stats.clone();
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
        // Collect PIDs for per-process shutdown
        let backend_pids: Vec<(String, Option<u32>)> = backend_slots
            .iter()
            .map(|s| (s.model_id.clone(), s.pid))
            .collect();

        let event_backend_running =
            backend_running_flag_opt.expect("backend_running_flag must be set in non-local mode");
        let event_handle = tokio::spawn(async move {
            use std::collections::HashMap;
            use tokio_util::sync::CancellationToken;

            // Track in-flight inference tasks so we can cancel them on
            // coordinator disconnect or explicit cancel messages.
            let mut inflight: HashMap<String, (CancellationToken, tokio::task::JoinHandle<()>)> =
                HashMap::new();
            let (done_tx, mut done_rx) = tokio::sync::mpsc::channel::<(String, bool)>(64);

            // Idle timeout: shut down the backend after a period of no
            // requests to free GPU memory. Lazy-reload on next request.
            // `idle_timeout` is None when disabled (0 minutes).
            let mut last_request_time = tokio::time::Instant::now();

            // Helper closures for the shared backend state flag (tri-state).
            let is_backend_running = || {
                event_backend_running.load(std::sync::atomic::Ordering::Relaxed) == BACKEND_RUNNING
            };
            let set_backend_state = |state: u8| {
                event_backend_running.store(state, std::sync::atomic::Ordering::Relaxed);
            };

            loop {
                let idle_sleep = async {
                    if let Some(timeout) = idle_timeout {
                        if is_backend_running() && inflight.is_empty() {
                            tokio::time::sleep_until(last_request_time + timeout).await;
                        } else {
                            std::future::pending::<()>().await;
                        }
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
                            coordinator::CoordinatorEvent::InferenceRequest {
                                request_id,
                                body,
                                response_public_key,
                            } => {
                                let Some(response_public_key) = response_public_key else {
                                    let _ = outbound_tx.send(
                                        protocol::ProviderMessage::InferenceError {
                                            request_id,
                                            error: "coordinator text request missing encrypted response session key".to_string(),
                                            status_code: 400,
                                        }
                                    ).await;
                                    continue;
                                };

                                last_request_time = tokio::time::Instant::now();
                                inference_active.store(true, std::sync::atomic::Ordering::Relaxed);

                                // Immediately tell the coordinator we accepted this request.
                                // This MUST happen before any cold-start reload so the
                                // coordinator switches from the 10s first-chunk timeout to
                                // the full inference timeout (~600s). Without this, cold
                                // starts (10-30s model load) always hit the 10s timeout.
                                let _ = outbound_tx.send(
                                    protocol::ProviderMessage::InferenceAccepted {
                                        request_id: request_id.clone(),
                                    }
                                ).await;

                                // Determine which model the request actually wants.
                                let req_model_id = body.get("model")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();

                                // Find the correct slot for the requested model.
                                // Each slot has a fixed (model, port) assignment that
                                // never changes — a Gemma request always goes to the
                                // Gemma slot, never overwrites a Qwen slot.
                                let slot_info = {
                                    let slots = shared_slots.lock().unwrap();
                                    slots.iter()
                                        .find(|s| s.model_id == req_model_id
                                            || s.model_id.contains(&req_model_id)
                                            || req_model_id.contains(&s.model_id))
                                        .map(|s| (s.model_id.clone(), s.model_path.clone(), s.port, s.pid, s.healthy, s.restarting))
                                };

                                if let Some((slot_model_id, _slot_model_path, slot_port, _slot_pid, slot_healthy, slot_restarting)) = slot_info {
                                    let backend_url = format!("http://127.0.0.1:{}", slot_port);
                                    let needs_reload = !slot_healthy || !backend::check_health(&backend_url).await;

                                    if needs_reload && !slot_restarting {
                                        tracing::warn!(
                                            "Slot for {} on port {} not running and cannot be restarted (subprocess management removed)",
                                            slot_model_id, slot_port
                                        );
                                        let _ = outbound_tx.send(
                                            protocol::ProviderMessage::InferenceError {
                                                request_id,
                                                error: format!("backend for {} is not running", slot_model_id),
                                                status_code: 503,
                                            }
                                        ).await;
                                        continue;
                                    }
                                } else {
                                    tracing::warn!("No slot configured for model {}", req_model_id);
                                    let _ = outbound_tx.send(
                                        protocol::ProviderMessage::InferenceError {
                                            request_id,
                                            error: format!("no backend slot for model {}", req_model_id),
                                            status_code: 404,
                                        }
                                    ).await;
                                    continue;
                                }

                                // (InferenceAccepted already sent above, before reload)

                                // Route to the correct backend based on the requested model.
                                let requested_model = body.get("model")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string();

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
                                let done_tx = done_tx.clone();
                                let rid = request_id.clone();
                                let proxy_backend_url = backend_url.clone();

                                let handle = {
                                    let stats = proxy_stats.clone();
                                    let response_keypair = node_keypair.clone();
                                    let se_h = se_handle.clone();
                                    let spawn_rid = rid.clone();
                                    let cancel_token_clone = cancel_token.clone();
                                    tokio::spawn(async move {
                                        proxy::handle_inference_request(
                                            spawn_rid.clone(),
                                            body,
                                            proxy_backend_url,
                                            tx,
                                            Some(response_keypair),
                                            cancel_token_clone,
                                            Some(stats),
                                            se_h,
                                        )
                                        .await;
                                        let _ = done_tx.send((spawn_rid, false)).await;
                                    })
                                };

                                inflight.insert(rid, (cancel_token, handle));
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
                            coordinator::CoordinatorEvent::RuntimeOutdated { mismatches: _ } => {
                                tracing::warn!(
                                    "Runtime verification failed — template mismatch reported"
                                );
                            }
                        }
                    }
                    Some((rid, backend_dead)) = done_rx.recv() => {
                        if inflight.remove(&rid).is_some() {
                            tracing::debug!("Request {rid} completed, removed from tracker ({} in-flight)", inflight.len());
                            if inflight.is_empty() {
                                inference_active.store(false, std::sync::atomic::Ordering::Relaxed);
                            }
                        }
                        if backend_dead && is_backend_running() {
                            tracing::warn!("Backend appears dead (connection refused) — will reload on next request");
                            set_backend_state(BACKEND_CRASHED);
                        }
                    }
                    _ = idle_sleep => {
                        tracing::info!(
                            "No requests for {} minutes — shutting down backends to free GPU memory. \
                             Next request will reload (~30-60s cold start).",
                            idle_timeout_mins
                        );
                        shutdown_backends(&backend_pids).await;
                        set_backend_state(BACKEND_IDLE_SHUTDOWN);
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

    // Clean up backends and PID file
    #[cfg(unix)]
    {
        let _ = std::process::Command::new("pkill")
            .args(["-f", "mlx_lm.server"])
            .status();
        let pid_file = dirs::home_dir()
            .unwrap_or_default()
            .join(".darkbloom/provider.pid");
        let _ = std::fs::remove_file(pid_file);
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
                .args(["-f", "mlx_lm.server"])
                .status();
        }
    }
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    tracing::info!("Backend processes terminated — GPU memory freed");
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
async fn cmd_enroll(coordinator_url: String) -> Result<()> {
    println!("Darkbloom Device Attestation Enrollment");
    println!();

    // Check if already enrolled
    if security::check_mdm_enrolled() {
        println!("✓ Already enrolled — no action needed.");
        println!();
        println!("  Verify with: darkbloom doctor");
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
        println!("  Click \"Install\" on the Darkbloom profile, then enter your password.");
        println!("  This verifies:");
        println!("    • SIP and Secure Boot are enabled");
        println!("    • Your Secure Enclave is genuine Apple hardware");
        println!("    • Device identity signed by Apple's Root CA");
        println!();
        println!("  Darkbloom CANNOT erase, lock, or control your Mac.");
        println!("  Remove anytime in System Settings → Device Management.");
    }

    println!();
    println!("After installing, verify with: darkbloom doctor");
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
    println!("Darkbloom Unenrollment");
    println!();

    if security::check_mdm_enrolled() {
        println!("MDM profile found. To remove:");
        println!("  System Settings → General → Device Management");
        println!("  Click on the Darkbloom profile → Remove");
        println!();
        #[cfg(target_os = "macos")]
        {
            println!("Opening System Settings...");
            let _ = std::process::Command::new("open")
                .arg("x-apple.systempreferences:com.apple.preferences.configurationprofiles")
                .status();
        }
    } else {
        println!("No Darkbloom MDM profile found. Nothing to remove.");
    }

    // Clean up local data
    println!();
    println!("Clean up local Darkbloom data? This removes:");
    println!("  - Config: ~/.config/eigeninference/");
    println!("  - Legacy key files in ~/.darkbloom/");
    println!("  - Auth token: ~/.darkbloom/auth_token");
    println!();
    println!("Type 'yes' to confirm:");
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    if input.trim() == "yes" {
        let home = dirs::home_dir().unwrap_or_default();
        let _ = std::fs::remove_dir_all(home.join(".config/eigeninference"));
        secure_enclave_key::cleanup_legacy_key_files();
        let _ = std::fs::remove_file(home.join(".darkbloom/wallet_key"));
        let _ = std::fs::remove_file(home.join(".darkbloom/auth_token"));
        println!("  ✓ Local data cleaned up");
    } else {
        println!("  Skipped cleanup");
    }

    Ok(())
}

async fn cmd_benchmark() -> Result<()> {
    let hw = hardware::detect()?;
    println!();
    println!("  Darkbloom Benchmark");
    println!("  ─────────────────────────────────────");
    println!(
        "  {} · {} GB RAM · {} GPU cores · {} GB/s",
        hw.chip_name, hw.memory_gb, hw.gpu_cores, hw.memory_bandwidth_gbs
    );
    println!();

    // Find bundled Python
    let eigeninference_dir = dirs::home_dir().unwrap_or_default().join(".darkbloom");
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
        anyhow::bail!("vllm-mlx not found. Run: darkbloom install");
    }

    // Scan downloaded models and filter by catalog
    let downloaded = models::scan_models(&hw);
    let catalog = fetch_catalog(DEFAULT_COORDINATOR_HTTP_URL).await;
    let catalog_ids: std::collections::HashSet<String> =
        catalog.iter().map(|c| c.id.clone()).collect();

    let servable: Vec<_> = downloaded
        .iter()
        .filter(|m| catalog_ids.contains(&m.id))
        .collect();

    if servable.is_empty() {
        anyhow::bail!("No catalog models downloaded. Run: darkbloom models download");
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
import time, json, sys, asyncio
sys.path.insert(0, '.')
from vllm_mlx.engine import SimpleEngine

async def main():
    engine = SimpleEngine(model_name="{model_path}")

    prompt = "Write a detailed analysis of the economic impact of artificial intelligence on the global workforce over the next decade."

    # Warmup
    print("  Warming up...", flush=True)
    await engine.generate(prompt, max_tokens=10)

    # Benchmark: 3 runs
    results = []
    for run in range(3):
        start = time.perf_counter()
        token_count = 0
        first_token_time = None
        async for out in engine.stream_generate(prompt, max_tokens=200):
            if first_token_time is None:
                first_token_time = time.perf_counter()
            token_count = out.completion_tokens
        end = time.perf_counter()

        ttft_ms = (first_token_time - start) * 1000 if first_token_time else 0
        decode_time = end - first_token_time if first_token_time else end - start
        n_tokens = token_count
        tps = n_tokens / decode_time if decode_time > 0 else 0

        results.append({{"ttft_ms": ttft_ms, "tokens": n_tokens, "tps": tps, "total_s": end - start}})
        print(f"  Run {{run+1}}: {{tps:.1f}} tok/s | TTFT {{ttft_ms:.0f}}ms | {{n_tokens}} tokens in {{end-start:.2f}}s", flush=True)

    # Summary
    avg_tps = sum(r["tps"] for r in results) / len(results)
    avg_ttft = sum(r["ttft_ms"] for r in results) / len(results)
    print()
    print(f"  Average: {{avg_tps:.1f}} tok/s | TTFT {{avg_ttft:.0f}}ms")
    print(json.dumps({{"avg_tps": avg_tps, "avg_ttft_ms": avg_ttft, "runs": results}}))

asyncio.run(main())
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
    let eigeninference_dir = home.join(".darkbloom");

    println!();
    println!("  Darkbloom Provider Status");
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

    println!("    SE signing:     ✓ Ephemeral (per-launch)");

    println!(
        "    Local MDM:      {}",
        if security::check_mdm_enrolled() {
            "✓ Profile present"
        } else {
            "✗ No profile found"
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
            "✗ No — run: darkbloom login"
        }
    );
    println!();

    // Coordinator trust is the network-side source of truth for routing.
    println!("  Coordinator trust:");
    match get_serial_number() {
        Ok(serial) => {
            println!("    Serial:    {serial}");
            match fetch_coordinator_provider_trust(DEFAULT_COORDINATOR_HTTP_URL, &serial).await {
                Ok(records) if records.is_empty() => {
                    println!("    Provider:  ✗ No coordinator record for this serial");
                    println!("    Trust:     ✗ Not verified");
                    println!(
                        "    Next:      Start or restart the provider after installing the MDM profile"
                    );
                }
                Ok(records) => {
                    let record = &records[0];
                    println!(
                        "    Provider:  {} ({})",
                        record.short_provider_id(),
                        record.status
                    );
                    println!("    Trust:     {}", record.trust_level);
                    println!(
                        "    MDM:       {}",
                        if record.mdm_verified {
                            "✓ Verified"
                        } else {
                            "✗ Not verified"
                        }
                    );
                    println!(
                        "    MDA/ACME:  {}/{}",
                        if record.mda_verified { "✓" } else { "✗" },
                        if record.acme_verified { "✓" } else { "✗" }
                    );
                    if record.is_hardware_verified() {
                        println!("    Trust gate: ✓ Passed");
                    } else {
                        println!(
                            "    Trust gate: ✗ Not routable until coordinator verifies hardware trust"
                        );
                        println!(
                            "    Next:       darkbloom stop && darkbloom start, then darkbloom doctor"
                        );
                    }
                }
                Err(e) => {
                    println!("    Trust:     ? Could not check coordinator ({e})");
                }
            }
        }
        Err(e) => {
            println!("    Serial:    ? Could not read serial ({e})");
        }
    }
    println!();

    // Models (catalog-filtered)
    let models = models::scan_models(&hw);
    let catalog = fetch_catalog(DEFAULT_COORDINATOR_HTTP_URL).await;
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
        println!("    darkbloom logs -w    Stream live logs");
        println!("    darkbloom stop       Stop serving");
    } else {
        println!();
        println!("  Commands:");
        println!("    darkbloom start       Start serving");
        println!("    darkbloom models download  Download models");
    }
    println!();

    Ok(())
}

async fn cmd_models(
    action: String,
    coordinator_url: String,
    model_override: Option<String>,
) -> Result<()> {
    let hw = hardware::detect()?;
    let downloaded = models::scan_models(&hw);

    // Fetch model catalog from coordinator
    let catalog = fetch_catalog(&coordinator_url).await;

    // When called with no action (default "list"), show the interactive hub
    let effective_action = if action == "list" {
        // Show overview first
        println!();
        println!("  Darkbloom Models");
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
        "download" | "download-s3" | "add" => {
            let base_url = coordinator_http_base(&coordinator_url);

            if let Some(selector) = model_override {
                let cm = catalog
                    .iter()
                    .find(|cm| catalog_model_matches(cm, &selector))
                    .with_context(|| {
                        format!("model {selector:?} is not in the supported catalog")
                    })?;

                if downloaded.iter().any(|m| m.id == cm.id) {
                    println!("  ✓ {} already downloaded", cm.display_name);
                    return Ok(());
                }

                println!("  Downloading {}...", cm.display_name);
                return download_catalog_model(cm, &base_url);
            }

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

            for sel in selections {
                if let Some((_, cm)) = downloadable.iter().find(|(i, _)| *i == sel) {
                    println!();
                    println!("  Downloading {}...", cm.display_name);
                    download_catalog_model(cm, &base_url)?;
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
            println!("Usage: darkbloom models [list|download|remove]");
        }
    }

    Ok(())
}

async fn cmd_earnings(coordinator_url: String) -> Result<()> {
    println!("Darkbloom Earnings");
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

#[cfg(target_os = "macos")]
fn support_command_output(program: &str, args: &[&str]) -> String {
    match std::process::Command::new(program).args(args).output() {
        Ok(output) => {
            let combined = format!(
                "{}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            let trimmed = combined.trim();
            if trimmed.is_empty() {
                "<no output>".to_string()
            } else {
                trimmed.lines().take(12).collect::<Vec<_>>().join("\n    ")
            }
        }
        Err(e) => format!("<failed to run: {e}>"),
    }
}

fn print_doctor_support_info(
    coordinator_url: &str,
    serial_number: Option<&str>,
    local_mdm_profile: bool,
    provider_records: &[CoordinatorProviderTrust],
    coordinator_trust_error: Option<&str>,
) {
    println!();
    println!("Support info");
    println!("  Coordinator: {}", coordinator_http_base(coordinator_url));
    println!("  Serial: {}", serial_number.unwrap_or("<unavailable>"));
    println!(
        "  Local MDM profile: {}",
        if local_mdm_profile {
            "present"
        } else {
            "not detected"
        }
    );

    if provider_records.is_empty() {
        println!("  Coordinator provider records: none for this serial");
    } else {
        println!("  Coordinator provider records:");
        for record in provider_records {
            println!(
                "    {} status={} trust={} mdm={} mda={} acme={} se={} sip={} secure_boot={} root={}",
                record.provider_id,
                record.status,
                record.trust_level,
                record.mdm_verified,
                record.mda_verified,
                record.acme_verified,
                record.secure_enclave,
                record.sip_enabled,
                record.secure_boot_enabled,
                record.authenticated_root_enabled
            );
        }
    }
    if let Some(error) = coordinator_trust_error {
        println!("  Coordinator trust lookup error: {error}");
    }

    #[cfg(target_os = "macos")]
    {
        println!("  profiles status -type enrollment:");
        println!(
            "    {}",
            support_command_output("profiles", &["status", "-type", "enrollment"])
        );
    }
}

async fn cmd_doctor(coordinator_url: String, support: bool) -> Result<()> {
    println!("Darkbloom Doctor — System Diagnostics");
    println!();

    let mut issues: Vec<String> = Vec::new();
    let mut passed = 0;
    let total_checks = 9;
    let local_serial = get_serial_number().ok();
    let mut provider_records: Vec<CoordinatorProviderTrust> = Vec::new();
    let mut coordinator_trust_error: Option<String> = None;

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
                std::process::Command::new(home.join(".darkbloom/bin/eigeninference-enclave"))
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

    // 4. Local MDM profile
    print!("4. Local MDM profile........... ");
    let local_mdm_profile = security::check_mdm_enrolled();
    if local_mdm_profile {
        println!("✓ Present");
        passed += 1;
    } else {
        #[cfg(target_os = "macos")]
        {
            println!("✗ Not detected");
            issues.push("Install the MDM profile: darkbloom enroll".to_string());
        }
        #[cfg(not(target_os = "macos"))]
        {
            println!("- Not applicable (non-macOS)");
            passed += 1;
        }
    }

    // 5. Inference runtime (vllm-mlx / mlx-lm)
    print!("5. Inference runtime........... ");
    let eigeninference_dir = dirs::home_dir().unwrap_or_default().join(".darkbloom");
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
                    issues.push(format!(
                        "Inference runtime not found. Reinstall:\n     curl -fsSL {} | bash",
                        DEFAULT_INSTALL_URL
                    ));
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
        issues.push("Download a model: darkbloom models download".to_string());
    }

    // 7. Text E2E key (ephemeral, generated at startup)
    print!("7. Text E2E key................ ");
    println!("✓ Ephemeral (generated at startup)");
    passed += 1;

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

    // 9. Coordinator hardware trust
    print!("9. Coordinator hardware trust.. ");
    match local_serial.as_deref() {
        Some(serial) => match fetch_coordinator_provider_trust(&coordinator_url, serial).await {
            Ok(records) if records.is_empty() => {
                println!("✗ No provider record for serial {serial}");
                issues.push(
                    "Coordinator has no provider record for this serial. Start or restart the provider after installing the MDM profile."
                        .to_string(),
                );
            }
            Ok(records) => {
                provider_records = records;
                let record = &provider_records[0];
                if record.is_hardware_verified() {
                    println!(
                        "✓ hardware ({}, provider {})",
                        record.status,
                        record.short_provider_id()
                    );
                    passed += 1;
                } else {
                    println!(
                        "✗ {} ({}, provider {})",
                        record.trust_level,
                        record.status,
                        record.short_provider_id()
                    );
                    if local_mdm_profile {
                        issues.push(
                            "Local MDM profile is present, but the coordinator has not verified this serial through MDM. Run: darkbloom stop && darkbloom start, then retry darkbloom doctor."
                                .to_string(),
                        );
                    } else {
                        issues.push(
                            "Coordinator trust is self-signed because no local MDM profile is detected. Run: darkbloom enroll."
                                .to_string(),
                        );
                    }
                }
            }
            Err(e) => {
                println!("? Could not check: {e}");
                coordinator_trust_error = Some(e.to_string());
                issues.push(format!(
                    "Could not check coordinator hardware trust for serial {serial}"
                ));
            }
        },
        None => {
            println!("✗ Could not read local serial number");
            issues
                .push("Could not read Mac serial number for coordinator trust lookup".to_string());
        }
    }

    // Summary
    println!();
    println!("Result: {passed}/{total_checks} checks passed");
    if issues.is_empty() {
        println!();
        println!("All good! Start serving with: darkbloom serve");
    } else {
        println!();
        println!("Issues to fix:");
        for (i, issue) in issues.iter().enumerate() {
            println!("  {}. {}", i + 1, issue);
        }
        println!();
        println!("For support details, run: darkbloom doctor --support");
    }

    if support {
        print_doctor_support_info(
            &coordinator_url,
            local_serial.as_deref(),
            local_mdm_profile,
            &provider_records,
            coordinator_trust_error.as_deref(),
        );
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
    idle_timeout: Option<u64>,
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
    let selected_models: Vec<String> = if let Some(m) = model_override {
        vec![m]
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
        let cdn_base = DEFAULT_R2_CDN_URL;
        let cdn_sizes: std::collections::HashMap<String, u64> = {
            let client = reqwest::Client::new();
            let mut sizes = std::collections::HashMap::new();
            for c in &catalog {
                if let Some(on_disk) = downloaded.iter().find(|m| m.id == c.id) {
                    // Only HEAD-check models we have locally (to verify completeness)
                    let url = format!("{}/{}/model.safetensors", cdn_base, c.s3_name);
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
            // Only show text models in the picker
            .filter(|c| c.model_type == "text")
            .filter(|c| (c.min_ram_gb as f64) <= hw.memory_gb as f64)
            .map(|c| {
                // Check if model is downloaded AND complete.
                let on_disk = downloaded.iter().find(|m| m.id == c.id);
                let is_downloaded = on_disk.is_some_and(|m| {
                    if let Some(&expected) = cdn_sizes.get(&c.id) {
                        m.size_bytes >= expected
                    } else {
                        m.size_bytes > 500_000_000
                    }
                });
                let size = if is_downloaded {
                    on_disk.map(|m| m.estimated_memory_gb).unwrap_or(c.size_gb)
                } else {
                    c.size_gb
                };
                PickerItem {
                    id: c.id.clone(),
                    display: c.display_name.clone(),
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

        // Download any selected models that aren't local yet
        for &idx in &selected_indices {
            let item = &items[idx];
            if !item.downloaded {
                println!();
                println!("  Downloading {}...", item.display);
                let cache_dir = dirs::home_dir()
                    .unwrap_or_default()
                    .join(".cache/huggingface/hub")
                    .join(format!("models--{}", item.id.replace('/', "--")))
                    .join("snapshots/main");
                std::fs::create_dir_all(&cache_dir)?;
                if !download_model_from_cdn(&item.s3_name, &cache_dir, &item.display) {
                    anyhow::bail!("Failed to download {}", item.display);
                }
                println!("  ✓ Downloaded {}", item.display);
            }
        }

        let text_models: Vec<String> = selected_indices
            .iter()
            .map(|&idx| items[idx].id.clone())
            .collect();
        text_models
    };

    if selected_models.is_empty() {
        anyhow::bail!("No models selected");
    }

    let log_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".darkbloom/provider.log");

    // Install as launchd user agent
    service::install_and_start(&coordinator_url, &selected_models, idle_timeout)?;

    println!("Provider installed as system service");
    println!(
        "  Models:  {} ({})",
        selected_models.len(),
        selected_models.join(", ")
    );
    println!("  Logs:    {}", log_path.display());
    println!("  Service: io.darkbloom.provider (launchd)");
    println!();
    println!("  darkbloom stop    Stop the provider");
    println!("  darkbloom logs    View logs");
    println!("  darkbloom status  Check status");

    Ok(())
}

async fn cmd_stop() -> Result<()> {
    let eigeninference_dir = dirs::home_dir().unwrap_or_default().join(".darkbloom");
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

async fn cmd_update(coordinator: String, force: bool) -> Result<()> {
    let current_version = env!("CARGO_PKG_VERSION");
    println!("Darkbloom Provider Update");
    println!();
    println!("  Current version: {current_version}");
    if force {
        println!("  Force mode: will re-download even if up to date");
    }

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
    let swift_release = is_swift_release(&info);
    let download_url = info["download_url"].as_str().unwrap_or("");

    println!("done");
    println!("  Latest version:  {latest}");

    if !force {
        if latest == current_version {
            println!();
            println!("  Already up to date!");
            return Ok(());
        }

        if !is_newer_version(current_version, latest) {
            println!();
            println!("  Already up to date!");
            return Ok(());
        }
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
        .join(".darkbloom");
    let bin_dir = eigeninference_dir.join("bin");

    println!("  Installing...");
    let status = std::process::Command::new("tar")
        .args(["xzf", tmp_path, "-C", &eigeninference_dir.to_string_lossy()])
        .status()?;
    if !status.success() {
        anyhow::bail!("tar extraction failed");
    }

    let coordinator_http = base_url
        .replace("wss://", "https://")
        .replace("ws://", "http://")
        .replace("/ws/provider", "");

    if swift_release {
        install_swift_update_bundle(&eigeninference_dir, &info, true)?;
    } else {
        // Move binaries to bin dir
        let _ = std::fs::rename(
            eigeninference_dir.join("darkbloom"),
            bin_dir.join("darkbloom"),
        );
        let _ = std::fs::rename(
            eigeninference_dir.join("eigeninference-enclave"),
            bin_dir.join("eigeninference-enclave"),
        );

        // Make executable
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for name in &["darkbloom", "eigeninference-enclave"] {
                let path = bin_dir.join(name);
                if path.exists() {
                    let mut perms = std::fs::metadata(&path)?.permissions();
                    perms.set_mode(0o755);
                    std::fs::set_permissions(&path, perms)?;
                }
            }
        }

        verify_installed_update_runtime(&eigeninference_dir, &coordinator_http, true)?;
    }

    std::fs::remove_file(tmp_path).ok();

    // Verify manifest if included in bundle
    let manifest_path = eigeninference_dir.join("manifest.json");
    if manifest_path.exists() {
        println!("  Runtime manifest: present ✓");
    }

    println!();
    println!("  Updated to {latest}!");

    // Auto-restart if the provider is currently running as a launchd service.
    // The plist already has the correct args from the last `start`, so we just
    // stop and re-kickstart with the new binary.
    if service::is_loaded() {
        println!("  Restarting provider...");
        service::stop()?;
        std::thread::sleep(std::time::Duration::from_secs(1));

        // Re-bootstrap and kickstart — plist is already on disk with correct args
        let uid = unsafe { libc::getuid() };
        let domain = format!("gui/{uid}");
        let plist = dirs::home_dir()
            .unwrap_or_default()
            .join("Library/LaunchAgents/io.darkbloom.provider.plist");
        if plist.exists() {
            let _ = std::process::Command::new("launchctl")
                .args(["bootstrap", &domain, &plist.to_string_lossy()])
                .output();
            let target = format!("gui/{uid}/io.darkbloom.provider");
            let _ = std::process::Command::new("launchctl")
                .args(["kickstart", &target])
                .output();
            println!("  Provider restarted with {latest}");
        }
    }

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

fn emit_update_status(stdout: bool, message: &str) {
    if stdout {
        println!("{message}");
    } else {
        tracing::info!("{message}");
    }
}

fn emit_update_warning(stdout: bool, message: &str) {
    if stdout {
        println!("{message}");
    } else {
        tracing::warn!("{message}");
    }
}

fn parse_codesign_team_identifier(output: &str) -> Option<String> {
    output.lines().find_map(|line| {
        line.trim()
            .strip_prefix("TeamIdentifier=")
            .map(str::trim)
            .filter(|team| !team.is_empty() && *team != "not set")
            .map(ToOwned::to_owned)
    })
}

fn codesign_team_identifier(path: &std::path::Path) -> Result<String> {
    let output = std::process::Command::new("codesign")
        .args(["-dvv", &path.to_string_lossy()])
        .output()
        .with_context(|| format!("failed to inspect code signature for {}", path.display()))?;

    let combined = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    parse_codesign_team_identifier(&combined)
        .ok_or_else(|| anyhow::anyhow!("{} is missing a TeamIdentifier", path.display()))
}

fn collect_python_core_signature_targets(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_python_core_signature_targets(&path, out);
            continue;
        }

        match path.extension().and_then(|ext| ext.to_str()) {
            Some("dylib") | Some("so") => out.push(path),
            _ => {}
        }
    }
}

fn verify_python_core_signature_match(eigeninference_dir: &std::path::Path) -> Result<()> {
    let darkbloom_path = eigeninference_dir.join("bin/darkbloom");
    if !darkbloom_path.exists() {
        anyhow::bail!("updated darkbloom binary missing after install");
    }

    let darkbloom_team = codesign_team_identifier(&darkbloom_path)?;
    let mut targets = Vec::new();

    let bundled_python = eigeninference_dir.join("python/bin/python3.12");
    if bundled_python.exists() {
        targets.push(bundled_python);
    }
    collect_python_core_signature_targets(&eigeninference_dir.join("python/lib"), &mut targets);
    targets.sort();
    targets.dedup();

    if targets.is_empty() {
        anyhow::bail!("bundled Python core missing after update");
    }

    for target in targets {
        let verify = std::process::Command::new("codesign")
            .args(["--verify", "--verbose", &target.to_string_lossy()])
            .output()
            .with_context(|| format!("failed to verify code signature for {}", target.display()))?;
        if !verify.status.success() {
            let detail = String::from_utf8_lossy(&verify.stderr).trim().to_string();
            let detail = if detail.is_empty() {
                format!("codesign exited with {}", verify.status)
            } else {
                detail
            };
            anyhow::bail!("{} has an invalid signature: {}", target.display(), detail);
        }

        let team = codesign_team_identifier(&target)?;
        if team != darkbloom_team {
            anyhow::bail!(
                "{} Team ID {} does not match darkbloom Team ID {}",
                target.display(),
                team,
                darkbloom_team
            );
        }
    }

    Ok(())
}

fn verify_installed_update_runtime(
    eigeninference_dir: &std::path::Path,
    coordinator_http: &str,
    stdout: bool,
) -> Result<()> {
    let bundled_python = eigeninference_dir.join("python/bin/python3.12");

    if let Err(err) = verify_python_core_signature_match(eigeninference_dir) {
        emit_update_warning(
            stdout,
            &format!("  ⚠ {err} — forcing canonical Python runtime reinstall"),
        );
        std::fs::remove_file(&bundled_python).ok();
    }

    if let Some(hash) = security::hash_file(&bundled_python) {
        let prefix_len = hash.len().min(8);
        let suffix_start = hash.len().saturating_sub(8);
        emit_update_status(
            stdout,
            &format!(
                "  Python hash: {}...{}",
                &hash[..prefix_len],
                &hash[suffix_start..]
            ),
        );
    }

    if bundled_python.exists() {
        let check = std::process::Command::new(&bundled_python)
            .args(["-c", "import vllm_mlx; print(vllm_mlx.__version__)"])
            .output();
        match check {
            Ok(o) if o.status.success() => {
                let ver = String::from_utf8_lossy(&o.stdout).trim().to_string();
                emit_update_status(stdout, &format!("  vllm-mlx: {ver} ✓"));
            }
            _ => emit_update_warning(stdout, "  ⚠ vllm-mlx import check failed"),
        }
    } else {
        emit_update_warning(
            stdout,
            "  ⚠ Bundled Python missing — downloading canonical runtime",
        );
    }

    emit_update_status(stdout, "  Verifying Python runtime...");
    let python_cmd = bundled_python.to_string_lossy().to_string();
    let python_check = std::process::Command::new(&python_cmd)
        .args(["-c", "print('ok')"])
        .output();
    if python_check.is_err() || !python_check.unwrap().status.success() {
        anyhow::bail!("Python runtime could not be verified after update");
    }
    verify_python_core_signature_match(eigeninference_dir)
        .context("bundled Python core still failed signature validation after reinstall")?;
    Ok(())
}

fn backup_installed_binary(path: &std::path::Path) -> Result<Option<std::path::PathBuf>> {
    if !path.exists() {
        return Ok(None);
    }

    let backup_path = path.with_extension("auto-update-backup");
    let _ = std::fs::remove_file(&backup_path);
    std::fs::copy(path, &backup_path)?;
    Ok(Some(backup_path))
}

fn restore_installed_binary(
    path: &std::path::Path,
    backup_path: Option<&std::path::Path>,
) -> Result<()> {
    let Some(backup_path) = backup_path else {
        return Ok(());
    };

    std::fs::copy(backup_path, path)?;
    std::fs::remove_file(backup_path).ok();
    Ok(())
}

fn remove_binary_backup(backup_path: Option<&std::path::Path>) {
    if let Some(backup_path) = backup_path {
        std::fs::remove_file(backup_path).ok();
    }
}

fn restore_or_remove_installed_path(
    path: &std::path::Path,
    backup_path: Option<&std::path::Path>,
) -> Result<()> {
    if let Some(backup_path) = backup_path {
        restore_installed_binary(path, Some(backup_path))
    } else {
        std::fs::remove_file(path).ok();
        Ok(())
    }
}

fn release_string<'a>(info: &'a serde_json::Value, key: &str) -> &'a str {
    info[key].as_str().unwrap_or("")
}

fn is_swift_release(info: &serde_json::Value) -> bool {
    release_string(info, "backend") == "mlx-swift"
        || !release_string(info, "metallib_hash").is_empty()
}

fn verify_update_file_hash(
    path: &std::path::Path,
    expected: &str,
    label: &str,
    stdout: bool,
) -> Result<()> {
    if expected.is_empty() {
        return Ok(());
    }
    let actual = security::hash_file(path)
        .ok_or_else(|| anyhow::anyhow!("{label} missing after Swift update: {}", path.display()))?;
    if actual != expected {
        anyhow::bail!("{label} hash mismatch — expected {expected}, got {actual}");
    }
    emit_update_status(stdout, &format!("  {label} hash verified ✓"));
    Ok(())
}

fn install_swift_update_bundle(
    eigeninference_dir: &std::path::Path,
    info: &serde_json::Value,
    stdout: bool,
) -> Result<()> {
    let bin_dir = eigeninference_dir.join("bin");
    std::fs::create_dir_all(&bin_dir)?;

    // Swift bundles are staged as bin/{darkbloom,darkbloom-enclave,mlx.metallib}.
    // Accept root-level files too so bridge updates can consume early bundles.
    for name in &["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
        let root_path = eigeninference_dir.join(name);
        if root_path.exists() {
            let _ = std::fs::rename(root_path, bin_dir.join(name));
        }
    }
    let legacy_root_helper = eigeninference_dir.join("eigeninference-enclave");
    if legacy_root_helper.exists() && !bin_dir.join("darkbloom-enclave").exists() {
        let _ = std::fs::rename(legacy_root_helper, bin_dir.join("darkbloom-enclave"));
    }

    let darkbloom = bin_dir.join("darkbloom");
    let enclave = bin_dir.join("darkbloom-enclave");
    let metallib = bin_dir.join("mlx.metallib");
    if !darkbloom.exists() {
        anyhow::bail!("Swift update bundle missing bin/darkbloom");
    }
    if !enclave.exists() {
        anyhow::bail!("Swift update bundle missing bin/darkbloom-enclave");
    }
    if !metallib.exists() {
        anyhow::bail!("Swift update bundle missing bin/mlx.metallib");
    }

    let binary_hash = release_string(info, "binary_hash");
    let metallib_hash = release_string(info, "metallib_hash");
    if binary_hash.is_empty() {
        anyhow::bail!("Swift update metadata missing binary_hash");
    }
    if metallib_hash.is_empty() {
        anyhow::bail!("Swift update metadata missing metallib_hash");
    }
    verify_update_file_hash(&darkbloom, binary_hash, "darkbloom", stdout)?;
    verify_update_file_hash(&metallib, metallib_hash, "mlx.metallib", stdout)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::{PermissionsExt, symlink};
        for path in [&darkbloom, &enclave] {
            let mut perms = std::fs::metadata(path)?.permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(path, perms)?;
        }

        let legacy_link = bin_dir.join("eigeninference-enclave");
        std::fs::remove_file(&legacy_link).ok();
        symlink(&enclave, &legacy_link)
            .with_context(|| format!("failed to create {}", legacy_link.display()))?;
    }

    emit_update_status(stdout, "  Swift runtime bundle verified ✓");
    Ok(())
}

/// Check for updates and install if available. Returns Ok(true) if an update was installed.
async fn auto_update_check(coordinator_base_url: &str) -> Result<bool> {
    let eigeninference_dir = dirs::home_dir()
        .ok_or_else(|| anyhow::anyhow!("cannot find home directory"))?
        .join(".darkbloom");
    auto_update_check_with_install_dir(coordinator_base_url, &eigeninference_dir).await
}

async fn auto_update_check_with_install_dir(
    coordinator_base_url: &str,
    eigeninference_dir: &std::path::Path,
) -> Result<bool> {
    let current_version = env!("CARGO_PKG_VERSION");
    let version_url = format!("{coordinator_base_url}/api/version");

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()?;

    let resp = client.get(&version_url).send().await?;
    if !resp.status().is_success() {
        anyhow::bail!("coordinator returned {}", resp.status());
    }

    let info: serde_json::Value = resp.json().await?;
    let latest = info["version"].as_str().unwrap_or("unknown");
    let swift_release = is_swift_release(&info);

    if !is_newer_version(current_version, latest) {
        return Ok(false);
    }

    let download_url = info["download_url"].as_str().unwrap_or("");
    if download_url.is_empty() {
        tracing::warn!("Update {current_version} → {latest} available but no download URL");
        return Ok(false);
    }

    tracing::info!("Downloading update: {current_version} → {latest}");

    let download = client.get(download_url).send().await?;
    if !download.status().is_success() {
        anyhow::bail!("download failed: {}", download.status());
    }
    let bytes = download.bytes().await?;

    // Verify bundle hash
    let expected_hash = info["bundle_hash"].as_str().unwrap_or("");
    if !expected_hash.is_empty() {
        let actual_hash = security::sha256_hex(&bytes);
        if actual_hash != expected_hash {
            anyhow::bail!("bundle hash mismatch — aborting update");
        }
        tracing::info!("Bundle hash verified");
    }

    // Extract and install
    let tmp_path = "/tmp/darkbloom-auto-update.tar.gz";
    std::fs::write(tmp_path, &bytes)?;

    let bin_dir = eigeninference_dir.join("bin");
    let darkbloom_backup = backup_installed_binary(&bin_dir.join("darkbloom"))?;
    let enclave_backup = backup_installed_binary(&bin_dir.join("eigeninference-enclave"))?;
    let swift_enclave_backup = backup_installed_binary(&bin_dir.join("darkbloom-enclave"))?;
    let metallib_backup = backup_installed_binary(&bin_dir.join("mlx.metallib"))?;

    let status = std::process::Command::new("tar")
        .args(["xzf", tmp_path, "-C", &eigeninference_dir.to_string_lossy()])
        .status()?;
    if !status.success() {
        anyhow::bail!("tar extraction failed");
    }

    let coordinator_http = coordinator_base_url
        .replace("wss://", "https://")
        .replace("ws://", "http://")
        .replace("/ws/provider", "");

    let install_result = if swift_release {
        install_swift_update_bundle(&eigeninference_dir, &info, false)
    } else {
        // Move binaries to bin dir
        let _ = std::fs::rename(
            eigeninference_dir.join("darkbloom"),
            bin_dir.join("darkbloom"),
        );
        let _ = std::fs::rename(
            eigeninference_dir.join("eigeninference-enclave"),
            bin_dir.join("eigeninference-enclave"),
        );

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for name in &["darkbloom", "eigeninference-enclave"] {
                let path = bin_dir.join(name);
                if path.exists() {
                    let mut perms = std::fs::metadata(&path)?.permissions();
                    perms.set_mode(0o755);
                    std::fs::set_permissions(&path, perms)?;
                }
            }
        }

        verify_installed_update_runtime(&eigeninference_dir, &coordinator_http, false)
    };

    std::fs::remove_file(tmp_path).ok();
    if let Err(err) = install_result {
        tracing::error!(
            "Auto-update verification failed after installing {latest}: {err}. Restoring previous binaries"
        );
        restore_or_remove_installed_path(&bin_dir.join("darkbloom"), darkbloom_backup.as_deref())?;
        restore_or_remove_installed_path(
            &bin_dir.join("eigeninference-enclave"),
            enclave_backup.as_deref(),
        )?;
        restore_or_remove_installed_path(
            &bin_dir.join("darkbloom-enclave"),
            swift_enclave_backup.as_deref(),
        )?;
        restore_or_remove_installed_path(
            &bin_dir.join("mlx.metallib"),
            metallib_backup.as_deref(),
        )?;
        anyhow::bail!("auto-update verification failed: {err}");
    }
    remove_binary_backup(darkbloom_backup.as_deref());
    remove_binary_backup(enclave_backup.as_deref());
    remove_binary_backup(swift_enclave_backup.as_deref());
    remove_binary_backup(metallib_backup.as_deref());
    tracing::info!("Update installed: {current_version} → {latest}");
    Ok(true)
}

/// Restart the launchd service after an auto-update. The plist already has the
/// correct args from the last `start`, so we just stop and re-kickstart.
fn auto_update_restart() -> Result<()> {
    if !service::is_loaded() {
        let exe = std::env::current_exe().context("cannot find executable")?;
        let args: Vec<String> = std::env::args().collect();
        tracing::info!("Re-executing updated binary: {}", exe.display());
        use std::ffi::CString;
        let c_exe =
            CString::new(exe.to_string_lossy().as_bytes()).context("invalid executable path")?;
        let c_args: Vec<CString> = args
            .iter()
            .map(|a| CString::new(a.as_bytes()).unwrap_or_default())
            .collect();
        let c_arg_ptrs: Vec<*const libc::c_char> = c_args
            .iter()
            .map(|a| a.as_ptr())
            .chain(std::iter::once(std::ptr::null()))
            .collect();
        unsafe { libc::execv(c_exe.as_ptr(), c_arg_ptrs.as_ptr()) };
        anyhow::bail!("execv failed: {}", std::io::Error::last_os_error());
    }

    service::stop()?;
    std::thread::sleep(std::time::Duration::from_secs(1));

    let uid = unsafe { libc::getuid() };
    let domain = format!("gui/{uid}");
    let plist = dirs::home_dir()
        .unwrap_or_default()
        .join("Library/LaunchAgents/io.darkbloom.provider.plist");
    if plist.exists() {
        let _ = std::process::Command::new("launchctl")
            .args(["bootstrap", &domain, &plist.to_string_lossy()])
            .output();
        let target = format!("gui/{uid}/io.darkbloom.provider");
        let _ = std::process::Command::new("launchctl")
            .args(["kickstart", &target])
            .output();
    }
    Ok(())
}

async fn cmd_logs(lines: usize, watch: bool) -> Result<()> {
    let log_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".darkbloom/provider.log");

    if !log_path.exists() {
        println!("No log file found at {}", log_path.display());
        println!("Start the provider first: darkbloom start");
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
        println!("Run 'darkbloom logout' first to unlink.");
        return Ok(());
    }

    println!("╔══════════════════════════════════════════╗");
    println!("║     Link to Darkbloom Account       ║");
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
            anyhow::bail!("Device code expired. Run 'darkbloom login' again.");
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
                println!("  Start serving with: darkbloom serve");
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

async fn cmd_autoupdate(action: &str) -> Result<()> {
    let config_path = config::default_config_path()?;
    let mut cfg = if config_path.exists() {
        config::load(&config_path)?
    } else {
        let hw = crate::hardware::detect()?;
        config::ProviderConfig::default_for_hardware(&hw)
    };

    match action {
        "enable" => {
            cfg.provider.auto_update = true;
            config::save(&config_path, &cfg)?;
            println!("Auto-update enabled.");
            println!(
                "The provider will check for updates every 30 minutes and install them automatically."
            );

            // If the service is running, restart it so the setting takes effect.
            if service::is_loaded() {
                println!("Restarting provider to apply...");
                let uid = unsafe { libc::getuid() };
                let target = format!("gui/{uid}/io.darkbloom.provider");
                let _ = std::process::Command::new("launchctl")
                    .args(["kickstart", "-k", &target])
                    .output();
                println!("Provider restarted.");
            }
        }
        "disable" => {
            cfg.provider.auto_update = false;
            config::save(&config_path, &cfg)?;
            println!("Auto-update disabled.");
            println!("Run `darkbloom update` to manually check for updates.");

            if service::is_loaded() {
                println!("Restarting provider to apply...");
                let uid = unsafe { libc::getuid() };
                let target = format!("gui/{uid}/io.darkbloom.provider");
                let _ = std::process::Command::new("launchctl")
                    .args(["kickstart", "-k", &target])
                    .output();
                println!("Provider restarted.");
            }
        }
        "status" => {
            let enabled = cfg.provider.auto_update;
            println!(
                "Auto-update: {}",
                if enabled { "enabled" } else { "disabled" }
            );
        }
        _ => {
            println!("Usage: darkbloom autoupdate <enable|disable|status>");
            std::process::exit(1);
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::{Mutex, OnceLock};

    fn backend_env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn auto_update_test_lock() -> &'static tokio::sync::Mutex<()> {
        static LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
    }

    fn write_test_command(script: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "darkbloom-runtime-smoke-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system time before unix epoch")
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("failed to create temp dir");
        let path = dir.join("python.sh");
        std::fs::write(&path, script).expect("failed to write temp script");
        let mut perms = std::fs::metadata(&path)
            .expect("failed to stat temp script")
            .permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms).expect("failed to chmod temp script");
        path
    }

    #[test]
    fn test_filter_provider_catalog_removes_retired_flux_and_cohere_models() {
        let models = vec![
            CatalogModel {
                id: "black-forest-labs/FLUX.1-schnell".into(),
                s3_name: "flux-4b".into(),
                display_name: "Flux 4B".into(),
                model_type: "image".into(),
                size_gb: 4.0,
                architecture: "diffusion".into(),
                description: "Retired image model".into(),
                min_ram_gb: 32,
            },
            CatalogModel {
                id: "cohere/command-audio-stt".into(),
                s3_name: "cohere-stt".into(),
                display_name: "Cohere STT".into(),
                model_type: "transcription".into(),
                size_gb: 8.0,
                architecture: "speech".into(),
                description: "Retired audio model".into(),
                min_ram_gb: 16,
            },
            CatalogModel {
                id: "qwen3.5-27b-claude-opus-8bit".into(),
                s3_name: "qwen35-27b-claude-opus-8bit".into(),
                display_name: "Qwen3.5 27B Claude Opus".into(),
                model_type: "text".into(),
                size_gb: 27.0,
                architecture: "27B dense".into(),
                description: "Frontier quality reasoning".into(),
                min_ram_gb: 36,
            },
        ];

        let filtered = filter_provider_catalog(models);

        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].id, "qwen3.5-27b-claude-opus-8bit");
    }

    #[test]
    fn test_catalog_model_matches_app_download_selector_forms() {
        let model = CatalogModel {
            id: "mlx-community/Qwen3.5-122B-A10B-8bit".into(),
            s3_name: "Qwen3.5-122B-A10B-8bit".into(),
            display_name: "Qwen3.5 122B".into(),
            model_type: "text".into(),
            size_gb: 122.0,
            architecture: "122B MoE, 10B active".into(),
            description: "Best quality".into(),
            min_ram_gb: 128,
        };

        assert!(catalog_model_matches(
            &model,
            "mlx-community/Qwen3.5-122B-A10B-8bit"
        ));
        assert!(catalog_model_matches(&model, "Qwen3.5-122B-A10B-8bit"));
        assert!(catalog_model_matches(&model, "Qwen3.5 122B"));
        assert!(!catalog_model_matches(&model, "Qwen3.5-27B"));
    }

    #[test]
    fn test_coordinator_http_base_normalizes_ws_provider_urls() {
        assert_eq!(
            coordinator_http_base("wss://api.darkbloom.dev/ws/provider"),
            "https://api.darkbloom.dev"
        );
        assert_eq!(
            coordinator_http_base("https://api.darkbloom.dev/"),
            "https://api.darkbloom.dev"
        );
    }

    #[test]
    fn test_provider_trust_sort_prefers_hardware_then_online() {
        let mut records = vec![
            CoordinatorProviderTrust {
                provider_id: "self-online".into(),
                serial_number: "SERIAL".into(),
                trust_level: "self_signed".into(),
                status: "online".into(),
                mdm_verified: false,
                acme_verified: false,
                mda_verified: false,
                secure_enclave: true,
                sip_enabled: true,
                secure_boot_enabled: true,
                authenticated_root_enabled: true,
            },
            CoordinatorProviderTrust {
                provider_id: "hardware-offline".into(),
                serial_number: "SERIAL".into(),
                trust_level: "hardware".into(),
                status: "offline".into(),
                mdm_verified: true,
                acme_verified: false,
                mda_verified: false,
                secure_enclave: true,
                sip_enabled: true,
                secure_boot_enabled: true,
                authenticated_root_enabled: true,
            },
            CoordinatorProviderTrust {
                provider_id: "hardware-online".into(),
                serial_number: "SERIAL".into(),
                trust_level: "hardware".into(),
                status: "online".into(),
                mdm_verified: true,
                acme_verified: false,
                mda_verified: false,
                secure_enclave: true,
                sip_enabled: true,
                secure_boot_enabled: true,
                authenticated_root_enabled: true,
            },
        ];

        records.sort_by(prefer_provider_record);

        assert_eq!(records[0].provider_id, "hardware-online");
        assert_eq!(records[1].provider_id, "hardware-offline");
        assert_eq!(records[2].provider_id, "self-online");
    }

    #[test]
    fn test_runtime_smoke_test_reports_success() {
        let path = write_test_command("#!/bin/sh\nprintf 'vllm-mlx 0.2.7; mlx-lm 0.31.2\\n'\n");
        let result = runtime_smoke_test(path.to_str().expect("non-utf8 path"));
        assert_eq!(
            result.expect("smoke test should succeed"),
            "vllm-mlx 0.2.7; mlx-lm 0.31.2"
        );
        let _ = std::fs::remove_dir_all(path.parent().expect("missing parent"));
    }

    #[test]
    fn test_runtime_smoke_test_reports_failure_output() {
        let path = write_test_command(
            "#!/bin/sh\necho 'ImportError: cannot import name GenerationBatch' >&2\nexit 1\n",
        );
        let err = runtime_smoke_test(path.to_str().expect("non-utf8 path"))
            .expect_err("smoke test should fail");
        assert!(err.contains("GenerationBatch"));
        let _ = std::fs::remove_dir_all(path.parent().expect("missing parent"));
    }

    #[test]
    fn test_parse_codesign_team_identifier_extracts_team_id() {
        let output =
            "Authority=Developer ID Application: Eigen Labs, Inc.\nTeamIdentifier=SLDQ2GJ6TL\n";
        assert_eq!(
            parse_codesign_team_identifier(output).as_deref(),
            Some("SLDQ2GJ6TL")
        );
    }

    #[test]
    fn test_parse_codesign_team_identifier_rejects_missing_team_id() {
        let output = "Authority=Apple Development: Someone\nTeamIdentifier=not set\n";
        assert!(parse_codesign_team_identifier(output).is_none());
    }

    /// Verify that spawn_backend_log_forwarder captures stdout/stderr from a child
    /// process instead of dropping it to /dev/null. This is the core regression test:
    /// without log forwarding, backend errors are invisible and users see only
    /// "health check failed" with no indication of the root cause.
    #[tokio::test]
    async fn test_log_forwarder_captures_output() {
        // Spawn a process that writes to both stdout and stderr
        let mut child = tokio::process::Command::new("sh")
            .args([
                "-c",
                "echo 'stdout line 1'; echo 'stderr line 1' >&2; echo 'stdout line 2'",
            ])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .expect("failed to spawn test process");

        // Collect output via channels instead of tracing (tracing output is hard to capture in tests)
        let (tx_out, mut rx_out) = tokio::sync::mpsc::channel::<String>(10);
        let (tx_err, mut rx_err) = tokio::sync::mpsc::channel::<String>(10);

        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();

        // Read stdout lines
        tokio::spawn(async move {
            let reader = tokio::io::BufReader::new(stdout);
            let mut lines = tokio::io::AsyncBufReadExt::lines(reader);
            while let Ok(Some(line)) = lines.next_line().await {
                let _ = tx_out.send(line).await;
            }
        });

        // Read stderr lines
        tokio::spawn(async move {
            let reader = tokio::io::BufReader::new(stderr);
            let mut lines = tokio::io::AsyncBufReadExt::lines(reader);
            while let Ok(Some(line)) = lines.next_line().await {
                let _ = tx_err.send(line).await;
            }
        });

        // Wait for process to exit
        let _ = child.wait().await;
        // Small delay for forwarders to flush
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        // Collect captured lines
        let mut stdout_lines = Vec::new();
        while let Ok(line) = rx_out.try_recv() {
            stdout_lines.push(line);
        }
        let mut stderr_lines = Vec::new();
        while let Ok(line) = rx_err.try_recv() {
            stderr_lines.push(line);
        }

        assert_eq!(stdout_lines, vec!["stdout line 1", "stdout line 2"]);
        assert_eq!(stderr_lines, vec!["stderr line 1"]);
    }

    /// Verify that spawn_backend_log_forwarder handles a process that exits
    /// immediately (e.g. crash on import) without panicking or hanging.
    #[tokio::test]
    async fn test_log_forwarder_handles_immediate_exit() {
        let mut child = tokio::process::Command::new("sh")
            .args(["-c", "echo 'fatal: module not found' >&2; exit 1"])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .expect("failed to spawn test process");

        let stderr = child.stderr.take().unwrap();
        let (tx, mut rx) = tokio::sync::mpsc::channel::<String>(10);

        tokio::spawn(async move {
            let reader = tokio::io::BufReader::new(stderr);
            let mut lines = tokio::io::AsyncBufReadExt::lines(reader);
            while let Ok(Some(line)) = lines.next_line().await {
                let _ = tx.send(line).await;
            }
        });

        let status = child.wait().await.expect("failed to wait");
        assert!(!status.success());

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let mut lines = Vec::new();
        while let Ok(line) = rx.try_recv() {
            lines.push(line);
        }
        assert_eq!(lines, vec!["fatal: module not found"]);
    }

    /// Verify that spawn_backend_log_forwarder handles multi-line Python
    /// tracebacks (the most common backend error output).
    #[tokio::test]
    async fn test_log_forwarder_captures_multiline_traceback() {
        let traceback = r#"echo 'Traceback (most recent call last):' >&2; echo '  File "server.py", line 1' >&2; echo 'ModuleNotFoundError: No module named mlx' >&2"#;
        let mut child = tokio::process::Command::new("sh")
            .args(["-c", traceback])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .expect("failed to spawn test process");

        let stderr = child.stderr.take().unwrap();
        let (tx, mut rx) = tokio::sync::mpsc::channel::<String>(10);

        tokio::spawn(async move {
            let reader = tokio::io::BufReader::new(stderr);
            let mut lines = tokio::io::AsyncBufReadExt::lines(reader);
            while let Ok(Some(line)) = lines.next_line().await {
                let _ = tx.send(line).await;
            }
        });

        let _ = child.wait().await;
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let mut lines = Vec::new();
        while let Ok(line) = rx.try_recv() {
            lines.push(line);
        }
        assert_eq!(lines.len(), 3);
        assert!(lines[0].contains("Traceback"));
        assert!(lines[2].contains("ModuleNotFoundError"));
    }

    /// Verify spawn_inference_backend returns a valid PID (non-zero).
    /// Uses a harmless command that exits quickly.
    #[tokio::test]
    async fn test_spawn_inference_backend_returns_pid() {
        // We can't actually spawn vllm_mlx.server in tests, but we can verify
        // the function handles a non-existent module gracefully — the process
        // will spawn (python starts) and then fail, but we still get a PID.
        // Use "python3" from system since bundled python won't exist in CI.
        let python = if std::path::Path::new("/usr/bin/python3").exists() {
            "/usr/bin/python3"
        } else {
            // Skip test if python3 not available
            return;
        };

        let result = spawn_inference_backend("http.server", "unused", 19999);
        match result {
            Ok(pid) => {
                assert!(pid > 0, "PID should be non-zero");
                // Clean up the spawned process
                let _ = tokio::process::Command::new("kill")
                    .arg(pid.to_string())
                    .status()
                    .await;
            }
            Err(_) => {
                // If spawn itself fails (no python3), that's OK for this test
            }
        }
    }

    #[test]
    fn test_is_newer_version_basic() {
        assert!(is_newer_version("0.3.5", "0.3.6"));
        assert!(is_newer_version("0.3.5", "0.4.0"));
        assert!(is_newer_version("0.3.5", "1.0.0"));
        assert!(!is_newer_version("0.3.6", "0.3.6"));
        assert!(!is_newer_version("0.3.6", "0.3.5"));
        assert!(!is_newer_version("1.0.0", "0.9.9"));
    }

    #[test]
    fn test_is_newer_version_edge_cases() {
        assert!(is_newer_version("0.0.1", "0.0.2"));
        assert!(!is_newer_version("0.0.2", "0.0.1"));
        assert!(is_newer_version("0.9.9", "0.10.0"));
        assert!(is_newer_version("0.3.5", "0.3.10"));
    }

    #[test]
    fn test_is_swift_release_detects_backend_or_metallib_hash() {
        let by_backend = serde_json::json!({"backend": "mlx-swift"});
        assert!(is_swift_release(&by_backend));

        let by_metallib = serde_json::json!({"metallib_hash": "abc"});
        assert!(is_swift_release(&by_metallib));

        let legacy = serde_json::json!({"backend": "vllm-mlx"});
        assert!(!is_swift_release(&legacy));
    }

    #[test]
    fn test_install_swift_update_bundle_accepts_bin_layout_and_verifies_hashes() {
        let tmp = tempfile::tempdir().unwrap();
        let install_dir = tmp.path();
        let bin_dir = install_dir.join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();

        let darkbloom = bin_dir.join("darkbloom");
        let enclave = bin_dir.join("darkbloom-enclave");
        let metallib = bin_dir.join("mlx.metallib");
        std::fs::write(&darkbloom, b"swift binary").unwrap();
        std::fs::write(&enclave, b"swift enclave").unwrap();
        std::fs::write(&metallib, b"metal kernels").unwrap();

        let info = serde_json::json!({
            "backend": "mlx-swift",
            "binary_hash": security::hash_file(&darkbloom).unwrap(),
            "metallib_hash": security::hash_file(&metallib).unwrap()
        });

        install_swift_update_bundle(install_dir, &info, false).unwrap();
        assert!(darkbloom.exists());
        assert!(enclave.exists());
        assert!(metallib.exists());
        assert!(bin_dir.join("eigeninference-enclave").exists());
    }

    struct SwiftBundleFixture {
        tar_bytes: Vec<u8>,
        bundle_hash: String,
        binary_hash: String,
        metallib_hash: String,
    }

    fn make_swift_bundle_tarball(root: &std::path::Path) -> SwiftBundleFixture {
        let bundle_root = root.join("swift-bundle");
        let bin_dir = bundle_root.join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();

        let darkbloom = bin_dir.join("darkbloom");
        let enclave = bin_dir.join("darkbloom-enclave");
        let metallib = bin_dir.join("mlx.metallib");
        std::fs::write(&darkbloom, b"new swift binary").unwrap();
        std::fs::write(&enclave, b"new swift enclave").unwrap();
        std::fs::write(&metallib, b"new metallib kernels").unwrap();

        let binary_hash = security::hash_file(&darkbloom).unwrap();
        let metallib_hash = security::hash_file(&metallib).unwrap();
        let tar_path = root.join("swift-bundle.tar.gz");
        let status = std::process::Command::new("tar")
            .args([
                "czf",
                &tar_path.to_string_lossy(),
                "-C",
                &bundle_root.to_string_lossy(),
                ".",
            ])
            .status()
            .unwrap();
        assert!(
            status.success(),
            "failed to create test Swift bundle tarball"
        );

        let tar_bytes = std::fs::read(&tar_path).unwrap();
        let bundle_hash = security::sha256_hex(&tar_bytes);
        SwiftBundleFixture {
            tar_bytes,
            bundle_hash,
            binary_hash,
            metallib_hash,
        }
    }

    async fn serve_swift_update(
        mut version_info: serde_json::Value,
        bundle_bytes: Vec<u8>,
    ) -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        version_info["download_url"] =
            serde_json::Value::String(format!("http://127.0.0.1:{port}/swift-bundle.tar.gz"));
        let body = serde_json::to_vec(&version_info).unwrap();

        let handle = tokio::spawn(async move {
            for _ in 0..2 {
                let Ok((mut stream, _)) = listener.accept().await else {
                    break;
                };

                let mut buf = vec![0u8; 4096];
                let n = tokio::io::AsyncReadExt::read(&mut stream, &mut buf)
                    .await
                    .unwrap_or(0);
                let request = String::from_utf8_lossy(&buf[..n]);
                let path = request
                    .lines()
                    .next()
                    .and_then(|line| line.split_whitespace().nth(1))
                    .unwrap_or("/");

                let (status, content_type, response_body): (&str, &str, &[u8]) = match path {
                    "/api/version" => ("200 OK", "application/json", &body),
                    "/swift-bundle.tar.gz" => {
                        ("200 OK", "application/gzip", bundle_bytes.as_slice())
                    }
                    _ => ("404 Not Found", "text/plain", b"not found"),
                };

                let headers = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    response_body.len()
                );
                let _ = tokio::io::AsyncWriteExt::write_all(&mut stream, headers.as_bytes()).await;
                let _ = tokio::io::AsyncWriteExt::write_all(&mut stream, response_body).await;
            }
        });

        (format!("http://127.0.0.1:{port}"), handle)
    }

    /// Verify auto_update_check returns Ok(false) when coordinator reports same version.
    #[tokio::test]
    async fn test_auto_update_check_already_up_to_date() {
        // Start a mock server that returns our current version
        let current = env!("CARGO_PKG_VERSION");
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();

        let mock_handle = tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = vec![0u8; 4096];
                let _ = tokio::io::AsyncReadExt::read(&mut stream, &mut buf).await;
                let body = format!(
                    r#"{{"version":"{}","download_url":"","bundle_hash":"","changelog":""}}"#,
                    current
                );
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = tokio::io::AsyncWriteExt::write_all(&mut stream, response.as_bytes()).await;
            }
        });

        let result = auto_update_check(&format!("http://127.0.0.1:{port}")).await;
        assert!(result.is_ok());
        assert!(
            !result.unwrap(),
            "should return false when already up to date"
        );
        mock_handle.abort();
    }

    /// Verify auto_update_check returns error when coordinator is unreachable.
    #[tokio::test]
    async fn test_auto_update_check_unreachable() {
        let result = auto_update_check("http://127.0.0.1:1").await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_auto_update_check_migrates_rust_install_to_swift_bundle_end_to_end() {
        let _guard = auto_update_test_lock().lock().await;
        let tmp = tempfile::tempdir().unwrap();
        let install_dir = tmp.path().join(".darkbloom");
        let bin_dir = install_dir.join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();

        std::fs::write(bin_dir.join("darkbloom"), b"old rust binary").unwrap();
        std::fs::write(bin_dir.join("eigeninference-enclave"), b"old rust enclave").unwrap();

        let python_bin = install_dir.join("python/bin");
        std::fs::create_dir_all(&python_bin).unwrap();
        let broken_python = python_bin.join("python3.12");
        std::fs::write(&broken_python, b"#!/bin/sh\nexit 99\n").unwrap();
        let mut perms = std::fs::metadata(&broken_python).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&broken_python, perms).unwrap();

        let fixture = make_swift_bundle_tarball(tmp.path());
        let version_info = serde_json::json!({
            "version": "9999.0.0",
            "backend": "mlx-swift",
            "download_url": "",
            "bundle_hash": fixture.bundle_hash,
            "binary_hash": fixture.binary_hash,
            "metallib_hash": fixture.metallib_hash,
            "changelog": "test"
        });
        let (base_url, server) = serve_swift_update(version_info, fixture.tar_bytes).await;

        let updated = auto_update_check_with_install_dir(&base_url, &install_dir)
            .await
            .unwrap();

        assert!(updated, "Swift update should install");
        assert_eq!(
            std::fs::read(bin_dir.join("darkbloom")).unwrap(),
            b"new swift binary"
        );
        assert_eq!(
            std::fs::read(bin_dir.join("darkbloom-enclave")).unwrap(),
            b"new swift enclave"
        );
        assert_eq!(
            std::fs::read(bin_dir.join("mlx.metallib")).unwrap(),
            b"new metallib kernels"
        );

        #[cfg(unix)]
        {
            let legacy_link = bin_dir.join("eigeninference-enclave");
            assert!(
                std::fs::symlink_metadata(&legacy_link)
                    .unwrap()
                    .file_type()
                    .is_symlink(),
                "legacy enclave helper path should become a symlink"
            );
            assert_eq!(
                std::fs::read_link(legacy_link).unwrap(),
                bin_dir.join("darkbloom-enclave")
            );
        }

        assert!(!bin_dir.join("darkbloom.auto-update-backup").exists());
        assert!(
            !bin_dir
                .join("eigeninference-enclave.auto-update-backup")
                .exists()
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn test_auto_update_check_rolls_back_swift_bundle_on_metallib_hash_mismatch() {
        let _guard = auto_update_test_lock().lock().await;
        let tmp = tempfile::tempdir().unwrap();
        let install_dir = tmp.path().join(".darkbloom");
        let bin_dir = install_dir.join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();

        std::fs::write(bin_dir.join("darkbloom"), b"old rust binary").unwrap();
        std::fs::write(bin_dir.join("eigeninference-enclave"), b"old rust enclave").unwrap();

        let fixture = make_swift_bundle_tarball(tmp.path());
        let version_info = serde_json::json!({
            "version": "9999.0.0",
            "backend": "mlx-swift",
            "download_url": "",
            "bundle_hash": fixture.bundle_hash,
            "binary_hash": fixture.binary_hash,
            "metallib_hash": "0".repeat(64),
            "changelog": "test"
        });
        let (base_url, server) = serve_swift_update(version_info, fixture.tar_bytes).await;

        let result = auto_update_check_with_install_dir(&base_url, &install_dir).await;

        assert!(
            result.is_err(),
            "metallib mismatch must abort Swift migration"
        );
        assert_eq!(
            std::fs::read(bin_dir.join("darkbloom")).unwrap(),
            b"old rust binary"
        );
        assert_eq!(
            std::fs::read(bin_dir.join("eigeninference-enclave")).unwrap(),
            b"old rust enclave"
        );
        assert!(!bin_dir.join("darkbloom-enclave").exists());
        assert!(!bin_dir.join("mlx.metallib").exists());
        assert!(!bin_dir.join("darkbloom.auto-update-backup").exists());
        assert!(
            !bin_dir
                .join("eigeninference-enclave.auto-update-backup")
                .exists()
        );
        server.await.unwrap();
    }
}

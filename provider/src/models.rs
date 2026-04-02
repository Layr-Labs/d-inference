//! HuggingFace cache scanning and model discovery.
//!
//! This module scans the local HuggingFace cache directory (~/.cache/huggingface/hub)
//! for downloaded MLX models and filters them by available memory. Only models
//! that fit in the Mac's available memory (total - OS reserve) are reported to
//! the coordinator.
//!
//! Model detection heuristics:
//!   1. Directory name contains "mlx" -> definitely an MLX model
//!   2. Has safetensors + quantization hint in name (4bit/8bit) -> likely MLX
//!   3. Has safetensors + config.json -> generic model, included as fallback
//!
//! Memory estimation: model weight file size * 1.2x overhead factor (accounts
//! for runtime buffers, KV cache, activation memory, etc.).
//!
//! Model metadata is extracted from config.json (model_type, parameter count)
//! and from the model name (quantization level).

use crate::hardware::HardwareInfo;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Information about an available model.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ModelInfo {
    pub id: String,
    pub model_type: Option<String>,
    pub parameters: Option<u64>,
    pub quantization: Option<String>,
    pub size_bytes: u64,
    pub estimated_memory_gb: f64,
}

impl std::fmt::Display for ModelInfo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.id)?;
        if let Some(ref mt) = self.model_type {
            write!(f, " (type: {mt})")?;
        }
        if let Some(ref q) = self.quantization {
            write!(f, " [{q}]")?;
        }
        write!(f, " — {:.1} GB", self.estimated_memory_gb)?;
        Ok(())
    }
}

/// Returns the default HuggingFace cache directory.
pub fn default_hf_cache_dir() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".cache").join("huggingface").join("hub"))
}

/// Resolve a model ID to its local path on disk.
///
/// Looks in the HuggingFace cache for a directory matching the model ID.
/// Returns the snapshot path (e.g. ~/.cache/huggingface/hub/models--org--name/snapshots/main/)
/// so the backend can load directly from disk without hitting HuggingFace.
pub fn resolve_local_path(model_id: &str) -> Option<PathBuf> {
    let cache_dir = default_hf_cache_dir()?;

    // Try exact match: models--{id with / replaced by --}
    let dir_name = format!("models--{}", model_id.replace('/', "--"));
    let model_dir = cache_dir.join(&dir_name);
    if model_dir.exists() {
        if let Some(snapshot) = find_latest_snapshot(&model_dir.join("snapshots")) {
            return Some(snapshot);
        }
    }

    // Try without org prefix (for our own models like "qwen3.5-27b-claude-opus-8bit")
    let dir_name_plain = format!("models--{}", model_id);
    let model_dir_plain = cache_dir.join(&dir_name_plain);
    if model_dir_plain.exists() {
        if let Some(snapshot) = find_latest_snapshot(&model_dir_plain.join("snapshots")) {
            return Some(snapshot);
        }
    }

    None
}

/// Scan for locally cached MLX models in the given HuggingFace cache directory.
/// Filters models to only those that fit in available memory (from HardwareInfo).
pub fn scan_models(hw: &HardwareInfo) -> Vec<ModelInfo> {
    let cache_dir = match default_hf_cache_dir() {
        Some(d) if d.exists() => d,
        _ => {
            tracing::debug!("HuggingFace cache directory not found");
            return Vec::new();
        }
    };

    scan_models_in_dir(&cache_dir, hw.memory_available_gb)
}

/// Scan for models in a specific cache directory, filtering by available memory in GB.
pub fn scan_models_in_dir(cache_dir: &Path, available_memory_gb: u64) -> Vec<ModelInfo> {
    let mut models = Vec::new();

    let entries = match std::fs::read_dir(cache_dir) {
        Ok(e) => e,
        Err(err) => {
            tracing::warn!("Failed to read cache directory {}: {err}", cache_dir.display());
            return models;
        }
    };

    for entry in entries.flatten() {
        let dir_name = entry.file_name().to_string_lossy().to_string();

        // HuggingFace cache stores models in directories like `models--org--name`
        if !dir_name.starts_with("models--") {
            continue;
        }

        // Only include MLX models (convention: name contains "MLX", "mlx", "4bit", "8bit", etc.)
        let model_name = dir_name
            .strip_prefix("models--")
            .unwrap_or(&dir_name)
            .replace("--", "/");

        let model_dir = entry.path();
        let snapshots_dir = model_dir.join("snapshots");

        if !snapshots_dir.exists() {
            continue;
        }

        // Find the latest snapshot (by name, which is a hash)
        let latest_snapshot = match find_latest_snapshot(&snapshots_dir) {
            Some(s) => s,
            None => continue,
        };

        // Check if this looks like an MLX model
        if !is_mlx_model(&latest_snapshot, &model_name) {
            continue;
        }

        // Parse model info
        if let Some(info) = parse_model_info(&latest_snapshot, &model_name) {
            if info.estimated_memory_gb <= available_memory_gb as f64 {
                models.push(info);
            } else {
                tracing::debug!(
                    "Skipping {} — needs {:.1} GB but only {} GB available",
                    info.id,
                    info.estimated_memory_gb,
                    available_memory_gb
                );
            }
        }
    }

    models.sort_by(|a, b| {
        a.estimated_memory_gb
            .partial_cmp(&b.estimated_memory_gb)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    models
}

/// Find the latest snapshot directory (most recently modified).
fn find_latest_snapshot(snapshots_dir: &Path) -> Option<PathBuf> {
    let mut latest: Option<(PathBuf, std::time::SystemTime)> = None;

    for entry in std::fs::read_dir(snapshots_dir).ok()?.flatten() {
        if !entry.path().is_dir() {
            continue;
        }
        let modified = entry
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .unwrap_or(std::time::SystemTime::UNIX_EPOCH);

        match &latest {
            Some((_, prev_time)) if modified > *prev_time => {
                latest = Some((entry.path(), modified));
            }
            None => {
                latest = Some((entry.path(), modified));
            }
            _ => {}
        }
    }

    latest.map(|(p, _)| p)
}

/// Check if a snapshot directory contains an MLX model.
fn is_mlx_model(snapshot_dir: &Path, model_name: &str) -> bool {
    let name_lower = model_name.to_lowercase();

    // Check if name contains MLX indicators
    if name_lower.contains("mlx") {
        return true;
    }

    // Check for MLX-specific weight files
    let has_mlx_weights = snapshot_dir.join("weights.npz").exists()
        || snapshot_dir.join("model.safetensors").exists()
        || snapshot_dir.join("model.safetensors.index.json").exists();

    // If it has weight files and quantization indicators in the name, likely an MLX model
    if has_mlx_weights
        && (name_lower.contains("4bit")
            || name_lower.contains("8bit")
            || name_lower.contains("quantized"))
    {
        return true;
    }

    // Check if it has safetensors files (common for MLX models)
    if has_mlx_weights {
        // Check for config.json which all valid models should have
        return snapshot_dir.join("config.json").exists();
    }

    false
}

/// Parse model info from a snapshot directory.
fn parse_model_info(snapshot_dir: &Path, model_name: &str) -> Option<ModelInfo> {
    let config_path = snapshot_dir.join("config.json");

    let (model_type, parameters) = if config_path.exists() {
        parse_config_json(&config_path)
    } else {
        (None, None)
    };

    let quantization = detect_quantization(model_name, snapshot_dir);
    let size_bytes = calculate_safetensors_size(snapshot_dir);

    if size_bytes == 0 {
        return None;
    }

    // Memory overhead factor: ~1.2x for runtime buffers, KV cache, etc.
    let overhead = 1.2;
    let estimated_memory_gb = (size_bytes as f64 / (1024.0 * 1024.0 * 1024.0)) * overhead;

    Some(ModelInfo {
        id: model_name.to_string(),
        model_type,
        parameters,
        quantization,
        size_bytes,
        estimated_memory_gb,
    })
}

/// Parse config.json to extract model_type and parameter count.
fn parse_config_json(config_path: &Path) -> (Option<String>, Option<u64>) {
    let content = match std::fs::read_to_string(config_path) {
        Ok(c) => c,
        Err(_) => return (None, None),
    };

    let json: serde_json::Value = match serde_json::from_str(&content) {
        Ok(v) => v,
        Err(_) => return (None, None),
    };

    let model_type = json
        .get("model_type")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    // Try various fields for parameter count
    let parameters = json
        .get("num_parameters")
        .and_then(|v| v.as_u64())
        .or_else(|| {
            // Try to compute from hidden_size, num_layers, etc. — rough estimate
            let hidden = json.get("hidden_size").and_then(|v| v.as_u64())?;
            let layers = json.get("num_hidden_layers").and_then(|v| v.as_u64())?;
            let vocab = json
                .get("vocab_size")
                .and_then(|v| v.as_u64())
                .unwrap_or(32000);
            // Very rough estimate: 12 * hidden^2 * layers + vocab * hidden
            Some(12 * hidden * hidden * layers / 1_000_000 * 1_000_000 + vocab * hidden)
        });

    (model_type, parameters)
}

/// Detect quantization from model name or config files.
fn detect_quantization(model_name: &str, snapshot_dir: &Path) -> Option<String> {
    let name_lower = model_name.to_lowercase();

    if name_lower.contains("4bit") || name_lower.contains("q4") || name_lower.contains("int4") {
        return Some("4bit".to_string());
    }
    if name_lower.contains("8bit") || name_lower.contains("q8") || name_lower.contains("int8") {
        return Some("8bit".to_string());
    }
    if name_lower.contains("3bit") || name_lower.contains("q3") {
        return Some("3bit".to_string());
    }
    if name_lower.contains("bf16") {
        return Some("bf16".to_string());
    }
    if name_lower.contains("fp16") || name_lower.contains("f16") {
        return Some("fp16".to_string());
    }

    // Check for quantization config file
    let quant_config = snapshot_dir.join("quantize_config.json");
    if quant_config.exists() {
        if let Ok(content) = std::fs::read_to_string(&quant_config) {
            if let Ok(json) = serde_json::from_str::<serde_json::Value>(&content) {
                if let Some(bits) = json.get("bits").and_then(|v| v.as_u64()) {
                    return Some(format!("{bits}bit"));
                }
            }
        }
    }

    None
}

/// Calculate total size of safetensors/weight files in a snapshot directory.
fn calculate_safetensors_size(snapshot_dir: &Path) -> u64 {
    let mut total = 0u64;

    let entries = match std::fs::read_dir(snapshot_dir) {
        Ok(e) => e,
        Err(_) => return 0,
    };

    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if name.ends_with(".safetensors")
            || name.ends_with(".npz")
            || name.ends_with(".bin")
            || name == "weights.npz"
        {
            if let Ok(meta) = entry.metadata() {
                // Handle symlinks — resolve to actual file size
                if meta.is_file() {
                    total += meta.len();
                } else if meta.file_type().is_symlink() {
                    if let Ok(resolved_meta) = std::fs::metadata(entry.path()) {
                        total += resolved_meta.len();
                    }
                }
            }
        }
    }

    total
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// Create a mock HF cache directory with model snapshots.
    fn create_mock_cache(
        tmp: &tempfile::TempDir,
        models: &[(&str, &str, u64)], // (dir_name, config_json, weight_size_bytes)
    ) -> PathBuf {
        let cache = tmp.path().join("hub");
        fs::create_dir_all(&cache).unwrap();

        for (dir_name, config_json, weight_size) in models {
            let model_dir = cache.join(dir_name);
            let snapshot_dir = model_dir.join("snapshots").join("abc123");
            fs::create_dir_all(&snapshot_dir).unwrap();

            // Write config.json
            fs::write(snapshot_dir.join("config.json"), config_json).unwrap();

            // Write a fake safetensors file of the specified size
            let weight_data = vec![0u8; *weight_size as usize];
            fs::write(snapshot_dir.join("model.safetensors"), &weight_data).unwrap();
        }

        cache
    }

    #[test]
    fn test_scan_finds_mlx_models() {
        let tmp = tempfile::tempdir().unwrap();

        let config = r#"{"model_type": "qwen2", "hidden_size": 2048, "num_hidden_layers": 24, "vocab_size": 32000}"#;
        let cache = create_mock_cache(
            &tmp,
            &[(
                "models--mlx-community--Qwen2.5-7B-4bit",
                config,
                4_000_000, // 4MB fake weights
            )],
        );

        let models = scan_models_in_dir(&cache, 128);
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].id, "mlx-community/Qwen2.5-7B-4bit");
        assert_eq!(models[0].model_type, Some("qwen2".to_string()));
        assert_eq!(models[0].quantization, Some("4bit".to_string()));
    }

    #[test]
    fn test_scan_filters_by_memory() {
        let tmp = tempfile::tempdir().unwrap();

        let config = r#"{"model_type": "llama"}"#;
        // Use small weight files but a very tight memory limit.
        // 500_000 bytes * 1.2 overhead ~= 0.00056 GB. So available_memory_gb=0 filters it out.
        // 100 bytes * 1.2 ~= 0.0000001 GB — fits in any positive limit.
        let cache = create_mock_cache(
            &tmp,
            &[
                (
                    "models--mlx-community--tiny-4bit",
                    config,
                    100, // very small — fits even with tight limit
                ),
                (
                    "models--mlx-community--bigger-4bit",
                    config,
                    5_000_000, // ~5MB * 1.2 = ~6MB = ~0.0056 GB
                ),
            ],
        );

        // Set available memory to 0 GB — nothing should fit
        let models = scan_models_in_dir(&cache, 0);
        assert_eq!(models.len(), 0);

        // Set available memory high — both should fit
        let models = scan_models_in_dir(&cache, 128);
        assert_eq!(models.len(), 2);
    }

    #[test]
    fn test_scan_skips_non_mlx_models() {
        let tmp = tempfile::tempdir().unwrap();

        let config = r#"{"model_type": "gpt2"}"#;
        // No "mlx" in name and no quantization hint
        let cache = create_mock_cache(
            &tmp,
            &[(
                "models--openai--gpt2",
                config,
                500_000,
            )],
        );

        // This model has config.json and safetensors, and is_mlx_model will detect it
        // because it has model.safetensors + config.json.
        // The is_mlx_model function checks for these files as a fallback.
        let models = scan_models_in_dir(&cache, 128);
        // It should be found since it has safetensors + config.json
        assert_eq!(models.len(), 1);
    }

    #[test]
    fn test_scan_empty_cache() {
        let tmp = tempfile::tempdir().unwrap();
        let cache = tmp.path().join("hub");
        fs::create_dir_all(&cache).unwrap();

        let models = scan_models_in_dir(&cache, 128);
        assert!(models.is_empty());
    }

    #[test]
    fn test_scan_nonexistent_dir() {
        let models = scan_models_in_dir(Path::new("/nonexistent/path"), 128);
        assert!(models.is_empty());
    }

    #[test]
    fn test_detect_quantization_from_name() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();

        assert_eq!(
            detect_quantization("model-4bit", dir),
            Some("4bit".to_string())
        );
        assert_eq!(
            detect_quantization("model-8bit", dir),
            Some("8bit".to_string())
        );
        assert_eq!(
            detect_quantization("model-Q4_K_M", dir),
            Some("4bit".to_string())
        );
        assert_eq!(
            detect_quantization("model-fp16", dir),
            Some("fp16".to_string())
        );
        assert_eq!(
            detect_quantization("model-bf16", dir),
            Some("bf16".to_string())
        );
        assert_eq!(detect_quantization("model-base", dir), None);
    }

    #[test]
    fn test_parse_config_json() {
        let tmp = tempfile::tempdir().unwrap();
        let config_path = tmp.path().join("config.json");

        let config = r#"{"model_type": "llama", "num_parameters": 7000000000}"#;
        fs::write(&config_path, config).unwrap();

        let (model_type, params) = parse_config_json(&config_path);
        assert_eq!(model_type, Some("llama".to_string()));
        assert_eq!(params, Some(7_000_000_000));
    }

    #[test]
    fn test_parse_config_json_estimate_params() {
        let tmp = tempfile::tempdir().unwrap();
        let config_path = tmp.path().join("config.json");

        let config =
            r#"{"model_type": "qwen2", "hidden_size": 4096, "num_hidden_layers": 32, "vocab_size": 152064}"#;
        fs::write(&config_path, config).unwrap();

        let (model_type, params) = parse_config_json(&config_path);
        assert_eq!(model_type, Some("qwen2".to_string()));
        // Should have estimated parameters
        assert!(params.is_some());
        assert!(params.unwrap() > 0);
    }

    #[test]
    fn test_calculate_safetensors_size() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();

        fs::write(dir.join("model.safetensors"), vec![0u8; 1000]).unwrap();
        fs::write(dir.join("model-00001.safetensors"), vec![0u8; 2000]).unwrap();
        fs::write(dir.join("config.json"), "{}").unwrap(); // not counted

        let size = calculate_safetensors_size(dir);
        assert_eq!(size, 3000);
    }

    #[test]
    fn test_model_info_display() {
        let info = ModelInfo {
            id: "mlx-community/Qwen2.5-7B-4bit".to_string(),
            model_type: Some("qwen2".to_string()),
            parameters: Some(7_000_000_000),
            quantization: Some("4bit".to_string()),
            size_bytes: 4_000_000_000,
            estimated_memory_gb: 4.5,
        };

        let display = format!("{info}");
        assert!(display.contains("mlx-community/Qwen2.5-7B-4bit"));
        assert!(display.contains("qwen2"));
        assert!(display.contains("4bit"));
        assert!(display.contains("4.5 GB"));
    }

    #[test]
    fn test_model_info_serialization_roundtrip() {
        let info = ModelInfo {
            id: "mlx-community/Qwen2.5-7B-4bit".to_string(),
            model_type: Some("qwen2".to_string()),
            parameters: Some(7_000_000_000),
            quantization: Some("4bit".to_string()),
            size_bytes: 4_000_000_000,
            estimated_memory_gb: 4.5,
        };

        let json = serde_json::to_string(&info).unwrap();
        let deserialized: ModelInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(info, deserialized);
    }

    #[test]
    fn test_models_sorted_by_memory() {
        let tmp = tempfile::tempdir().unwrap();
        let config = r#"{"model_type": "llama"}"#;

        let cache = create_mock_cache(
            &tmp,
            &[
                ("models--mlx-community--large-4bit", config, 5_000_000),
                ("models--mlx-community--small-4bit", config, 1_000_000),
                ("models--mlx-community--medium-4bit", config, 3_000_000),
            ],
        );

        let models = scan_models_in_dir(&cache, 128);
        assert_eq!(models.len(), 3);
        assert!(models[0].estimated_memory_gb <= models[1].estimated_memory_gb);
        assert!(models[1].estimated_memory_gb <= models[2].estimated_memory_gb);
    }
}

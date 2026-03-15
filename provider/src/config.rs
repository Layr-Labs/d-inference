//! Provider configuration management.
//!
//! Configuration is stored in TOML format at `~/.config/dginf/provider.toml`
//! (or the platform-appropriate config directory). The config includes:
//!   - Provider identity (name, memory reserve)
//!   - Backend settings (type, port, model, continuous batching)
//!   - Coordinator connection settings (URL, heartbeat interval)
//!
//! A default config is generated based on detected hardware when the provider
//! is first initialized (`dginf-provider init`). CLI flags can override
//! config values at runtime.

use crate::hardware::HardwareInfo;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProviderConfig {
    pub provider: ProviderSettings,
    pub backend: BackendSettings,
    pub coordinator: CoordinatorSettings,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProviderSettings {
    pub name: String,
    pub memory_reserve_gb: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BackendSettings {
    pub primary: BackendType,
    pub port: u16,
    pub model: Option<String>,
    pub continuous_batching: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum BackendType {
    VllmMlx,
    MlxLm,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CoordinatorSettings {
    pub url: String,
    pub heartbeat_interval_secs: u64,
}

impl ProviderConfig {
    pub fn default_for_hardware(hw: &HardwareInfo) -> Self {
        let name = format!("dginf-{}", &hw.machine_model.replace(',', "-").to_lowercase());

        Self {
            provider: ProviderSettings {
                name,
                memory_reserve_gb: 4,
            },
            backend: BackendSettings {
                primary: BackendType::VllmMlx,
                port: 8100,
                model: None,
                continuous_batching: true,
            },
            coordinator: CoordinatorSettings {
                url: "ws://localhost:8080/ws/provider".to_string(),
                heartbeat_interval_secs: 30,
            },
        }
    }
}

pub fn default_config_path() -> Result<PathBuf> {
    let config_dir = dirs::config_dir()
        .context("could not determine config directory")?
        .join("dginf");
    Ok(config_dir.join("provider.toml"))
}

pub fn save(path: &Path, config: &ProviderConfig) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create config directory {}", parent.display()))?;
    }

    let toml_str =
        toml::to_string_pretty(config).context("failed to serialize config to TOML")?;
    std::fs::write(path, &toml_str)
        .with_context(|| format!("failed to write config to {}", path.display()))?;

    Ok(())
}

pub fn load(path: &Path) -> Result<ProviderConfig> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read config from {}", path.display()))?;
    let config: ProviderConfig =
        toml::from_str(&content).context("failed to parse config TOML")?;
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hardware::{ChipFamily, ChipTier, CpuCores};

    fn sample_hardware() -> HardwareInfo {
        HardwareInfo {
            machine_model: "Mac16,1".to_string(),
            chip_name: "Apple M4 Max".to_string(),
            chip_family: ChipFamily::M4,
            chip_tier: ChipTier::Max,
            memory_gb: 128,
            memory_available_gb: 124,
            cpu_cores: CpuCores {
                total: 16,
                performance: 12,
                efficiency: 4,
            },
            gpu_cores: 40,
            memory_bandwidth_gbs: 546,
        }
    }

    #[test]
    fn test_default_config_for_hardware() {
        let hw = sample_hardware();
        let config = ProviderConfig::default_for_hardware(&hw);

        assert_eq!(config.provider.name, "dginf-mac16-1");
        assert_eq!(config.backend.primary, BackendType::VllmMlx);
        assert_eq!(config.backend.port, 8100);
        assert!(config.backend.continuous_batching);
    }

    #[test]
    fn test_config_roundtrip_toml() {
        let hw = sample_hardware();
        let config = ProviderConfig::default_for_hardware(&hw);

        let toml_str = toml::to_string_pretty(&config).unwrap();
        let deserialized: ProviderConfig = toml::from_str(&toml_str).unwrap();
        assert_eq!(config, deserialized);
    }

    #[test]
    fn test_config_save_and_load() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("provider.toml");

        let hw = sample_hardware();
        let config = ProviderConfig::default_for_hardware(&hw);

        save(&path, &config).unwrap();
        let loaded = load(&path).unwrap();
        assert_eq!(config, loaded);
    }

    #[test]
    fn test_config_save_creates_parent_dirs() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("deep").join("nested").join("provider.toml");

        let hw = sample_hardware();
        let config = ProviderConfig::default_for_hardware(&hw);

        save(&path, &config).unwrap();
        assert!(path.exists());
    }

    #[test]
    fn test_config_load_missing_file() {
        let result = load(Path::new("/nonexistent/provider.toml"));
        assert!(result.is_err());
    }
}

//! Provider configuration management.
//!
//! Configuration is stored in TOML format at `~/.config/eigeninference/provider.toml`
//! (or the platform-appropriate config directory). The config includes:
//!   - Provider identity (name, memory reserve)
//!   - Backend settings (type, port, model, continuous batching)
//!   - Coordinator connection settings (URL, heartbeat interval)
//!
//! A default config is generated based on detected hardware when the provider
//! is first initialized (`eigeninference-provider init`). CLI flags can override
//! config values at runtime.

use crate::hardware::HardwareInfo;
use crate::scheduling::ScheduleConfig;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProviderConfig {
    pub provider: ProviderSettings,
    pub backend: BackendSettings,
    pub coordinator: CoordinatorSettings,
    #[serde(default)]
    pub schedule: Option<ScheduleConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProviderSettings {
    pub name: String,
    pub memory_reserve_gb: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BackendSettings {
    pub port: u16,
    pub model: Option<String>,
    pub continuous_batching: bool,
    /// Which models to advertise to the network. If empty, all downloaded models
    /// are advertised. If set, only these models are offered (others stay on disk
    /// but are not served).
    #[serde(default)]
    pub enabled_models: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CoordinatorSettings {
    pub url: String,
    pub heartbeat_interval_secs: u64,
}

impl ProviderConfig {
    pub fn default_for_hardware(hw: &HardwareInfo) -> Self {
        let name = format!(
            "eigeninference-{}",
            &hw.machine_model.replace(',', "-").to_lowercase()
        );

        Self {
            provider: ProviderSettings {
                name,
                memory_reserve_gb: 4,
            },
            backend: BackendSettings {
                port: 8100,
                model: None,
                continuous_batching: true,
                enabled_models: Vec::new(),
            },
            coordinator: CoordinatorSettings {
                url: "ws://localhost:8080/ws/provider".to_string(),
                heartbeat_interval_secs: 30,
            },
            schedule: None,
        }
    }
}

pub fn default_config_path() -> Result<PathBuf> {
    let config_dir = dirs::config_dir()
        .context("could not determine config directory")?
        .join("eigeninference");
    Ok(config_dir.join("provider.toml"))
}

pub fn save(path: &Path, config: &ProviderConfig) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create config directory {}", parent.display()))?;
    }

    let toml_str = toml::to_string_pretty(config).context("failed to serialize config to TOML")?;
    std::fs::write(path, &toml_str)
        .with_context(|| format!("failed to write config to {}", path.display()))?;

    Ok(())
}

pub fn load(path: &Path) -> Result<ProviderConfig> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read config from {}", path.display()))?;
    let config: ProviderConfig = toml::from_str(&content).context("failed to parse config TOML")?;
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

        assert_eq!(config.provider.name, "eigeninference-mac16-1");
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

    // -----------------------------------------------------------------------
    // Config defaults for different hardware profiles
    // -----------------------------------------------------------------------

    fn make_hardware(
        model: &str,
        chip: &str,
        family: ChipFamily,
        tier: ChipTier,
        mem: u64,
        gpu: u32,
        bw: u32,
    ) -> HardwareInfo {
        HardwareInfo {
            machine_model: model.to_string(),
            chip_name: chip.to_string(),
            chip_family: family,
            chip_tier: tier,
            memory_gb: mem,
            memory_available_gb: mem - 4,
            cpu_cores: CpuCores {
                total: 12,
                performance: 8,
                efficiency: 4,
            },
            gpu_cores: gpu,
            memory_bandwidth_gbs: bw,
        }
    }

    #[test]
    fn test_config_m4_max_defaults() {
        let hw = make_hardware(
            "Mac16,1",
            "Apple M4 Max",
            ChipFamily::M4,
            ChipTier::Max,
            128,
            40,
            546,
        );
        let config = ProviderConfig::default_for_hardware(&hw);
        assert_eq!(config.provider.name, "eigeninference-mac16-1");
        assert_eq!(config.backend.port, 8100);
        assert_eq!(config.coordinator.heartbeat_interval_secs, 30);
        assert!(config.backend.continuous_batching);
        assert!(config.backend.model.is_none());
        assert!(config.backend.enabled_models.is_empty());
    }

    #[test]
    fn test_config_m3_defaults() {
        let hw = make_hardware(
            "Mac15,3",
            "Apple M3",
            ChipFamily::M3,
            ChipTier::Base,
            24,
            10,
            100,
        );
        let config = ProviderConfig::default_for_hardware(&hw);
        assert_eq!(config.provider.name, "eigeninference-mac15-3");
        assert_eq!(config.backend.port, 8100);
        assert_eq!(config.provider.memory_reserve_gb, 4);
    }

    #[test]
    fn test_config_m2_pro_defaults() {
        let hw = make_hardware(
            "Mac14,10",
            "Apple M2 Pro",
            ChipFamily::M2,
            ChipTier::Pro,
            32,
            19,
            200,
        );
        let config = ProviderConfig::default_for_hardware(&hw);
        assert_eq!(config.provider.name, "eigeninference-mac14-10");
        assert_eq!(config.backend.port, 8100);
        assert_eq!(config.coordinator.url, "ws://localhost:8080/ws/provider");
    }

    #[test]
    fn test_config_toml_roundtrip_with_enabled_models() {
        let hw = sample_hardware();
        let mut config = ProviderConfig::default_for_hardware(&hw);
        config.backend.enabled_models = vec![
            "mlx-community/Qwen2.5-7B-4bit".to_string(),
            "mlx-community/Llama-3-8B-4bit".to_string(),
        ];
        config.backend.model = Some("mlx-community/Qwen2.5-7B-4bit".to_string());

        let toml_str = toml::to_string_pretty(&config).unwrap();
        let deserialized: ProviderConfig = toml::from_str(&toml_str).unwrap();
        assert_eq!(config, deserialized);
        assert_eq!(deserialized.backend.enabled_models.len(), 2);
    }

    #[test]
    fn test_config_toml_backward_compat_no_enabled_models() {
        // Old configs won't have enabled_models — verify it defaults to empty
        let toml_str = r#"
[provider]
name = "old-provider"
memory_reserve_gb = 4

[backend]
port = 8100
continuous_batching = true

[coordinator]
url = "ws://localhost:8080/ws/provider"
heartbeat_interval_secs = 30
"#;
        let config: ProviderConfig = toml::from_str(toml_str).unwrap();
        assert!(config.backend.enabled_models.is_empty());
        assert!(config.backend.model.is_none());
    }

    #[test]
    fn test_config_all_fields_preserved_through_file_io() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("provider.toml");

        let config = ProviderConfig {
            provider: ProviderSettings {
                name: "test-provider".to_string(),
                memory_reserve_gb: 8,
            },
            backend: BackendSettings {
                port: 9000,
                model: Some("my-model".to_string()),
                continuous_batching: false,
                enabled_models: vec!["m1".to_string(), "m2".to_string()],
            },
            coordinator: CoordinatorSettings {
                url: "wss://example.com/ws/provider".to_string(),
                heartbeat_interval_secs: 15,
            },
            schedule: None,
        };

        save(&path, &config).unwrap();
        let loaded = load(&path).unwrap();
        assert_eq!(config, loaded);
    }
}

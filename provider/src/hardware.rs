//! Apple Silicon hardware detection for the DGInf provider agent.
//!
//! Detects the Mac's hardware capabilities by querying macOS system APIs:
//!   - `sysctl` for memory size, CPU core counts, and machine model
//!   - `system_profiler SPDisplaysDataType` for GPU chip name and core count
//!
//! The chip family (M1/M2/M3/M4) and tier (Base/Pro/Max/Ultra) are parsed
//! from the chip name string. Memory bandwidth is looked up from a table
//! based on chip identity and GPU core count.
//!
//! Bandwidth data sources: Apple technical specifications, AnandTech reviews,
//! and Macworld benchmark results. The M3 Max and M4 Max have two GPU core
//! count variants with different memory bandwidth (different numbers of
//! memory channels).

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fmt;
use std::process::Command;

// ---------------------------------------------------------------------------
// Real-time system metrics (collected every heartbeat)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ThermalState {
    Nominal,
    Fair,
    Serious,
    Critical,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SystemMetrics {
    /// Memory pressure as a fraction (0.0 = no pressure, 1.0 = fully pressured).
    pub memory_pressure: f64,
    /// CPU usage as a fraction (0.0 = idle, 1.0 = fully loaded).
    pub cpu_usage: f64,
    /// macOS thermal state derived from CPU speed limit.
    pub thermal_state: ThermalState,
}

/// Collect live system metrics using macOS APIs (no root required).
pub fn collect_system_metrics(cpu_cores: u32) -> SystemMetrics {
    SystemMetrics {
        memory_pressure: collect_memory_pressure().unwrap_or(0.0),
        cpu_usage: collect_cpu_usage(cpu_cores).unwrap_or(0.0),
        thermal_state: collect_thermal_state().unwrap_or(ThermalState::Nominal),
    }
}

/// Compute memory pressure from `vm_stat` output.
/// Pressure = (active + wired + compressed) / (active + wired + compressed + free).
fn collect_memory_pressure() -> Result<f64> {
    let output = Command::new("vm_stat")
        .output()
        .context("failed to run vm_stat")?;
    if !output.status.success() {
        anyhow::bail!("vm_stat failed");
    }
    let text = String::from_utf8_lossy(&output.stdout);

    let parse_pages = |label: &str| -> u64 {
        for line in text.lines() {
            if line.contains(label) {
                // Format: "Pages active:    123456."
                if let Some(val) = line.split(':').nth(1) {
                    return val.trim().trim_end_matches('.').parse().unwrap_or(0);
                }
            }
        }
        0
    };

    let active = parse_pages("Pages active");
    let wired = parse_pages("Pages wired down");
    let compressed = parse_pages("Pages occupied by compressor");
    let free = parse_pages("Pages free");

    let used = active + wired + compressed;
    let total = used + free;
    if total == 0 {
        return Ok(0.0);
    }

    let pressure = used as f64 / total as f64;
    Ok(pressure.clamp(0.0, 1.0))
}

/// Compute CPU usage from 1-minute load average normalized by core count.
fn collect_cpu_usage(cpu_cores: u32) -> Result<f64> {
    let output = Command::new("sysctl")
        .args(["-n", "vm.loadavg"])
        .output()
        .context("failed to run sysctl vm.loadavg")?;
    if !output.status.success() {
        anyhow::bail!("sysctl vm.loadavg failed");
    }
    // Output format: "{ 1.23 4.56 7.89 }"
    let text = String::from_utf8_lossy(&output.stdout);
    let load_1m: f64 = text
        .trim()
        .trim_start_matches('{')
        .trim_end_matches('}')
        .split_whitespace()
        .next()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0.0);

    let cores = if cpu_cores > 0 { cpu_cores as f64 } else { 1.0 };
    Ok((load_1m / cores).clamp(0.0, 1.0))
}

/// Read thermal state from `pmset -g therm` CPU_Speed_Limit value.
/// 100 = nominal, 80-99 = fair, 50-79 = serious, <50 = critical.
fn collect_thermal_state() -> Result<ThermalState> {
    let output = Command::new("pmset")
        .args(["-g", "therm"])
        .output()
        .context("failed to run pmset -g therm")?;
    if !output.status.success() {
        anyhow::bail!("pmset -g therm failed");
    }
    let text = String::from_utf8_lossy(&output.stdout);

    for line in text.lines() {
        if line.contains("CPU_Speed_Limit") {
            if let Some(val) = line.split('=').nth(1) {
                let limit: u32 = val.trim().parse().unwrap_or(100);
                return Ok(match limit {
                    100 => ThermalState::Nominal,
                    80..=99 => ThermalState::Fair,
                    50..=79 => ThermalState::Serious,
                    _ => ThermalState::Critical,
                });
            }
        }
    }

    // No CPU_Speed_Limit found — assume nominal
    Ok(ThermalState::Nominal)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HardwareInfo {
    pub machine_model: String,
    pub chip_name: String,
    pub chip_family: ChipFamily,
    pub chip_tier: ChipTier,
    pub memory_gb: u64,
    pub memory_available_gb: u64,
    pub cpu_cores: CpuCores,
    pub gpu_cores: u32,
    pub memory_bandwidth_gbs: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CpuCores {
    pub total: u32,
    pub performance: u32,
    pub efficiency: u32,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub enum ChipFamily {
    M1,
    M2,
    M3,
    M4,
    Unknown,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub enum ChipTier {
    Base,
    Pro,
    Max,
    Ultra,
    Unknown,
}

impl fmt::Display for HardwareInfo {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "Hardware Info:")?;
        writeln!(f, "  Machine:    {}", self.machine_model)?;
        writeln!(f, "  Chip:       {}", self.chip_name)?;
        writeln!(
            f,
            "  Family:     {:?} {:?}",
            self.chip_family, self.chip_tier
        )?;
        writeln!(f, "  Memory:     {} GB total", self.memory_gb)?;
        writeln!(
            f,
            "  Available:  {} GB (for inference)",
            self.memory_available_gb
        )?;
        writeln!(
            f,
            "  CPU:        {} cores ({} P + {} E)",
            self.cpu_cores.total, self.cpu_cores.performance, self.cpu_cores.efficiency
        )?;
        writeln!(f, "  GPU:        {} cores", self.gpu_cores)?;
        write!(f, "  Bandwidth:  {} GB/s", self.memory_bandwidth_gbs)
    }
}

const OS_MEMORY_RESERVE_GB: u64 = 4;

pub fn detect() -> Result<HardwareInfo> {
    let machine_model = sysctl_string("hw.model")?;
    let memory_bytes = sysctl_u64("hw.memsize")?;
    let memory_gb = memory_bytes / (1024 * 1024 * 1024);

    let cpu_total = sysctl_u32("hw.ncpu")?;
    let cpu_perf = sysctl_u32_optional("hw.perflevel0.logicalcpu").unwrap_or(cpu_total);
    let cpu_eff = sysctl_u32_optional("hw.perflevel1.logicalcpu").unwrap_or(0);

    let (chip_name, gpu_cores) = detect_gpu_info()?;
    let (chip_family, chip_tier) = parse_chip_identity(&chip_name);
    let memory_bandwidth_gbs = lookup_bandwidth(chip_family, chip_tier, gpu_cores);
    let memory_available_gb = memory_gb.saturating_sub(OS_MEMORY_RESERVE_GB);

    Ok(HardwareInfo {
        machine_model,
        chip_name,
        chip_family,
        chip_tier,
        memory_gb,
        memory_available_gb,
        cpu_cores: CpuCores {
            total: cpu_total,
            performance: cpu_perf,
            efficiency: cpu_eff,
        },
        gpu_cores,
        memory_bandwidth_gbs,
    })
}

/// Get total physical memory in GB. Falls back to 16 GB if detection fails.
pub fn total_memory_gb() -> u64 {
    sysctl_u64("hw.memsize")
        .map(|bytes| bytes / (1024 * 1024 * 1024))
        .unwrap_or(16)
}

fn sysctl_string(key: &str) -> Result<String> {
    let output = Command::new("sysctl")
        .arg("-n")
        .arg(key)
        .output()
        .with_context(|| format!("failed to run sysctl -n {key}"))?;

    if !output.status.success() {
        anyhow::bail!("sysctl -n {key} failed: {}", String::from_utf8_lossy(&output.stderr));
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn sysctl_u64(key: &str) -> Result<u64> {
    let s = sysctl_string(key)?;
    s.parse::<u64>()
        .with_context(|| format!("failed to parse sysctl {key} value '{s}' as u64"))
}

fn sysctl_u32(key: &str) -> Result<u32> {
    let s = sysctl_string(key)?;
    s.parse::<u32>()
        .with_context(|| format!("failed to parse sysctl {key} value '{s}' as u32"))
}

fn sysctl_u32_optional(key: &str) -> Option<u32> {
    sysctl_string(key).ok()?.parse::<u32>().ok()
}

fn detect_gpu_info() -> Result<(String, u32)> {
    let output = Command::new("system_profiler")
        .args(["SPDisplaysDataType", "-json"])
        .output()
        .context("failed to run system_profiler SPDisplaysDataType")?;

    if !output.status.success() {
        anyhow::bail!(
            "system_profiler failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let json: serde_json::Value = serde_json::from_slice(&output.stdout)
        .context("failed to parse system_profiler JSON")?;

    let displays = json
        .get("SPDisplaysDataType")
        .and_then(|v| v.as_array())
        .context("missing SPDisplaysDataType array")?;

    for display in displays {
        let chip_name = display
            .get("sppci_model")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        let gpu_cores = display
            .get("sppci_cores")
            .and_then(|v| v.as_str())
            .and_then(|s| s.parse::<u32>().ok())
            .or_else(|| {
                display
                    .get("sppci_gpu_core_count")
                    .and_then(|v| v.as_str())
                    .and_then(|s| s.parse::<u32>().ok())
            })
            .unwrap_or(0);

        if !chip_name.is_empty() {
            return Ok((chip_name, gpu_cores));
        }
    }

    // Fallback: try sysctl for chip name
    let chip_name = sysctl_string("machdep.cpu.brand_string")
        .unwrap_or_else(|_| "Unknown Apple Silicon".to_string());

    Ok((chip_name, 0))
}

fn parse_chip_identity(chip_name: &str) -> (ChipFamily, ChipTier) {
    let name = chip_name.to_lowercase();

    let family = if name.contains("m4") {
        ChipFamily::M4
    } else if name.contains("m3") {
        ChipFamily::M3
    } else if name.contains("m2") {
        ChipFamily::M2
    } else if name.contains("m1") {
        ChipFamily::M1
    } else {
        ChipFamily::Unknown
    };

    let tier = if name.contains("ultra") {
        ChipTier::Ultra
    } else if name.contains("max") {
        ChipTier::Max
    } else if name.contains("pro") {
        ChipTier::Pro
    } else if family != ChipFamily::Unknown {
        ChipTier::Base
    } else {
        ChipTier::Unknown
    };

    (family, tier)
}

/// Memory bandwidth in GB/s, based on chip and GPU core count.
/// Sources: Apple specs, AnandTech, Macworld benchmarks.
fn lookup_bandwidth(family: ChipFamily, tier: ChipTier, gpu_cores: u32) -> u32 {
    match (family, tier) {
        // M1 family
        (ChipFamily::M1, ChipTier::Base) => 68,
        (ChipFamily::M1, ChipTier::Pro) => 200,
        (ChipFamily::M1, ChipTier::Max) => 400,
        (ChipFamily::M1, ChipTier::Ultra) => 800,

        // M2 family
        (ChipFamily::M2, ChipTier::Base) => 100,
        (ChipFamily::M2, ChipTier::Pro) => 200,
        (ChipFamily::M2, ChipTier::Max) => 400,
        (ChipFamily::M2, ChipTier::Ultra) => 800,

        // M3 family
        (ChipFamily::M3, ChipTier::Base) => 100,
        (ChipFamily::M3, ChipTier::Pro) => 150,
        (ChipFamily::M3, ChipTier::Max) => {
            // M3 Max comes in 30-core and 40-core GPU variants
            if gpu_cores >= 40 {
                400 // 40-core: 16 channels
            } else {
                300 // 30-core: 12 channels
            }
        }
        (ChipFamily::M3, ChipTier::Ultra) => 819,

        // M4 family
        (ChipFamily::M4, ChipTier::Base) => 120,
        (ChipFamily::M4, ChipTier::Pro) => 273,
        (ChipFamily::M4, ChipTier::Max) => {
            if gpu_cores >= 40 {
                546 // 40-core
            } else {
                410 // 32-core
            }
        }
        (ChipFamily::M4, ChipTier::Ultra) => 819, // expected, not released yet

        // Unknown — conservative estimate
        _ => 100,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_chip_identity() {
        let cases = vec![
            ("Apple M1", ChipFamily::M1, ChipTier::Base),
            ("Apple M1 Pro", ChipFamily::M1, ChipTier::Pro),
            ("Apple M1 Max", ChipFamily::M1, ChipTier::Max),
            ("Apple M1 Ultra", ChipFamily::M1, ChipTier::Ultra),
            ("Apple M2", ChipFamily::M2, ChipTier::Base),
            ("Apple M3 Pro", ChipFamily::M3, ChipTier::Pro),
            ("Apple M3 Max", ChipFamily::M3, ChipTier::Max),
            ("Apple M3 Ultra", ChipFamily::M3, ChipTier::Ultra),
            ("Apple M4", ChipFamily::M4, ChipTier::Base),
            ("Apple M4 Pro", ChipFamily::M4, ChipTier::Pro),
            ("Apple M4 Max", ChipFamily::M4, ChipTier::Max),
        ];

        for (name, expected_family, expected_tier) in cases {
            let (family, tier) = parse_chip_identity(name);
            assert_eq!(family, expected_family, "family mismatch for '{name}'");
            assert_eq!(tier, expected_tier, "tier mismatch for '{name}'");
        }
    }

    #[test]
    fn test_parse_unknown_chip() {
        let (family, tier) = parse_chip_identity("Intel Core i9");
        assert_eq!(family, ChipFamily::Unknown);
        assert_eq!(tier, ChipTier::Unknown);
    }

    #[test]
    fn test_bandwidth_lookup_known_chips() {
        assert_eq!(lookup_bandwidth(ChipFamily::M3, ChipTier::Ultra, 80), 819);
        assert_eq!(lookup_bandwidth(ChipFamily::M4, ChipTier::Max, 40), 546);
        assert_eq!(lookup_bandwidth(ChipFamily::M4, ChipTier::Max, 32), 410);
        assert_eq!(lookup_bandwidth(ChipFamily::M1, ChipTier::Base, 8), 68);
        assert_eq!(lookup_bandwidth(ChipFamily::M3, ChipTier::Max, 40), 400);
        assert_eq!(lookup_bandwidth(ChipFamily::M3, ChipTier::Max, 30), 300);
    }

    #[test]
    fn test_bandwidth_lookup_unknown_returns_conservative() {
        assert_eq!(
            lookup_bandwidth(ChipFamily::Unknown, ChipTier::Unknown, 0),
            100
        );
    }

    #[test]
    fn test_hardware_info_display() {
        let hw = HardwareInfo {
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
        };

        let display = format!("{hw}");
        assert!(display.contains("Apple M4 Max"));
        assert!(display.contains("128 GB"));
        assert!(display.contains("40 cores"));
        assert!(display.contains("546 GB/s"));
    }

    #[test]
    fn test_thermal_state_serialization() {
        let cases = vec![
            (ThermalState::Nominal, "\"nominal\""),
            (ThermalState::Fair, "\"fair\""),
            (ThermalState::Serious, "\"serious\""),
            (ThermalState::Critical, "\"critical\""),
        ];
        for (state, expected) in cases {
            let json = serde_json::to_string(&state).unwrap();
            assert_eq!(json, expected, "serialization mismatch for {:?}", state);
            let deserialized: ThermalState = serde_json::from_str(&json).unwrap();
            assert_eq!(deserialized, state, "roundtrip mismatch for {:?}", state);
        }
    }

    #[test]
    fn test_system_metrics_serialization_roundtrip() {
        let metrics = SystemMetrics {
            memory_pressure: 0.75,
            cpu_usage: 0.42,
            thermal_state: ThermalState::Fair,
        };
        let json = serde_json::to_string(&metrics).unwrap();
        assert!(json.contains("\"memory_pressure\":0.75"));
        assert!(json.contains("\"thermal_state\":\"fair\""));
        let deserialized: SystemMetrics = serde_json::from_str(&json).unwrap();
        assert_eq!(metrics, deserialized);
    }

    #[test]
    fn test_collect_system_metrics_runs() {
        // Integration test: verify collection produces values in range.
        let metrics = collect_system_metrics(8);
        assert!(
            (0.0..=1.0).contains(&metrics.memory_pressure),
            "memory_pressure out of range: {}",
            metrics.memory_pressure
        );
        assert!(
            (0.0..=1.0).contains(&metrics.cpu_usage),
            "cpu_usage out of range: {}",
            metrics.cpu_usage
        );
    }

    #[test]
    fn test_hardware_info_serialization_roundtrip() {
        let hw = HardwareInfo {
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
        };

        let json = serde_json::to_string(&hw).unwrap();
        let deserialized: HardwareInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(hw, deserialized);
    }
}

//! Environment-derived Datadog Agent bridge configuration.

use std::sync::Arc;

use thiserror::Error;

use super::tags::valid_value;

const DEFAULT_CAPACITY: usize = 8_192;
const DEFAULT_DOGSTATSD_PORT: u16 = 8_125;
const DEFAULT_TRACE_PORT: u16 = 8_126;

#[derive(Clone, Debug)]
pub(super) struct UnifiedTags {
    pub(super) service: Arc<str>,
    pub(super) environment: Arc<str>,
    pub(super) version: Arc<str>,
    pub(super) commit: Arc<str>,
}

#[derive(Clone, Debug)]
pub(super) struct DatadogConfig {
    pub(super) agent_host: Arc<str>,
    pub(super) dogstatsd_port: u16,
    pub(super) trace_port: u16,
    pub(super) metrics_enabled: bool,
    pub(super) traces_enabled: bool,
    pub(super) capacity: usize,
    pub(super) tags: UnifiedTags,
}

impl DatadogConfig {
    pub(super) fn from_env() -> Result<Self, DatadogConfigError> {
        let agent_host: Arc<str> =
            Arc::from(std::env::var("DD_AGENT_HOST").unwrap_or_else(|_| "127.0.0.1".to_owned()));
        let agent_was_configured = std::env::var_os("DD_AGENT_HOST").is_some();
        let dogstatsd_port = env_port("DD_DOGSTATSD_PORT", DEFAULT_DOGSTATSD_PORT)?;
        let trace_port = env_port("DD_TRACE_AGENT_PORT", DEFAULT_TRACE_PORT)?;
        let capacity = env_capacity()?;
        let tags = UnifiedTags {
            service: normalized_unified_tag(
                "DD_SERVICE",
                std::env::var("DD_SERVICE")
                    .unwrap_or_else(|_| "d-inference-coordinator".to_owned()),
            )?,
            environment: normalized_unified_tag(
                "DD_ENV",
                std::env::var("DD_ENV").unwrap_or_else(|_| "development".to_owned()),
            )?,
            version: normalized_unified_tag(
                "DD_VERSION",
                std::env::var("DD_VERSION").unwrap_or_else(|_| {
                    option_env!("DARKBLOOM_BUILD_VERSION")
                        .unwrap_or("dev")
                        .to_owned()
                }),
            )?,
            commit: normalized_unified_tag(
                "DD_GIT_COMMIT_SHA",
                std::env::var("DD_GIT_COMMIT_SHA")
                    .or_else(|_| std::env::var("DD_GIT_COMMIT"))
                    .unwrap_or_else(|_| {
                        option_env!("DARKBLOOM_BUILD_COMMIT")
                            .unwrap_or("unknown")
                            .to_owned()
                    }),
            )?,
        };
        Ok(Self {
            agent_host,
            dogstatsd_port,
            trace_port,
            metrics_enabled: env_bool("DD_DOGSTATSD_ENABLED", agent_was_configured)?,
            traces_enabled: env_bool("DD_TRACE_ENABLED", agent_was_configured)?,
            capacity,
            tags,
        })
    }
}

fn env_port(name: &'static str, default: u16) -> Result<u16, DatadogConfigError> {
    match std::env::var(name) {
        Ok(value) => value
            .parse::<u16>()
            .ok()
            .filter(|port| *port > 0)
            .ok_or(DatadogConfigError::InvalidPort { name, value }),
        Err(_) => Ok(default),
    }
}

fn env_capacity() -> Result<usize, DatadogConfigError> {
    let Ok(value) = std::env::var("EIGENINFERENCE_RUST_DD_METRICS_CAPACITY") else {
        return Ok(DEFAULT_CAPACITY);
    };
    value
        .parse::<usize>()
        .ok()
        .filter(|capacity| *capacity > 0 && *capacity <= crate::telemetry::MAX_TELEMETRY_CAPACITY)
        .ok_or(DatadogConfigError::InvalidCapacity(value))
}

fn env_bool(name: &'static str, default: bool) -> Result<bool, DatadogConfigError> {
    match std::env::var(name) {
        Ok(value) if value == "true" || value == "1" => Ok(true),
        Ok(value) if value == "false" || value == "0" => Ok(false),
        Ok(value) => Err(DatadogConfigError::InvalidBoolean { name, value }),
        Err(_) => Ok(default),
    }
}

fn normalized_unified_tag(
    name: &'static str,
    value: String,
) -> Result<Arc<str>, DatadogConfigError> {
    if valid_value(&value) {
        Ok(Arc::from(value))
    } else {
        Err(DatadogConfigError::InvalidUnifiedTag { name })
    }
}

#[derive(Debug, Error)]
pub enum DatadogConfigError {
    #[error("{name} must be a nonzero TCP/UDP port, got {value:?}")]
    InvalidPort { name: &'static str, value: String },
    #[error("EIGENINFERENCE_RUST_DD_METRICS_CAPACITY is outside the bounded range: {0:?}")]
    InvalidCapacity(String),
    #[error("{name} must be true, false, 1, or 0, got {value:?}")]
    InvalidBoolean { name: &'static str, value: String },
    #[error("{name} is not a safe low-cardinality Datadog unified tag")]
    InvalidUnifiedTag { name: &'static str },
}

use std::{net::SocketAddr, time::Duration};

use thiserror::Error;

use crate::{
    pilot::{PilotConfig, PilotConfigError},
    surface::{FullSurfaceConfig, FullSurfaceConfigError},
};

const DEFAULT_BIND_ADDRESS: &str = "0.0.0.0:8081";
const DEFAULT_DATABASE_MAX_CONNECTIONS: u32 = 32;
const DEFAULT_DATABASE_ACQUIRE_TIMEOUT: Duration = Duration::from_secs(3);
const DEFAULT_SHUTDOWN_GRACE: Duration = Duration::from_secs(30);

/// Immutable startup configuration for the Rust coordinator.
#[derive(Clone)]
pub struct Config {
    pub bind_address: SocketAddr,
    pub database_url: String,
    pub database_max_connections: u32,
    pub database_acquire_timeout: Duration,
    pub ownership_enabled: bool,
    pub shutdown_grace: Duration,
    pub pilot: PilotConfig,
    pub full_surface: FullSurfaceConfig,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("EIGENINFERENCE_DATABASE_URL is required")]
    MissingDatabaseUrl,
    #[error("invalid EIGENINFERENCE_RUST_BIND_ADDRESS {value:?}: {source}")]
    InvalidBindAddress {
        value: String,
        source: std::net::AddrParseError,
    },
    #[error("invalid EIGENINFERENCE_RUST_DATABASE_MAX_CONNECTIONS {0:?}")]
    InvalidDatabaseMaxConnections(String),
    #[error("invalid EIGENINFERENCE_RUST_SHUTDOWN_GRACE_SECONDS {0:?}")]
    InvalidShutdownGrace(String),
    #[error("the production full surface requires coordinator ownership fencing")]
    FullSurfaceRequiresOwnership,
    #[error(transparent)]
    Pilot(#[from] PilotConfigError),
    #[error(transparent)]
    FullSurface(#[from] FullSurfaceConfigError),
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let mut config = Self::from_values(
            std::env::var("EIGENINFERENCE_RUST_BIND_ADDRESS").ok(),
            std::env::var("EIGENINFERENCE_DATABASE_URL").ok(),
            std::env::var("EIGENINFERENCE_RUST_DATABASE_MAX_CONNECTIONS").ok(),
            std::env::var("EIGENINFERENCE_COORDINATOR_OWNERSHIP_ENABLED").ok(),
            std::env::var("EIGENINFERENCE_RUST_SHUTDOWN_GRACE_SECONDS").ok(),
        )?;
        config.full_surface = FullSurfaceConfig::from_env()?;
        config.pilot = PilotConfig::from_env_mode(config.full_surface.enabled)?;
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> Result<(), ConfigError> {
        if self.full_surface.enabled && !self.ownership_enabled {
            return Err(ConfigError::FullSurfaceRequiresOwnership);
        }
        Ok(())
    }

    fn from_values(
        bind_value: Option<String>,
        database_url: Option<String>,
        max_connections: Option<String>,
        ownership_enabled: Option<String>,
        shutdown_grace_seconds: Option<String>,
    ) -> Result<Self, ConfigError> {
        let bind_value = bind_value.unwrap_or_else(|| DEFAULT_BIND_ADDRESS.to_owned());
        let bind_address =
            bind_value
                .parse()
                .map_err(|source| ConfigError::InvalidBindAddress {
                    value: bind_value,
                    source,
                })?;
        let database_url = database_url.ok_or(ConfigError::MissingDatabaseUrl)?;
        if database_url.trim().is_empty() {
            return Err(ConfigError::MissingDatabaseUrl);
        }
        let database_max_connections = match max_connections {
            Some(value) => {
                let parsed = value
                    .parse::<u32>()
                    .map_err(|_| ConfigError::InvalidDatabaseMaxConnections(value.clone()))?;
                if parsed == 0 {
                    return Err(ConfigError::InvalidDatabaseMaxConnections(value));
                }
                parsed
            }
            None => DEFAULT_DATABASE_MAX_CONNECTIONS,
        };
        let shutdown_grace = match shutdown_grace_seconds {
            Some(value) => {
                let seconds = value
                    .parse::<u64>()
                    .map_err(|_| ConfigError::InvalidShutdownGrace(value.clone()))?;
                if seconds == 0 {
                    return Err(ConfigError::InvalidShutdownGrace(value));
                }
                Duration::from_secs(seconds)
            }
            None => DEFAULT_SHUTDOWN_GRACE,
        };
        Ok(Self {
            bind_address,
            database_url,
            database_max_connections,
            database_acquire_timeout: DEFAULT_DATABASE_ACQUIRE_TIMEOUT,
            ownership_enabled: ownership_enabled.as_deref() == Some("true"),
            shutdown_grace,
            pilot: PilotConfig::disabled(),
            full_surface: FullSurfaceConfig::disabled(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{Config, ConfigError, DEFAULT_BIND_ADDRESS};

    #[test]
    fn default_bind_address_is_separate_from_go() {
        assert_eq!(DEFAULT_BIND_ADDRESS, "0.0.0.0:8081");
    }

    #[test]
    fn missing_database_url_is_a_hard_error() {
        let error = match Config::from_values(None, None, None, None, None) {
            Err(error) => error,
            Ok(_) => panic!("missing database URL was accepted"),
        };
        assert!(matches!(error, ConfigError::MissingDatabaseUrl));
    }

    #[test]
    fn parses_explicit_bounded_values() {
        let config = Config::from_values(
            Some("127.0.0.1:9000".to_owned()),
            Some("postgres://localhost/test".to_owned()),
            Some("7".to_owned()),
            Some("true".to_owned()),
            Some("12".to_owned()),
        )
        .expect("valid config");
        assert_eq!(config.bind_address.to_string(), "127.0.0.1:9000");
        assert_eq!(config.database_max_connections, 7);
        assert!(config.ownership_enabled);
        assert_eq!(config.shutdown_grace.as_secs(), 12);
    }

    #[test]
    fn rejects_zero_resource_bounds() {
        assert!(matches!(
            Config::from_values(
                None,
                Some("postgres://localhost/test".to_owned()),
                Some("0".to_owned()),
                None,
                None,
            ),
            Err(ConfigError::InvalidDatabaseMaxConnections(_))
        ));
        assert!(matches!(
            Config::from_values(
                None,
                Some("postgres://localhost/test".to_owned()),
                None,
                None,
                Some("0".to_owned()),
            ),
            Err(ConfigError::InvalidShutdownGrace(_))
        ));
    }

    #[test]
    fn full_surface_requires_ownership_without_changing_disabled_defaults() {
        let mut config = Config::from_values(
            None,
            Some("postgres://localhost/test".to_owned()),
            None,
            None,
            None,
        )
        .expect("base config");
        assert!(!config.full_surface.enabled);
        assert!(config.validate().is_ok());

        config.full_surface.enabled = true;
        assert!(matches!(
            config.validate(),
            Err(ConfigError::FullSurfaceRequiresOwnership)
        ));
    }
}

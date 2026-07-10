use std::{net::SocketAddr, time::Duration};

use thiserror::Error;

const DEFAULT_BIND_ADDRESS: &str = "0.0.0.0:8081";
const DEFAULT_DATABASE_MAX_CONNECTIONS: u32 = 32;
const DEFAULT_DATABASE_ACQUIRE_TIMEOUT: Duration = Duration::from_secs(3);

/// Immutable startup configuration for the Rust coordinator.
#[derive(Clone)]
pub struct Config {
    pub bind_address: SocketAddr,
    pub database_url: String,
    pub database_max_connections: u32,
    pub database_acquire_timeout: Duration,
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
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let bind_value = std::env::var("EIGENINFERENCE_RUST_BIND_ADDRESS")
            .unwrap_or_else(|_| DEFAULT_BIND_ADDRESS.to_owned());
        let bind_address =
            bind_value
                .parse()
                .map_err(|source| ConfigError::InvalidBindAddress {
                    value: bind_value,
                    source,
                })?;
        let database_url = std::env::var("EIGENINFERENCE_DATABASE_URL")
            .map_err(|_| ConfigError::MissingDatabaseUrl)?;
        if database_url.trim().is_empty() {
            return Err(ConfigError::MissingDatabaseUrl);
        }
        let database_max_connections =
            match std::env::var("EIGENINFERENCE_RUST_DATABASE_MAX_CONNECTIONS") {
                Ok(value) => {
                    let parsed = value
                        .parse::<u32>()
                        .map_err(|_| ConfigError::InvalidDatabaseMaxConnections(value.clone()))?;
                    if parsed == 0 {
                        return Err(ConfigError::InvalidDatabaseMaxConnections(value));
                    }
                    parsed
                }
                Err(_) => DEFAULT_DATABASE_MAX_CONNECTIONS,
            };
        Ok(Self {
            bind_address,
            database_url,
            database_max_connections,
            database_acquire_timeout: DEFAULT_DATABASE_ACQUIRE_TIMEOUT,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{ConfigError, DEFAULT_BIND_ADDRESS};

    #[test]
    fn default_bind_address_is_separate_from_go() {
        assert_eq!(DEFAULT_BIND_ADDRESS, "0.0.0.0:8081");
    }

    #[test]
    fn missing_database_url_is_a_hard_error() {
        assert_eq!(
            ConfigError::MissingDatabaseUrl.to_string(),
            "EIGENINFERENCE_DATABASE_URL is required"
        );
    }
}

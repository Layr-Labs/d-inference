//! Typed startup configuration (plan §27: no live env reads).
//!
//! Every environment variable is read exactly once by [`Config::from_env`] at
//! process startup, validated, and converted into typed fields. Nothing else
//! in the server reads the environment; policy changes ship as versioned
//! snapshots ([`crate::contracts::RequestPolicy`]), not live flag reads.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use secrecy::SecretString;

use crate::contracts::RequestPolicy;

/// Where the coordinator X25519 identity comes from.
#[derive(Clone)]
pub enum CoordinatorSecretSource {
    /// Base64 of the 32-byte X25519 secret key, from
    /// `DARKBLOOM_COORDINATOR_X25519_SECRET_B64`.
    EnvB64(SecretString),
    /// No secret configured: generate an ephemeral keypair at startup with a
    /// loud warning. Dev only — providers will not recognize the key across
    /// restarts.
    Ephemeral,
}

impl std::fmt::Debug for CoordinatorSecretSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::EnvB64(_) => f.write_str("EnvB64(<redacted>)"),
            Self::Ephemeral => f.write_str("Ephemeral"),
        }
    }
}

/// Bounded fleet mailbox capacities (plan §14: separate reliable
/// lifecycle/admission lane and coalesced heartbeat lane).
#[derive(Debug, Clone, Copy)]
pub struct FleetMailboxCaps {
    pub commands: usize,
    pub heartbeats: usize,
}

/// SQLx pool sizing and per-connection statement timeout (plan §14: bounded
/// pool and statement timeout; no unbounded waiter creation).
#[derive(Debug, Clone, Copy)]
pub struct DbConfig {
    pub max_connections: u32,
    pub acquire_timeout: Duration,
    pub statement_timeout: Duration,
}

/// Complete typed startup configuration.
#[derive(Debug, Clone)]
pub struct Config {
    /// Required. The coordinator refuses to start without a database — there
    /// is no memory-store fallback (plan §5.3).
    pub database_url: SecretString,
    pub listen_addr: SocketAddr,
    pub coordinator_secret: CoordinatorSecretSource,
    pub policy: RequestPolicy,
    pub fleet_mailbox: FleetMailboxCaps,
    pub db: DbConfig,
    /// Optional JSON catalog fallback for dev (plan §8; see
    /// [`crate::catalog`]).
    pub catalog_file: Option<PathBuf>,
    /// Legacy account id credited with platform fees (fee allocations fold
    /// into this balance, plan §12.6).
    pub platform_account: String,
    /// Stable holder name recorded in `rust_coord.coordinator_ownership`.
    pub ownership_holder: String,
    /// Emit JSON logs instead of human-readable ones.
    pub log_json: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error(
        "database URL is required: set DARKBLOOM_DATABASE_URL (or EIGENINFERENCE_DATABASE_URL); \
         the Rust coordinator has no memory-store fallback (plan §5.3)"
    )]
    MissingDatabaseUrl,
    #[error("invalid value for {var}: {reason}")]
    Invalid { var: &'static str, reason: String },
}

/// Plan-§16-derived request policy defaults.
///
/// - First-content deadline: conservative 5 s base + 1 ms per estimated
///   prompt token (observed OpenRouter policy is ~10 s + 1 ms/token, plan §3).
/// - Absolute request deadline: 600 s hard (replaces the Go 120 s queue-bound
///   deadline; created at ingress, never reset per attempt).
/// - Prepare hedge budget: < 10% of admissions (plan §11.8); default 5%.
/// - Consumer chunk pipe: 512 items / 384 KiB — multi-second burst absorption
///   (plan §13.6), never a handful of chunks.
pub fn default_policy() -> RequestPolicy {
    RequestPolicy {
        first_content_base: Duration::from_secs(5),
        first_content_per_prompt_token: Duration::from_millis(1),
        request_deadline: Duration::from_secs(600),
        hedge_enabled: true,
        hedge_budget_fraction: 0.05,
        hedge_prepare_timeout: Duration::from_millis(300),
        prepare_deadline: Duration::from_secs(10),
        terminal_wait: Duration::from_secs(10),
        pipe_max_items: 512,
        pipe_max_bytes: 384 * 1024,
        stream_idle_timeout: Duration::from_secs(300),
    }
}

impl Config {
    /// Reads the environment ONCE. Call this a single time from `main`;
    /// nothing else may read env vars (plan §27).
    pub fn from_env() -> Result<Self, ConfigError> {
        let database_url = read_env("DARKBLOOM_DATABASE_URL")
            .or_else(|| read_env("EIGENINFERENCE_DATABASE_URL"))
            .ok_or(ConfigError::MissingDatabaseUrl)?;

        let listen_addr = parse_or(
            "DARKBLOOM_LISTEN_ADDR",
            SocketAddr::from(([127, 0, 0, 1], 8090)),
        )?;

        let coordinator_secret = match read_env("DARKBLOOM_COORDINATOR_X25519_SECRET_B64") {
            Some(b64) => CoordinatorSecretSource::EnvB64(SecretString::from(b64)),
            None => CoordinatorSecretSource::Ephemeral,
        };

        let mut policy = default_policy();
        if let Some(fraction) = parse_opt::<f64>("DARKBLOOM_HEDGE_BUDGET_FRACTION")? {
            if !(0.0..0.10).contains(&fraction) {
                return Err(ConfigError::Invalid {
                    var: "DARKBLOOM_HEDGE_BUDGET_FRACTION",
                    reason: format!("{fraction} outside [0, 0.10) (plan §11.8)"),
                });
            }
            policy.hedge_budget_fraction = fraction;
            policy.hedge_enabled = fraction > 0.0;
        }

        let fleet_mailbox = FleetMailboxCaps {
            commands: parse_or("DARKBLOOM_FLEET_COMMAND_CAP", 1024usize)?,
            heartbeats: parse_or("DARKBLOOM_FLEET_HEARTBEAT_CAP", 1024usize)?,
        };

        let db = DbConfig {
            max_connections: parse_or("DARKBLOOM_DB_MAX_CONNECTIONS", 16u32)?,
            acquire_timeout: Duration::from_millis(parse_or(
                "DARKBLOOM_DB_ACQUIRE_TIMEOUT_MS",
                5_000u64,
            )?),
            statement_timeout: Duration::from_millis(parse_or(
                "DARKBLOOM_DB_STATEMENT_TIMEOUT_MS",
                30_000u64,
            )?),
        };

        let config = Self {
            database_url: SecretString::from(database_url),
            listen_addr,
            coordinator_secret,
            policy,
            fleet_mailbox,
            db,
            catalog_file: read_env("DARKBLOOM_CATALOG_FILE").map(PathBuf::from),
            platform_account: read_env("DARKBLOOM_PLATFORM_ACCOUNT")
                .unwrap_or_else(|| "platform".to_owned()),
            ownership_holder: read_env("DARKBLOOM_OWNERSHIP_HOLDER").unwrap_or_else(default_holder),
            log_json: parse_or("DARKBLOOM_LOG_JSON", false)?,
        };
        config.validate()?;
        Ok(config)
    }

    /// A fully valid config pointing at the given database, for tests.
    pub fn for_tests(database_url: &str) -> Self {
        Self {
            database_url: SecretString::from(database_url.to_owned()),
            listen_addr: SocketAddr::from(([127, 0, 0, 1], 0)),
            coordinator_secret: CoordinatorSecretSource::Ephemeral,
            policy: default_policy(),
            fleet_mailbox: FleetMailboxCaps {
                commands: 64,
                heartbeats: 64,
            },
            db: DbConfig {
                max_connections: 8,
                acquire_timeout: Duration::from_secs(5),
                statement_timeout: Duration::from_secs(30),
            },
            catalog_file: None,
            platform_account: "platform".to_owned(),
            ownership_holder: "test".to_owned(),
            log_json: false,
        }
    }

    fn validate(&self) -> Result<(), ConfigError> {
        if self.db.max_connections == 0 {
            return Err(ConfigError::Invalid {
                var: "DARKBLOOM_DB_MAX_CONNECTIONS",
                reason: "must be > 0".to_owned(),
            });
        }
        if self.fleet_mailbox.commands == 0 || self.fleet_mailbox.heartbeats == 0 {
            return Err(ConfigError::Invalid {
                var: "DARKBLOOM_FLEET_COMMAND_CAP",
                reason: "mailbox capacities must be > 0 (plan §14)".to_owned(),
            });
        }
        if self.policy.pipe_max_items == 0 || self.policy.pipe_max_bytes == 0 {
            return Err(ConfigError::Invalid {
                var: "policy.pipe",
                reason: "chunk pipe must be non-empty (plan §13.6)".to_owned(),
            });
        }
        Ok(())
    }
}

fn default_holder() -> String {
    format!(
        "coordinator-rs@{}",
        std::env::var("HOSTNAME").unwrap_or_else(|_| "unknown-host".to_owned())
    )
}

fn read_env(var: &str) -> Option<String> {
    match std::env::var(var) {
        Ok(v) if !v.trim().is_empty() => Some(v),
        _ => None,
    }
}

fn parse_opt<T: std::str::FromStr>(var: &'static str) -> Result<Option<T>, ConfigError>
where
    T::Err: std::fmt::Display,
{
    match read_env(var) {
        None => Ok(None),
        Some(raw) => raw
            .trim()
            .parse::<T>()
            .map(Some)
            .map_err(|e| ConfigError::Invalid {
                var,
                reason: e.to_string(),
            }),
    }
}

fn parse_or<T: std::str::FromStr>(var: &'static str, default: T) -> Result<T, ConfigError>
where
    T::Err: std::fmt::Display,
{
    Ok(parse_opt(var)?.unwrap_or(default))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_plan_section_16() {
        let p = default_policy();
        assert_eq!(p.first_content_base, Duration::from_secs(5));
        assert_eq!(p.first_content_per_prompt_token, Duration::from_millis(1));
        assert_eq!(p.request_deadline, Duration::from_secs(600));
        assert!(p.hedge_budget_fraction < 0.10);
        assert_eq!(p.prepare_deadline, Duration::from_secs(10));
        assert_eq!(p.pipe_max_items, 512);
        assert_eq!(p.pipe_max_bytes, 384 * 1024);
        assert_eq!(p.stream_idle_timeout, Duration::from_secs(300));
    }

    #[test]
    fn for_tests_is_valid() {
        let c = Config::for_tests("postgres://localhost/x");
        c.validate().expect("test config must validate");
    }
}

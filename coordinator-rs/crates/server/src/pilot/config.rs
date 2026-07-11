use std::{path::PathBuf, sync::Arc, time::Duration};

use darkbloom_coordinator_protocol::v2::ProviderId;
use serde::Deserialize;
use thiserror::Error;
use uuid::Uuid;

use crate::trust::{ConfiguredProviderCredential, TrustFloor, TrustLevel};

pub const INPUT_RESERVATION_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_CONSUMER_BODY_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_CONSUMER_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
pub const RESPONSE_RESERVATION_BYTES: usize = 32 * 1024 * 1024;
pub type ProviderCredentialEntry = (ProviderId, Arc<str>);

const DEFAULT_STATE_DIRECTORY: &str = "/var/lib/darkbloom/rust-pilot";
const DEFAULT_MODEL_ID: &str = "darkbloom/pilot-text";
const DEFAULT_MODEL_ALIAS: &str = "darkbloom-pilot";

#[derive(Deserialize)]
struct ProviderCredentialValue {
    provider_id: String,
    token: String,
}

/// Finite, immutable Objective 5 pilot policy.
#[derive(Clone)]
pub struct PilotConfig {
    pub enabled: bool,
    pub state_directory: PathBuf,
    pub provider_credentials: Arc<[ProviderCredentialEntry]>,
    pub consumer_api_keys: Arc<[Arc<str>]>,
    pub process_key_id: Arc<str>,
    pub process_private_key: Arc<str>,
    pub process_public_key: Arc<str>,
    pub model_id: Arc<str>,
    pub model_alias: Arc<str>,
    pub trust_floor: TrustFloor,
    pub maximum_sessions: usize,
    pub maximum_requests: usize,
    pub session_event_capacity: usize,
    pub request_queue_capacity: usize,
    pub telemetry_capacity: usize,
    pub input_budget_bytes: usize,
    pub response_budget_bytes: usize,
    pub maximum_output_bytes: usize,
    pub maximum_output_chunks: usize,
    pub request_timeout: Duration,
    pub permit_lease_ttl: Duration,
}

impl PilotConfig {
    pub fn disabled() -> Self {
        Self {
            enabled: false,
            state_directory: PathBuf::from(DEFAULT_STATE_DIRECTORY),
            provider_credentials: Arc::from([]),
            consumer_api_keys: Arc::from([]),
            process_key_id: Arc::from("disabled"),
            process_private_key: Arc::from(""),
            process_public_key: Arc::from(""),
            model_id: Arc::from(DEFAULT_MODEL_ID),
            model_alias: Arc::from(DEFAULT_MODEL_ALIAS),
            trust_floor: TrustFloor::SELF_ROUTE,
            maximum_sessions: 1_024,
            maximum_requests: 1_024,
            session_event_capacity: 8_192,
            request_queue_capacity: 1_024,
            telemetry_capacity: 4_096,
            input_budget_bytes: 64 * 1024 * 1024,
            response_budget_bytes: 64 * 1024 * 1024,
            maximum_output_bytes: 4 * 1024 * 1024,
            maximum_output_chunks: 16_384,
            request_timeout: Duration::from_secs(120),
            permit_lease_ttl: Duration::from_secs(5),
        }
    }

    pub fn from_env() -> Result<Self, PilotConfigError> {
        if std::env::var("EIGENINFERENCE_RUST_PILOT_ENABLED").as_deref() != Ok("true") {
            return Ok(Self::disabled());
        }
        let mut config = Self::disabled();
        config.enabled = true;
        config.state_directory = std::env::var("EIGENINFERENCE_RUST_PILOT_STATE_DIRECTORY")
            .map_or_else(|_| PathBuf::from(DEFAULT_STATE_DIRECTORY), PathBuf::from);
        config.provider_credentials =
            parse_provider_credentials(required("EIGENINFERENCE_RUST_PROVIDER_CREDENTIALS_JSON")?)?;
        config.consumer_api_keys =
            parse_consumer_keys(required("EIGENINFERENCE_RUST_CONSUMER_API_KEYS_JSON")?)?;
        config.process_key_id = Arc::from(required("EIGENINFERENCE_RUST_PROCESS_X25519_KEY_ID")?);
        config.process_private_key =
            Arc::from(required("EIGENINFERENCE_RUST_PROCESS_X25519_PRIVATE_KEY")?);
        config.process_public_key =
            Arc::from(required("EIGENINFERENCE_RUST_PROCESS_X25519_PUBLIC_KEY")?);
        config.model_id = Arc::from(
            std::env::var("EIGENINFERENCE_RUST_PILOT_MODEL_ID")
                .unwrap_or_else(|_| DEFAULT_MODEL_ID.to_owned()),
        );
        config.model_alias = Arc::from(
            std::env::var("EIGENINFERENCE_RUST_PILOT_MODEL_ALIAS")
                .unwrap_or_else(|_| DEFAULT_MODEL_ALIAS.to_owned()),
        );
        config.trust_floor = match std::env::var("EIGENINFERENCE_RUST_PILOT_TRUST_FLOOR")
            .as_deref()
            .unwrap_or("self_signed")
        {
            "self_signed" => TrustFloor::SELF_ROUTE,
            "hardware" => TrustFloor::PUBLIC,
            other => return Err(PilotConfigError::InvalidTrustFloor(other.to_owned())),
        };
        validate(&config)?;
        Ok(config)
    }

    pub fn configured_credentials(
        &self,
    ) -> impl Iterator<Item = ConfiguredProviderCredential> + '_ {
        self.provider_credentials
            .iter()
            .map(|(provider_id, token)| {
                ConfiguredProviderCredential::new(*provider_id, token.as_ref())
            })
    }

    pub fn established_trust_level(&self) -> TrustLevel {
        // The pilot currently verifies exact SE evidence locally. Hardware
        // trust still requires the external MDM path and therefore fails
        // closed when configured as the route floor.
        TrustLevel::SelfSigned
    }
}

fn required(name: &'static str) -> Result<String, PilotConfigError> {
    std::env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .ok_or(PilotConfigError::Missing(name))
}

fn parse_provider_credentials(
    encoded: String,
) -> Result<Arc<[ProviderCredentialEntry]>, PilotConfigError> {
    let values: Vec<ProviderCredentialValue> =
        serde_json::from_str(&encoded).map_err(|source| PilotConfigError::InvalidJson {
            name: "EIGENINFERENCE_RUST_PROVIDER_CREDENTIALS_JSON",
            source,
        })?;
    if values.is_empty() || values.len() > 1_024 {
        return Err(PilotConfigError::InvalidProviderCredentials);
    }
    let mut result = Vec::with_capacity(values.len());
    for value in values {
        let uuid = Uuid::parse_str(&value.provider_id)
            .map_err(|_| PilotConfigError::InvalidProviderCredentials)?;
        if uuid.is_nil() || value.token.is_empty() || value.token.len() > 4_096 {
            return Err(PilotConfigError::InvalidProviderCredentials);
        }
        result.push((ProviderId::new(*uuid.as_bytes()), Arc::from(value.token)));
    }
    Ok(result.into())
}

fn parse_consumer_keys(encoded: String) -> Result<Arc<[Arc<str>]>, PilotConfigError> {
    let values: Vec<String> =
        serde_json::from_str(&encoded).map_err(|source| PilotConfigError::InvalidJson {
            name: "EIGENINFERENCE_RUST_CONSUMER_API_KEYS_JSON",
            source,
        })?;
    if values.is_empty()
        || values.len() > 1_024
        || values.iter().any(|key| key.is_empty() || key.len() > 4_096)
    {
        return Err(PilotConfigError::InvalidConsumerKeys);
    }
    Ok(values.into_iter().map(Arc::from).collect::<Vec<_>>().into())
}

fn validate(config: &PilotConfig) -> Result<(), PilotConfigError> {
    let maximum_input_product = config
        .maximum_requests
        .checked_mul(INPUT_RESERVATION_BYTES)
        .ok_or(PilotConfigError::InvalidBounds)?;
    let maximum_response_product = config
        .maximum_requests
        .checked_mul(RESPONSE_RESERVATION_BYTES)
        .ok_or(PilotConfigError::InvalidBounds)?;
    if config.input_budget_bytes < INPUT_RESERVATION_BYTES
        || config.response_budget_bytes < RESPONSE_RESERVATION_BYTES
        || config.input_budget_bytes > maximum_input_product
        || config.response_budget_bytes > maximum_response_product
        || config.maximum_sessions == 0
        || config.maximum_requests == 0
        || config.session_event_capacity == 0
        || config.request_queue_capacity == 0
        || config.telemetry_capacity == 0
        || config.maximum_output_bytes == 0
        || config.maximum_output_bytes > MAX_CONSUMER_RESPONSE_BYTES
        || config.maximum_output_chunks == 0
        || config.request_timeout.is_zero()
        || config.permit_lease_ttl.is_zero()
        || config.permit_lease_ttl >= config.request_timeout
    {
        return Err(PilotConfigError::InvalidBounds);
    }
    if config.maximum_output_bytes > u32::MAX as usize
        || RESPONSE_RESERVATION_BYTES > u32::MAX as usize
    {
        return Err(PilotConfigError::InvalidBounds);
    }
    Ok(())
}

#[derive(Debug, Error)]
pub enum PilotConfigError {
    #[error("missing required pilot environment variable {0}")]
    Missing(&'static str),
    #[error("invalid JSON in {name}: {source}")]
    InvalidJson {
        name: &'static str,
        source: serde_json::Error,
    },
    #[error("provider credentials must be 1..=1024 unique nonempty values")]
    InvalidProviderCredentials,
    #[error("consumer API keys must be 1..=1024 bounded nonempty values")]
    InvalidConsumerKeys,
    #[error("invalid pilot trust floor {0:?}")]
    InvalidTrustFloor(String),
    #[error("invalid pilot resource bounds")]
    InvalidBounds,
}

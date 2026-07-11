use std::{path::PathBuf, sync::Arc, time::Duration};

use darkbloom_coordinator_protocol::v2::ProviderId;
use serde::Deserialize;
use thiserror::Error;
use uuid::Uuid;

use crate::{
    ledger::{
        AccountId, LedgerAmount,
        types::{InputError, Version},
    },
    trust::{ConfiguredProviderCredential, TrustFloor, TrustLevel},
};

pub const INPUT_RESERVATION_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_CONSUMER_BODY_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_CONSUMER_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
pub const RESPONSE_RESERVATION_BYTES: usize = 32 * 1024 * 1024;
pub type ProviderCredentialEntry = (ProviderId, Arc<str>);
type ParsedProviderCredentials = (
    Arc<[ProviderCredentialEntry]>,
    Arc<[ProviderBeneficiaryEntry]>,
);

const DEFAULT_STATE_DIRECTORY: &str = "/var/lib/darkbloom/rust-pilot";
const DEFAULT_MODEL_ID: &str = "darkbloom/pilot-text";
const DEFAULT_MODEL_ALIAS: &str = "darkbloom-pilot";

#[derive(Deserialize)]
struct ProviderCredentialValue {
    provider_id: String,
    token: String,
    #[serde(default)]
    beneficiary_account_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum ConsumerCredentialValue {
    Free(String),
    Paid {
        api_key: String,
        account_id: String,
        api_key_id: String,
    },
}

#[derive(Deserialize)]
struct PaidBillingValue {
    platform_account_id: String,
    #[serde(default)]
    referral_account_id: Option<String>,
    pricing_version: u64,
    rounding_version: u64,
    base_reservation_micro_usd: u64,
    input_micro_usd_per_million: u64,
    output_micro_usd_per_million: u64,
    provider_share_ppm: u32,
    referral_share_ppm: u32,
}

#[derive(Clone)]
pub struct ConsumerCredentialEntry {
    pub raw_key: Arc<str>,
    pub account_id: Option<AccountId>,
    pub api_key_id: Arc<str>,
}

#[derive(Clone)]
pub struct ProviderBeneficiaryEntry {
    pub provider_id: ProviderId,
    pub account_id: AccountId,
}

/// Immutable prices and beneficiary allocation frozen into every paid job.
#[derive(Clone)]
pub struct PaidBillingPolicy {
    pub platform_account_id: AccountId,
    pub referral_account_id: Option<AccountId>,
    pub pricing_version: Version,
    pub rounding_version: Version,
    pub base_reservation: LedgerAmount,
    pub input_micro_usd_per_million: LedgerAmount,
    pub output_micro_usd_per_million: LedgerAmount,
    pub provider_share_ppm: u32,
    pub referral_share_ppm: u32,
}

/// Finite, immutable public/private pilot policy.
#[derive(Clone)]
pub struct PilotConfig {
    pub enabled: bool,
    pub state_directory: PathBuf,
    pub provider_credentials: Arc<[ProviderCredentialEntry]>,
    pub consumer_credentials: Arc<[ConsumerCredentialEntry]>,
    pub provider_beneficiaries: Arc<[ProviderBeneficiaryEntry]>,
    pub paid_billing: Option<PaidBillingPolicy>,
    pub process_key_id: Arc<str>,
    pub process_private_key: Arc<str>,
    pub process_public_key: Arc<str>,
    pub model_id: Arc<str>,
    pub model_alias: Arc<str>,
    pub trust_floor: TrustFloor,
    #[cfg(test)]
    pub test_established_trust: Option<TrustLevel>,
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
            consumer_credentials: Arc::from([]),
            provider_beneficiaries: Arc::from([]),
            paid_billing: None,
            process_key_id: Arc::from("disabled"),
            process_private_key: Arc::from(""),
            process_public_key: Arc::from(""),
            model_id: Arc::from(DEFAULT_MODEL_ID),
            model_alias: Arc::from(DEFAULT_MODEL_ALIAS),
            trust_floor: TrustFloor::SELF_ROUTE,
            #[cfg(test)]
            test_established_trust: None,
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
        let (provider_credentials, provider_beneficiaries) =
            parse_provider_credentials(required("EIGENINFERENCE_RUST_PROVIDER_CREDENTIALS_JSON")?)?;
        config.provider_credentials = provider_credentials;
        config.provider_beneficiaries = provider_beneficiaries;
        config.consumer_credentials =
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
        if config.trust_floor == TrustFloor::PUBLIC {
            config.paid_billing = Some(parse_paid_billing(required(
                "EIGENINFERENCE_RUST_BILLING_JSON",
            )?)?);
        }
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
        #[cfg(test)]
        if let Some(established) = self.test_established_trust {
            return established;
        }
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
) -> Result<ParsedProviderCredentials, PilotConfigError> {
    let values: Vec<ProviderCredentialValue> =
        serde_json::from_str(&encoded).map_err(|source| PilotConfigError::InvalidJson {
            name: "EIGENINFERENCE_RUST_PROVIDER_CREDENTIALS_JSON",
            source,
        })?;
    if values.is_empty() || values.len() > 1_024 {
        return Err(PilotConfigError::InvalidProviderCredentials);
    }
    let mut result = Vec::with_capacity(values.len());
    let mut beneficiaries = Vec::with_capacity(values.len());
    for value in values {
        let uuid = Uuid::parse_str(&value.provider_id)
            .map_err(|_| PilotConfigError::InvalidProviderCredentials)?;
        if uuid.is_nil() || value.token.is_empty() || value.token.len() > 4_096 {
            return Err(PilotConfigError::InvalidProviderCredentials);
        }
        let provider_id = ProviderId::new(*uuid.as_bytes());
        result.push((provider_id, Arc::from(value.token)));
        if let Some(account_id) = value.beneficiary_account_id {
            beneficiaries.push(ProviderBeneficiaryEntry {
                provider_id,
                account_id: AccountId::new(account_id).map_err(PilotConfigError::BillingInput)?,
            });
        }
    }
    Ok((result.into(), beneficiaries.into()))
}

fn parse_consumer_keys(
    encoded: String,
) -> Result<Arc<[ConsumerCredentialEntry]>, PilotConfigError> {
    let values: Vec<ConsumerCredentialValue> =
        serde_json::from_str(&encoded).map_err(|source| PilotConfigError::InvalidJson {
            name: "EIGENINFERENCE_RUST_CONSUMER_API_KEYS_JSON",
            source,
        })?;
    if values.is_empty()
        || values.len() > 1_024
        || values.iter().any(|value| match value {
            ConsumerCredentialValue::Free(key) => key.is_empty() || key.len() > 4_096,
            ConsumerCredentialValue::Paid {
                api_key,
                account_id,
                api_key_id,
            } => {
                api_key.is_empty()
                    || api_key.len() > 4_096
                    || account_id.is_empty()
                    || api_key_id.is_empty()
                    || api_key_id.len() > 256
                    || api_key_id.trim() != api_key_id
                    || api_key_id.chars().any(char::is_control)
            }
        })
    {
        return Err(PilotConfigError::InvalidConsumerKeys);
    }
    values
        .into_iter()
        .map(|value| match value {
            ConsumerCredentialValue::Free(raw_key) => Ok(ConsumerCredentialEntry {
                raw_key: Arc::from(raw_key),
                account_id: None,
                api_key_id: Arc::from("self-route"),
            }),
            ConsumerCredentialValue::Paid {
                api_key,
                account_id,
                api_key_id,
            } => Ok(ConsumerCredentialEntry {
                raw_key: Arc::from(api_key),
                account_id: Some(
                    AccountId::new(account_id).map_err(PilotConfigError::BillingInput)?,
                ),
                api_key_id: Arc::from(api_key_id),
            }),
        })
        .collect::<Result<Vec<_>, _>>()
        .map(Into::into)
}

fn parse_paid_billing(encoded: String) -> Result<PaidBillingPolicy, PilotConfigError> {
    let value: PaidBillingValue =
        serde_json::from_str(&encoded).map_err(|source| PilotConfigError::InvalidJson {
            name: "EIGENINFERENCE_RUST_BILLING_JSON",
            source,
        })?;
    if value.provider_share_ppm > 1_000_000 || value.referral_share_ppm > 1_000_000 {
        return Err(PilotConfigError::InvalidBillingPolicy);
    }
    let referral_account_id = value
        .referral_account_id
        .map(AccountId::new)
        .transpose()
        .map_err(PilotConfigError::BillingInput)?;
    if (referral_account_id.is_some()) != (value.referral_share_ppm > 0) {
        return Err(PilotConfigError::InvalidBillingPolicy);
    }
    let policy = PaidBillingPolicy {
        platform_account_id: AccountId::new(value.platform_account_id)
            .map_err(PilotConfigError::BillingInput)?,
        referral_account_id,
        pricing_version: Version::new(value.pricing_version)
            .map_err(PilotConfigError::BillingInput)?,
        rounding_version: Version::new(value.rounding_version)
            .map_err(PilotConfigError::BillingInput)?,
        base_reservation: LedgerAmount::new(value.base_reservation_micro_usd)
            .map_err(PilotConfigError::BillingInput)?,
        input_micro_usd_per_million: LedgerAmount::new(value.input_micro_usd_per_million)
            .map_err(PilotConfigError::BillingInput)?,
        output_micro_usd_per_million: LedgerAmount::new(value.output_micro_usd_per_million)
            .map_err(PilotConfigError::BillingInput)?,
        provider_share_ppm: value.provider_share_ppm,
        referral_share_ppm: value.referral_share_ppm,
    };
    if policy.base_reservation == LedgerAmount::ZERO {
        return Err(PilotConfigError::InvalidBillingPolicy);
    }
    Ok(policy)
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
    if config.trust_floor == TrustFloor::PUBLIC
        && (config.paid_billing.is_none()
            || config
                .consumer_credentials
                .iter()
                .any(|credential| credential.account_id.is_none())
            || config.provider_beneficiaries.len() != config.provider_credentials.len())
    {
        return Err(PilotConfigError::PaidBillingRequired);
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
    #[error("public pilot mode requires complete consumer/provider billing mappings")]
    PaidBillingRequired,
    #[error("invalid paid billing policy")]
    InvalidBillingPolicy,
    #[error("invalid billing identity or amount: {0}")]
    BillingInput(InputError),
    #[error("invalid pilot trust floor {0:?}")]
    InvalidTrustFloor(String),
    #[error("invalid pilot resource bounds")]
    InvalidBounds,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_pilot_parses_complete_immutable_billing_context() {
        let provider_id = Uuid::new_v4();
        let (providers, beneficiaries) = parse_provider_credentials(format!(
            r#"[{{
                "provider_id":"{provider_id}",
                "token":"provider-secret",
                "beneficiary_account_id":"provider-account"
            }}]"#
        ))
        .expect("provider credentials");
        let consumers = parse_consumer_keys(
            r#"[{
                "api_key":"consumer-secret",
                "account_id":"consumer-account",
                "api_key_id":"api-key-id"
            }]"#
            .to_owned(),
        )
        .expect("consumer credentials");
        let policy = parse_paid_billing(
            r#"{
                "platform_account_id":"platform-account",
                "referral_account_id":"referral-account",
                "pricing_version":7,
                "rounding_version":3,
                "base_reservation_micro_usd":500,
                "input_micro_usd_per_million":123,
                "output_micro_usd_per_million":456,
                "provider_share_ppm":750000,
                "referral_share_ppm":200000
            }"#
            .to_owned(),
        )
        .expect("billing policy");
        let mut config = PilotConfig::disabled();
        config.enabled = true;
        config.trust_floor = TrustFloor::PUBLIC;
        config.provider_credentials = providers;
        config.provider_beneficiaries = beneficiaries;
        config.consumer_credentials = consumers;
        config.paid_billing = Some(policy);

        validate(&config).expect("complete public billing config");
        assert_eq!(
            config.consumer_credentials[0]
                .account_id
                .as_ref()
                .expect("consumer account")
                .as_str(),
            "consumer-account"
        );
        assert_eq!(
            config.provider_beneficiaries[0].account_id.as_str(),
            "provider-account"
        );
        let policy = config.paid_billing.as_ref().expect("paid policy");
        assert_eq!(policy.pricing_version.as_i64(), 7);
        assert_eq!(policy.rounding_version.as_i64(), 3);
        assert_eq!(policy.input_micro_usd_per_million.as_i64(), 123);
        assert_eq!(policy.output_micro_usd_per_million.as_i64(), 456);
    }

    #[test]
    fn public_pilot_rejects_an_explicit_free_credential() {
        let provider_id = Uuid::new_v4();
        let (providers, beneficiaries) = parse_provider_credentials(format!(
            r#"[{{
                "provider_id":"{provider_id}",
                "token":"provider-secret",
                "beneficiary_account_id":"provider-account"
            }}]"#
        ))
        .expect("provider credentials");
        let mut config = PilotConfig::disabled();
        config.enabled = true;
        config.trust_floor = TrustFloor::PUBLIC;
        config.provider_credentials = providers;
        config.provider_beneficiaries = beneficiaries;
        config.consumer_credentials =
            parse_consumer_keys(r#"["free-key"]"#.to_owned()).expect("free credential");
        config.paid_billing = Some(
            parse_paid_billing(
                r#"{
                    "platform_account_id":"platform-account",
                    "pricing_version":1,
                    "rounding_version":1,
                    "base_reservation_micro_usd":1,
                    "input_micro_usd_per_million":1,
                    "output_micro_usd_per_million":1,
                    "provider_share_ppm":1000000,
                    "referral_share_ppm":0
                }"#
                .to_owned(),
            )
            .expect("billing policy"),
        );

        assert!(matches!(
            validate(&config),
            Err(PilotConfigError::PaidBillingRequired)
        ));
    }
}

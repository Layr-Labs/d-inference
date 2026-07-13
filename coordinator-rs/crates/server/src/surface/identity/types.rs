use std::{sync::Arc, time::Duration};

use ipnet::IpNet;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MutationAuthority {
    pub owner_id: Arc<str>,
    pub epoch: i64,
}

impl MutationAuthority {
    pub fn new(owner_id: impl Into<Arc<str>>, epoch: i64) -> Option<Self> {
        let owner_id = owner_id.into();
        (!owner_id.is_empty() && epoch > 0).then_some(Self { owner_id, epoch })
    }
}

#[derive(Clone, Debug)]
pub struct IdentitySurfaceConfig {
    pub operation_timeout: Duration,
    pub console_url: Arc<str>,
    pub latest_provider_version: Arc<str>,
    pub minimum_provider_version: Arc<str>,
    pub heartbeat_timeout: Duration,
    pub challenge_max_age: Duration,
    pub maximum_body_bytes: usize,
    /// Transport peers permitted to supply proxy-appended client addresses.
    pub trusted_proxy_cidrs: Arc<[IpNet]>,
}

impl Default for IdentitySurfaceConfig {
    fn default() -> Self {
        Self {
            operation_timeout: Duration::from_secs(5),
            console_url: Arc::from("https://console.darkbloom.dev"),
            latest_provider_version: Arc::from(""),
            minimum_provider_version: Arc::from(""),
            heartbeat_timeout: Duration::from_secs(90),
            challenge_max_age: Duration::from_secs(6 * 60),
            maximum_body_bytes: 64 * 1024,
            trusted_proxy_cidrs: Arc::from([
                "127.0.0.0/8".parse().expect("static loopback CIDR"),
                "::1/128".parse().expect("static loopback CIDR"),
            ]),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AuthPrincipal {
    Privy { subject: Arc<str> },
    ApiKey { key_id: Arc<str> },
    ProviderToken { label: Arc<str> },
}

#[derive(Clone, Debug, PartialEq)]
pub struct AuthContext {
    pub principal: AuthPrincipal,
    pub account_id: Arc<str>,
    /// One-way credential identity used by durable billing provenance.
    pub credential_hash: Arc<str>,
    pub email: Arc<str>,
    pub role: Arc<str>,
    pub stripe_account_status: Arc<str>,
    pub api_key: Option<ApiKeyRecord>,
}

impl AuthContext {
    #[must_use]
    pub fn is_interactive(&self) -> bool {
        matches!(self.principal, AuthPrincipal::Privy { .. })
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct ApiKeyCreate {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub limit_usd: Option<f64>,
    #[serde(default)]
    pub limit_reset: String,
    #[serde(default)]
    pub rpm_limit: Option<i64>,
    #[serde(default)]
    pub itpm_limit: Option<i64>,
    #[serde(default)]
    pub otpm_limit: Option<i64>,
    #[serde(default)]
    pub allowed_models: Vec<String>,
    #[serde(default)]
    pub self_route_only: bool,
    #[serde(default)]
    pub expires_at: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ApiKeyRecord {
    pub id: String,
    pub owner_account_id: String,
    pub name: String,
    pub label: String,
    pub disabled: bool,
    pub limit_micro_usd: Option<i64>,
    pub limit_reset: String,
    pub usage_micro_usd: i64,
    pub rpm_limit: Option<i64>,
    pub itpm_limit: Option<i64>,
    pub otpm_limit: Option<i64>,
    pub allowed_models: Vec<String>,
    pub self_route_only: bool,
    pub expires_at: Option<String>,
    pub created_at: String,
    pub last_used_at: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ApiKeyResponse {
    pub id: String,
    pub name: String,
    pub label: String,
    pub disabled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit_usd: Option<f64>,
    pub limit_reset: String,
    pub usage_usd: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remaining_usd: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rpm_limit: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub itpm_limit: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub otpm_limit: Option<i64>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub allowed_models: Vec<String>,
    pub self_route_only: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
    pub created_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_used_at: Option<String>,
}

impl From<ApiKeyRecord> for ApiKeyResponse {
    fn from(record: ApiKeyRecord) -> Self {
        let limit_usd = record
            .limit_micro_usd
            .map(|amount| amount as f64 / 1_000_000.0);
        let usage_usd = record.usage_micro_usd as f64 / 1_000_000.0;
        let remaining_usd = record
            .limit_micro_usd
            .map(|limit| limit.saturating_sub(record.usage_micro_usd).max(0) as f64 / 1_000_000.0);
        Self {
            id: record.id,
            name: record.name,
            label: record.label,
            disabled: record.disabled,
            limit_usd,
            limit_reset: record.limit_reset,
            usage_usd,
            remaining_usd,
            rpm_limit: record.rpm_limit,
            itpm_limit: record.itpm_limit,
            otpm_limit: record.otpm_limit,
            allowed_models: record.allowed_models,
            self_route_only: record.self_route_only,
            expires_at: record.expires_at,
            created_at: record.created_at,
            last_used_at: record.last_used_at,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct ApiKeyListResponse {
    pub object: &'static str,
    pub data: Vec<ApiKeyResponse>,
}

#[derive(Debug, Serialize)]
pub struct CreatedApiKeyResponse {
    pub key: String,
    pub data: ApiKeyResponse,
}

#[derive(Debug, Serialize)]
pub struct LegacyCreatedKeyResponse {
    pub api_key: String,
    pub account_id: Arc<str>,
}

#[derive(Debug, Serialize)]
pub struct RevokedResponse {
    pub status: &'static str,
}

#[derive(Clone, Debug, Serialize)]
pub struct ProviderResponse {
    pub id: String,
    pub account_id: String,
    pub status: String,
    pub online: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_heartbeat: Option<String>,
    pub hardware: Value,
    pub models: Value,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub backend: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub version: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub serial_number: String,
    pub trust_level: String,
    pub attested: bool,
    pub mda_verified: bool,
    pub acme_verified: bool,
    pub se_key_bound: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub se_public_key: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub provider_key: String,
    pub secure_enclave: bool,
    pub sip_enabled: bool,
    pub secure_boot_enabled: bool,
    pub authenticated_root_enabled: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub system_volume_hash: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub mda_cert_chain_b64: Vec<String>,
    pub runtime_verified: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub python_hash: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub runtime_hash: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_challenge_verified: Option<String>,
    pub failed_challenges: i32,
    pub reputation: ReputationResponse,
    pub lifetime_requests_served: i64,
    pub lifetime_tokens_generated: i64,
    pub pending_requests: i32,
    pub max_concurrency: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub registered_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_seen: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct ReputationResponse {
    pub score: f64,
    pub total_jobs: i32,
    pub successful_jobs: i32,
    pub failed_jobs: i32,
    pub total_uptime_seconds: i64,
    pub avg_response_time_ms: i64,
    pub challenges_passed: i32,
    pub challenges_failed: i32,
}

#[derive(Debug, Serialize)]
pub struct ProvidersResponse {
    pub providers: Vec<ProviderResponse>,
    pub latest_provider_version: Arc<str>,
    pub min_provider_version: Arc<str>,
    pub heartbeat_timeout_seconds: u64,
    pub challenge_max_age_seconds: u64,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct FleetCounts {
    pub total: i64,
    pub online: i64,
    pub serving: i64,
    pub offline: i64,
    pub untrusted: i64,
    pub hardware: i64,
    pub needs_attention: i64,
}

#[derive(Debug, Serialize)]
pub struct SummaryResponse {
    pub account_id: Arc<str>,
    pub available_balance_micro_usd: i64,
    pub withdrawable_balance_micro_usd: i64,
    pub payout_ready: bool,
    pub lifetime_micro_usd: i64,
    pub lifetime_jobs: i64,
    pub last_24h_micro_usd: i64,
    pub last_24h_jobs: i64,
    pub last_7d_micro_usd: i64,
    pub last_7d_jobs: i64,
    pub counts: FleetCounts,
    pub latest_provider_version: Arc<str>,
    pub min_provider_version: Arc<str>,
}

#[derive(Debug, Serialize)]
pub struct SelfRouteModelsResponse {
    pub models: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct DeleteProviderResponse {
    pub deleted: bool,
    pub serial: String,
    pub rows_removed: i64,
}

#[derive(Debug, Serialize)]
pub struct DeviceCodeResponse {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub expires_in: u64,
    pub interval: u64,
}

#[derive(Debug, Serialize)]
#[serde(tag = "status")]
pub enum DeviceTokenResponse {
    #[serde(rename = "authorization_pending")]
    Pending,
    #[serde(rename = "authorized")]
    Authorized { token: String, account_id: String },
}

#[derive(Debug, Serialize)]
pub struct DeviceApprovedResponse {
    pub status: &'static str,
    pub message: &'static str,
}

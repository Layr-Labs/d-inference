//! Privy, API-key, device authorization, and account HTTP surface.
//!
//! The module is intentionally self-contained so the coordinator composition
//! root can construct [`IdentityState`] and merge [`router`] without coupling
//! identity persistence to inference or billing internals.

mod accounts;
mod api_key_support;
mod api_keys;
mod auth;
mod device;
mod error;
mod jwks;
mod rate;
mod routes;
mod store;
mod types;

pub use accounts::AccountService;
pub use api_keys::{ApiKeyPatch, ApiKeyService, hash_secret};
pub use auth::{AuthRequirement, AuthService};
pub use device::{DEVICE_CODE_EXPIRY, DEVICE_CODE_POLL_INTERVAL, DeviceService};
pub use error::IdentityError;
pub use jwks::{PrivyVerifier, PrivyVerifierConfig, PrivyVerifierError, VerifiedPrivyClaims};
pub use rate::{BoundedRateConfig, BoundedRateLimiter, RateClass, RateLimitHook, RateRule};
pub use routes::{IdentityState, IdentityStateBuilder, router};
pub use types::{
    ApiKeyCreate, ApiKeyListResponse, ApiKeyRecord, ApiKeyResponse, AuthContext, AuthPrincipal,
    CreatedApiKeyResponse, DeleteProviderResponse, DeviceApprovedResponse, DeviceCodeResponse,
    DeviceTokenResponse, FleetCounts, IdentitySurfaceConfig, LegacyCreatedKeyResponse,
    MutationAuthority, ProviderResponse, ProvidersResponse, ReputationResponse, RevokedResponse,
    SelfRouteModelsResponse, SummaryResponse,
};

#[cfg(test)]
mod tests;

//! Shared application state (constructed in main, read by HTTP) plus the
//! API-key auth seam.

use std::sync::Arc;

use async_trait::async_trait;

use darkbloom_core::fleet::admission::AdmissionConfig;
use darkbloom_core::ids::{AccountId, ApiKeyId, CoordinatorEpoch};
use darkbloom_core::money::MicroUsd;

use super::fleet::FleetHandle;
use super::ledger::LedgerFacade;
use super::policy::{RequestPolicy, SharedCatalog};

#[derive(Debug, Clone)]
pub struct ApiKeyRecord {
    pub key_id: ApiKeyId,
    pub account: AccountId,
    pub spend_cap: Option<MicroUsd>,
    pub disabled: bool,
}

#[async_trait]
pub trait ApiKeyStore: Send + Sync {
    /// Returns None for unknown/invalid tokens. Implementations cache.
    async fn validate(&self, token: &str) -> Option<ApiKeyRecord>;
}

#[derive(Clone)]
pub struct AppState {
    pub fleet: FleetHandle,
    pub ledger: Arc<dyn LedgerFacade>,
    pub keys: Arc<dyn ApiKeyStore>,
    pub catalog: SharedCatalog,
    pub policy: Arc<RequestPolicy>,
    pub coordinator_epoch: CoordinatorEpoch,
    /// Coordinator X25519 identity for provider-bound encryption.
    pub encryption: Arc<CoordinatorKeys>,
    pub admission_config: Arc<AdmissionConfig>,
}

/// Coordinator key material. Secret bytes zeroized on drop by the crypto
/// layer; only the protocol crate touches raw secrets.
pub struct CoordinatorKeys {
    pub x25519_public_b64: String,
    pub x25519_secret: darkbloom_protocol::crypto::nacl_box::SecretKey,
}

//! Unique configured provider credentials and first-key-wins binding.

use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    path::PathBuf,
    sync::{Arc, Mutex},
};

use darkbloom_coordinator_protocol::v2::ProviderId;
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use thiserror::Error;
use zeroize::Zeroize;

use crate::crypto::{
    DurableFileError, X25519PublicKey,
    epoch_store::{read_json_if_exists, write_json_atomic},
};

const CREDENTIAL_BINDING_VERSION: u32 = 1;
const TOKEN_DIGEST_DOMAIN: &[u8] = b"darkbloom.provider-credential.v1\0";
const MAX_TOKEN_BYTES: usize = 4_096;

/// One startup-configured raw token and stable provider identity.
///
/// `CredentialRegistry::open` consumes and zeroizes the raw token after
/// deriving its domain-separated digest.
pub struct ConfiguredProviderCredential {
    provider_id: ProviderId,
    token: String,
}

impl ConfiguredProviderCredential {
    /// Creates one credential to be consumed by the registry.
    #[must_use]
    pub fn new(provider_id: ProviderId, token: impl Into<String>) -> Self {
        Self {
            provider_id,
            token: token.into(),
        }
    }

    /// Stable configured identity.
    #[must_use]
    pub const fn provider_id(&self) -> ProviderId {
        self.provider_id
    }
}

impl fmt::Debug for ConfiguredProviderCredential {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ConfiguredProviderCredential")
            .field("provider_id", &self.provider_id)
            .field("token", &"[REDACTED]")
            .finish()
    }
}

impl Drop for ConfiguredProviderCredential {
    fn drop(&mut self) {
        self.token.zeroize();
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct BindingFile {
    version: u32,
    bindings: BTreeMap<ProviderId, String>,
}

#[derive(Debug, Default)]
struct CredentialState {
    bindings: BTreeMap<ProviderId, X25519PublicKey>,
    pending: BTreeMap<ProviderId, u64>,
    next_ticket: u64,
}

#[derive(Debug)]
struct CredentialInner {
    path: PathBuf,
    token_identities: BTreeMap<[u8; 32], ProviderId>,
    configured_identities: BTreeSet<ProviderId>,
    state: Mutex<CredentialState>,
}

/// Finite configured credential registry.
#[derive(Clone, Debug)]
pub struct CredentialRegistry {
    inner: Arc<CredentialInner>,
}

impl CredentialRegistry {
    /// Loads persistent first-bound keys and consumes unique configured tokens.
    pub fn open(
        path: impl Into<PathBuf>,
        maximum_credentials: usize,
        credentials: impl IntoIterator<Item = ConfiguredProviderCredential>,
    ) -> Result<Self, CredentialConfigError> {
        if maximum_credentials == 0 {
            return Err(CredentialConfigError::ZeroLimit);
        }
        let mut token_identities = BTreeMap::new();
        let mut configured_identities = BTreeSet::new();
        for mut credential in credentials {
            if token_identities.len() == maximum_credentials {
                return Err(CredentialConfigError::CredentialLimit {
                    maximum: maximum_credentials,
                });
            }
            if credential.token.is_empty() || credential.token.len() > MAX_TOKEN_BYTES {
                return Err(CredentialConfigError::InvalidToken);
            }
            let digest = token_digest(&credential.token);
            credential.token.zeroize();
            if token_identities
                .insert(digest, credential.provider_id)
                .is_some()
            {
                return Err(CredentialConfigError::SharedToken);
            }
            if !configured_identities.insert(credential.provider_id) {
                return Err(CredentialConfigError::DuplicateProviderIdentity(
                    credential.provider_id,
                ));
            }
        }

        let path = path.into();
        let file = read_json_if_exists::<BindingFile>(&path)?.unwrap_or(BindingFile {
            version: CREDENTIAL_BINDING_VERSION,
            bindings: BTreeMap::new(),
        });
        if file.version != CREDENTIAL_BINDING_VERSION {
            return Err(CredentialConfigError::UnsupportedVersion(file.version));
        }
        if file.bindings.len() > maximum_credentials {
            return Err(CredentialConfigError::CredentialLimit {
                maximum: maximum_credentials,
            });
        }
        let mut bindings = BTreeMap::new();
        for (provider_id, encoded) in file.bindings {
            if !configured_identities.contains(&provider_id) {
                return Err(CredentialConfigError::UnknownPersistedProvider(provider_id));
            }
            let key = X25519PublicKey::from_base64(&encoded)
                .map_err(|_| CredentialConfigError::InvalidPersistedKey(provider_id))?;
            bindings.insert(provider_id, key);
        }
        Ok(Self {
            inner: Arc::new(CredentialInner {
                path,
                token_identities,
                configured_identities,
                state: Mutex::new(CredentialState {
                    bindings,
                    pending: BTreeMap::new(),
                    next_ticket: 0,
                }),
            }),
        })
    }

    /// Authenticates a token digest and reserves one pending verification slot.
    pub fn begin(&self, token: &str) -> Result<PendingCredential, CredentialError> {
        if token.is_empty() || token.len() > MAX_TOKEN_BYTES {
            return Err(CredentialError::InvalidToken);
        }
        let provider_id = self
            .inner
            .token_identities
            .get(&token_digest(token))
            .copied()
            .ok_or(CredentialError::InvalidToken)?;
        let mut state = self.lock_state();
        if state.pending.contains_key(&provider_id) {
            return Err(CredentialError::VerificationPending(provider_id));
        }
        state.next_ticket = state
            .next_ticket
            .checked_add(1)
            .ok_or(CredentialError::TicketExhausted)?;
        let ticket = state.next_ticket;
        state.pending.insert(provider_id, ticket);
        drop(state);
        Ok(PendingCredential {
            registry: Arc::clone(&self.inner),
            provider_id,
            ticket,
            completed: false,
        })
    }

    /// Returns the persistent key already bound to a stable provider.
    #[must_use]
    pub fn bound_key(&self, provider_id: ProviderId) -> Option<X25519PublicKey> {
        self.lock_state().bindings.get(&provider_id).copied()
    }

    /// Number of configured token identities.
    #[must_use]
    pub fn len(&self) -> usize {
        self.inner.token_identities.len()
    }

    /// Returns whether no credentials are configured.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.inner.token_identities.is_empty()
    }

    /// Number of currently pending verification guards.
    #[must_use]
    pub fn pending_len(&self) -> usize {
        self.lock_state().pending.len()
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, CredentialState> {
        self.inner
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// Authenticated identity whose attestation/key verification is pending.
pub struct PendingCredential {
    registry: Arc<CredentialInner>,
    provider_id: ProviderId,
    ticket: u64,
    completed: bool,
}

impl PendingCredential {
    /// Stable identity selected only by the configured token digest.
    #[must_use]
    pub const fn provider_id(&self) -> ProviderId {
        self.provider_id
    }

    /// Fsyncs the first verified X25519 key or accepts the exact existing key.
    ///
    /// A later registration using the shared credential cannot rotate identity
    /// to a new key. Every error drops and removes this pending verification.
    pub fn complete(
        mut self,
        verified_x25519_key: X25519PublicKey,
    ) -> Result<ProviderId, CredentialError> {
        let mut state = self.lock_state();
        if state.pending.get(&self.provider_id) != Some(&self.ticket) {
            return Err(CredentialError::PendingStale(self.provider_id));
        }
        if let Some(existing) = state.bindings.get(&self.provider_id) {
            if !existing.ct_eq(&verified_x25519_key) {
                return Err(CredentialError::IdentityRotation(self.provider_id));
            }
        } else {
            let mut candidate = state.bindings.clone();
            candidate.insert(self.provider_id, verified_x25519_key);
            persist_bindings(&self.registry, &candidate)?;
            state.bindings = candidate;
        }
        state.pending.remove(&self.provider_id);
        drop(state);
        self.completed = true;
        Ok(self.provider_id)
    }

    /// Explicitly abandons failed verification and releases the pending slot.
    pub fn fail(mut self) {
        self.remove_if_current();
        self.completed = true;
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, CredentialState> {
        self.registry
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn remove_if_current(&self) {
        let mut state = self.lock_state();
        if state.pending.get(&self.provider_id) == Some(&self.ticket) {
            state.pending.remove(&self.provider_id);
        }
    }
}

impl fmt::Debug for PendingCredential {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PendingCredential")
            .field("provider_id", &self.provider_id)
            .field("ticket", &self.ticket)
            .finish_non_exhaustive()
    }
}

impl Drop for PendingCredential {
    fn drop(&mut self) {
        if !self.completed {
            self.remove_if_current();
        }
    }
}

fn persist_bindings(
    registry: &CredentialInner,
    bindings: &BTreeMap<ProviderId, X25519PublicKey>,
) -> Result<(), CredentialError> {
    debug_assert!(
        bindings
            .keys()
            .all(|provider| registry.configured_identities.contains(provider))
    );
    let file = BindingFile {
        version: CREDENTIAL_BINDING_VERSION,
        bindings: bindings
            .iter()
            .map(|(provider, key)| (*provider, key.to_base64()))
            .collect(),
    };
    write_json_atomic(&registry.path, &file).map_err(CredentialError::Durable)
}

fn token_digest(token: &str) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update(TOKEN_DIGEST_DOMAIN);
    digest.update(token.as_bytes());
    digest.finalize().into()
}

/// Invalid configured credential set or persisted binding file.
#[derive(Debug, Error)]
pub enum CredentialConfigError {
    /// At least one slot must be configured.
    #[error("provider credential limit must be greater than zero")]
    ZeroLimit,
    /// Configured or persisted identities exceed the finite bound.
    #[error("provider credential limit of {maximum} exceeded")]
    CredentialLimit {
        /// Configured bound.
        maximum: usize,
    },
    /// Empty and oversized raw tokens are rejected.
    #[error("provider credential token is invalid")]
    InvalidToken,
    /// One token cannot select multiple stable identities.
    #[error("provider credential token is shared by multiple identities")]
    SharedToken,
    /// One stable provider cannot have multiple configured tokens.
    #[error("provider {0} has multiple configured credentials")]
    DuplicateProviderIdentity(ProviderId),
    /// A removed credential still has a persistent key binding.
    #[error("persistent binding references unconfigured provider {0}")]
    UnknownPersistedProvider(ProviderId),
    /// Persistent binding is not a canonical X25519 key.
    #[error("persistent binding for provider {0} contains invalid X25519 key")]
    InvalidPersistedKey(ProviderId),
    /// File schema is incompatible.
    #[error("unsupported provider credential binding version {0}")]
    UnsupportedVersion(u32),
    /// Durable file operation failed.
    #[error(transparent)]
    Durable(#[from] DurableFileError),
}

/// Authentication or first-key binding rejection.
#[derive(Debug, Error)]
pub enum CredentialError {
    /// No configured token digest matched.
    #[error("invalid provider credential")]
    InvalidToken,
    /// One verification for this identity is already pending.
    #[error("provider {0} credential verification is already pending")]
    VerificationPending(ProviderId),
    /// Internal pending guard sequence cannot wrap.
    #[error("provider credential pending ticket exhausted")]
    TicketExhausted,
    /// Guard was superseded or already removed.
    #[error("provider {0} credential verification is stale")]
    PendingStale(ProviderId),
    /// First-bound key is immutable for this stable credential identity.
    #[error("provider {0} credential cannot rotate its bound X25519 key")]
    IdentityRotation(ProviderId),
    /// Persistent binding operation failed.
    #[error(transparent)]
    Durable(#[from] DurableFileError),
}

#[cfg(test)]
mod tests {
    use std::fs;

    use uuid::Uuid;

    use super::*;

    fn path() -> PathBuf {
        std::env::temp_dir().join(format!("darkbloom-credentials-{}.json", Uuid::new_v4()))
    }

    #[test]
    fn first_key_persists_rotation_fails_and_pending_failure_cleans_up() {
        let path = path();
        let provider = ProviderId::new([1; 16]);
        let registry = CredentialRegistry::open(
            &path,
            2,
            [ConfiguredProviderCredential::new(provider, "token")],
        )
        .expect("registry");
        let key = X25519PublicKey::from_bytes([3; 32]).expect("key");
        registry
            .begin("token")
            .expect("begin")
            .complete(key)
            .expect("bind");
        registry.begin("token").expect("begin failure").fail();
        assert_eq!(registry.pending_len(), 0);
        drop(registry.begin("token").expect("dropped verification"));
        assert_eq!(registry.pending_len(), 0);
        assert!(matches!(
            registry
                .begin("token")
                .expect("begin rotation")
                .complete(X25519PublicKey::from_bytes([4; 32]).expect("other")),
            Err(CredentialError::IdentityRotation(id)) if id == provider
        ));
        assert_eq!(registry.pending_len(), 0);
        drop(registry);

        assert!(matches!(
            CredentialRegistry::open(
                &path,
                2,
                [ConfiguredProviderCredential::new(
                    ProviderId::new([2; 16]),
                    "token"
                )],
            ),
            Err(CredentialConfigError::UnknownPersistedProvider(id)) if id == provider
        ));
        let restarted = CredentialRegistry::open(
            &path,
            2,
            [ConfiguredProviderCredential::new(provider, "token")],
        )
        .expect("restart");
        assert_eq!(restarted.bound_key(provider), Some(key));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn duplicate_token_and_provider_are_rejected() {
        let path = path();
        assert!(matches!(
            CredentialRegistry::open(
                &path,
                2,
                [
                    ConfiguredProviderCredential::new(ProviderId::new([1; 16]), "same"),
                    ConfiguredProviderCredential::new(ProviderId::new([2; 16]), "same"),
                ],
            ),
            Err(CredentialConfigError::SharedToken)
        ));
        assert!(matches!(
            CredentialRegistry::open(
                &path,
                2,
                [
                    ConfiguredProviderCredential::new(ProviderId::new([1; 16]), "one"),
                    ConfiguredProviderCredential::new(ProviderId::new([1; 16]), "two"),
                ],
            ),
            Err(CredentialConfigError::DuplicateProviderIdentity(_))
        ));
    }

    #[test]
    fn one_thousand_unique_credentials_remain_bounded_and_stable() {
        let path = path();
        let credentials = (1..=1_000_u128).map(|value| {
            ConfiguredProviderCredential::new(
                ProviderId::new(value.to_be_bytes()),
                format!("provider-token-{value}"),
            )
        });
        let registry = CredentialRegistry::open(&path, 1_000, credentials).expect("registry");
        assert_eq!(registry.len(), 1_000);
        for value in 1..=1_000_u128 {
            assert_eq!(
                registry
                    .begin(&format!("provider-token-{value}"))
                    .expect("credential")
                    .provider_id(),
                ProviderId::new(value.to_be_bytes())
            );
        }
        assert_eq!(registry.pending_len(), 0);

        let over_limit = (1..=1_001_u128).map(|value| {
            ConfiguredProviderCredential::new(
                ProviderId::new(value.to_be_bytes()),
                format!("bounded-token-{value}"),
            )
        });
        assert!(matches!(
            CredentialRegistry::open(&path, 1_000, over_limit),
            Err(CredentialConfigError::CredentialLimit { maximum: 1_000 })
        ));
    }
}

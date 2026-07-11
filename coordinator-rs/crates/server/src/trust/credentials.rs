//! Unique configured provider credentials and first-key-wins binding.

use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU8, AtomicU64, Ordering},
    },
    time::{Duration, Instant},
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

use super::P256PublicIdentity;

const CREDENTIAL_BINDING_VERSION: u32 = 2;
const LEGACY_CREDENTIAL_BINDING_VERSION: u32 = 1;
const TOKEN_DIGEST_DOMAIN: &[u8] = b"darkbloom.provider-credential.v1\0";
const MAX_TOKEN_BYTES: usize = 4_096;
const PENDING_LEASE_TTL: Duration = Duration::from_secs(30);
const LEASE_ACTIVE: u8 = 0;
const LEASE_ABANDONED: u8 = 1;
const LEASE_FINALIZED: u8 = 2;

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
    bindings: BTreeMap<ProviderId, PersistedBinding>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(untagged)]
enum PersistedBinding {
    LegacyX25519(String),
    StableIdentity {
        x25519_public_key: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        se_p256_public_key: Option<String>,
    },
}

#[derive(Clone, Debug)]
struct CredentialBinding {
    x25519_public_key: X25519PublicKey,
    se_p256_public_key: Option<P256PublicIdentity>,
}

#[derive(Debug, Default)]
struct CredentialState {
    bindings: BTreeMap<ProviderId, CredentialBinding>,
    pending: BTreeMap<ProviderId, PendingEntry>,
    next_ticket: u64,
}

#[derive(Debug)]
struct PendingLeaseMarker {
    state: AtomicU8,
    ticket: AtomicU64,
}

impl PendingLeaseMarker {
    fn new() -> Self {
        Self {
            state: AtomicU8::new(LEASE_ACTIVE),
            ticket: AtomicU64::new(0),
        }
    }

    fn abandon(&self) {
        let _ = self.state.compare_exchange(
            LEASE_ACTIVE,
            LEASE_ABANDONED,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
    }

    fn finalize(&self) {
        self.state.store(LEASE_FINALIZED, Ordering::Release);
    }

    fn is_active(&self) -> bool {
        self.state.load(Ordering::Acquire) == LEASE_ACTIVE
    }

    fn assign_ticket(&self, ticket: u64) -> bool {
        self.ticket
            .compare_exchange(0, ticket, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }

    fn ticket(&self) -> u64 {
        self.ticket.load(Ordering::Acquire)
    }
}

#[derive(Debug)]
struct PendingEntry {
    ticket: u64,
    expires_at: Instant,
    marker: Arc<PendingLeaseMarker>,
}

#[derive(Clone, Debug)]
pub(crate) struct PendingCredentialLease {
    provider_id: ProviderId,
    marker: Arc<PendingLeaseMarker>,
}

impl PendingCredentialLease {
    pub(crate) fn abandon(&self) {
        self.marker.abandon();
    }
}

/// Async-owned registration finalizer. Dropping it only flips an atomic
/// marker; mutex-backed cleanup remains an explicit durable-I/O operation.
#[derive(Debug)]
pub(crate) struct PendingCredentialFinalizer {
    lease: PendingCredentialLease,
    armed: bool,
}

impl PendingCredentialFinalizer {
    pub(crate) const fn provider_id(&self) -> ProviderId {
        self.lease.provider_id
    }

    pub(crate) fn lease(&self) -> PendingCredentialLease {
        self.lease.clone()
    }

    pub(crate) fn abandon(&self) {
        self.lease.abandon();
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for PendingCredentialFinalizer {
    fn drop(&mut self) {
        if self.armed {
            self.lease.abandon();
        }
    }
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
        if !matches!(
            file.version,
            LEGACY_CREDENTIAL_BINDING_VERSION | CREDENTIAL_BINDING_VERSION
        ) {
            return Err(CredentialConfigError::UnsupportedVersion(file.version));
        }
        if file.bindings.len() > maximum_credentials {
            return Err(CredentialConfigError::CredentialLimit {
                maximum: maximum_credentials,
            });
        }
        let mut bindings = BTreeMap::new();
        for (provider_id, persisted) in file.bindings {
            if !configured_identities.contains(&provider_id) {
                return Err(CredentialConfigError::UnknownPersistedProvider(provider_id));
            }
            let (x25519, se_p256) = match persisted {
                PersistedBinding::LegacyX25519(encoded) => (encoded, None),
                PersistedBinding::StableIdentity {
                    x25519_public_key,
                    se_p256_public_key,
                } => (x25519_public_key, se_p256_public_key),
            };
            let key = X25519PublicKey::from_base64(&x25519)
                .map_err(|_| CredentialConfigError::InvalidPersistedKey(provider_id))?;
            let signing_key = se_p256
                .map(|encoded| P256PublicIdentity::from_base64(&encoded))
                .transpose()
                .map_err(|_| CredentialConfigError::InvalidPersistedSigningKey(provider_id))?;
            bindings.insert(
                provider_id,
                CredentialBinding {
                    x25519_public_key: key,
                    se_p256_public_key: signing_key,
                },
            );
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
        let mut finalizer = self.prepare(token)?;
        let pending = self.begin_prepared(finalizer.lease());
        if pending.is_ok() {
            finalizer.disarm();
        }
        pending
    }

    /// Authenticates without taking the contended state mutex and creates the
    /// async-owned atomic finalizer before durable-I/O admission.
    pub(crate) fn prepare(
        &self,
        token: &str,
    ) -> Result<PendingCredentialFinalizer, CredentialError> {
        if token.is_empty() || token.len() > MAX_TOKEN_BYTES {
            return Err(CredentialError::InvalidToken);
        }
        let provider_id = self
            .inner
            .token_identities
            .get(&token_digest(token))
            .copied()
            .ok_or(CredentialError::InvalidToken)?;
        Ok(PendingCredentialFinalizer {
            lease: PendingCredentialLease {
                provider_id,
                marker: Arc::new(PendingLeaseMarker::new()),
            },
            armed: true,
        })
    }

    /// Reserves one pending slot for a previously authenticated finalizer.
    /// Async callers execute this contended mutation inside `DurableIoPool`.
    pub(crate) fn begin_prepared(
        &self,
        lease: PendingCredentialLease,
    ) -> Result<PendingCredential, CredentialError> {
        let provider_id = lease.provider_id;
        let mut state = self.lock_state();
        prune_pending(&mut state, Instant::now());
        if !lease.marker.is_active() {
            return Err(CredentialError::PendingStale(provider_id));
        }
        if state.pending.contains_key(&provider_id) {
            return Err(CredentialError::VerificationPending(provider_id));
        }
        state.next_ticket = state
            .next_ticket
            .checked_add(1)
            .ok_or(CredentialError::TicketExhausted)?;
        let ticket = state.next_ticket;
        if !lease.marker.assign_ticket(ticket) {
            return Err(CredentialError::PendingStale(provider_id));
        }
        state.pending.insert(
            provider_id,
            PendingEntry {
                ticket,
                expires_at: Instant::now() + PENDING_LEASE_TTL,
                marker: lease.marker.clone(),
            },
        );
        drop(state);
        Ok(PendingCredential {
            registry: Arc::clone(&self.inner),
            provider_id,
            ticket,
            marker: lease.marker,
        })
    }

    /// Returns the persistent key already bound to a stable provider.
    #[must_use]
    pub fn bound_key(&self, provider_id: ProviderId) -> Option<X25519PublicKey> {
        self.lock_state()
            .bindings
            .get(&provider_id)
            .map(|binding| binding.x25519_public_key)
    }

    /// Returns the persistent Secure Enclave verification identity bound to a
    /// stable provider credential across process generations.
    #[must_use]
    pub fn bound_signing_key(&self, provider_id: ProviderId) -> Option<P256PublicIdentity> {
        self.lock_state()
            .bindings
            .get(&provider_id)
            .and_then(|binding| binding.se_p256_public_key.clone())
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
        let mut state = self.lock_state();
        prune_pending(&mut state, Instant::now());
        state.pending.len()
    }

    /// Removes one exact failed pending lease. Callers from async code execute
    /// this method inside the bounded durable-I/O pool.
    pub(crate) fn release_pending(&self, lease: &PendingCredentialLease) -> bool {
        lease.abandon();
        let mut state = self.lock_state();
        let removed = state.pending.get(&lease.provider_id).is_some_and(|entry| {
            entry.ticket == lease.marker.ticket() && Arc::ptr_eq(&entry.marker, &lease.marker)
        });
        if removed {
            state.pending.remove(&lease.provider_id);
        }
        prune_pending(&mut state, Instant::now());
        lease.marker.finalize();
        removed
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
    marker: Arc<PendingLeaseMarker>,
}

impl PendingCredential {
    /// Stable identity selected only by the configured token digest.
    #[must_use]
    pub const fn provider_id(&self) -> ProviderId {
        self.provider_id
    }

    #[cfg(test)]
    fn lease(&self) -> PendingCredentialLease {
        PendingCredentialLease {
            provider_id: self.provider_id,
            marker: self.marker.clone(),
        }
    }

    /// Fsyncs the first verified X25519 and Secure Enclave keys or accepts the
    /// exact existing stable identity.
    ///
    /// A later registration using the shared credential cannot rotate identity
    /// to a new key. Errors explicitly remove the lease, while cancellation
    /// atomically abandons it for bounded lazy pruning.
    pub fn complete(
        self,
        verified_x25519_key: X25519PublicKey,
        verified_se_p256_key: P256PublicIdentity,
    ) -> Result<ProviderId, CredentialError> {
        let mut state = self.lock_state();
        prune_pending(&mut state, Instant::now());
        let result = if state
            .pending
            .get(&self.provider_id)
            .is_none_or(|entry| entry.ticket != self.ticket)
        {
            Err(CredentialError::PendingStale(self.provider_id))
        } else if let Some(existing) = state.bindings.get(&self.provider_id) {
            if !existing.x25519_public_key.ct_eq(&verified_x25519_key) {
                Err(CredentialError::X25519IdentityRotation(self.provider_id))
            } else if existing
                .se_p256_public_key
                .as_ref()
                .is_some_and(|signing_key| !signing_key.ct_eq(&verified_se_p256_key))
            {
                Err(CredentialError::SigningIdentityRotation(self.provider_id))
            } else if existing.se_p256_public_key.is_none() {
                let mut candidate = state.bindings.clone();
                candidate
                    .get_mut(&self.provider_id)
                    .expect("existing provider binding")
                    .se_p256_public_key = Some(verified_se_p256_key);
                match persist_bindings(&self.registry, &candidate) {
                    Ok(()) => {
                        state.bindings = candidate;
                        Ok(self.provider_id)
                    }
                    Err(error) => Err(error),
                }
            } else {
                Ok(self.provider_id)
            }
        } else {
            let mut candidate = state.bindings.clone();
            candidate.insert(
                self.provider_id,
                CredentialBinding {
                    x25519_public_key: verified_x25519_key,
                    se_p256_public_key: Some(verified_se_p256_key),
                },
            );
            match persist_bindings(&self.registry, &candidate) {
                Ok(()) => {
                    state.bindings = candidate;
                    Ok(self.provider_id)
                }
                Err(error) => Err(error),
            }
        };
        if state
            .pending
            .get(&self.provider_id)
            .is_some_and(|entry| entry.ticket == self.ticket)
        {
            state.pending.remove(&self.provider_id);
        }
        drop(state);
        self.marker.finalize();
        result
    }

    /// Atomically abandons failed verification for bounded lazy pruning.
    pub fn fail(self) {
        self.marker.abandon();
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, CredentialState> {
        self.registry
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
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
        self.marker.abandon();
    }
}

fn prune_pending(state: &mut CredentialState, now: Instant) {
    state
        .pending
        .retain(|_, entry| entry.expires_at > now && entry.marker.is_active());
}

fn persist_bindings(
    registry: &CredentialInner,
    bindings: &BTreeMap<ProviderId, CredentialBinding>,
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
            .map(|(provider, binding)| {
                (
                    *provider,
                    PersistedBinding::StableIdentity {
                        x25519_public_key: binding.x25519_public_key.to_base64(),
                        se_p256_public_key: binding
                            .se_p256_public_key
                            .as_ref()
                            .map(|key| key.as_base64().to_owned()),
                    },
                )
            })
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
    /// Persistent binding is not a canonical P-256 Secure Enclave key.
    #[error("persistent binding for provider {0} contains invalid Secure Enclave P-256 key")]
    InvalidPersistedSigningKey(ProviderId),
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
    /// First-bound X25519 key is immutable for this stable credential identity.
    #[error("provider {0} credential cannot rotate its bound X25519 key")]
    X25519IdentityRotation(ProviderId),
    /// First-bound Secure Enclave verification key is stable across process generations.
    #[error("provider {0} credential cannot rotate its bound Secure Enclave P-256 key")]
    SigningIdentityRotation(ProviderId),
    /// Persistent binding operation failed.
    #[error(transparent)]
    Durable(#[from] DurableFileError),
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        sync::atomic::{AtomicBool, Ordering},
        thread,
        time::Duration,
    };

    use base64::{Engine as _, engine::general_purpose::STANDARD};
    use p256::ecdsa::SigningKey;
    use uuid::Uuid;

    use super::*;
    use crate::crypto::{DurableIoError, DurableIoPool};

    fn path() -> PathBuf {
        std::env::temp_dir().join(format!("darkbloom-credentials-{}.json", Uuid::new_v4()))
    }

    fn signing_key() -> P256PublicIdentity {
        let key = SigningKey::from_slice(&[7; 32]).expect("test key");
        P256PublicIdentity::from_base64(&STANDARD.encode(key.verifying_key().to_sec1_point(false)))
            .expect("public key")
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
            .complete(key, signing_key())
            .expect("bind");
        registry.begin("token").expect("begin failure").fail();
        assert_eq!(registry.pending_len(), 0);
        drop(registry.begin("token").expect("dropped verification"));
        assert_eq!(registry.pending_len(), 0);
        assert!(matches!(
            registry
                .begin("token")
                .expect("begin rotation")
                .complete(
                    X25519PublicKey::from_bytes([4; 32]).expect("other"),
                    signing_key(),
                ),
            Err(CredentialError::X25519IdentityRotation(id)) if id == provider
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
        assert!(
            restarted
                .bound_signing_key(provider)
                .is_some_and(|key| key.ct_eq(&signing_key()))
        );

        let rotated_signing = SigningKey::from_slice(&[8; 32]).expect("other key");
        let rotated_signing = P256PublicIdentity::from_base64(
            &STANDARD.encode(rotated_signing.verifying_key().to_sec1_point(false)),
        )
        .expect("other public key");
        assert!(matches!(
            restarted
                .begin("token")
                .expect("begin signing rotation")
                .complete(key, rotated_signing),
            Err(CredentialError::SigningIdentityRotation(id)) if id == provider
        ));
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
    fn expired_pending_lease_is_pruned_without_guard_finalization() {
        let path = path();
        let provider = ProviderId::new([9; 16]);
        let registry = CredentialRegistry::open(
            &path,
            1,
            [ConfiguredProviderCredential::new(provider, "token")],
        )
        .expect("registry");
        let expired_guard = registry.begin("token").expect("pending credential");
        registry
            .lock_state()
            .pending
            .get_mut(&provider)
            .expect("pending entry")
            .expires_at = Instant::now();
        assert_eq!(registry.pending_len(), 0);
        let replacement = registry.begin("token").expect("expired lease was pruned");
        drop(expired_guard);
        assert_eq!(registry.pending_len(), 1);
        drop(replacement);
        assert_eq!(registry.pending_len(), 0);
        let _ = fs::remove_file(path);
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

    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    async fn stalled_persistence_lock_cannot_park_guard_drop_or_leak_pending_bound() {
        let path = path();
        let credentials = (1..=1_000_u128).map(|value| {
            ConfiguredProviderCredential::new(
                ProviderId::new(value.to_be_bytes()),
                format!("provider-token-{value}"),
            )
        });
        let registry = CredentialRegistry::open(&path, 1_000, credentials).expect("registry");
        let pending = (1..=1_000_u128)
            .map(|value| {
                registry
                    .begin(&format!("provider-token-{value}"))
                    .expect("pending credential")
            })
            .collect::<Vec<_>>();
        let leases = pending
            .iter()
            .map(PendingCredential::lease)
            .collect::<Vec<_>>();
        assert_eq!(registry.lock_state().pending.len(), 1_000);

        let started = Arc::new(AtomicBool::new(false));
        let release = Arc::new(AtomicBool::new(false));
        let stalled_registry = registry.clone();
        let stalled_started = started.clone();
        let stalled_release = release.clone();
        let stalled = tokio::task::spawn_blocking(move || {
            let _state = stalled_registry.lock_state();
            stalled_started.store(true, Ordering::Release);
            while !stalled_release.load(Ordering::Acquire) {
                thread::yield_now();
            }
        });
        while !started.load(Ordering::Acquire) {
            tokio::task::yield_now().await;
        }

        let pool = DurableIoPool::new(1, Duration::from_millis(20)).expect("I/O pool");
        let cleanup_registry = registry.clone();
        let cleanup_lease = leases[0].clone();
        assert!(matches!(
            pool.run("stalled credential cleanup", move || {
                cleanup_registry.release_pending(&cleanup_lease)
            })
            .await,
            Err(DurableIoError::Timeout { .. })
        ));

        tokio::time::timeout(Duration::from_millis(100), async move {
            drop(pending);
            tokio::task::yield_now().await;
        })
        .await
        .expect("atomic pending guard drop must not acquire the stalled mutex");

        let cancellation = tokio_util::sync::CancellationToken::new();
        let waiter = cancellation.clone();
        let cancelled = tokio::spawn(async move {
            waiter.cancelled().await;
        });
        cancellation.cancel();
        tokio::time::timeout(Duration::from_millis(100), cancelled)
            .await
            .expect("Tokio worker remains responsive")
            .expect("cancellation task");

        release.store(true, Ordering::Release);
        stalled.await.expect("stalled lock task");
        while pool.available_permits() == 0 {
            tokio::task::yield_now().await;
        }
        assert_eq!(registry.pending_len(), 0);
        let _ = fs::remove_file(path);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    async fn timed_out_contended_begin_cannot_create_a_late_pending_lease() {
        let path = path();
        let provider = ProviderId::new([10; 16]);
        let registry = CredentialRegistry::open(
            &path,
            1,
            [ConfiguredProviderCredential::new(provider, "token")],
        )
        .expect("registry");
        let finalizer = registry.prepare("token").expect("finalizer");
        let lease = finalizer.lease();

        let started = Arc::new(AtomicBool::new(false));
        let release = Arc::new(AtomicBool::new(false));
        let stalled_registry = registry.clone();
        let stalled_started = started.clone();
        let stalled_release = release.clone();
        let stalled = tokio::task::spawn_blocking(move || {
            let _state = stalled_registry.lock_state();
            stalled_started.store(true, Ordering::Release);
            while !stalled_release.load(Ordering::Acquire) {
                thread::yield_now();
            }
        });
        while !started.load(Ordering::Acquire) {
            tokio::task::yield_now().await;
        }

        let pool = DurableIoPool::new(1, Duration::from_millis(20)).expect("I/O pool");
        let begin_registry = registry.clone();
        assert!(matches!(
            pool.run("contended credential begin", move || {
                begin_registry.begin_prepared(lease)
            })
            .await,
            Err(DurableIoError::Timeout { .. })
        ));
        drop(finalizer);
        release.store(true, Ordering::Release);
        stalled.await.expect("stalled lock task");
        while pool.available_permits() == 0 {
            tokio::task::yield_now().await;
        }
        assert_eq!(registry.pending_len(), 0);
        let replacement = registry.begin("token").expect("fresh begin");
        drop(replacement);
        assert_eq!(registry.pending_len(), 0);
        let _ = fs::remove_file(path);
    }
}

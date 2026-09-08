//! Legacy-TEXT ↔ typed account-id directory.
//!
//! Legacy account ids are arbitrary strings (`did:privy:…`, `platform`,
//! `acct_…`); [`darkbloom_core::ids::AccountId`] is a UUID newtype. The
//! contracts follow the same convention as provider identities (see
//! `contracts::RegistrationSummary`): the UUID is derived deterministically
//! from the stable legacy string. This directory owns that derivation and the
//! reverse mapping the ledger needs to write legacy projections.
//!
//! The reverse mapping cannot be inverted mathematically, so it is kept as a
//! bounded in-process map populated wherever a legacy id is first seen
//! (API-key validation, explicit [`AccountDirectory::register`] calls). On a
//! miss the ledger falls back to scanning the small set of known legacy
//! account ids and matching by digest.

use std::collections::HashMap;
use std::sync::RwLock;

use sha2::{Digest, Sha256};
use sqlx::PgPool;
use uuid::Uuid;

use darkbloom_core::ids::AccountId;

use crate::contracts::LedgerError;

use super::error::map_sqlx;

/// Domain-separation prefix for the account digest. Never change: every
/// component deriving `AccountId`s from legacy strings must agree.
const ACCOUNT_UUID_DOMAIN: &[u8] = b"darkbloom.account.v1\0";

/// Directory capacity. Accounts are bounded in practice (thousands); on
/// overflow the map is cleared and repopulated lazily via the DB fallback.
const MAX_ENTRIES: usize = 65_536;

/// Deterministically derives the typed account id for a legacy TEXT id:
/// `uuid(SHA-256(domain ‖ legacy)[..16])` with the RFC 4122 version nibble
/// set to 8 (custom) and the variant bits set, so the value is a well-formed
/// UUID but can never collide with a v4 identifier minted elsewhere.
#[must_use]
pub fn account_id_for(legacy: &str) -> AccountId {
    let mut hasher = Sha256::new();
    hasher.update(ACCOUNT_UUID_DOMAIN);
    hasher.update(legacy.as_bytes());
    let digest = hasher.finalize();
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x80; // version 8 (custom)
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
    AccountId::new(Uuid::from_bytes(bytes))
}

/// Bounded bidirectional registry: typed account id → legacy TEXT id.
pub struct AccountDirectory {
    map: RwLock<HashMap<Uuid, String>>,
}

impl Default for AccountDirectory {
    fn default() -> Self {
        Self::new()
    }
}

impl AccountDirectory {
    #[must_use]
    pub fn new() -> Self {
        Self {
            map: RwLock::new(HashMap::new()),
        }
    }

    /// Registers a legacy account id and returns its typed id. Idempotent.
    pub fn register(&self, legacy: &str) -> AccountId {
        let id = account_id_for(legacy);
        if let Ok(mut map) = self.map.write() {
            if map.len() >= MAX_ENTRIES && !map.contains_key(&id.get()) {
                tracing::warn!(
                    entries = map.len(),
                    "account directory at capacity; clearing (repopulates via DB fallback)"
                );
                map.clear();
            }
            map.entry(id.get()).or_insert_with(|| legacy.to_owned());
        }
        id
    }

    /// In-process reverse lookup only.
    #[must_use]
    pub fn lookup(&self, id: AccountId) -> Option<String> {
        self.map
            .read()
            .ok()
            .and_then(|map| map.get(&id.get()).cloned())
    }

    /// Resolves a typed account id back to its legacy TEXT id, falling back
    /// to a bounded scan of every known legacy account id (balances, users,
    /// api-key owners, referrers). An account that appears in none of those
    /// tables holds no funds, so callers treat a miss as
    /// [`LedgerError::InsufficientFunds`]-adjacent and surface it typed.
    pub async fn resolve(&self, pool: &PgPool, id: AccountId) -> Result<String, LedgerError> {
        if let Some(found) = self.lookup(id) {
            return Ok(found);
        }
        let rows: Vec<(String,)> = sqlx::query_as(
            "SELECT account_id FROM ( \
                 SELECT account_id FROM balances \
                 UNION SELECT account_id FROM users \
                 UNION SELECT owner_account_id FROM api_keys WHERE owner_account_id <> '' \
                 UNION SELECT account_id FROM referrers \
             ) ids",
        )
        .fetch_all(pool)
        .await
        .map_err(map_sqlx)?;

        for (legacy,) in rows {
            if account_id_for(&legacy) == id {
                self.register(&legacy);
                return Ok(legacy);
            }
        }
        Err(LedgerError::Conflict(format!(
            "no legacy account id known for {id:?}; register() must precede use"
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derivation_is_deterministic_and_distinct() {
        let a1 = account_id_for("acct_consumer");
        let a2 = account_id_for("acct_consumer");
        let b = account_id_for("acct_provider");
        assert_eq!(a1, a2);
        assert_ne!(a1, b);
        // Version nibble is 8, variant bits are RFC 4122.
        let bytes = a1.get().into_bytes();
        assert_eq!(bytes[6] >> 4, 0x8);
        assert_eq!(bytes[8] >> 6, 0b10);
    }

    #[test]
    fn directory_round_trips() {
        let dir = AccountDirectory::new();
        let id = dir.register("did:privy:abc");
        assert_eq!(dir.lookup(id).as_deref(), Some("did:privy:abc"));
        assert_eq!(dir.lookup(account_id_for("unknown")), None);
    }
}

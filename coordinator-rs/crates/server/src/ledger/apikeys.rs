//! API-key authentication against the legacy `api_keys` table.
//!
//! Hashing replicates Go `store.HashKey` exactly (SHA-256 hex of the raw
//! key, `coordinator/store/postgres.go`) so every existing production key
//! validates unchanged.
//!
//! The in-process cache mirrors the Go `apiKeyCache` semantics
//! (`coordinator/api/server.go`): 60 s TTL, bounded at 1000 entries with
//! oldest-entry eviction, negative caching for unknown tokens, a generation
//! counter whose bump atomically invalidates every entry, and a time-based
//! expiry re-check on every cache hit. Unlike Go, entries are keyed by the
//! key HASH, so raw tokens are never retained in memory. Raw keys are never
//! logged; diagnostics use the hash prefix only.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use sha2::{Digest, Sha256};
use sqlx::Row;

use darkbloom_core::ids::ApiKeyId;
use darkbloom_core::money::MicroUsd;

use crate::contracts::ApiKeyRecord;

use super::Ledger;

const CACHE_TTL: Duration = Duration::from_secs(60);
const CACHE_MAX_SIZE: usize = 1000;

/// SHA-256 hex digest of a raw API key — byte-identical to Go
/// `store.HashKey`.
#[must_use]
pub fn hash_key(raw: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(raw.as_bytes());
    hex_encode(&hasher.finalize())
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        use std::fmt::Write;
        // Writing to a String cannot fail.
        let _ = write!(out, "{b:02x}");
    }
    out
}

/// One cached auth result. `record: None` is the negative cache for
/// unknown tokens.
#[derive(Clone)]
struct Entry {
    record: Option<ApiKeyRecord>,
    /// Key expiry re-checked on every hit: a key can expire while its
    /// positive entry is still within TTL (mirrors the Go re-check).
    expires_at: Option<DateTime<Utc>>,
    cached_at: Instant,
    generation: u64,
}

pub(crate) struct KeyCache {
    inner: Mutex<CacheInner>,
}

struct CacheInner {
    entries: HashMap<String, Entry>,
    generation: u64,
}

impl KeyCache {
    pub(super) fn new() -> Self {
        Self {
            inner: Mutex::new(CacheInner {
                entries: HashMap::new(),
                generation: 0,
            }),
        }
    }

    fn lookup(&self, key_hash: &str) -> Option<Entry> {
        let inner = self.inner.lock().ok()?;
        let entry = inner.entries.get(key_hash)?;
        if entry.generation != inner.generation || entry.cached_at.elapsed() > CACHE_TTL {
            return None;
        }
        Some(entry.clone())
    }

    fn store(
        &self,
        key_hash: String,
        record: Option<ApiKeyRecord>,
        expires_at: Option<DateTime<Utc>>,
    ) {
        let Ok(mut inner) = self.inner.lock() else {
            return;
        };
        let generation = inner.generation;
        if inner.entries.len() >= CACHE_MAX_SIZE {
            // Evict the oldest entry (mirrors Go storeAPIKeyCache).
            if let Some(oldest) = inner
                .entries
                .iter()
                .min_by_key(|(_, e)| e.cached_at)
                .map(|(k, _)| k.clone())
            {
                inner.entries.remove(&oldest);
            }
        }
        inner.entries.insert(
            key_hash,
            Entry {
                record,
                expires_at,
                cached_at: Instant::now(),
                generation,
            },
        );
    }

    /// Generation bump: atomically invalidates every cached entry (mirrors
    /// Go `invalidateAllAPIKeyCache`).
    pub(super) fn invalidate_all(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.generation += 1;
            inner.entries.clear();
        }
    }
}

/// Validates a raw bearer token against the legacy `api_keys` table.
/// Returns `None` for unknown tokens and for keys that are disabled,
/// expired, or not linked to an account.
pub(super) async fn validate(ledger: &Ledger, token: &str) -> Option<ApiKeyRecord> {
    let key_hash = hash_key(token);

    if let Some(entry) = ledger.key_cache.lookup(&key_hash) {
        return live_record(entry.record, entry.expires_at);
    }

    let row = sqlx::query(
        "SELECT id, owner_account_id, active, limit_micro_usd, expires_at \
         FROM api_keys WHERE key_hash = $1",
    )
    .bind(&key_hash)
    .fetch_optional(&ledger.pool)
    .await
    .map_err(|err| {
        tracing::warn!(
            key_hash_prefix = &key_hash[..8],
            error = %err,
            "api key lookup failed"
        );
        err
    })
    .ok()?;

    let Some(row) = row else {
        // Negative-cache unknown tokens to avoid hammering the DB.
        ledger.key_cache.store(key_hash, None, None);
        return None;
    };

    let id: String = row.try_get("id").ok()?;
    let owner: String = row.try_get("owner_account_id").ok()?;
    let active: bool = row.try_get("active").ok()?;
    let limit_micro_usd: Option<i64> = row.try_get("limit_micro_usd").ok()?;
    let expires_at: Option<DateTime<Utc>> = row.try_get("expires_at").ok()?;

    if owner.is_empty() {
        // Legacy unlinked keys are not supported by the Rust pilot
        // (linking runs through the Go coordinator's migration path).
        tracing::debug!(
            key_hash_prefix = &key_hash[..8],
            "api key has no owner account"
        );
        ledger.key_cache.store(key_hash, None, None);
        return None;
    }

    let account = ledger.accounts.register(&owner);
    let record = ApiKeyRecord {
        key_id: ApiKeyId::new(id),
        account,
        spend_cap: limit_micro_usd.map(MicroUsd::new),
        disabled: !active,
    };
    ledger
        .key_cache
        .store(key_hash, Some(record.clone()), expires_at);
    live_record(Some(record), expires_at)
}

/// Applies the disabled/expired filter at return time (the hit-path
/// re-check): a disabled or expired key validates as `None`.
fn live_record(
    record: Option<ApiKeyRecord>,
    expires_at: Option<DateTime<Utc>>,
) -> Option<ApiKeyRecord> {
    let record = record?;
    if record.disabled {
        return None;
    }
    if let Some(expiry) = expires_at {
        if Utc::now() > expiry {
            return None;
        }
    }
    Some(record)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_matches_go_store_hashkey() {
        // Precomputed: printf 'test-key' | shasum -a 256
        assert_eq!(
            hash_key("test-key"),
            "62af8704764faf8ea82fc61ce9c4c3908b6cb97d463a634e9e587d7c885db0ef"
        );
    }

    #[test]
    fn cache_generation_bump_invalidates() {
        let cache = KeyCache::new();
        cache.store("h1".to_owned(), None, None);
        assert!(cache.lookup("h1").is_some());
        cache.invalidate_all();
        assert!(cache.lookup("h1").is_none());
    }

    #[test]
    fn cache_is_bounded() {
        let cache = KeyCache::new();
        for i in 0..(CACHE_MAX_SIZE + 10) {
            cache.store(format!("h{i}"), None, None);
        }
        let inner = cache.inner.lock().expect("lock");
        assert!(inner.entries.len() <= CACHE_MAX_SIZE);
    }

    #[test]
    fn expired_key_validates_as_none() {
        let record = ApiKeyRecord {
            key_id: ApiKeyId::new("k"),
            account: super::super::accounts::account_id_for("acct"),
            spend_cap: None,
            disabled: false,
        };
        let past = Utc::now() - chrono::Duration::seconds(1);
        assert!(live_record(Some(record.clone()), Some(past)).is_none());
        let future = Utc::now() + chrono::Duration::seconds(60);
        assert!(live_record(Some(record), Some(future)).is_some());
    }
}

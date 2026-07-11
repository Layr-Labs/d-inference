//! Durable bounded cache of finalized terminal dispositions.

use std::{collections::VecDeque, path::PathBuf, sync::Mutex};

use darkbloom_coordinator_protocol::v2::{
    AttemptId, AttemptIdentity, Digest, ProviderId, ProviderProcessGenerationId,
    TerminalDisposition,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::epoch_store::{DurableFileError, read_json_if_exists, write_json_atomic};

const TERMINAL_STORE_VERSION: u32 = 1;

/// Provider-local identity of a terminal receipt.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
pub struct TerminalKey {
    /// Stable provider identity.
    pub provider_id: ProviderId,
    /// Provider process generation that signed the terminal.
    pub provider_process_generation: ProviderProcessGenerationId,
    /// Attempt identity within that process generation.
    pub attempt_id: AttemptId,
}

impl From<&AttemptIdentity> for TerminalKey {
    fn from(identity: &AttemptIdentity) -> Self {
        Self {
            provider_id: identity.provider_id,
            provider_process_generation: identity.provider_process_generation,
            attempt_id: identity.attempt_id,
        }
    }
}

/// One durable finalized receipt.
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct TerminalRecord {
    /// Provider-local terminal key.
    pub key: TerminalKey,
    /// Canonical provider terminal digest.
    pub terminal_digest: Digest,
    /// Coordinator decision returned in the terminal ACK.
    pub disposition: TerminalDisposition,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct TerminalFile {
    version: u32,
    entries: VecDeque<TerminalRecord>,
}

/// Result of finalization or historical lookup.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminalResolution {
    /// New final decision was fsynced.
    Finalized(TerminalDisposition),
    /// Exact digest and disposition were already finalized.
    Idempotent(TerminalDisposition),
    /// The key exists with different terminal facts; only this key conflicts.
    Conflict {
        /// Original immutable disposition.
        original: TerminalDisposition,
    },
    /// No retained record exists. Historical replay is safely and
    /// deterministically acknowledged as late without mutating the store.
    Late,
}

impl TerminalResolution {
    /// ACK disposition corresponding to this resolution.
    #[must_use]
    pub const fn disposition(self) -> TerminalDisposition {
        match self {
            Self::Finalized(disposition) | Self::Idempotent(disposition) => disposition,
            Self::Conflict { .. } => TerminalDisposition::Conflict,
            Self::Late => TerminalDisposition::Late,
        }
    }
}

/// FIFO cache of immutable finalized dispositions.
#[derive(Debug)]
pub struct TerminalDispositionStore {
    path: PathBuf,
    capacity: usize,
    state: Mutex<TerminalFile>,
}

impl TerminalDispositionStore {
    /// Opens a finite durable cache.
    pub fn open(path: impl Into<PathBuf>, capacity: usize) -> Result<Self, TerminalStoreError> {
        if capacity == 0 {
            return Err(TerminalStoreError::ZeroCapacity);
        }
        let path = path.into();
        let state = read_json_if_exists::<TerminalFile>(&path)?.unwrap_or(TerminalFile {
            version: TERMINAL_STORE_VERSION,
            entries: VecDeque::new(),
        });
        validate_loaded(&state, capacity)?;
        Ok(Self {
            path,
            capacity,
            state: Mutex::new(state),
        })
    }

    /// Fsyncs a first final decision, or resolves an exact/local replay.
    pub fn finalize(
        &self,
        record: TerminalRecord,
    ) -> Result<TerminalResolution, TerminalStoreError> {
        if matches!(
            record.disposition,
            TerminalDisposition::Late | TerminalDisposition::Conflict
        ) {
            return Err(TerminalStoreError::DerivedDisposition);
        }
        let mut state = self.lock_state();
        if let Some(existing) = state.entries.iter().find(|entry| entry.key == record.key) {
            return if existing == &record {
                Ok(TerminalResolution::Idempotent(existing.disposition))
            } else {
                Ok(TerminalResolution::Conflict {
                    original: existing.disposition,
                })
            };
        }

        let mut candidate = state.clone();
        if candidate.entries.len() == self.capacity {
            candidate.entries.pop_front();
        }
        candidate.entries.push_back(record.clone());
        write_json_atomic(&self.path, &candidate)?;
        *state = candidate;
        Ok(TerminalResolution::Finalized(record.disposition))
    }

    /// Resolves historical replay without ever writing an unknown key.
    #[must_use]
    pub fn resolve_historical(
        &self,
        key: TerminalKey,
        terminal_digest: Digest,
    ) -> TerminalResolution {
        self.lock_state()
            .entries
            .iter()
            .find(|entry| entry.key == key)
            .map_or(TerminalResolution::Late, |entry| {
                if entry.terminal_digest == terminal_digest {
                    TerminalResolution::Idempotent(entry.disposition)
                } else {
                    TerminalResolution::Conflict {
                        original: entry.disposition,
                    }
                }
            })
    }

    /// Number of retained finalized records.
    #[must_use]
    pub fn len(&self) -> usize {
        self.lock_state().entries.len()
    }

    /// Returns whether the cache has no finalized records.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.lock_state().entries.is_empty()
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, TerminalFile> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

fn validate_loaded(state: &TerminalFile, capacity: usize) -> Result<(), TerminalStoreError> {
    if state.version != TERMINAL_STORE_VERSION {
        return Err(TerminalStoreError::UnsupportedVersion(state.version));
    }
    if state.entries.len() > capacity {
        return Err(TerminalStoreError::CapacityExceeded { capacity });
    }
    for (index, entry) in state.entries.iter().enumerate() {
        if matches!(
            entry.disposition,
            TerminalDisposition::Late | TerminalDisposition::Conflict
        ) {
            return Err(TerminalStoreError::DerivedDisposition);
        }
        if state
            .entries
            .iter()
            .skip(index + 1)
            .any(|other| other.key == entry.key)
        {
            return Err(TerminalStoreError::DuplicateKey(entry.key));
        }
    }
    Ok(())
}

/// Durable terminal cache failure.
#[derive(Debug, Error)]
pub enum TerminalStoreError {
    /// Cache must retain at least one final decision.
    #[error("terminal disposition cache capacity must be greater than zero")]
    ZeroCapacity,
    /// Existing file cannot fit the configured bound.
    #[error("terminal disposition cache exceeds capacity {capacity}")]
    CapacityExceeded {
        /// Configured capacity.
        capacity: usize,
    },
    /// `late` and `conflict` are derived ACKs, not durable final decisions.
    #[error("late and conflict terminal dispositions cannot be finalized")]
    DerivedDisposition,
    /// On-disk cache contains the same provider-local key more than once.
    #[error("duplicate terminal key in durable cache: {0:?}")]
    DuplicateKey(TerminalKey),
    /// On-disk schema is incompatible.
    #[error("unsupported terminal disposition store version {0}")]
    UnsupportedVersion(u32),
    /// Durable cache operation failed.
    #[error(transparent)]
    Durable(#[from] DurableFileError),
}

#[cfg(test)]
mod tests {
    use std::fs;

    use darkbloom_coordinator_protocol::v2::TerminalDisposition;
    use uuid::Uuid;

    use super::*;

    fn path() -> PathBuf {
        std::env::temp_dir().join(format!("darkbloom-terminals-{}.json", Uuid::new_v4()))
    }

    fn record(provider: u8, attempt: u8, digest: u8) -> TerminalRecord {
        TerminalRecord {
            key: TerminalKey {
                provider_id: ProviderId::new([provider; 16]),
                provider_process_generation: ProviderProcessGenerationId::new([provider + 1; 16]),
                attempt_id: AttemptId::new([attempt; 16]),
            },
            terminal_digest: Digest::new([digest; 32]),
            disposition: TerminalDisposition::Settled,
        }
    }

    #[test]
    fn identical_is_idempotent_conflict_is_local_and_restart_is_durable() {
        let path = path();
        let store = TerminalDispositionStore::open(&path, 2).expect("store");
        let first = record(1, 2, 3);
        assert_eq!(
            store.finalize(first.clone()).expect("finalize"),
            TerminalResolution::Finalized(TerminalDisposition::Settled)
        );
        assert_eq!(
            store.finalize(first.clone()).expect("idempotent"),
            TerminalResolution::Idempotent(TerminalDisposition::Settled)
        );
        let conflicting = record(1, 2, 4);
        assert_eq!(
            store.finalize(conflicting).expect("local conflict"),
            TerminalResolution::Conflict {
                original: TerminalDisposition::Settled
            }
        );
        store.finalize(record(9, 8, 7)).expect("other provider");
        drop(store);

        let restarted = TerminalDispositionStore::open(&path, 2).expect("restart");
        assert_eq!(
            restarted.resolve_historical(first.key, first.terminal_digest),
            TerminalResolution::Idempotent(TerminalDisposition::Settled)
        );
        let _ = fs::remove_file(path);
    }

    #[test]
    fn fifo_eviction_makes_unknown_history_late_without_persisting_it() {
        let path = path();
        let store = TerminalDispositionStore::open(&path, 1).expect("store");
        let old = record(1, 1, 1);
        store.finalize(old.clone()).expect("old");
        store.finalize(record(2, 2, 2)).expect("new");
        drop(store);

        let restarted = TerminalDispositionStore::open(&path, 1).expect("restart");
        let before = fs::read(&path).expect("before");
        assert_eq!(
            restarted.resolve_historical(old.key, old.terminal_digest),
            TerminalResolution::Late
        );
        assert_eq!(fs::read(&path).expect("after"), before);
        let _ = fs::remove_file(path);
    }
}

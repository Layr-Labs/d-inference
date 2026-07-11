//! Fsynced monotonic provider session epochs.

use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{self, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    sync::Mutex,
};

use darkbloom_coordinator_protocol::v2::{ProviderId, SessionEpoch};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use thiserror::Error;
use uuid::Uuid;
use zeroize::Zeroizing;

const EPOCH_STORE_VERSION: u32 = 1;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct EpochFile {
    version: u32,
    epochs: BTreeMap<ProviderId, u64>,
}

/// Durable finite allocator for stable-provider WebSocket epochs.
#[derive(Debug)]
pub struct SessionEpochStore {
    path: PathBuf,
    maximum_providers: usize,
    state: Mutex<EpochFile>,
}

impl SessionEpochStore {
    /// Opens existing state or an empty store without writing to disk.
    pub fn open(
        path: impl Into<PathBuf>,
        maximum_providers: usize,
    ) -> Result<Self, SessionEpochStoreError> {
        if maximum_providers == 0 {
            return Err(SessionEpochStoreError::ZeroProviderLimit);
        }
        let path = path.into();
        let state = match read_json_if_exists::<EpochFile>(&path)? {
            Some(state) => state,
            None => EpochFile {
                version: EPOCH_STORE_VERSION,
                epochs: BTreeMap::new(),
            },
        };
        if state.version != EPOCH_STORE_VERSION {
            return Err(SessionEpochStoreError::UnsupportedVersion(state.version));
        }
        if state.epochs.len() > maximum_providers {
            return Err(SessionEpochStoreError::ProviderLimit {
                maximum: maximum_providers,
            });
        }
        if state.epochs.values().any(|epoch| *epoch == 0) {
            return Err(SessionEpochStoreError::InvalidEpoch);
        }
        Ok(Self {
            path,
            maximum_providers,
            state: Mutex::new(state),
        })
    }

    /// Fsyncs the next epoch before returning it to a registration ACK.
    pub fn allocate(
        &self,
        provider_id: ProviderId,
    ) -> Result<SessionEpoch, SessionEpochStoreError> {
        let mut state = self.lock_state();
        if !state.epochs.contains_key(&provider_id) && state.epochs.len() == self.maximum_providers
        {
            return Err(SessionEpochStoreError::ProviderLimit {
                maximum: self.maximum_providers,
            });
        }
        let next = state
            .epochs
            .get(&provider_id)
            .copied()
            .unwrap_or(0)
            .checked_add(1)
            .ok_or(SessionEpochStoreError::EpochExhausted)?;
        let mut candidate = state.clone();
        candidate.epochs.insert(provider_id, next);
        write_json_atomic(&self.path, &candidate)?;
        *state = candidate;
        Ok(SessionEpoch(next))
    }

    /// Last durably allocated epoch for one stable provider.
    #[must_use]
    pub fn current(&self, provider_id: ProviderId) -> Option<SessionEpoch> {
        self.lock_state()
            .epochs
            .get(&provider_id)
            .copied()
            .map(SessionEpoch)
    }

    /// Number of stable providers retained for monotonicity.
    #[must_use]
    pub fn len(&self) -> usize {
        self.lock_state().epochs.len()
    }

    /// Returns whether no provider has allocated an epoch.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.lock_state().epochs.is_empty()
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, EpochFile> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// Durable epoch allocation failure.
#[derive(Debug, Error)]
pub enum SessionEpochStoreError {
    /// A finite store must retain at least one provider.
    #[error("session epoch provider limit must be greater than zero")]
    ZeroProviderLimit,
    /// Persisted state exceeds the configured provider bound.
    #[error("session epoch provider limit of {maximum} reached")]
    ProviderLimit {
        /// Configured bound.
        maximum: usize,
    },
    /// Persisted epoch zero is not a legal allocated epoch.
    #[error("session epoch store contains epoch zero")]
    InvalidEpoch,
    /// Incrementing the durable epoch would wrap.
    #[error("provider session epoch exhausted")]
    EpochExhausted,
    /// The file was written by an incompatible implementation.
    #[error("unsupported session epoch store version {0}")]
    UnsupportedVersion(u32),
    /// Durable file operation failed.
    #[error(transparent)]
    Durable(#[from] DurableFileError),
}

/// Shared atomic-file failure used by the security stores.
#[derive(Debug, Error)]
pub enum DurableFileError {
    /// Filesystem operation failed.
    #[error("durable file {path}: {source}")]
    Io {
        /// Path being operated on.
        path: PathBuf,
        /// Underlying failure.
        source: io::Error,
    },
    /// Persisted JSON was malformed.
    #[error("decode durable file {path}: {source}")]
    Decode {
        /// Path being decoded.
        path: PathBuf,
        /// JSON failure.
        source: serde_json::Error,
    },
    /// State could not be serialized.
    #[error("encode durable state: {0}")]
    Encode(serde_json::Error),
}

pub(crate) fn read_json_if_exists<T: DeserializeOwned>(
    path: &Path,
) -> Result<Option<T>, DurableFileError> {
    let bytes = match fs::read(path) {
        Ok(bytes) => Zeroizing::new(bytes),
        Err(source) if source.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(source) => {
            return Err(DurableFileError::Io {
                path: path.to_path_buf(),
                source,
            });
        }
    };
    serde_json::from_slice(bytes.as_slice())
        .map(Some)
        .map_err(|source| DurableFileError::Decode {
            path: path.to_path_buf(),
            source,
        })
}

pub(crate) fn write_json_atomic<T: Serialize>(
    path: &Path,
    value: &T,
) -> Result<(), DurableFileError> {
    let bytes = Zeroizing::new(serde_json::to_vec(value).map_err(DurableFileError::Encode)?);
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).map_err(|source| DurableFileError::Io {
        path: parent.to_path_buf(),
        source,
    })?;
    let temporary = temporary_path(path);
    let result = (|| {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(|source| DurableFileError::Io {
                path: temporary.clone(),
                source,
            })?;
        file.write_all(bytes.as_slice())
            .and_then(|()| file.sync_all())
            .map_err(|source| DurableFileError::Io {
                path: temporary.clone(),
                source,
            })?;
        fs::rename(&temporary, path).map_err(|source| DurableFileError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|source| DurableFileError::Io {
                path: parent.to_path_buf(),
                source,
            })?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

fn temporary_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("state");
    path.with_file_name(format!(
        ".{file_name}.tmp-{}-{}",
        std::process::id(),
        Uuid::new_v4()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn path() -> PathBuf {
        std::env::temp_dir().join(format!("darkbloom-epochs-{}.json", Uuid::new_v4()))
    }

    #[test]
    fn epochs_survive_restart_and_never_regress() {
        let path = path();
        let provider = ProviderId::new([7; 16]);
        let store = SessionEpochStore::open(&path, 2).expect("open");
        assert_eq!(store.allocate(provider).expect("first"), SessionEpoch(1));
        assert_eq!(store.allocate(provider).expect("second"), SessionEpoch(2));
        drop(store);

        let restarted = SessionEpochStore::open(&path, 2).expect("restart");
        assert_eq!(restarted.current(provider), Some(SessionEpoch(2)));
        assert_eq!(
            restarted.allocate(provider).expect("third"),
            SessionEpoch(3)
        );
        let _ = fs::remove_file(path);
    }

    #[test]
    fn provider_bound_is_enforced_without_losing_existing_history() {
        let path = path();
        let store = SessionEpochStore::open(&path, 1).expect("open");
        let first = ProviderId::new([1; 16]);
        store.allocate(first).expect("first");
        assert!(matches!(
            store.allocate(ProviderId::new([2; 16])),
            Err(SessionEpochStoreError::ProviderLimit { maximum: 1 })
        ));
        assert_eq!(store.current(first), Some(SessionEpoch(1)));
        let _ = fs::remove_file(path);
    }
}

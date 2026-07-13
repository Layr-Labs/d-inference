use std::{
    fmt, fs,
    io::Read as _,
    path::{Path, PathBuf},
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use axum::{
    body::Body,
    extract::State,
    http::{HeaderMap, HeaderValue, header},
    response::{IntoResponse, Response},
};
use darkbloom_coordinator_protocol::crypto::seal_box;
use serde::Serialize;
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::crypto::X25519PublicKey;

use super::{OperationsState, auth::require_admin_key, error::OperationsError};

const DEFAULT_MAX_BYTES: u64 = 512 * 1024 * 1024;
const DEFAULT_MAX_FILES: usize = 100_000;
const ARCHIVE_MAGIC: &[u8] = b"DARKBLOOM-STATE-V1\0";

#[derive(Clone)]
pub struct StateExportConfig {
    root: Arc<PathBuf>,
    recipient: X25519PublicKey,
    recipient_key_id: Arc<str>,
    maximum_bytes: u64,
    maximum_files: usize,
}

impl fmt::Debug for StateExportConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("StateExportConfig")
            .field("root", &self.root)
            .field("recipient_key_id", &self.recipient_key_id)
            .field("maximum_bytes", &self.maximum_bytes)
            .field("maximum_files", &self.maximum_files)
            .finish_non_exhaustive()
    }
}

impl StateExportConfig {
    pub fn encrypted(
        root: impl Into<PathBuf>,
        recipient_key_id: impl Into<Arc<str>>,
        recipient_public_key_base64: &str,
    ) -> Result<Self, StateExportConfigError> {
        let recipient = X25519PublicKey::from_base64(recipient_public_key_base64)
            .map_err(|_| StateExportConfigError::InvalidRecipient)?;
        let mut config = Self {
            root: Arc::new(root.into()),
            recipient,
            recipient_key_id: recipient_key_id.into(),
            maximum_bytes: DEFAULT_MAX_BYTES,
            maximum_files: DEFAULT_MAX_FILES,
        };
        config.validate()?;
        config.root = Arc::new(
            fs::canonicalize(config.root.as_ref())
                .map_err(StateExportConfigError::RootUnavailable)?,
        );
        Ok(config)
    }

    #[must_use]
    pub fn with_limits(mut self, maximum_bytes: u64, maximum_files: usize) -> Self {
        self.maximum_bytes = maximum_bytes;
        self.maximum_files = maximum_files;
        self
    }

    pub(super) fn validate(&self) -> Result<(), StateExportConfigError> {
        if self.recipient_key_id.is_empty()
            || self.recipient_key_id.len() > 256
            || self.recipient_key_id.chars().any(char::is_control)
        {
            return Err(StateExportConfigError::InvalidKeyId);
        }
        if self.maximum_bytes == 0 || self.maximum_files == 0 {
            return Err(StateExportConfigError::InvalidLimits);
        }
        let metadata = fs::symlink_metadata(self.root.as_ref())
            .map_err(StateExportConfigError::RootUnavailable)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(StateExportConfigError::InvalidRoot);
        }
        Ok(())
    }
}

#[derive(Debug, Error)]
pub enum StateExportConfigError {
    #[error("state export recipient is not a canonical X25519 public key")]
    InvalidRecipient,
    #[error("state export recipient key id is invalid")]
    InvalidKeyId,
    #[error("state export limits must be positive")]
    InvalidLimits,
    #[error("state export root is unavailable: {0}")]
    RootUnavailable(std::io::Error),
    #[error("state export root must be a real directory, not a symlink")]
    InvalidRoot,
}

pub(super) async fn export(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
) -> Result<Response, OperationsError> {
    let config = state
        .settings
        .state_export
        .as_ref()
        .ok_or_else(|| OperationsError::not_found("state export is disabled"))?
        .clone();
    require_admin_key(&state.auth, &headers)?;
    let export = tokio::task::spawn_blocking(move || build_export(&config))
        .await
        .map_err(|error| OperationsError::internal("join state export", error))?
        .map_err(|error| OperationsError::internal("build state export", error))?;
    let filename = format!("darkbloom-state-{}.box.json", export.created_epoch_seconds);
    let mut response = Body::from(export.body).into_response();
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/octet-stream"),
    );
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    if let Ok(value) = HeaderValue::from_str(&format!("attachment; filename=\"{filename}\"")) {
        response
            .headers_mut()
            .insert(header::CONTENT_DISPOSITION, value);
    }
    state.metrics.increment("state_exports");
    Ok(response)
}

struct BuiltExport {
    body: Vec<u8>,
    created_epoch_seconds: u64,
}

#[derive(Serialize)]
struct SealedExport {
    schema_version: u32,
    recipient_key_id: String,
    file_count: usize,
    plaintext_sha256: String,
    ephemeral_public_key: String,
    ciphertext: String,
}

fn build_export(config: &StateExportConfig) -> Result<BuiltExport, Arc<str>> {
    let first = manifest(config)?;
    if first.is_empty() {
        return Err(Arc::from("state export root contains no regular files"));
    }
    let archive = archive(config, &first)?;
    let second = manifest(config)?;
    if first != second {
        return Err(Arc::from(
            "state changed while snapshot was being constructed",
        ));
    }
    let plaintext_sha256 = hex(&Sha256::digest(&archive));
    let encrypted = seal_box(config.recipient.as_bytes(), &archive)
        .map_err(|error| Arc::from(error.to_string()))?;
    let body = serde_json::to_vec(&SealedExport {
        schema_version: 1,
        recipient_key_id: config.recipient_key_id.to_string(),
        file_count: first.len(),
        plaintext_sha256,
        ephemeral_public_key: encrypted.ephemeral_public_key,
        ciphertext: encrypted.ciphertext,
    })
    .map_err(|error| Arc::from(error.to_string()))?;
    let created_epoch_seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| Arc::from(error.to_string()))?
        .as_secs();
    Ok(BuiltExport {
        body,
        created_epoch_seconds,
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ManifestEntry {
    relative: PathBuf,
    length: u64,
    modified: Option<SystemTime>,
    sha256: [u8; 32],
}

fn manifest(config: &StateExportConfig) -> Result<Vec<ManifestEntry>, Arc<str>> {
    let root =
        fs::canonicalize(config.root.as_ref()).map_err(|error| Arc::from(error.to_string()))?;
    let mut pending = vec![root.clone()];
    let mut entries = Vec::new();
    let mut total = 0_u64;
    while let Some(directory) = pending.pop() {
        let children = fs::read_dir(&directory)
            .map_err(|error| Arc::from(error.to_string()))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| Arc::from(error.to_string()))?;
        for child in children {
            let path = child.path();
            let metadata =
                fs::symlink_metadata(&path).map_err(|error| Arc::from(error.to_string()))?;
            if metadata.file_type().is_symlink() {
                return Err(Arc::from(format!(
                    "state root contains symlink {}",
                    path.display()
                )));
            }
            if metadata.is_dir() {
                pending.push(path);
                continue;
            }
            if !metadata.is_file() {
                return Err(Arc::from(format!(
                    "state root contains non-regular file {}",
                    path.display()
                )));
            }
            total = total
                .checked_add(metadata.len())
                .ok_or_else(|| Arc::from("state export size overflow"))?;
            if total > config.maximum_bytes {
                return Err(Arc::from("state export exceeds configured byte limit"));
            }
            if entries.len() == config.maximum_files {
                return Err(Arc::from("state export exceeds configured file limit"));
            }
            let sha256 = stable_file_digest(&path, metadata.len(), metadata.modified().ok())?;
            entries.push(ManifestEntry {
                relative: path
                    .strip_prefix(&root)
                    .map_err(|error| Arc::from(error.to_string()))?
                    .to_owned(),
                length: metadata.len(),
                modified: metadata.modified().ok(),
                sha256,
            });
        }
    }
    entries.sort_by(|left, right| left.relative.cmp(&right.relative));
    Ok(entries)
}

fn archive(config: &StateExportConfig, manifest: &[ManifestEntry]) -> Result<Vec<u8>, Arc<str>> {
    let capacity = manifest
        .iter()
        .try_fold(ARCHIVE_MAGIC.len() as u64 + 8, |total, entry| {
            total
                .checked_add(entry.length)
                .and_then(|value| value.checked_add(entry.relative.as_os_str().len() as u64 + 44))
        })
        .ok_or_else(|| Arc::from("state archive size overflow"))?;
    if capacity > config.maximum_bytes.saturating_add(8 * 1024 * 1024) {
        return Err(Arc::from("state archive exceeds configured byte limit"));
    }
    let mut output = Vec::with_capacity(
        usize::try_from(capacity).map_err(|_| Arc::from("state archive does not fit memory"))?,
    );
    output.extend_from_slice(ARCHIVE_MAGIC);
    output.extend_from_slice(&(manifest.len() as u64).to_be_bytes());
    for entry in manifest {
        let path = portable_path(&entry.relative)?;
        let path_length =
            u32::try_from(path.len()).map_err(|_| Arc::from("state path is too long"))?;
        let absolute = config.root.join(&entry.relative);
        let before = fs::metadata(&absolute).map_err(|error| Arc::from(error.to_string()))?;
        if before.len() != entry.length || before.modified().ok() != entry.modified {
            return Err(Arc::from("state file changed before snapshot read"));
        }
        let data = fs::read(&absolute).map_err(|error| Arc::from(error.to_string()))?;
        let after = fs::metadata(&absolute).map_err(|error| Arc::from(error.to_string()))?;
        if after.len() != entry.length
            || after.modified().ok() != entry.modified
            || data.len() as u64 != entry.length
            || Sha256::digest(&data).as_slice() != entry.sha256
        {
            return Err(Arc::from("state file changed during snapshot read"));
        }
        output.extend_from_slice(&path_length.to_be_bytes());
        output.extend_from_slice(path.as_bytes());
        output.extend_from_slice(&entry.length.to_be_bytes());
        output.extend_from_slice(&Sha256::digest(&data));
        output.extend_from_slice(&data);
    }
    Ok(output)
}

fn stable_file_digest(
    path: &Path,
    expected_length: u64,
    expected_modified: Option<SystemTime>,
) -> Result<[u8; 32], Arc<str>> {
    let before = fs::metadata(path).map_err(|error| Arc::from(error.to_string()))?;
    if !before.is_file()
        || before.len() != expected_length
        || before.modified().ok() != expected_modified
    {
        return Err(Arc::from("state file changed before snapshot digest"));
    }
    let mut file = fs::File::open(path).map_err(|error| Arc::from(error.to_string()))?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| Arc::from(error.to_string()))?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    let after = file
        .metadata()
        .map_err(|error| Arc::from(error.to_string()))?;
    if !after.is_file()
        || after.len() != expected_length
        || after.modified().ok() != expected_modified
    {
        return Err(Arc::from("state file changed during snapshot digest"));
    }
    Ok(digest.finalize().into())
}

fn portable_path(path: &Path) -> Result<String, Arc<str>> {
    let parts = path
        .components()
        .map(|component| {
            let value = component.as_os_str().to_string_lossy();
            if value.is_empty() || value == "." || value == ".." || value.contains('/') {
                Err(Arc::from("state path contains an unsafe component"))
            } else {
                Ok(value.into_owned())
            }
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(parts.join("/"))
}

fn hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[usize::from(byte >> 4)] as char);
        output.push(HEX[usize::from(byte & 0x0f)] as char);
    }
    output
}

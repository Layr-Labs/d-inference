use crate::contract::{
    ContractMetadata, METADATA_FILE, compute_contract_id, is_prompt_role, validate_relative_path,
};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::ffi::CString;
use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path};
use thiserror::Error;
use tokenizers::Tokenizer;

const MAX_METADATA_BYTES: u64 = 1 << 20;
const MAX_CONFIG_BYTES: u64 = 8 << 20;
const MAX_ARTIFACT_BYTES: u64 = 128 << 20;
const MAX_CONTRACT_BYTES: u64 = 512 << 20;

pub struct LoadedArtifacts {
    pub metadata: ContractMetadata,
    pub tokenizer: Tokenizer,
    pub tokenizer_config: Map<String, Value>,
    pub model_config: Map<String, Value>,
    pub chat_template: Value,
}

#[derive(Debug, Error)]
pub enum ArtifactError {
    #[error("invalid prompt contract identifier")]
    InvalidContractID,
    #[error("prompt contract metadata is invalid")]
    InvalidMetadata,
    #[error("prompt contract is incomplete")]
    Incomplete,
    #[error("prompt contract artifact is unsafe")]
    UnsafeArtifact,
    #[error("prompt contract artifact exceeds its declared bound")]
    ArtifactTooLarge,
    #[error("prompt contract artifact failed integrity verification")]
    Integrity,
    #[error("prompt contract tokenizer is unsupported")]
    Tokenizer,
    #[error("prompt contract could not be read")]
    Io(#[from] io::Error),
}

pub fn load(root: &Path, contract_id: &str) -> Result<LoadedArtifacts, ArtifactError> {
    validate_contract_id(contract_id)?;
    let root = open_directory_tree(root)?;
    let directory = open_directory_at(&root, contract_id)?;

    let metadata_value = read_json_object_at(&directory, METADATA_FILE, MAX_METADATA_BYTES)?;
    let metadata: ContractMetadata = serde_json::from_value(Value::Object(metadata_value))
        .map_err(|_| ArtifactError::InvalidMetadata)?;
    if metadata.schema_version != 1
        || metadata.prompt_contract_id != contract_id
        || compute_contract_id(&metadata.artifacts, &metadata.versions)
            .map_err(|_| ArtifactError::InvalidMetadata)?
            != contract_id
    {
        return Err(ArtifactError::InvalidMetadata);
    }

    let mut total = 0u64;
    let mut tokenizer_bytes = None;
    let mut tokenizer_config_bytes = None;
    let mut model_config_bytes = None;
    let mut chat_template_jinja_bytes = None;
    let mut chat_template_json_bytes = None;
    for artifact in &metadata.artifacts {
        if !is_prompt_role(&artifact.role) || !validate_relative_path(&artifact.path) {
            return Err(ArtifactError::UnsafeArtifact);
        }
        if artifact.size_bytes > MAX_ARTIFACT_BYTES {
            return Err(ArtifactError::ArtifactTooLarge);
        }
        total = total
            .checked_add(artifact.size_bytes)
            .filter(|sum| *sum <= MAX_CONTRACT_BYTES)
            .ok_or(ArtifactError::ArtifactTooLarge)?;
        let bytes = read_verified_file_at(
            &directory,
            &artifact.path,
            artifact.size_bytes,
            &artifact.sha256,
        )?;
        match artifact.path.as_str() {
            "tokenizer.json" => tokenizer_bytes = Some(bytes),
            "tokenizer_config.json" => tokenizer_config_bytes = Some(bytes),
            "config.json" => model_config_bytes = Some(bytes),
            "chat_template.jinja" => chat_template_jinja_bytes = Some(bytes),
            "chat_template.json" => chat_template_json_bytes = Some(bytes),
            _ => {}
        }
    }

    let tokenizer = Tokenizer::from_bytes(tokenizer_bytes.ok_or(ArtifactError::Incomplete)?)
        .map_err(|_| ArtifactError::Tokenizer)?;
    let tokenizer_config = match tokenizer_config_bytes {
        Some(bytes) => parse_json_object(&bytes, MAX_CONFIG_BYTES)?,
        None => Map::new(),
    };
    let model_config = parse_json_object(
        &model_config_bytes.ok_or(ArtifactError::Incomplete)?,
        MAX_CONFIG_BYTES,
    )?;
    if let Some(metadata_type) = metadata.model_type.as_deref()
        && model_config.get("model_type").and_then(Value::as_str) != Some(metadata_type)
    {
        return Err(ArtifactError::InvalidMetadata);
    }
    let chat_template = load_chat_template(
        chat_template_jinja_bytes.as_deref(),
        chat_template_json_bytes.as_deref(),
        &tokenizer_config,
    )?;

    Ok(LoadedArtifacts {
        metadata,
        tokenizer,
        tokenizer_config,
        model_config,
        chat_template,
    })
}

fn load_chat_template(
    jinja_bytes: Option<&[u8]>,
    json_bytes: Option<&[u8]>,
    tokenizer_config: &Map<String, Value>,
) -> Result<Value, ArtifactError> {
    if let Some(bytes) = jinja_bytes {
        if bytes.len() as u64 > MAX_CONFIG_BYTES {
            return Err(ArtifactError::ArtifactTooLarge);
        }
        if let Ok(template) = String::from_utf8(bytes.to_vec()) {
            return Ok(Value::String(template));
        }
    } else if let Some(bytes) = json_bytes
        && let Ok(config) = parse_json_object(bytes, MAX_CONFIG_BYTES)
        && let Some(template) = config.get("chat_template").and_then(Value::as_str)
    {
        return Ok(Value::String(template.to_owned()));
    }
    tokenizer_config
        .get("chat_template")
        .filter(|template| !template.is_null())
        .cloned()
        .ok_or(ArtifactError::Incomplete)
}

pub fn is_valid_contract_id(contract_id: &str) -> bool {
    validate_contract_id(contract_id).is_ok()
}

fn validate_contract_id(contract_id: &str) -> Result<(), ArtifactError> {
    if contract_id.len() != 64
        || contract_id
            .bytes()
            .any(|byte| !byte.is_ascii_hexdigit() || byte.is_ascii_uppercase())
    {
        return Err(ArtifactError::InvalidContractID);
    }
    Ok(())
}

fn read_verified_file_at(
    directory: &File,
    path: &str,
    expected_size: u64,
    expected_hash: &str,
) -> Result<Vec<u8>, ArtifactError> {
    let mut file = open_regular_at(directory, path)?;
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file() || metadata.len() != expected_size {
        return Err(ArtifactError::UnsafeArtifact);
    }
    let expected = hex::decode(expected_hash).map_err(|_| ArtifactError::Integrity)?;
    if expected.len() != 32 || expected_hash.bytes().any(|byte| byte.is_ascii_uppercase()) {
        return Err(ArtifactError::Integrity);
    }
    let mut hasher = Sha256::new();
    let mut bytes = Vec::with_capacity(expected_size as usize);
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        bytes.extend_from_slice(&buffer[..read]);
    }
    if hasher.finalize().as_slice() != expected.as_slice() {
        return Err(ArtifactError::Integrity);
    }
    Ok(bytes)
}

fn read_json_object_at(
    directory: &File,
    path: &str,
    max: u64,
) -> Result<Map<String, Value>, ArtifactError> {
    let bytes = read_bounded_at(directory, path, max)?;
    parse_json_object(&bytes, max)
}

fn parse_json_object(bytes: &[u8], max: u64) -> Result<Map<String, Value>, ArtifactError> {
    if bytes.len() as u64 > max {
        return Err(ArtifactError::ArtifactTooLarge);
    }
    match serde_json::from_slice(bytes).map_err(|_| ArtifactError::InvalidMetadata)? {
        Value::Object(object) => Ok(object),
        _ => Err(ArtifactError::InvalidMetadata),
    }
}

fn read_bounded_at(directory: &File, path: &str, max: u64) -> Result<Vec<u8>, ArtifactError> {
    let file = open_regular_at(directory, path)?;
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file() || metadata.len() > max {
        return Err(ArtifactError::ArtifactTooLarge);
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(max + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max {
        return Err(ArtifactError::ArtifactTooLarge);
    }
    Ok(bytes)
}

fn open_directory_tree(path: &Path) -> Result<File, ArtifactError> {
    if !path.is_absolute() {
        return Err(ArtifactError::UnsafeArtifact);
    }
    let mut current = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open("/")?;
    for component in path.components() {
        match component {
            Component::RootDir => {}
            Component::Normal(component) => {
                current = open_directory_at(&current, component)?;
            }
            _ => return Err(ArtifactError::UnsafeArtifact),
        }
    }
    Ok(current)
}

fn open_directory_at(
    directory: &File,
    name: impl AsRef<std::ffi::OsStr>,
) -> Result<File, ArtifactError> {
    open_at(
        directory,
        name.as_ref().as_bytes(),
        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
    )
}

fn open_regular_at(directory: &File, relative_path: &str) -> Result<File, ArtifactError> {
    if !validate_relative_path(relative_path) {
        return Err(ArtifactError::UnsafeArtifact);
    }
    let mut current = directory.try_clone()?;
    let components = relative_path.split('/').collect::<Vec<_>>();
    for component in &components[..components.len() - 1] {
        current = open_directory_at(&current, component)?;
    }
    open_at(
        &current,
        components[components.len() - 1].as_bytes(),
        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
    )
}

fn open_at(directory: &File, name: &[u8], flags: libc::c_int) -> Result<File, ArtifactError> {
    let name = CString::new(name).map_err(|_| ArtifactError::UnsafeArtifact)?;
    let descriptor = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
    if descriptor < 0 {
        return Err(ArtifactError::Io(io::Error::last_os_error()));
    }
    Ok(unsafe { File::from_raw_fd(descriptor) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn rejects_symlinked_artifact() {
        let temp = tempfile::tempdir().unwrap();
        let target = temp.path().join("target");
        let link = temp.path().join("link");
        std::fs::write(&target, b"secret").unwrap();
        symlink(&target, &link).unwrap();
        let root = open_directory_tree(&std::fs::canonicalize(temp.path()).unwrap()).unwrap();
        assert!(read_bounded_at(&root, "link", 1024).is_err());
    }

    #[test]
    fn rejects_symlinked_ancestor() {
        let temp = tempfile::tempdir().unwrap();
        let target = temp.path().join("target");
        let link = temp.path().join("link");
        std::fs::create_dir(&target).unwrap();
        std::fs::write(target.join("artifact"), b"secret").unwrap();
        symlink(&target, &link).unwrap();
        let root = open_directory_tree(&std::fs::canonicalize(temp.path()).unwrap()).unwrap();
        assert!(read_bounded_at(&root, "link/artifact", 1024).is_err());
    }

    #[test]
    fn matches_swift_chat_template_precedence() {
        let config = Map::from_iter([(
            "chat_template".into(),
            Value::String("config-template".into()),
        )]);

        assert_eq!(
            load_chat_template(
                Some(b"jinja-template"),
                Some(br#"{"chat_template":"json-template"}"#),
                &config
            )
            .unwrap(),
            Value::String("jinja-template".into())
        );
        assert_eq!(
            load_chat_template(None, Some(br#"{"chat_template":"json-template"}"#), &config)
                .unwrap(),
            Value::String("json-template".into())
        );
        assert_eq!(
            load_chat_template(None, None, &config).unwrap(),
            Value::String("config-template".into())
        );
    }
}

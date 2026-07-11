use std::{
    fs,
    io::{BufReader, Read as _},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Arc,
};

use axum::{
    Json,
    body::to_bytes,
    extract::{Query, Request, State},
    http::HeaderMap,
};
use futures_util::StreamExt as _;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::Row;
use tokio::io::AsyncWriteExt as _;
use uuid::Uuid;

use super::{
    OperationsState,
    auth::{require_admin, require_public, require_release},
    error::OperationsError,
    public::release_json,
};

const DEFAULT_PLATFORM: &str = "macos-arm64";
const MAX_RELEASE_BODY: usize = 64 * 1024;
const MAX_RELEASE_ARTIFACT: u64 = 2 << 30;
const MAX_RELEASE_PROVIDER_BINARY: u64 = 512 << 20;
const MAX_ARCHIVE_LIST: u64 = 16 << 20;

#[derive(Debug, Deserialize)]
pub(super) struct LatestQuery {
    platform: Option<String>,
}

pub(super) async fn latest_release(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
    Query(query): Query<LatestQuery>,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    let platform = query.platform.as_deref().unwrap_or(DEFAULT_PLATFORM);
    validate_platform(platform)?;
    let row = sqlx::query(
        r#"
        SELECT version, platform, backend, binary_hash, bundle_hash, metallib_hash,
               python_hash, runtime_hash, template_hashes, grpc_binary_hash,
               url, changelog
        FROM public.releases
        WHERE platform=$1 AND active
        ORDER BY created_at DESC LIMIT 1
        "#,
    )
    .bind(platform)
    .fetch_optional(state.pool())
    .await
    .map_err(|error| OperationsError::internal("load latest release", error))?
    .ok_or_else(|| {
        OperationsError::not_found(format!("no active release for platform {platform}"))
    })?;
    Ok(Json(release_json(&row)))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RegisterRelease {
    version: String,
    #[serde(default = "default_platform")]
    platform: String,
    #[serde(default)]
    backend: String,
    binary_hash: String,
    bundle_hash: String,
    #[serde(default)]
    metallib_hash: String,
    #[serde(default)]
    python_hash: String,
    #[serde(default)]
    runtime_hash: String,
    #[serde(default)]
    template_hashes: String,
    #[serde(default)]
    grpc_binary_hash: String,
    url: String,
    #[serde(default)]
    changelog: String,
}

pub(super) async fn register_release(
    State(state): State<Arc<OperationsState>>,
    request: Request,
) -> Result<Json<Value>, OperationsError> {
    require_release(&state.auth, request.headers())?;
    let bytes = to_bytes(request.into_body(), MAX_RELEASE_BODY)
        .await
        .map_err(|_| OperationsError::payload_too_large("release body exceeds 64KB"))?;
    let mut release: RegisterRelease = parse_json(&bytes)?;
    normalize_release(&state, &mut release)?;
    verify_artifact(
        &state,
        &release.url,
        &release.bundle_hash,
        &release.binary_hash,
    )
    .await?;

    let mut transaction = state
        .database
        .begin_owned()
        .await
        .map_err(|error| OperationsError::internal("begin release registration", error))?;
    sqlx::query(
        r#"
        INSERT INTO public.releases (
            version, platform, backend, binary_hash, bundle_hash, metallib_hash,
            python_hash, runtime_hash, template_hashes, grpc_binary_hash,
            url, changelog, active
        ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,TRUE)
        ON CONFLICT (version, platform) DO UPDATE SET
            backend=EXCLUDED.backend, binary_hash=EXCLUDED.binary_hash,
            bundle_hash=EXCLUDED.bundle_hash, metallib_hash=EXCLUDED.metallib_hash,
            python_hash=EXCLUDED.python_hash, runtime_hash=EXCLUDED.runtime_hash,
            template_hashes=EXCLUDED.template_hashes,
            grpc_binary_hash=EXCLUDED.grpc_binary_hash,
            url=EXCLUDED.url, changelog=EXCLUDED.changelog, active=TRUE
        "#,
    )
    .bind(&release.version)
    .bind(&release.platform)
    .bind(&release.backend)
    .bind(&release.binary_hash)
    .bind(&release.bundle_hash)
    .bind(&release.metallib_hash)
    .bind(&release.python_hash)
    .bind(&release.runtime_hash)
    .bind(&release.template_hashes)
    .bind(&release.grpc_binary_hash)
    .bind(&release.url)
    .bind(&release.changelog)
    .execute(transaction.connection())
    .await
    .map_err(|error| OperationsError::internal("upsert release", error))?;
    transaction
        .commit()
        .await
        .map_err(|error| OperationsError::internal("commit release registration", error))?;
    state.mark_mutation();
    state.metrics.increment("releases_registered");
    Ok(Json(json!({
        "status": "release_registered",
        "release": release_value(&release),
    })))
}

pub(super) async fn admin_list(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, OperationsError> {
    require_admin(&state.auth, &state.admin_sessions, &headers)?;
    let rows = sqlx::query(
        r#"
        SELECT version, platform, backend, binary_hash, bundle_hash, metallib_hash,
               python_hash, runtime_hash, template_hashes, grpc_binary_hash,
               url, changelog, active,
               to_char(created_at AT TIME ZONE 'UTC',
                       'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at
        FROM public.releases ORDER BY created_at DESC, version, platform
        "#,
    )
    .fetch_all(state.pool())
    .await
    .map_err(|error| OperationsError::internal("list releases", error))?
    .into_iter()
    .map(|row| {
        let mut value = release_json(&row);
        value["active"] = Value::Bool(row.get("active"));
        value["created_at"] = Value::String(row.get("created_at"));
        value
    })
    .collect::<Vec<_>>();
    Ok(Json(json!({"releases": rows})))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct DeleteRelease {
    version: String,
    #[serde(default = "default_platform")]
    platform: String,
    #[serde(default)]
    force: bool,
}

pub(super) async fn admin_delete(
    State(state): State<Arc<OperationsState>>,
    request: Request,
) -> Result<Json<Value>, OperationsError> {
    require_admin(&state.auth, &state.admin_sessions, request.headers())?;
    let bytes = to_bytes(request.into_body(), MAX_RELEASE_BODY)
        .await
        .map_err(|_| OperationsError::payload_too_large("release body exceeds 64KB"))?;
    let request: DeleteRelease = parse_json(&bytes)?;
    validate_version(&request.version)?;
    validate_platform(&request.platform)?;
    let release = sqlx::query(
        "SELECT binary_hash FROM public.releases WHERE version=$1 AND platform=$2 AND active",
    )
    .bind(&request.version)
    .bind(&request.platform)
    .fetch_optional(state.pool())
    .await
    .map_err(|error| OperationsError::internal("load release for deactivation", error))?
    .ok_or_else(|| OperationsError::not_found("active release not found"))?;
    if !request.force {
        ensure_release_not_in_use(&state, &release.get::<String, _>("binary_hash")).await?;
    }

    let mut transaction = state
        .database
        .begin_owned()
        .await
        .map_err(|error| OperationsError::internal("begin release deactivation", error))?;
    let result = sqlx::query(
        "UPDATE public.releases SET active=FALSE WHERE version=$1 AND platform=$2 AND active",
    )
    .bind(&request.version)
    .bind(&request.platform)
    .execute(transaction.connection())
    .await
    .map_err(|error| OperationsError::internal("deactivate release", error))?;
    if result.rows_affected() == 0 {
        return Err(OperationsError::not_found("active release not found"));
    }
    transaction
        .commit()
        .await
        .map_err(|error| OperationsError::internal("commit release deactivation", error))?;
    state.mark_mutation();
    state.metrics.increment("releases_deactivated");
    Ok(Json(json!({
        "status": "release_deactivated",
        "version": request.version,
        "platform": request.platform,
        "force": request.force,
    })))
}

async fn verify_artifact(
    state: &OperationsState,
    url: &str,
    expected_bundle_hash: &str,
    expected_binary_hash: &str,
) -> Result<(), OperationsError> {
    let response = state
        .http_client
        .get(url)
        .timeout(state.operation_timeout)
        .send()
        .await
        .map_err(|error| {
            OperationsError::bad_request(format!("download release artifact: {error}"))
        })?;
    if !response.status().is_success() {
        return Err(OperationsError::bad_request(format!(
            "release artifact returned {}",
            response.status()
        )));
    }
    if response
        .content_length()
        .is_some_and(|length| length > MAX_RELEASE_ARTIFACT)
    {
        return Err(OperationsError::payload_too_large(
            "release artifact exceeds 2GiB",
        ));
    }
    let artifact = TempArtifact::create().await?;
    let mut file = tokio::fs::OpenOptions::new()
        .write(true)
        .open(artifact.path())
        .await
        .map_err(|error| OperationsError::internal("open temporary release artifact", error))?;
    let mut length = 0_u64;
    let mut digest = Sha256::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| {
            OperationsError::bad_request(format!("read release artifact: {error}"))
        })?;
        length = length.saturating_add(chunk.len() as u64);
        if length > MAX_RELEASE_ARTIFACT {
            return Err(OperationsError::payload_too_large(
                "release artifact exceeds 2GiB",
            ));
        }
        digest.update(&chunk);
        file.write_all(&chunk).await.map_err(|error| {
            OperationsError::internal("write temporary release artifact", error)
        })?;
    }
    file.flush()
        .await
        .map_err(|error| OperationsError::internal("flush temporary release artifact", error))?;
    drop(file);
    if hex(&digest.finalize()) != expected_bundle_hash {
        return Err(OperationsError::bad_request(
            "bundle_hash does not match release artifact",
        ));
    }
    let expected_binary_hash = expected_binary_hash.to_owned();
    tokio::task::spawn_blocking(move || {
        verify_bundled_binary(artifact.path(), &expected_binary_hash)
    })
    .await
    .map_err(|error| OperationsError::internal("join release artifact verification", error))?
    .map_err(OperationsError::bad_request)?;
    Ok(())
}

async fn ensure_release_not_in_use(
    state: &OperationsState,
    binary_hash: &str,
) -> Result<(), OperationsError> {
    let Some(pilot) = state.pilot() else {
        return Ok(());
    };
    let ids = pilot
        .fleet_snapshot()
        .providers()
        .map(|provider| provider.provider().fence().provider_id.to_string())
        .collect::<Vec<_>>();
    if ids.is_empty() {
        return Ok(());
    }
    let active: i64 = sqlx::query_scalar(
        r#"
        SELECT COUNT(*)::BIGINT
        FROM public.providers
        WHERE id=ANY($1)
          AND COALESCE(attestation_result->>'binary_hash','')=$2
        "#,
    )
    .bind(&ids)
    .bind(binary_hash)
    .fetch_one(state.pool())
    .await
    .map_err(|error| OperationsError::internal("check release provider use", error))?;
    if active > 0 {
        return Err(OperationsError::conflict(
            "release_in_use",
            format!(
                "release binary hash is still used by {active} connected provider(s); set force=true to deactivate"
            ),
        ));
    }
    Ok(())
}

struct TempArtifact {
    path: PathBuf,
}

impl TempArtifact {
    async fn create() -> Result<Self, OperationsError> {
        let path =
            std::env::temp_dir().join(format!("darkbloom-release-{}.tar.gz", Uuid::new_v4()));
        tokio::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&path)
            .await
            .map_err(|error| {
                OperationsError::internal("create temporary release artifact", error)
            })?;
        Ok(Self { path })
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempArtifact {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_file(&self.path)
            && error.kind() != std::io::ErrorKind::NotFound
        {
            tracing::warn!(path = %self.path.display(), error = %error, "remove release artifact");
        }
    }
}

fn verify_bundled_binary(path: &Path, expected_hash: &str) -> Result<(), String> {
    let mut list = Command::new("tar")
        .args(["-tvzf"])
        .arg(path)
        .env("LC_ALL", "C")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("inspect release bundle: {error}"))?;
    let mut output = String::new();
    list.stdout
        .take()
        .ok_or_else(|| "release bundle list output unavailable".to_owned())?
        .take(MAX_ARCHIVE_LIST + 1)
        .read_to_string(&mut output)
        .map_err(|error| format!("read release bundle list: {error}"))?;
    if output.len() as u64 > MAX_ARCHIVE_LIST {
        let _ = list.kill();
        let _ = list.wait();
        return Err("release bundle file list exceeds maximum size".to_owned());
    }
    let status = list
        .wait()
        .map_err(|error| format!("wait for release bundle inspection: {error}"))?;
    if !status.success() {
        return Err("release artifact is not a valid gzip-compressed tar archive".to_owned());
    }
    let mut member = None;
    for line in output.lines() {
        let Some(kind) = line.as_bytes().first().copied() else {
            continue;
        };
        for token in line.split_ascii_whitespace().rev() {
            let Ok(clean) = clean_archive_path(token) else {
                continue;
            };
            if clean != "bin/darkbloom" {
                continue;
            }
            if kind != b'-' {
                return Err("bundled provider binary is not a regular file".to_owned());
            }
            if member.replace(token.to_owned()).is_some() {
                return Err("bundle contains multiple provider binaries".to_owned());
            }
            break;
        }
    }
    let member = member.ok_or_else(|| "bundle is missing bin/darkbloom".to_owned())?;
    let mut extract = Command::new("tar")
        .args(["-xOzf"])
        .arg(path)
        .arg("--")
        .arg(&member)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("read bundled provider binary: {error}"))?;
    let mut reader = BufReader::new(
        extract
            .stdout
            .take()
            .ok_or_else(|| "bundled provider binary output unavailable".to_owned())?,
    );
    let mut length = 0_u64;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = reader
            .read(&mut buffer)
            .map_err(|error| format!("read bundled provider binary: {error}"))?;
        if read == 0 {
            break;
        }
        length = length.saturating_add(read as u64);
        if length > MAX_RELEASE_PROVIDER_BINARY {
            let _ = extract.kill();
            let _ = extract.wait();
            return Err("provider binary exceeds maximum size".to_owned());
        }
        digest.update(&buffer[..read]);
    }
    let status = extract
        .wait()
        .map_err(|error| format!("wait for bundled provider binary: {error}"))?;
    if !status.success() {
        return Err("failed to extract bundled provider binary".to_owned());
    }
    if hex(&digest.finalize()) != expected_hash {
        return Err("binary_hash does not match bundled provider binary".to_owned());
    }
    Ok(())
}

fn clean_archive_path(name: &str) -> Result<String, ()> {
    if name.is_empty() || name.starts_with('/') || name.contains('\\') {
        return Err(());
    }
    let mut clean = Vec::new();
    for component in name.split('/') {
        match component {
            "" | "." => {}
            ".." => return Err(()),
            value => clean.push(value),
        }
    }
    if clean.is_empty() {
        return Err(());
    }
    Ok(clean.join("/"))
}

fn normalize_release(
    state: &OperationsState,
    release: &mut RegisterRelease,
) -> Result<(), OperationsError> {
    release.version = release.version.trim().to_owned();
    release.platform = release.platform.trim().to_ascii_lowercase();
    release.backend = release.backend.trim().to_owned();
    release.binary_hash = normalize_hash(&release.binary_hash, "binary_hash")?;
    release.bundle_hash = normalize_hash(&release.bundle_hash, "bundle_hash")?;
    for (value, name) in [
        (&mut release.metallib_hash, "metallib_hash"),
        (&mut release.python_hash, "python_hash"),
        (&mut release.runtime_hash, "runtime_hash"),
        (&mut release.grpc_binary_hash, "grpc_binary_hash"),
    ] {
        if !value.trim().is_empty() {
            *value = normalize_hash(value, name)?;
        }
    }
    validate_version(&release.version)?;
    validate_platform(&release.platform)?;
    if release.backend == "mlx-swift" && release.metallib_hash.is_empty() {
        return Err(OperationsError::bad_request(
            "metallib_hash is required for mlx-swift releases",
        ));
    }
    release.template_hashes = normalize_template_hashes(&release.template_hashes)?;
    let expected = state
        .settings
        .release_cdn_url
        .join(&format!(
            "releases/v{}/darkbloom-bundle-{}.tar.gz",
            release.version, release.platform
        ))
        .map_err(|error| OperationsError::internal("construct release URL", error))?;
    let actual = url::Url::parse(release.url.trim())
        .map_err(|_| OperationsError::bad_request("url must be an absolute URL"))?;
    if actual != expected {
        return Err(OperationsError::bad_request(
            "url must match configured release artifact path",
        ));
    }
    release.url = actual.to_string();
    Ok(())
}

fn validate_version(version: &str) -> Result<(), OperationsError> {
    let core = version
        .split(['-', '+'])
        .next()
        .unwrap_or_default()
        .split('.')
        .collect::<Vec<_>>();
    let suffix_valid = version
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'+'));
    if core.len() != 3
        || core
            .iter()
            .any(|part| part.is_empty() || !part.bytes().all(|byte| byte.is_ascii_digit()))
        || !suffix_valid
    {
        return Err(OperationsError::bad_request(
            "version must be semver, e.g. 1.2.3 or 1.2.3-dev.1",
        ));
    }
    Ok(())
}

fn validate_platform(platform: &str) -> Result<(), OperationsError> {
    if platform.is_empty()
        || platform.len() > 64
        || !platform.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"._-".contains(&byte)
        })
        || !platform
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
    {
        return Err(OperationsError::bad_request(
            "platform contains invalid characters",
        ));
    }
    Ok(())
}

fn normalize_template_hashes(raw: &str) -> Result<String, OperationsError> {
    let mut output = Vec::new();
    for entry in raw
        .split(',')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
    {
        let (name, hash) = entry.split_once('=').ok_or_else(|| {
            OperationsError::bad_request("template_hashes entries must be name=sha256")
        })?;
        if name.is_empty()
            || !name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
        {
            return Err(OperationsError::bad_request(
                "template_hashes contains an invalid template name",
            ));
        }
        output.push(format!(
            "{name}={}",
            normalize_hash(hash, "template_hashes")?
        ));
    }
    Ok(output.join(","))
}

fn normalize_hash(value: &str, name: &str) -> Result<String, OperationsError> {
    let value = value.trim().to_ascii_lowercase();
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(OperationsError::bad_request(format!(
            "{name} must be a 64-character SHA-256 hex digest"
        )));
    }
    Ok(value)
}

fn release_value(release: &RegisterRelease) -> Value {
    json!({
        "version": release.version,
        "platform": release.platform,
        "backend": release.backend,
        "binary_hash": release.binary_hash,
        "bundle_hash": release.bundle_hash,
        "metallib_hash": release.metallib_hash,
        "python_hash": release.python_hash,
        "runtime_hash": release.runtime_hash,
        "template_hashes": release.template_hashes,
        "grpc_binary_hash": release.grpc_binary_hash,
        "url": release.url,
        "changelog": release.changelog,
        "active": true,
    })
}

fn parse_json<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T, OperationsError> {
    let mut deserializer = serde_json::Deserializer::from_slice(bytes);
    let value = T::deserialize(&mut deserializer)
        .map_err(|error| OperationsError::bad_request(format!("invalid JSON: {error}")))?;
    deserializer
        .end()
        .map_err(|error| OperationsError::bad_request(format!("invalid JSON: {error}")))?;
    Ok(value)
}

fn default_platform() -> String {
    DEFAULT_PLATFORM.to_owned()
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

use std::borrow::Cow;

use rand::TryRng as _;
use serde_json::Value;
use sha2::{Digest as _, Sha256};
use sqlx::FromRow;
use subtle::ConstantTimeEq as _;

use super::{
    error::IdentityError,
    types::{ApiKeyCreate, ApiKeyRecord},
};

const KEY_PREFIX: &str = "sk-db-";
const MAXIMUM_NAME_BYTES: usize = 128;
const MAXIMUM_MODELS: usize = 128;
const MAXIMUM_MODEL_BYTES: usize = 256;
const MAXIMUM_SECRET_BYTES: usize = 512;

#[derive(Clone, Debug, Default)]
pub struct ApiKeyPatch {
    pub name: Option<String>,
    pub disabled: Option<bool>,
    pub limit_micro_usd: Option<Option<i64>>,
    pub limit_reset: Option<String>,
    pub rpm_limit: Option<Option<i64>>,
    pub itpm_limit: Option<Option<i64>>,
    pub otpm_limit: Option<Option<i64>>,
    pub allowed_models: Option<Vec<String>>,
    pub self_route_only: Option<bool>,
    pub expires_at: Option<Option<String>>,
}

impl ApiKeyPatch {
    pub(super) fn validate(mut self) -> Result<ValidatedPatch, IdentityError> {
        if let Some(name) = &mut self.name {
            *name = name.trim().to_owned();
            validate_name(name)?;
        }
        if let Some(limit) = self.limit_micro_usd.flatten()
            && limit < 0
        {
            return Err(IdentityError::invalid("limit_usd must be non-negative"));
        }
        if let Some(reset) = &mut self.limit_reset {
            *reset = normalize_reset(reset)?;
        }
        validate_optional_limit(self.rpm_limit, "rpm_limit")?;
        validate_optional_limit(self.itpm_limit, "itpm_limit")?;
        validate_optional_limit(self.otpm_limit, "otpm_limit")?;
        let allowed_models_json = self
            .allowed_models
            .as_ref()
            .map(|models| validate_models(models))
            .transpose()?;
        if let Some(Some(expires_at)) = &self.expires_at {
            validate_timestamp_shape(expires_at)?;
        }
        Ok(ValidatedPatch {
            name: self.name,
            disabled: self.disabled,
            limit_micro_usd: self.limit_micro_usd,
            limit_reset: self.limit_reset,
            rpm_limit: self.rpm_limit,
            itpm_limit: self.itpm_limit,
            otpm_limit: self.otpm_limit,
            allowed_models_json,
            self_route_only: self.self_route_only,
            expires_at: self.expires_at,
        })
    }
}

pub(super) struct ValidatedKeyInput {
    pub(super) name: String,
    pub(super) limit_micro_usd: Option<i64>,
    pub(super) limit_reset: String,
    pub(super) rpm_limit: Option<i64>,
    pub(super) itpm_limit: Option<i64>,
    pub(super) otpm_limit: Option<i64>,
    pub(super) allowed_models_json: String,
    pub(super) self_route_only: bool,
    pub(super) expires_at: Option<String>,
}

impl TryFrom<ApiKeyCreate> for ValidatedKeyInput {
    type Error = IdentityError;

    fn try_from(mut value: ApiKeyCreate) -> Result<Self, Self::Error> {
        value.name = value.name.trim().to_owned();
        validate_name(&value.name)?;
        let limit_micro_usd = value.limit_usd.map(usd_to_micro).transpose()?;
        let limit_reset = normalize_reset(&value.limit_reset)?;
        validate_limit(value.rpm_limit, "rpm_limit")?;
        validate_limit(value.itpm_limit, "itpm_limit")?;
        validate_limit(value.otpm_limit, "otpm_limit")?;
        let allowed_models_json = validate_models(&value.allowed_models)?;
        if let Some(expires_at) = &value.expires_at {
            validate_timestamp_shape(expires_at)?;
        }
        Ok(Self {
            name: value.name,
            limit_micro_usd,
            limit_reset,
            rpm_limit: value.rpm_limit,
            itpm_limit: value.itpm_limit,
            otpm_limit: value.otpm_limit,
            allowed_models_json,
            self_route_only: value.self_route_only,
            expires_at: value.expires_at,
        })
    }
}

pub(super) struct ValidatedPatch {
    pub(super) name: Option<String>,
    pub(super) disabled: Option<bool>,
    pub(super) limit_micro_usd: Option<Option<i64>>,
    pub(super) limit_reset: Option<String>,
    pub(super) rpm_limit: Option<Option<i64>>,
    pub(super) itpm_limit: Option<Option<i64>>,
    pub(super) otpm_limit: Option<Option<i64>>,
    pub(super) allowed_models_json: Option<String>,
    pub(super) self_route_only: Option<bool>,
    pub(super) expires_at: Option<Option<String>>,
}

#[derive(FromRow)]
pub(super) struct ApiKeyDbRow {
    pub(super) id: String,
    pub(super) owner_account_id: String,
    pub(super) name: String,
    pub(super) label: String,
    pub(super) key_hash: String,
    pub(super) disabled: bool,
    pub(super) limit_micro_usd: Option<i64>,
    pub(super) limit_reset: String,
    pub(super) usage_micro_usd: i64,
    pub(super) rpm_limit: Option<i64>,
    pub(super) itpm_limit: Option<i64>,
    pub(super) otpm_limit: Option<i64>,
    pub(super) allowed_models: String,
    pub(super) self_route_only: bool,
    pub(super) expires_at: Option<String>,
    pub(super) created_at: String,
    pub(super) last_used_at: Option<String>,
}

impl ApiKeyDbRow {
    pub(super) fn into_record(self) -> Result<ApiKeyRecord, IdentityError> {
        Ok(ApiKeyRecord {
            id: self.id,
            owner_account_id: self.owner_account_id,
            name: self.name,
            label: self.label,
            disabled: self.disabled,
            limit_micro_usd: self.limit_micro_usd,
            limit_reset: self.limit_reset,
            usage_micro_usd: self.usage_micro_usd,
            rpm_limit: self.rpm_limit,
            itpm_limit: self.itpm_limit,
            otpm_limit: self.otpm_limit,
            allowed_models: decode_models(&self.allowed_models)?,
            self_route_only: self.self_route_only,
            expires_at: self.expires_at,
            created_at: self.created_at,
            last_used_at: self.last_used_at,
        })
    }
}

#[derive(FromRow)]
pub(super) struct MutationKeyRow {
    pub(super) authority_ok: bool,
    pub(super) expiry_ok: bool,
    pub(super) id: Option<String>,
    pub(super) owner_account_id: Option<String>,
    pub(super) name: Option<String>,
    pub(super) label: Option<String>,
    pub(super) key_hash: Option<String>,
    pub(super) disabled: Option<bool>,
    pub(super) limit_micro_usd: Option<i64>,
    pub(super) limit_reset: Option<String>,
    pub(super) usage_micro_usd: Option<i64>,
    pub(super) rpm_limit: Option<i64>,
    pub(super) itpm_limit: Option<i64>,
    pub(super) otpm_limit: Option<i64>,
    pub(super) allowed_models: Option<String>,
    pub(super) self_route_only: Option<bool>,
    pub(super) expires_at: Option<String>,
    pub(super) created_at: Option<String>,
    pub(super) last_used_at: Option<String>,
}

impl MutationKeyRow {
    pub(super) fn into_record(self) -> Result<ApiKeyRecord, IdentityError> {
        ensure_authority(self.authority_ok)?;
        if !self.expiry_ok {
            return Err(IdentityError::invalid("expires_at must be in the future"));
        }
        ApiKeyDbRow {
            id: self
                .id
                .ok_or_else(|| IdentityError::not_found("key not found"))?,
            owner_account_id: self.owner_account_id.unwrap_or_default(),
            name: self.name.unwrap_or_default(),
            label: self.label.unwrap_or_default(),
            key_hash: self.key_hash.unwrap_or_default(),
            disabled: self.disabled.unwrap_or(false),
            limit_micro_usd: self.limit_micro_usd,
            limit_reset: self.limit_reset.unwrap_or_else(|| "none".to_owned()),
            usage_micro_usd: self.usage_micro_usd.unwrap_or(0),
            rpm_limit: self.rpm_limit,
            itpm_limit: self.itpm_limit,
            otpm_limit: self.otpm_limit,
            allowed_models: self.allowed_models.unwrap_or_default(),
            self_route_only: self.self_route_only.unwrap_or(false),
            expires_at: self.expires_at,
            created_at: self.created_at.unwrap_or_default(),
            last_used_at: self.last_used_at,
        }
        .into_record()
    }
}

pub fn hash_secret(secret: &str) -> String {
    let digest = Sha256::digest(secret.as_bytes());
    encode_hex(&digest)
}

pub(super) fn constant_time_secret_check(expected: &str, stored: Option<&str>) -> bool {
    let dummy = "0000000000000000000000000000000000000000000000000000000000000000";
    let candidate = stored.unwrap_or(dummy);
    let equal = expected.as_bytes().ct_eq(candidate.as_bytes()).unwrap_u8() == 1;
    equal && stored.is_some()
}

pub(super) fn generate_raw_key() -> Result<String, IdentityError> {
    let mut bytes = [0_u8; 32];
    rand::rngs::SysRng
        .try_fill_bytes(&mut bytes)
        .map_err(|_| IdentityError::Unavailable)?;
    Ok(format!("{KEY_PREFIX}{}", encode_hex(&bytes)))
}

pub(super) fn generate_key_id() -> Result<String, IdentityError> {
    let mut bytes = [0_u8; 12];
    rand::rngs::SysRng
        .try_fill_bytes(&mut bytes)
        .map_err(|_| IdentityError::Unavailable)?;
    Ok(format!("key_{}", encode_hex(&bytes)))
}

pub(super) fn key_label(raw: &str) -> String {
    let head = KEY_PREFIX.len() + 4;
    format!("{}…{}", &raw[..head], &raw[raw.len() - 4..])
}

pub(super) fn validate_public_id(value: &str) -> Result<(), IdentityError> {
    if !value.starts_with("key_")
        || value.len() > 64
        || value
            .bytes()
            .any(|byte| !byte.is_ascii_alphanumeric() && byte != b'_')
    {
        return Err(IdentityError::not_found("key not found"));
    }
    Ok(())
}

pub(super) fn validate_raw_secret(value: &str) -> Result<(), IdentityError> {
    if value.is_empty()
        || value.len() > MAXIMUM_SECRET_BYTES
        || value
            .bytes()
            .any(|byte| byte.is_ascii_whitespace() || byte.is_ascii_control())
    {
        return Err(IdentityError::Unauthorized);
    }
    Ok(())
}

pub(super) fn ensure_authority(authority_ok: bool) -> Result<(), IdentityError> {
    if authority_ok {
        Ok(())
    } else {
        Err(IdentityError::OwnershipUnavailable)
    }
}

pub(super) fn is_unique_violation(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(|error| error.code())
        .is_some_and(|code| code == "23505")
}

pub(super) fn is_invalid_timestamp(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(|error| error.code())
        .is_some_and(|code| matches!(code.as_ref(), "22007" | "22008" | "22009"))
}

fn encode_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(char::from(HEX[usize::from(byte >> 4)]));
        encoded.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    encoded
}

fn validate_name(name: &str) -> Result<(), IdentityError> {
    if name.len() > MAXIMUM_NAME_BYTES || name.bytes().any(|byte| byte.is_ascii_control()) {
        return Err(IdentityError::invalid(
            "name must be at most 128 bytes and contain no control characters",
        ));
    }
    Ok(())
}

fn validate_models(models: &[String]) -> Result<String, IdentityError> {
    if models.len() > MAXIMUM_MODELS
        || models.iter().any(|model| {
            model.is_empty()
                || model.len() > MAXIMUM_MODEL_BYTES
                || model.bytes().any(|byte| byte.is_ascii_control())
        })
    {
        return Err(IdentityError::invalid(
            "allowed_models is invalid or too large",
        ));
    }
    serde_json::to_string(models).map_err(|_| IdentityError::invalid("allowed_models is invalid"))
}

fn decode_models(encoded: &str) -> Result<Vec<String>, IdentityError> {
    if encoded.is_empty() {
        return Ok(Vec::new());
    }
    let value: Value = serde_json::from_str(encoded).map_err(|_| {
        IdentityError::Database(sqlx::Error::Decode("invalid allowed_models JSON".into()))
    })?;
    serde_json::from_value(value).map_err(|_| {
        IdentityError::Database(sqlx::Error::Decode("invalid allowed_models JSON".into()))
    })
}

fn normalize_reset(reset: &str) -> Result<String, IdentityError> {
    match reset.trim() {
        "" | "none" => Ok("none".to_owned()),
        "daily" | "weekly" | "monthly" => Ok(reset.trim().to_owned()),
        _ => Err(IdentityError::invalid(
            "limit_reset must be one of none, daily, weekly, or monthly",
        )),
    }
}

fn usd_to_micro(value: f64) -> Result<i64, IdentityError> {
    let micro = value * 1_000_000.0;
    if !value.is_finite() || value < 0.0 || micro > i64::MAX as f64 {
        return Err(IdentityError::invalid(
            "limit_usd must be a finite non-negative value",
        ));
    }
    Ok(micro.round() as i64)
}

fn validate_limit(value: Option<i64>, name: &'static str) -> Result<(), IdentityError> {
    if value.is_some_and(|value| value < 0) {
        return Err(IdentityError::invalid(Cow::Owned(format!(
            "{name} must be non-negative"
        ))));
    }
    Ok(())
}

fn validate_optional_limit(
    value: Option<Option<i64>>,
    name: &'static str,
) -> Result<(), IdentityError> {
    validate_limit(value.flatten(), name)
}

fn validate_timestamp_shape(value: &str) -> Result<(), IdentityError> {
    if value.len() < 20
        || value.len() > 64
        || !value.contains('T')
        || value.bytes().any(|byte| byte.is_ascii_control())
    {
        return Err(IdentityError::invalid(
            "expires_at must be a valid RFC 3339 timestamp",
        ));
    }
    Ok(())
}

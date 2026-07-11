use std::sync::Arc;

use axum::{
    extract::Request,
    http::{HeaderMap, header},
};
use sha2::{Digest as _, Sha256};
use subtle::ConstantTimeEq;

use super::error::BillingError;

const MAX_ID_BYTES: usize = 256;

/// Trusted billing identity installed by the coordinator's authentication
/// layer before this router is called.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BillingPrincipal {
    account_id: Arc<str>,
    email: Arc<str>,
    kind: AuthenticationKind,
    admin: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AuthenticationKind {
    ApiKey,
    Privy,
}

impl BillingPrincipal {
    pub fn new(
        account_id: impl Into<Arc<str>>,
        email: impl Into<Arc<str>>,
        kind: AuthenticationKind,
        admin: bool,
    ) -> Result<Self, BillingError> {
        let account_id = account_id.into();
        validate_identifier(&account_id, "account id")?;
        let email = email.into();
        if email.len() > MAX_ID_BYTES || email.chars().any(char::is_control) {
            return Err(BillingError::bad_request("invalid authenticated email"));
        }
        Ok(Self {
            account_id,
            email,
            kind,
            admin,
        })
    }

    #[must_use]
    pub fn account_id(&self) -> &str {
        &self.account_id
    }

    #[must_use]
    pub fn email(&self) -> &str {
        &self.email
    }

    #[must_use]
    pub const fn kind(&self) -> AuthenticationKind {
        self.kind
    }

    #[must_use]
    pub const fn is_admin(&self) -> bool {
        self.admin
    }
}

pub(super) fn principal(request: &Request) -> Result<&BillingPrincipal, BillingError> {
    request
        .extensions()
        .get::<BillingPrincipal>()
        .ok_or_else(|| BillingError::unauthorized("authenticated account required"))
}

pub(super) fn privy_principal(request: &Request) -> Result<&BillingPrincipal, BillingError> {
    let principal = principal(request)?;
    if principal.kind() != AuthenticationKind::Privy {
        return Err(BillingError::unauthorized(
            "this operation requires an authenticated Privy account",
        ));
    }
    Ok(principal)
}

pub(super) fn require_admin(
    request: &Request,
    configured_admin_key_digest: Option<&[u8; 32]>,
) -> Result<(), BillingError> {
    if request
        .extensions()
        .get::<BillingPrincipal>()
        .is_some_and(BillingPrincipal::is_admin)
    {
        return Ok(());
    }
    let Some(expected) = configured_admin_key_digest else {
        return Err(BillingError::forbidden("admin access required"));
    };
    let Some(token) = bearer(request.headers()) else {
        return Err(BillingError::forbidden("admin access required"));
    };
    let presented: [u8; 32] = Sha256::digest(token.as_bytes()).into();
    if bool::from(presented.ct_eq(expected)) {
        Ok(())
    } else {
        Err(BillingError::forbidden("admin access required"))
    }
}

pub(super) fn idempotency_key(
    headers: &HeaderMap,
    required: bool,
) -> Result<Option<&str>, BillingError> {
    static IDEMPOTENCY_KEY: axum::http::HeaderName =
        axum::http::HeaderName::from_static("idempotency-key");
    let value = headers.get(&IDEMPOTENCY_KEY);
    let Some(value) = value else {
        return if required {
            Err(BillingError::bad_request(
                "Idempotency-Key header is required",
            ))
        } else {
            Ok(None)
        };
    };
    let value = value.to_str().map_err(|_| {
        BillingError::bad_request("Idempotency-Key must contain visible ASCII bytes")
    })?;
    validate_identifier(value, "Idempotency-Key")?;
    Ok(Some(value))
}

pub(super) fn validate_identifier(value: &str, field: &'static str) -> Result<(), BillingError> {
    if value.is_empty()
        || value.len() > MAX_ID_BYTES
        || value.trim() != value
        || value.chars().any(char::is_control)
    {
        return Err(BillingError::bad_request(format!(
            "{field} must be 1..={MAX_ID_BYTES} visible bytes without surrounding whitespace"
        )));
    }
    Ok(())
}

pub(super) fn operation_suffix(scope: &str, key: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(b"darkbloom.billing.operation.v1\0");
    digest.update((scope.len() as u64).to_be_bytes());
    digest.update(scope.as_bytes());
    digest.update((key.len() as u64).to_be_bytes());
    digest.update(key.as_bytes());
    hex(&digest.finalize())
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| !value.is_empty())
}

fn hex(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(ALPHABET[(byte >> 4) as usize] as char);
        output.push(ALPHABET[(byte & 0x0f) as usize] as char);
    }
    output
}

pub(super) fn admin_key_digest(key: &str) -> Option<[u8; 32]> {
    (!key.is_empty()).then(|| Sha256::digest(key.as_bytes()).into())
}

use std::{
    collections::VecDeque,
    fmt,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use axum::{
    extract::Request,
    http::{HeaderMap, HeaderName, header},
};
use sha2::{Digest, Sha256};
use sqlx::Row;
use subtle::ConstantTimeEq;

use crate::database::Database;

use super::error::OperationsError;

const MAX_ADMIN_SESSIONS: usize = 64;
const ADMIN_SESSION_TTL: Duration = Duration::from_secs(60 * 60);

/// Authentication classes are deliberately separate. A release or publishing
/// credential can never authorize an administrator endpoint.
#[derive(Clone, Debug)]
pub struct OperationsAuth {
    pub public: PublicAuth,
    pub admin: ExactBearer,
    pub release: ExactBearer,
    pub publishing: PublishingAuth,
    pub mdm: MdmAuth,
}

/// Trusted identity resolved by the composition-root middleware. This is
/// intentionally distinct from release, publishing, MDM, and exact admin-key
/// credentials.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct OperationsPrincipal {
    admin: bool,
}

impl OperationsPrincipal {
    #[must_use]
    pub(crate) const fn new(admin: bool) -> Self {
        Self { admin }
    }

    #[must_use]
    const fn is_admin(self) -> bool {
        self.admin
    }
}

#[derive(Clone, Debug)]
pub enum PublicAuth {
    Open,
    Bearer(ExactBearer),
}

#[derive(Clone)]
pub struct ExactBearer {
    digest: Option<[u8; 32]>,
}

impl fmt::Debug for ExactBearer {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ExactBearer")
            .field("configured", &self.is_configured())
            .finish()
    }
}

impl ExactBearer {
    #[must_use]
    pub fn disabled() -> Self {
        Self { digest: None }
    }

    pub fn required(secret: &str) -> Result<Self, AuthConfigError> {
        if secret.is_empty() {
            return Err(AuthConfigError::EmptySecret);
        }
        Ok(Self {
            digest: Some(secret_digest(secret)),
        })
    }

    fn accepts(&self, presented: &str) -> bool {
        let Some(expected) = self.digest else {
            return false;
        };
        expected.ct_eq(&secret_digest(presented)).into()
    }

    #[must_use]
    pub const fn is_configured(&self) -> bool {
        self.digest.is_some()
    }
}

#[derive(Clone, Copy, Debug)]
pub struct PublishingAuth {
    pub enabled: bool,
}

#[derive(Clone, Debug)]
pub struct MdmAuth {
    token: ExactBearer,
    pub header_name: Arc<str>,
    pub query_parameter: Arc<str>,
}

impl MdmAuth {
    pub fn required(secret: &str) -> Result<Self, AuthConfigError> {
        Ok(Self {
            token: ExactBearer::required(secret)?,
            header_name: Arc::from("x-webhook-token"),
            query_parameter: Arc::from("token"),
        })
    }

    pub fn with_names(
        secret: &str,
        header_name: impl Into<Arc<str>>,
        query_parameter: impl Into<Arc<str>>,
    ) -> Result<Self, AuthConfigError> {
        let header_name = header_name.into();
        let query_parameter = query_parameter.into();
        if HeaderName::from_bytes(header_name.as_bytes()).is_err()
            || query_parameter.is_empty()
            || query_parameter.len() > 128
            || !query_parameter
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        {
            return Err(AuthConfigError::InvalidMdmParameter);
        }
        Ok(Self {
            token: ExactBearer::required(secret)?,
            header_name,
            query_parameter,
        })
    }

    pub(super) fn accepts(&self, headers: &HeaderMap, query_token: Option<&str>) -> bool {
        let from_header = headers
            .get(self.header_name.as_ref())
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default();
        let presented = if from_header.is_empty() {
            query_token.unwrap_or_default()
        } else {
            from_header
        };
        self.token.accepts(presented)
    }
}

#[derive(Clone, Debug, thiserror::Error)]
pub enum AuthConfigError {
    #[error("authentication secret must not be empty")]
    EmptySecret,
    #[error("MDM header and query parameter names must not be empty")]
    InvalidMdmParameter,
}

#[derive(Debug, Default)]
pub(super) struct AdminSessions {
    sessions: Mutex<VecDeque<AdminSession>>,
}

#[derive(Debug)]
struct AdminSession {
    digest: [u8; 32],
    expires_at: Instant,
}

impl AdminSessions {
    pub(super) fn authorize(&self, token: &str) {
        let now = Instant::now();
        let mut sessions = lock(&self.sessions);
        sessions.retain(|session| session.expires_at > now);
        if sessions.len() == MAX_ADMIN_SESSIONS {
            sessions.pop_front();
        }
        sessions.push_back(AdminSession {
            digest: secret_digest(token),
            expires_at: now + ADMIN_SESSION_TTL,
        });
    }

    fn accepts(&self, token: &str) -> bool {
        if token.is_empty() {
            return false;
        }
        let now = Instant::now();
        let presented = secret_digest(token);
        let mut sessions = lock(&self.sessions);
        sessions.retain(|session| session.expires_at > now);
        sessions
            .iter()
            .any(|session| bool::from(session.digest.ct_eq(&presented)))
    }
}

pub(super) fn require_public(
    auth: &OperationsAuth,
    headers: &HeaderMap,
) -> Result<(), OperationsError> {
    match &auth.public {
        PublicAuth::Open => Ok(()),
        PublicAuth::Bearer(required) if required.accepts(bearer(headers).unwrap_or_default()) => {
            Ok(())
        }
        PublicAuth::Bearer(_) => Err(OperationsError::unauthorized(
            "valid public API bearer credential required",
        )),
    }
}

pub(super) fn require_admin(
    auth: &OperationsAuth,
    sessions: &AdminSessions,
    request: &Request,
) -> Result<(), OperationsError> {
    if request
        .extensions()
        .get::<OperationsPrincipal>()
        .is_some_and(|principal| principal.is_admin())
    {
        return Ok(());
    }
    let token = bearer(request.headers()).unwrap_or_default();
    if auth.admin.accepts(token) || sessions.accepts(token) {
        Ok(())
    } else {
        Err(OperationsError::forbidden("admin access required"))
    }
}

pub(super) fn require_admin_key(
    auth: &OperationsAuth,
    headers: &HeaderMap,
) -> Result<(), OperationsError> {
    if auth.admin.accepts(bearer(headers).unwrap_or_default()) {
        Ok(())
    } else {
        Err(OperationsError::forbidden("admin key required"))
    }
}

pub(super) fn require_release(
    auth: &OperationsAuth,
    headers: &HeaderMap,
) -> Result<(), OperationsError> {
    if auth.release.accepts(bearer(headers).unwrap_or_default()) {
        Ok(())
    } else {
        Err(OperationsError::unauthorized("invalid release key"))
    }
}

pub(super) async fn require_publishing(
    auth: &OperationsAuth,
    database: &Database,
    headers: &HeaderMap,
) -> Result<PublishingActor, OperationsError> {
    let token = bearer(headers).unwrap_or_default();
    if auth.admin.accepts(token) {
        return Ok(PublishingActor {
            id: "admin".to_owned(),
            name: "admin".to_owned(),
        });
    }
    if !auth.publishing.enabled {
        return Err(OperationsError::unavailable(
            "model publishing is not configured",
        ));
    }
    let token = (!token.is_empty())
        .then_some(token)
        .ok_or_else(|| OperationsError::unauthorized("publishing API key required"))?;
    let key_hash = hex_digest(token);
    let mut transaction = database
        .begin_owned()
        .await
        .map_err(|error| OperationsError::internal("begin publishing authentication", error))?;
    let row = sqlx::query(
        r#"
        UPDATE public.publishing_api_keys
        SET last_used_at = NOW()
        WHERE key_hash = $1 AND active
        RETURNING id, name
        "#,
    )
    .bind(key_hash)
    .fetch_optional(transaction.connection())
    .await
    .map_err(|error| OperationsError::internal("authenticate publishing key", error))?
    .ok_or_else(|| OperationsError::unauthorized("invalid publishing API key"))?;
    let actor = PublishingActor {
        id: row.get("id"),
        name: row.get("name"),
    };
    transaction
        .commit()
        .await
        .map_err(|error| OperationsError::internal("commit publishing authentication", error))?;
    Ok(actor)
}

#[derive(Clone, Debug)]
pub(super) struct PublishingActor {
    pub id: String,
    pub name: String,
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| !value.is_empty())
}

fn secret_digest(value: &str) -> [u8; 32] {
    Sha256::digest(value.as_bytes()).into()
}

fn hex_digest(value: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let digest = secret_digest(value);
    let mut encoded = String::with_capacity(64);
    for byte in digest {
        encoded.push(HEX[usize::from(byte >> 4)] as char);
        encoded.push(HEX[usize::from(byte & 0x0f)] as char);
    }
    encoded
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

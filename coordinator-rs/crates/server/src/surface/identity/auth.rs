use std::sync::Arc;

use axum::http::{HeaderMap, header};
use sha2::{Digest as _, Sha256};
use sqlx::FromRow;
use subtle::ConstantTimeEq as _;
use uuid::Uuid;

use super::{
    api_keys::{ApiKeyService, hash_secret},
    error::IdentityError,
    jwks::{PrivyVerifier, PrivyVerifierError},
    store::IdentityStore,
    types::{AuthContext, AuthPrincipal},
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AuthRequirement {
    Privy,
    PrivyOrApiKey,
    ProviderToken,
}

#[derive(Clone, Debug)]
pub struct AuthService {
    store: IdentityStore,
    keys: ApiKeyService,
    privy: PrivyVerifier,
}

impl AuthService {
    pub fn new(store: IdentityStore, keys: ApiKeyService, privy: PrivyVerifier) -> Self {
        Self { store, keys, privy }
    }

    pub async fn authenticate(
        &self,
        headers: &HeaderMap,
        requirement: AuthRequirement,
    ) -> Result<AuthContext, IdentityError> {
        let token = bearer_token(headers)?;
        match requirement {
            AuthRequirement::Privy => self.authenticate_privy(token).await,
            AuthRequirement::ProviderToken => self.authenticate_provider_token(token).await,
            AuthRequirement::PrivyOrApiKey => {
                if looks_like_jwt(token) {
                    self.authenticate_privy(token).await
                } else {
                    self.authenticate_api_key(token).await
                }
            }
        }
    }

    pub async fn authenticate_privy(&self, token: &str) -> Result<AuthContext, IdentityError> {
        if !looks_like_jwt(token) {
            return Err(IdentityError::PrivyRequired);
        }
        let claims = self.privy.verify(token).await.map_err(map_privy_error)?;
        let user = self.get_or_create_user(&claims.subject).await?;
        Ok(AuthContext {
            principal: AuthPrincipal::Privy {
                subject: Arc::from(claims.subject.clone()),
            },
            account_id: Arc::from(user.account_id),
            credential_hash: Arc::from(hash_secret(&claims.subject)),
            email: Arc::from(user.email),
            role: Arc::from(user.role),
            stripe_account_status: Arc::from(user.stripe_account_status),
            api_key: None,
        })
    }

    pub async fn authenticate_api_key(&self, token: &str) -> Result<AuthContext, IdentityError> {
        let key = self.keys.authenticate(token).await?;
        let account_id = if key.owner_account_id.is_empty() {
            Arc::<str>::from(format!("legacy:{}", hash_secret(token)))
        } else {
            Arc::from(key.owner_account_id.clone())
        };
        let user = if key.owner_account_id.is_empty() {
            None
        } else {
            self.user_by_account(&key.owner_account_id).await?
        };
        Ok(AuthContext {
            principal: AuthPrincipal::ApiKey {
                key_id: Arc::from(key.id.clone()),
            },
            account_id,
            credential_hash: Arc::from(hash_secret(token)),
            email: Arc::from(
                user.as_ref()
                    .map_or_else(String::new, |user| user.email.clone()),
            ),
            role: Arc::from(
                user.as_ref()
                    .map_or_else(String::new, |user| user.role.clone()),
            ),
            stripe_account_status: Arc::from(
                user.as_ref()
                    .map_or_else(String::new, |user| user.stripe_account_status.clone()),
            ),
            api_key: Some(key),
        })
    }

    pub async fn authenticate_provider_token(
        &self,
        token: &str,
    ) -> Result<AuthContext, IdentityError> {
        validate_bearer_secret(token)?;
        let hash = hash_secret(token);
        let row = self
            .store
            .bounded(
                sqlx::query_as::<_, ProviderTokenRow>(
                    r#"
                    SELECT token_hash, account_id, label
                    FROM public.provider_tokens
                    WHERE token_hash = $1 AND active = TRUE
                    "#,
                )
                .bind(&hash)
                .fetch_optional(self.store.pool()),
            )
            .await?;
        let stored = row.as_ref().map(|row| row.token_hash.as_str());
        if !constant_time_hash_match(&hash, stored) {
            return Err(IdentityError::Unauthorized);
        }
        let row = row.ok_or(IdentityError::Unauthorized)?;
        let user = self.user_by_account(&row.account_id).await?;
        Ok(AuthContext {
            principal: AuthPrincipal::ProviderToken {
                label: Arc::from(row.label),
            },
            account_id: Arc::from(row.account_id),
            credential_hash: Arc::from(hash),
            email: Arc::from(
                user.as_ref()
                    .map_or_else(String::new, |user| user.email.clone()),
            ),
            role: Arc::from(
                user.as_ref()
                    .map_or_else(String::new, |user| user.role.clone()),
            ),
            stripe_account_status: Arc::from(
                user.as_ref()
                    .map_or_else(String::new, |user| user.stripe_account_status.clone()),
            ),
            api_key: None,
        })
    }

    async fn get_or_create_user(&self, subject: &str) -> Result<UserRow, IdentityError> {
        let candidate_account = Uuid::new_v4().to_string();
        let row = self
            .store
            .bounded(
                sqlx::query_as::<_, UserMutationRow>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT EXISTS (
                            SELECT 1
                            FROM public.coordinator_ownership
                            WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                            FOR SHARE
                        ) AS ok
                    ), resolved AS (
                        INSERT INTO public.users (account_id, privy_user_id, email)
                        SELECT $3, $4, ''
                        FROM authority
                        WHERE ok
                        ON CONFLICT (privy_user_id) DO UPDATE
                        SET privy_user_id = EXCLUDED.privy_user_id
                        RETURNING
                            account_id, email, role,
                            stripe_account_status
                    ), balance AS (
                        INSERT INTO public.balances (
                            account_id, balance_micro_usd, withdrawable_micro_usd
                        )
                        SELECT account_id, 0, 0
                        FROM resolved
                        ON CONFLICT (account_id) DO NOTHING
                    )
                    SELECT
                        authority.ok AS authority_ok,
                        resolved.account_id,
                        resolved.email,
                        resolved.role,
                        resolved.stripe_account_status
                    FROM authority
                    LEFT JOIN resolved ON TRUE
                    "#,
                )
                .bind(self.store.owner_id())
                .bind(self.store.epoch())
                .bind(&candidate_account)
                .bind(subject)
                .fetch_one(self.store.pool()),
            )
            .await?;
        if !row.authority_ok {
            return Err(IdentityError::OwnershipUnavailable);
        }
        row.into_user()
    }

    async fn user_by_account(&self, account_id: &str) -> Result<Option<UserRow>, IdentityError> {
        self.store
            .bounded(
                sqlx::query_as::<_, UserRow>(
                    r#"
                    SELECT
                        account_id, email, role,
                        stripe_account_status
                    FROM public.users
                    WHERE account_id = $1
                    "#,
                )
                .bind(account_id)
                .fetch_optional(self.store.pool()),
            )
            .await
    }
}

fn bearer_token(headers: &HeaderMap) -> Result<&str, IdentityError> {
    let mut values = headers.get_all(header::AUTHORIZATION).iter();
    let value = values.next().ok_or(IdentityError::Unauthorized)?;
    if values.next().is_some() {
        return Err(IdentityError::Unauthorized);
    }
    let value = value.to_str().map_err(|_| IdentityError::Unauthorized)?;
    let token = value
        .strip_prefix("Bearer ")
        .filter(|token| !token.is_empty())
        .ok_or(IdentityError::Unauthorized)?;
    validate_bearer_secret(token)?;
    Ok(token)
}

fn validate_bearer_secret(token: &str) -> Result<(), IdentityError> {
    if token.len() > 16 * 1024
        || token
            .bytes()
            .any(|byte| byte.is_ascii_whitespace() || byte.is_ascii_control())
    {
        return Err(IdentityError::Unauthorized);
    }
    Ok(())
}

fn looks_like_jwt(token: &str) -> bool {
    token.starts_with("eyJ") && token.bytes().filter(|byte| *byte == b'.').count() == 2
}

fn map_privy_error(error: PrivyVerifierError) -> IdentityError {
    match error {
        PrivyVerifierError::InvalidToken | PrivyVerifierError::UnknownKey => {
            IdentityError::Unauthorized
        }
        PrivyVerifierError::InvalidConfiguration
        | PrivyVerifierError::CacheUnavailable
        | PrivyVerifierError::FetchTimeout
        | PrivyVerifierError::RefreshThrottled
        | PrivyVerifierError::Http(_)
        | PrivyVerifierError::JwksStatus(_)
        | PrivyVerifierError::JwksTooLarge
        | PrivyVerifierError::InvalidJwks => IdentityError::Unavailable,
    }
}

fn constant_time_hash_match(expected: &str, stored: Option<&str>) -> bool {
    let missing_hash = "0000000000000000000000000000000000000000000000000000000000000000";
    let equal = expected
        .as_bytes()
        .ct_eq(stored.unwrap_or(missing_hash).as_bytes())
        .unwrap_u8()
        == 1;
    equal && stored.is_some()
}

#[derive(FromRow)]
struct UserRow {
    account_id: String,
    email: String,
    role: String,
    stripe_account_status: String,
}

#[derive(FromRow)]
struct UserMutationRow {
    authority_ok: bool,
    account_id: Option<String>,
    email: Option<String>,
    role: Option<String>,
    stripe_account_status: Option<String>,
}

impl UserMutationRow {
    fn into_user(self) -> Result<UserRow, IdentityError> {
        Ok(UserRow {
            account_id: self.account_id.ok_or(IdentityError::Unavailable)?,
            email: self.email.unwrap_or_default(),
            role: self.role.unwrap_or_default(),
            stripe_account_status: self.stripe_account_status.unwrap_or_default(),
        })
    }
}

#[derive(FromRow)]
struct ProviderTokenRow {
    token_hash: String,
    account_id: String,
    label: String,
}

#[must_use]
pub fn opaque_rate_identity(value: &str) -> String {
    let digest = Sha256::digest(value.as_bytes());
    let mut encoded = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(encoded, "{byte:02x}");
    }
    encoded
}

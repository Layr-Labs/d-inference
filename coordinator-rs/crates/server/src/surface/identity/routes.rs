use std::{
    net::{IpAddr, SocketAddr},
    sync::Arc,
};

use axum::{
    Json, Router,
    body::Bytes,
    extract::{ConnectInfo, DefaultBodyLimit, Path, Request, State},
    http::HeaderMap,
    routing::{delete, get, post},
};
use serde::Deserialize;
use serde_json::Value;
use sqlx::PgPool;

use crate::pilot::PilotHandle;

use super::{
    accounts::AccountService,
    api_keys::{ApiKeyPatch, ApiKeyService},
    auth::{AuthRequirement, AuthService, opaque_rate_identity},
    device::DeviceService,
    error::IdentityError,
    jwks::PrivyVerifier,
    rate::{BoundedRateConfig, BoundedRateLimiter, RateClass, RateLimitHook},
    store::IdentityStore,
    types::{
        ApiKeyCreate, ApiKeyListResponse, ApiKeyResponse, CreatedApiKeyResponse,
        IdentitySurfaceConfig, LegacyCreatedKeyResponse, MutationAuthority, RevokedResponse,
    },
};

#[derive(Clone)]
pub struct IdentityState {
    inner: Arc<IdentityStateInner>,
}

impl std::fmt::Debug for IdentityState {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("IdentityState")
            .finish_non_exhaustive()
    }
}

impl IdentityState {
    pub fn builder(
        pool: PgPool,
        authority: MutationAuthority,
        privy: PrivyVerifier,
    ) -> IdentityStateBuilder {
        IdentityStateBuilder {
            pool,
            authority,
            privy,
            config: IdentitySurfaceConfig::default(),
            rate_limiter: None,
            pilot: None,
        }
    }

    #[must_use]
    pub fn auth(&self) -> &AuthService {
        &self.inner.auth
    }

    #[must_use]
    pub fn keys(&self) -> &ApiKeyService {
        &self.inner.keys
    }

    #[must_use]
    pub fn accounts(&self) -> &AccountService {
        &self.inner.accounts
    }

    #[must_use]
    pub fn devices(&self) -> &DeviceService {
        &self.inner.devices
    }
}

pub struct IdentityStateBuilder {
    pool: PgPool,
    authority: MutationAuthority,
    privy: PrivyVerifier,
    config: IdentitySurfaceConfig,
    rate_limiter: Option<Arc<dyn RateLimitHook>>,
    pilot: Option<PilotHandle>,
}

impl IdentityStateBuilder {
    #[must_use]
    pub fn config(mut self, config: IdentitySurfaceConfig) -> Self {
        self.config = config;
        self
    }

    #[must_use]
    pub fn rate_limiter(mut self, rate_limiter: Arc<dyn RateLimitHook>) -> Self {
        self.rate_limiter = Some(rate_limiter);
        self
    }

    #[must_use]
    pub fn pilot(mut self, pilot: PilotHandle) -> Self {
        self.pilot = Some(pilot);
        self
    }

    pub fn build(self) -> Result<IdentityState, IdentityError> {
        validate_surface_config(&self.config)?;
        let store = IdentityStore::new(self.pool, self.authority, self.config.operation_timeout)?;
        let config = Arc::new(self.config);
        let keys = ApiKeyService::new(store.clone());
        let auth = AuthService::new(store.clone(), keys.clone(), self.privy);
        let mut accounts = AccountService::new(store.clone(), Arc::clone(&config));
        if let Some(pilot) = self.pilot {
            accounts = accounts.with_pilot(pilot);
        }
        let devices = DeviceService::new(store, Arc::clone(&config));
        let rate_limiter = match self.rate_limiter {
            Some(rate_limiter) => rate_limiter,
            None => Arc::new(BoundedRateLimiter::new(BoundedRateConfig::default())?),
        };
        Ok(IdentityState {
            inner: Arc::new(IdentityStateInner {
                auth,
                keys,
                accounts,
                devices,
                config,
                rate_limiter,
            }),
        })
    }
}

struct IdentityStateInner {
    auth: AuthService,
    keys: ApiKeyService,
    accounts: AccountService,
    devices: DeviceService,
    config: Arc<IdentitySurfaceConfig>,
    rate_limiter: Arc<dyn RateLimitHook>,
}

pub fn router(state: IdentityState) -> Router {
    let body_limit = state.inner.config.maximum_body_bytes;
    Router::new()
        .route(
            "/v1/auth/keys",
            post(create_legacy_key).delete(revoke_legacy_key),
        )
        .route("/v1/keys", get(list_keys).post(create_key))
        .route(
            "/v1/keys/{id}",
            get(get_key).patch(update_key).delete(delete_key),
        )
        .route("/v1/keys/{id}/rotate", post(rotate_key))
        .route("/v1/key", get(calling_key))
        .route("/v1/me/providers", get(my_providers))
        .route("/v1/me/summary", get(my_summary))
        .route("/v1/me/self-route-models", get(my_self_route_models))
        .route("/v1/me/providers/{serial}", delete(delete_my_provider))
        .route("/v1/device/code", post(create_device_code))
        .route("/v1/device/token", post(poll_device_token))
        .route("/v1/device/approve", post(approve_device))
        .layer(DefaultBodyLimit::max(body_limit))
        .with_state(state)
}

async fn create_legacy_key(
    State(state): State<IdentityState>,
    headers: HeaderMap,
) -> Result<Json<LegacyCreatedKeyResponse>, IdentityError> {
    let context = state
        .inner
        .auth
        .authenticate(&headers, AuthRequirement::Privy)
        .await?;
    rate_limit(&state, RateClass::Financial, &context.account_id)?;
    let (raw, _) = state
        .inner
        .keys
        .create(&context.account_id, ApiKeyCreate::default())
        .await?;
    Ok(Json(LegacyCreatedKeyResponse {
        api_key: raw,
        account_id: context.account_id,
    }))
}

#[derive(Deserialize)]
struct RevokeLegacyKeyRequest {
    key: String,
}

async fn revoke_legacy_key(
    State(state): State<IdentityState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<RevokedResponse>, IdentityError> {
    let context = state
        .inner
        .auth
        .authenticate(&headers, AuthRequirement::Privy)
        .await?;
    rate_limit(&state, RateClass::Financial, &context.account_id)?;
    let request: RevokeLegacyKeyRequest = parse_required_json(&body)?;
    state
        .inner
        .keys
        .revoke_raw(&context.account_id, &request.key)
        .await?;
    Ok(Json(RevokedResponse { status: "revoked" }))
}

async fn list_keys(
    State(state): State<IdentityState>,
    headers: HeaderMap,
) -> Result<Json<ApiKeyListResponse>, IdentityError> {
    let context = state
        .inner
        .auth
        .authenticate(&headers, AuthRequirement::Privy)
        .await?;
    let data = state
        .inner
        .keys
        .list(&context.account_id)
        .await?
        .into_iter()
        .map(ApiKeyResponse::from)
        .collect();
    Ok(Json(ApiKeyListResponse {
        object: "list",
        data,
    }))
}

async fn create_key(
    State(state): State<IdentityState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<CreatedApiKeyResponse>, IdentityError> {
    let context = state
        .inner
        .auth
        .authenticate(&headers, AuthRequirement::Privy)
        .await?;
    rate_limit(&state, RateClass::Financial, &context.account_id)?;
    let request = parse_optional_json(&body)?;
    let (key, record) = state
        .inner
        .keys
        .create(&context.account_id, request)
        .await?;
    Ok(Json(CreatedApiKeyResponse {
        key,
        data: record.into(),
    }))
}

async fn get_key(
    State(state): State<IdentityState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<ApiKeyResponse>, IdentityError> {
    let context = state
        .inner
        .auth
        .authenticate(&headers, AuthRequirement::Privy)
        .await?;
    Ok(Json(
        state.inner.keys.get(&context.account_id, &id).await?.into(),
    ))
}

async fn update_key(
    State(state): State<IdentityState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    body: Bytes,
) -> Result<Json<ApiKeyResponse>, IdentityError> {
    let context = state
        .inner
        .auth
        .authenticate(&headers, AuthRequirement::Privy)
        .await?;
    rate_limit(&state, RateClass::Financial, &context.account_id)?;
    let patch = parse_key_patch(&body)?;
    Ok(Json(
        state
            .inner
            .keys
            .patch(&context.account_id, &id, patch)
            .await?
            .into(),
    ))
}

async fn delete_key(
    State(state): State<IdentityState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<RevokedResponse>, IdentityError> {
    let context = state
        .inner
        .auth
        .authenticate(&headers, AuthRequirement::Privy)
        .await?;
    rate_limit(&state, RateClass::Financial, &context.account_id)?;
    state.inner.keys.delete(&context.account_id, &id).await?;
    Ok(Json(RevokedResponse { status: "revoked" }))
}

async fn rotate_key(
    State(state): State<IdentityState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<CreatedApiKeyResponse>, IdentityError> {
    let context = state
        .inner
        .auth
        .authenticate(&headers, AuthRequirement::Privy)
        .await?;
    rate_limit(&state, RateClass::Financial, &context.account_id)?;
    let (key, record) = state.inner.keys.rotate(&context.account_id, &id).await?;
    Ok(Json(CreatedApiKeyResponse {
        key,
        data: record.into(),
    }))
}

async fn calling_key(
    State(state): State<IdentityState>,
    request: Request,
) -> Result<Json<ApiKeyResponse>, IdentityError> {
    let context = match request.extensions().get::<super::types::AuthContext>() {
        Some(context) => context.clone(),
        None => {
            state
                .inner
                .auth
                .authenticate(request.headers(), AuthRequirement::PrivyOrApiKey)
                .await?
        }
    };
    let key = context
        .api_key
        .ok_or_else(|| IdentityError::not_found("this endpoint requires API key authentication"))?;
    Ok(Json(key.into()))
}

async fn my_providers(
    State(state): State<IdentityState>,
    headers: HeaderMap,
) -> Result<Json<super::types::ProvidersResponse>, IdentityError> {
    let context = state
        .inner
        .auth
        .authenticate(&headers, AuthRequirement::Privy)
        .await?;
    Ok(Json(
        state.inner.accounts.providers(&context.account_id).await?,
    ))
}

async fn my_summary(
    State(state): State<IdentityState>,
    headers: HeaderMap,
) -> Result<Json<super::types::SummaryResponse>, IdentityError> {
    let context = state
        .inner
        .auth
        .authenticate(&headers, AuthRequirement::Privy)
        .await?;
    let payout_ready = context.stripe_account_status.as_ref() == "ready";
    Ok(Json(
        state
            .inner
            .accounts
            .summary(context.account_id, payout_ready)
            .await?,
    ))
}

async fn my_self_route_models(
    State(state): State<IdentityState>,
    headers: HeaderMap,
) -> Result<Json<super::types::SelfRouteModelsResponse>, IdentityError> {
    let context = state
        .inner
        .auth
        .authenticate(&headers, AuthRequirement::Privy)
        .await?;
    Ok(Json(
        state
            .inner
            .accounts
            .self_route_models(&context.account_id)
            .await?,
    ))
}

async fn delete_my_provider(
    State(state): State<IdentityState>,
    headers: HeaderMap,
    Path(serial): Path<String>,
) -> Result<Json<super::types::DeleteProviderResponse>, IdentityError> {
    let context = state
        .inner
        .auth
        .authenticate(&headers, AuthRequirement::Privy)
        .await?;
    rate_limit(&state, RateClass::Financial, &context.account_id)?;
    Ok(Json(
        state
            .inner
            .accounts
            .delete_provider(&context.account_id, &serial)
            .await?,
    ))
}

async fn create_device_code(
    State(state): State<IdentityState>,
    request: Request,
) -> Result<Json<super::types::DeviceCodeResponse>, IdentityError> {
    let connect_info = request
        .extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .copied();
    let client = public_client_identity(
        connect_info,
        request.headers(),
        &state.inner.config.trusted_proxy_cidrs,
    );
    rate_limit(&state, RateClass::DeviceCode, &client)?;
    Ok(Json(state.inner.devices.create_code().await?))
}

#[derive(Deserialize)]
struct DevicePollRequest {
    device_code: String,
}

async fn poll_device_token(
    State(state): State<IdentityState>,
    body: Bytes,
) -> Result<Json<super::types::DeviceTokenResponse>, IdentityError> {
    let request: DevicePollRequest = parse_required_json(&body)?;
    let identity = opaque_rate_identity(&request.device_code);
    rate_limit(&state, RateClass::DevicePoll, &identity)?;
    Ok(Json(state.inner.devices.poll(&request.device_code).await?))
}

#[derive(Deserialize)]
struct DeviceApprovalRequest {
    user_code: String,
}

async fn approve_device(
    State(state): State<IdentityState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<super::types::DeviceApprovedResponse>, IdentityError> {
    let context = state
        .inner
        .auth
        .authenticate(&headers, AuthRequirement::Privy)
        .await?;
    rate_limit(&state, RateClass::DeviceApprove, &context.account_id)?;
    let request: DeviceApprovalRequest = parse_required_json(&body)?;
    Ok(Json(
        state
            .inner
            .devices
            .approve(&context.account_id, &request.user_code)
            .await?,
    ))
}

fn rate_limit(
    state: &IdentityState,
    class: RateClass,
    identity: &str,
) -> Result<(), IdentityError> {
    state.inner.rate_limiter.check(class, identity)
}

const MAX_FORWARDED_HEADER_BYTES: usize = 1024;
const MAX_FORWARDED_HOPS: usize = 16;

fn public_client_identity(
    connect_info: Option<ConnectInfo<SocketAddr>>,
    headers: &HeaderMap,
    trusted_proxy_cidrs: &[ipnet::IpNet],
) -> String {
    let address = match connect_info {
        None => "transport-identity-unavailable".to_owned(),
        Some(ConnectInfo(peer)) => {
            let peer_ip = peer.ip();
            if trusted_proxy_cidrs
                .iter()
                .any(|network| network.contains(&peer_ip))
            {
                proxy_appended_client_ip(headers)
                    .unwrap_or(peer_ip)
                    .to_string()
            } else {
                peer_ip.to_string()
            }
        }
    };
    opaque_rate_identity(&address)
}

fn proxy_appended_client_ip(headers: &HeaderMap) -> Option<IpAddr> {
    match bounded_single_header(headers, "x-forwarded-for") {
        HeaderState::Valid(value) => return rightmost_x_forwarded_for(value),
        HeaderState::Invalid => return None,
        HeaderState::Absent => {}
    }
    match bounded_single_header(headers, "forwarded") {
        HeaderState::Valid(value) => rightmost_forwarded(value),
        HeaderState::Invalid | HeaderState::Absent => None,
    }
}

enum HeaderState<'a> {
    Absent,
    Invalid,
    Valid(&'a str),
}

fn bounded_single_header<'a>(headers: &'a HeaderMap, name: &str) -> HeaderState<'a> {
    let mut values = headers.get_all(name).iter();
    let Some(value) = values.next() else {
        return HeaderState::Absent;
    };
    if values.next().is_some()
        || value.as_bytes().len() > MAX_FORWARDED_HEADER_BYTES
        || value.as_bytes().contains(&b'\0')
    {
        return HeaderState::Invalid;
    }
    match value.to_str() {
        Ok(value) => HeaderState::Valid(value),
        Err(_) => HeaderState::Invalid,
    }
}

fn rightmost_x_forwarded_for(value: &str) -> Option<IpAddr> {
    let hops = value.split(',').map(str::trim).collect::<Vec<_>>();
    if hops.is_empty() || hops.len() > MAX_FORWARDED_HOPS || hops.iter().any(|hop| hop.is_empty()) {
        return None;
    }
    hops.last()?.parse().ok()
}

fn rightmost_forwarded(value: &str) -> Option<IpAddr> {
    let hops = value.split(',').map(str::trim).collect::<Vec<_>>();
    if hops.is_empty() || hops.len() > MAX_FORWARDED_HOPS || hops.iter().any(|hop| hop.is_empty()) {
        return None;
    }
    let mut forwarded_for = None;
    for parameter in hops.last()?.split(';') {
        let (name, value) = parameter.trim().split_once('=')?;
        if name.trim().eq_ignore_ascii_case("for") {
            if forwarded_for.is_some() {
                return None;
            }
            forwarded_for = Some(value.trim().trim_matches('"'));
        }
    }
    parse_forwarded_for(forwarded_for?)
}

fn parse_forwarded_for(value: &str) -> Option<IpAddr> {
    if value.is_empty() || value.eq_ignore_ascii_case("unknown") || value.starts_with('_') {
        return None;
    }
    if let Ok(ip) = value.parse() {
        return Some(ip);
    }
    if let Ok(socket) = value.parse::<SocketAddr>() {
        return Some(socket.ip());
    }
    if let Some(rest) = value.strip_prefix('[') {
        let (ip, suffix) = rest.split_once(']')?;
        if !suffix.is_empty()
            && (!suffix.starts_with(':')
                || suffix[1..].is_empty()
                || !suffix[1..].bytes().all(|byte| byte.is_ascii_digit()))
        {
            return None;
        }
        return ip.parse().ok();
    }
    None
}

fn parse_required_json<T: serde::de::DeserializeOwned>(body: &[u8]) -> Result<T, IdentityError> {
    if body.is_empty() {
        return Err(IdentityError::invalid("JSON body is required"));
    }
    serde_json::from_slice(body).map_err(|_| IdentityError::invalid("invalid JSON body"))
}

fn parse_optional_json<T>(body: &[u8]) -> Result<T, IdentityError>
where
    T: serde::de::DeserializeOwned + Default,
{
    if body.is_empty() {
        Ok(T::default())
    } else {
        parse_required_json(body)
    }
}

fn parse_key_patch(body: &[u8]) -> Result<ApiKeyPatch, IdentityError> {
    let Value::Object(mut fields) =
        serde_json::from_slice(body).map_err(|_| IdentityError::invalid("invalid JSON body"))?
    else {
        return Err(IdentityError::invalid("JSON object is required"));
    };
    let allowed = [
        "name",
        "disabled",
        "limit_usd",
        "limit_reset",
        "rpm_limit",
        "itpm_limit",
        "otpm_limit",
        "allowed_models",
        "self_route_only",
        "expires_at",
    ];
    if fields.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(IdentityError::invalid("patch contains an unknown field"));
    }
    Ok(ApiKeyPatch {
        name: take_typed(&mut fields, "name")?,
        disabled: take_typed(&mut fields, "disabled")?,
        limit_micro_usd: take_nullable_f64(&mut fields, "limit_usd")?,
        limit_reset: take_typed(&mut fields, "limit_reset")?,
        rpm_limit: take_nullable(&mut fields, "rpm_limit")?,
        itpm_limit: take_nullable(&mut fields, "itpm_limit")?,
        otpm_limit: take_nullable(&mut fields, "otpm_limit")?,
        allowed_models: take_nullable(&mut fields, "allowed_models")?
            .map(Option::unwrap_or_default),
        self_route_only: take_typed(&mut fields, "self_route_only")?,
        expires_at: take_nullable(&mut fields, "expires_at")?,
    })
}

fn take_typed<T: serde::de::DeserializeOwned>(
    fields: &mut serde_json::Map<String, Value>,
    name: &str,
) -> Result<Option<T>, IdentityError> {
    fields
        .remove(name)
        .map(|value| {
            serde_json::from_value(value)
                .map_err(|_| IdentityError::invalid(format!("invalid value for {name}")))
        })
        .transpose()
}

fn take_nullable<T: serde::de::DeserializeOwned>(
    fields: &mut serde_json::Map<String, Value>,
    name: &str,
) -> Result<Option<Option<T>>, IdentityError> {
    let Some(value) = fields.remove(name) else {
        return Ok(None);
    };
    if value.is_null() {
        Ok(Some(None))
    } else {
        serde_json::from_value(value)
            .map(Some)
            .map(Some)
            .map_err(|_| IdentityError::invalid(format!("invalid value for {name}")))
    }
}

fn take_nullable_f64(
    fields: &mut serde_json::Map<String, Value>,
    name: &str,
) -> Result<Option<Option<i64>>, IdentityError> {
    let value: Option<Option<f64>> = take_nullable(fields, name)?;
    value
        .map(|value| value.map(usd_to_micro).transpose())
        .transpose()
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

fn validate_surface_config(config: &IdentitySurfaceConfig) -> Result<(), IdentityError> {
    if config.operation_timeout.is_zero()
        || config.console_url.is_empty()
        || config.maximum_body_bytes == 0
        || config.maximum_body_bytes > 1024 * 1024
        || config.heartbeat_timeout.is_zero()
        || config.challenge_max_age.is_zero()
    {
        return Err(IdentityError::Unavailable);
    }
    Ok(())
}

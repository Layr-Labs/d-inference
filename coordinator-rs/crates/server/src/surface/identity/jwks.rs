use std::{
    collections::BTreeMap,
    sync::{Arc, RwLock},
    time::{Duration, Instant},
};

use futures_util::StreamExt as _;
use jsonwebtoken::{
    Algorithm, DecodingKey, Validation, decode, decode_header,
    jwk::{AlgorithmParameters, EllipticCurve, JwkSet, KeyAlgorithm, KeyOperations, PublicKeyUse},
};
use reqwest::{Client, Url, header};
use serde::Deserialize;
use thiserror::Error;
use tokio::{sync::Mutex, time::timeout};

const MAX_TOKEN_BYTES: usize = 16 * 1024;
const MAX_KEY_ID_BYTES: usize = 128;
const MAX_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MIN_CACHE_TTL: Duration = Duration::from_millis(1);
const MAX_CACHE_TTL: Duration = Duration::from_secs(24 * 60 * 60);
const MAX_CLOCK_SKEW: Duration = Duration::from_secs(5 * 60);

#[derive(Clone, Debug)]
pub struct PrivyVerifierConfig {
    pub issuer: String,
    pub audience: String,
    pub jwks_url: Url,
    pub request_timeout: Duration,
    pub cache_ttl: Duration,
    pub minimum_refresh_interval: Duration,
    pub maximum_keys: usize,
    pub maximum_jwks_bytes: usize,
    pub clock_skew: Duration,
    pub subject_prefix: String,
}

impl PrivyVerifierConfig {
    pub fn production(audience: impl Into<String>, jwks_url: Url) -> Self {
        Self {
            issuer: "privy.io".to_owned(),
            audience: audience.into(),
            jwks_url,
            request_timeout: Duration::from_secs(5),
            cache_ttl: Duration::from_secs(5 * 60),
            minimum_refresh_interval: Duration::from_secs(5),
            maximum_keys: 16,
            maximum_jwks_bytes: 256 * 1024,
            clock_skew: Duration::from_secs(30),
            subject_prefix: "did:privy:".to_owned(),
        }
    }

    fn validate(&self) -> Result<(), PrivyVerifierError> {
        if self.issuer.is_empty()
            || self.audience.is_empty()
            || self.subject_prefix.is_empty()
            || self.request_timeout.is_zero()
            || self.request_timeout > MAX_REQUEST_TIMEOUT
            || self.cache_ttl < MIN_CACHE_TTL
            || self.cache_ttl > MAX_CACHE_TTL
            || self.minimum_refresh_interval.is_zero()
            || self.minimum_refresh_interval > self.cache_ttl
            || self.clock_skew > MAX_CLOCK_SKEW
            || self.maximum_keys == 0
            || self.maximum_keys > 64
            || !(1024..=1024 * 1024).contains(&self.maximum_jwks_bytes)
        {
            return Err(PrivyVerifierError::InvalidConfiguration);
        }
        if self.jwks_url.scheme() != "https"
            && !(self.jwks_url.scheme() == "http"
                && self.jwks_url.host_str().is_some_and(|host| {
                    host == "127.0.0.1" || host == "::1" || host == "localhost"
                }))
        {
            return Err(PrivyVerifierError::InvalidConfiguration);
        }
        if self.jwks_url.host_str().is_none()
            || !self.jwks_url.username().is_empty()
            || self.jwks_url.password().is_some()
            || self.jwks_url.fragment().is_some()
        {
            return Err(PrivyVerifierError::InvalidConfiguration);
        }
        Ok(())
    }
}

#[derive(Clone)]
pub struct PrivyVerifier {
    config: Arc<PrivyVerifierConfig>,
    client: Client,
    cache: Arc<RwLock<KeyCache>>,
    refresh: Arc<Mutex<()>>,
}

impl std::fmt::Debug for PrivyVerifier {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("PrivyVerifier")
            .field("issuer", &self.config.issuer)
            .field("audience", &self.config.audience)
            .field("jwks_url", &self.config.jwks_url)
            .finish_non_exhaustive()
    }
}

impl PrivyVerifier {
    pub fn new(config: PrivyVerifierConfig) -> Result<Self, PrivyVerifierError> {
        config.validate()?;
        let client = Client::builder()
            .timeout(config.request_timeout)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(PrivyVerifierError::Http)?;
        Ok(Self {
            config: Arc::new(config),
            client,
            cache: Arc::new(RwLock::new(KeyCache::default())),
            refresh: Arc::new(Mutex::new(())),
        })
    }

    pub async fn verify(&self, token: &str) -> Result<VerifiedPrivyClaims, PrivyVerifierError> {
        if token.is_empty() || token.len() > MAX_TOKEN_BYTES {
            return Err(PrivyVerifierError::InvalidToken);
        }
        let header = decode_header(token).map_err(|_| PrivyVerifierError::InvalidToken)?;
        if header.alg != Algorithm::ES256 {
            return Err(PrivyVerifierError::InvalidToken);
        }
        let key_id = header.kid.ok_or(PrivyVerifierError::InvalidToken)?;
        if key_id.is_empty()
            || key_id.len() > MAX_KEY_ID_BYTES
            || key_id.bytes().any(|byte| byte.is_ascii_control())
        {
            return Err(PrivyVerifierError::InvalidToken);
        }
        let key = self.key_for(&key_id).await?;
        let mut validation = Validation::new(Algorithm::ES256);
        validation.set_issuer(&[self.config.issuer.as_str()]);
        validation.set_audience(&[self.config.audience.as_str()]);
        validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
        validation.validate_nbf = true;
        validation.leeway = self.config.clock_skew.as_secs();
        let claims = decode::<PrivyClaims>(token, &key, &validation)
            .map_err(|_| PrivyVerifierError::InvalidToken)?
            .claims;
        if claims.sub.len() > 256
            || !claims.sub.starts_with(&self.config.subject_prefix)
            || claims.sub.bytes().any(|byte| byte.is_ascii_control())
        {
            return Err(PrivyVerifierError::InvalidToken);
        }
        Ok(VerifiedPrivyClaims {
            subject: claims.sub,
            expires_at: claims.exp,
            not_before: claims.nbf,
        })
    }

    async fn key_for(&self, key_id: &str) -> Result<Arc<DecodingKey>, PrivyVerifierError> {
        let now = Instant::now();
        {
            let cache = self
                .cache
                .read()
                .map_err(|_| PrivyVerifierError::CacheUnavailable)?;
            if cache.expires_at.is_some_and(|expires_at| expires_at > now)
                && let Some(key) = cache.keys.get(key_id)
            {
                return Ok(Arc::clone(key));
            }
        }

        let _refresh_guard = self.refresh.lock().await;
        let now = Instant::now();
        {
            let cache = self
                .cache
                .read()
                .map_err(|_| PrivyVerifierError::CacheUnavailable)?;
            if cache.expires_at.is_some_and(|expires_at| expires_at > now)
                && let Some(key) = cache.keys.get(key_id)
            {
                return Ok(Arc::clone(key));
            }
            if cache.attempted_at.is_some_and(|attempted_at| {
                now.duration_since(attempted_at) < self.config.minimum_refresh_interval
            }) {
                return if cache.expires_at.is_some_and(|expires_at| expires_at > now) {
                    Err(PrivyVerifierError::UnknownKey)
                } else {
                    Err(PrivyVerifierError::RefreshThrottled)
                };
            }
        }

        self.cache
            .write()
            .map_err(|_| PrivyVerifierError::CacheUnavailable)?
            .attempted_at = Some(now);
        let fetched = timeout(self.config.request_timeout, self.fetch_keys())
            .await
            .map_err(|_| PrivyVerifierError::FetchTimeout)??;
        let key = fetched.keys.get(key_id).cloned();
        let mut cache = self
            .cache
            .write()
            .map_err(|_| PrivyVerifierError::CacheUnavailable)?;
        *cache = fetched;
        key.ok_or(PrivyVerifierError::UnknownKey)
    }

    async fn fetch_keys(&self) -> Result<KeyCache, PrivyVerifierError> {
        let response = self
            .client
            .get(self.config.jwks_url.clone())
            .header(header::ACCEPT, "application/json")
            .send()
            .await
            .map_err(PrivyVerifierError::Http)?;
        if !response.status().is_success() {
            return Err(PrivyVerifierError::JwksStatus(response.status()));
        }
        if response
            .content_length()
            .is_some_and(|length| length > self.config.maximum_jwks_bytes as u64)
        {
            return Err(PrivyVerifierError::JwksTooLarge);
        }
        let cache_ttl = response_cache_ttl(response.headers(), self.config.cache_ttl);
        let mut bytes = Vec::new();
        let mut stream = response.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(PrivyVerifierError::Http)?;
            if bytes.len().saturating_add(chunk.len()) > self.config.maximum_jwks_bytes {
                return Err(PrivyVerifierError::JwksTooLarge);
            }
            bytes.extend_from_slice(&chunk);
        }
        let set: JwkSet =
            serde_json::from_slice(&bytes).map_err(|_| PrivyVerifierError::InvalidJwks)?;
        if set.keys.is_empty() || set.keys.len() > self.config.maximum_keys {
            return Err(PrivyVerifierError::InvalidJwks);
        }
        let mut keys = BTreeMap::new();
        for jwk in set.keys {
            if jwk.common.key_algorithm != Some(KeyAlgorithm::ES256)
                || jwk
                    .common
                    .public_key_use
                    .as_ref()
                    .is_some_and(|usage| usage != &PublicKeyUse::Signature)
                || jwk
                    .common
                    .key_operations
                    .as_ref()
                    .is_some_and(|operations| !operations.contains(&KeyOperations::Verify))
                || !matches!(
                    &jwk.algorithm,
                    AlgorithmParameters::EllipticCurve(parameters)
                        if parameters.curve == EllipticCurve::P256
                )
            {
                continue;
            }
            let key_id = jwk
                .common
                .key_id
                .as_deref()
                .filter(|key_id| {
                    !key_id.is_empty()
                        && key_id.len() <= MAX_KEY_ID_BYTES
                        && !key_id.bytes().any(|byte| byte.is_ascii_control())
                })
                .ok_or(PrivyVerifierError::InvalidJwks)?;
            let decoding_key =
                DecodingKey::from_jwk(&jwk).map_err(|_| PrivyVerifierError::InvalidJwks)?;
            if keys
                .insert(key_id.to_owned(), Arc::new(decoding_key))
                .is_some()
            {
                return Err(PrivyVerifierError::InvalidJwks);
            }
        }
        if keys.is_empty() {
            return Err(PrivyVerifierError::InvalidJwks);
        }
        let now = Instant::now();
        Ok(KeyCache {
            keys,
            attempted_at: Some(now),
            expires_at: Some(now + cache_ttl),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedPrivyClaims {
    pub subject: String,
    pub expires_at: u64,
    pub not_before: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct PrivyClaims {
    sub: String,
    exp: u64,
    #[serde(default)]
    nbf: Option<u64>,
}

#[derive(Default)]
struct KeyCache {
    keys: BTreeMap<String, Arc<DecodingKey>>,
    attempted_at: Option<Instant>,
    expires_at: Option<Instant>,
}

fn response_cache_ttl(headers: &reqwest::header::HeaderMap, maximum: Duration) -> Duration {
    let advertised = headers
        .get(header::CACHE_CONTROL)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| {
            value.split(',').find_map(|directive| {
                directive
                    .trim()
                    .strip_prefix("max-age=")
                    .and_then(|seconds| seconds.parse::<u64>().ok())
            })
        })
        .map(Duration::from_secs)
        .unwrap_or(maximum);
    advertised.clamp(MIN_CACHE_TTL, maximum)
}

#[derive(Debug, Error)]
pub enum PrivyVerifierError {
    #[error("invalid Privy verifier configuration")]
    InvalidConfiguration,
    #[error("invalid Privy access token")]
    InvalidToken,
    #[error("Privy signing key is not present")]
    UnknownKey,
    #[error("Privy JWKS cache is unavailable")]
    CacheUnavailable,
    #[error("Privy JWKS request timed out")]
    FetchTimeout,
    #[error("Privy JWKS refresh is temporarily throttled")]
    RefreshThrottled,
    #[error("Privy JWKS request failed: {0}")]
    Http(#[source] reqwest::Error),
    #[error("Privy JWKS endpoint returned {0}")]
    JwksStatus(reqwest::StatusCode),
    #[error("Privy JWKS response exceeded its configured bound")]
    JwksTooLarge,
    #[error("Privy JWKS response was invalid")]
    InvalidJwks,
}

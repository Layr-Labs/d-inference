use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use axum::{
    Json, Router,
    body::{Body, to_bytes},
    extract::State,
    http::{Method, Request, StatusCode, header},
    routing::get,
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use p256::{
    ecdsa::SigningKey,
    elliptic_curve::Generate as _,
    pkcs8::{EncodePrivateKey as _, LineEnding},
};
use serde::Serialize;
use serde_json::{Value, json};
use tokio::{net::TcpListener, task::JoinHandle};
use tower::ServiceExt as _;
use url::Url;

use super::super::{PrivyVerifier, PrivyVerifierConfig};

pub(super) const TEST_ISSUER: &str = "privy.io";
pub(super) const TEST_AUDIENCE: &str = "test-privy-app";
const TEST_KID: &str = "identity-test-key";

pub(super) struct JwtFixture {
    encoding_key: EncodingKey,
    verifier: PrivyVerifier,
    requests: Arc<AtomicUsize>,
    server: JoinHandle<()>,
}

impl JwtFixture {
    pub(super) async fn start() -> Self {
        Self::start_with_timing(Duration::from_secs(60), Duration::from_millis(50)).await
    }

    pub(super) async fn start_with_timing(
        cache_ttl: Duration,
        minimum_refresh_interval: Duration,
    ) -> Self {
        let signing_key = SigningKey::generate();
        let verifying_key = signing_key.verifying_key();
        let point = verifying_key.to_sec1_point(false);
        let jwks = json!({
            "keys": [{
                "kty": "EC",
                "crv": "P-256",
                "x": URL_SAFE_NO_PAD.encode(point.x().expect("P-256 x coordinate")),
                "y": URL_SAFE_NO_PAD.encode(point.y().expect("P-256 y coordinate")),
                "alg": "ES256",
                "use": "sig",
                "key_ops": ["verify"],
                "kid": TEST_KID
            }]
        });
        let requests = Arc::new(AtomicUsize::new(0));
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind test JWKS server");
        let address = listener.local_addr().expect("test JWKS address");
        let state = Arc::new(JwksState {
            document: jwks,
            requests: Arc::clone(&requests),
        });
        let app = Router::new()
            .route("/jwks", get(jwks_document))
            .with_state(state);
        let server = tokio::spawn(async move {
            axum::serve(listener, app)
                .await
                .expect("serve test JWKS document");
        });
        let private_pem = signing_key
            .to_pkcs8_pem(LineEnding::LF)
            .expect("encode test ES256 key");
        let encoding_key =
            EncodingKey::from_ec_pem(private_pem.as_bytes()).expect("parse test ES256 key");
        let verifier = PrivyVerifier::new(PrivyVerifierConfig {
            issuer: TEST_ISSUER.to_owned(),
            audience: TEST_AUDIENCE.to_owned(),
            jwks_url: Url::parse(&format!("http://{address}/jwks")).expect("test JWKS URL"),
            request_timeout: Duration::from_millis(500),
            cache_ttl,
            minimum_refresh_interval,
            maximum_keys: 2,
            maximum_jwks_bytes: 16 * 1024,
            clock_skew: Duration::ZERO,
            subject_prefix: "did:privy:".to_owned(),
        })
        .expect("build test Privy verifier");
        Self {
            encoding_key,
            verifier,
            requests,
            server,
        }
    }

    pub(super) fn verifier(&self) -> PrivyVerifier {
        self.verifier.clone()
    }

    pub(super) fn valid_token(&self, subject: &str) -> String {
        self.token(TokenClaims::valid(subject))
    }

    pub(super) fn token(&self, claims: TokenClaims) -> String {
        self.token_with_kid(claims, TEST_KID)
    }

    pub(super) fn token_with_kid(&self, claims: TokenClaims, key_id: &str) -> String {
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(key_id.to_owned());
        encode(&header, &claims, &self.encoding_key).expect("sign test Privy token")
    }

    pub(super) fn request_count(&self) -> usize {
        self.requests.load(Ordering::Acquire)
    }

    pub(super) fn stop_server(&self) {
        self.server.abort();
    }
}

impl Drop for JwtFixture {
    fn drop(&mut self) {
        self.server.abort();
    }
}

#[derive(Clone, Debug, Serialize)]
pub(super) struct TokenClaims {
    pub(super) iss: String,
    pub(super) aud: String,
    pub(super) sub: String,
    pub(super) exp: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) nbf: Option<u64>,
}

impl TokenClaims {
    pub(super) fn valid(subject: &str) -> Self {
        Self {
            iss: TEST_ISSUER.to_owned(),
            aud: TEST_AUDIENCE.to_owned(),
            sub: subject.to_owned(),
            exp: unix_time().saturating_add(3_600),
            nbf: None,
        }
    }
}

pub(super) async fn call(
    router: &Router,
    method: Method,
    uri: &str,
    bearer: Option<&str>,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let encoded = body.map_or_else(Vec::new, |value| {
        serde_json::to_vec(&value).expect("encode test request")
    });
    let mut request = Request::builder().method(method).uri(uri);
    if let Some(token) = bearer {
        request = request.header(header::AUTHORIZATION, format!("Bearer {token}"));
    }
    if !encoded.is_empty() {
        request = request.header(header::CONTENT_TYPE, "application/json");
    }
    let response = router
        .clone()
        .oneshot(
            request
                .body(Body::from(encoded))
                .expect("build identity test request"),
        )
        .await
        .expect("call identity router");
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 2 * 1024 * 1024)
        .await
        .expect("read identity response");
    let payload = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or_else(|error| {
            panic!(
                "identity response was not JSON: {error}; body={}",
                String::from_utf8_lossy(&bytes)
            )
        })
    };
    (status, payload)
}

pub(super) fn unix_time() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock after Unix epoch")
        .as_secs()
}

struct JwksState {
    document: Value,
    requests: Arc<AtomicUsize>,
}

async fn jwks_document(State(state): State<Arc<JwksState>>) -> Json<Value> {
    state.requests.fetch_add(1, Ordering::AcqRel);
    Json(state.document.clone())
}

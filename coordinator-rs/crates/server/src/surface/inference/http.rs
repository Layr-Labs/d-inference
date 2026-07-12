use std::{
    borrow::Cow,
    collections::VecDeque,
    io,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use axum::{
    Json,
    body::{Body, Bytes, to_bytes},
    extract::{Extension, Request, State},
    http::{HeaderMap, HeaderValue, Response, StatusCode, header},
    response::IntoResponse,
};
use futures_util::stream;
use serde::Serialize;
use tokio::sync::{OwnedSemaphorePermit, oneshot};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{
    crypto::X25519PublicKey,
    pilot::{
        BillingContext, DurableRequestIdentity, INPUT_RESERVATION_BYTES,
        MAX_CONSUMER_RESPONSE_BYTES, PilotHandle, PilotRequestControls, PilotRequestError,
        PilotRequestJob, PilotResponse, parse_request_facts, request_id_from_idempotency,
    },
    request::BytePipeReceiver,
    surface::{FullSurfaceBuildError, FullSurfaceState, identity::AuthContext},
    telemetry::datadog::{self, Metric, Tag, TagKey},
};

use super::{
    AdaptedStreamFailure, AdapterContext, AdapterError, AnthropicStreamAdapter,
    CanonicalChatRequest, CompletionsStreamAdapter, InferenceControlError, InferenceSurface,
    ResponsesStreamAdapter, SEALED_CONTENT_TYPE, adapt_anthropic_nonstream,
    adapt_completions_nonstream, adapt_responses_nonstream, open_transport_request,
    parse_anthropic_request, parse_completions_request, parse_responses_request,
};

const X_EIGEN_SEALED: &str = "x-eigen-sealed";
const X_EIGEN_SEALED_KID: &str = "x-eigen-sealed-kid";

pub async fn chat(
    State(state): State<FullSurfaceState>,
    Extension(auth): Extension<AuthContext>,
    Extension(billing): Extension<BillingContext>,
    request: Request,
) -> Result<Response<Body>, InferenceHttpError> {
    let input = read_input(request, &state.pilot).await?;
    let dispatched = dispatch(&state, &auth, billing, input, None).await?;
    Ok(crate::http::response::consumer_response(
        dispatched.response,
        state.pilot,
        dispatched.sender,
    ))
}

pub async fn responses(
    State(state): State<FullSurfaceState>,
    Extension(auth): Extension<AuthContext>,
    Extension(billing): Extension<BillingContext>,
    request: Request,
) -> Result<Response<Body>, InferenceHttpError> {
    adapted(state, auth, billing, request, InferenceSurface::Responses).await
}

pub async fn completions(
    State(state): State<FullSurfaceState>,
    Extension(auth): Extension<AuthContext>,
    Extension(billing): Extension<BillingContext>,
    request: Request,
) -> Result<Response<Body>, InferenceHttpError> {
    adapted(state, auth, billing, request, InferenceSurface::Completions).await
}

pub async fn messages(
    State(state): State<FullSurfaceState>,
    Extension(auth): Extension<AuthContext>,
    Extension(billing): Extension<BillingContext>,
    request: Request,
) -> Result<Response<Body>, InferenceHttpError> {
    adapted(
        state,
        auth,
        billing,
        request,
        InferenceSurface::AnthropicMessages,
    )
    .await
}

async fn adapted(
    state: FullSurfaceState,
    auth: AuthContext,
    billing: BillingContext,
    request: Request,
    surface: InferenceSurface,
) -> Result<Response<Body>, InferenceHttpError> {
    adapted_request(state, auth, billing, request, surface)
        .await
        .map_err(|error| error.for_surface(surface))
}

async fn adapted_request(
    state: FullSurfaceState,
    auth: AuthContext,
    billing: BillingContext,
    request: Request,
    surface: InferenceSurface,
) -> Result<Response<Body>, InferenceHttpError> {
    let input = read_input(request, &state.pilot).await?;
    let canonical = match surface {
        InferenceSurface::Responses => parse_responses_request(&input.plaintext),
        InferenceSurface::Completions => parse_completions_request(&input.plaintext),
        InferenceSurface::AnthropicMessages => parse_anthropic_request(&input.plaintext),
    }?;
    let stream = canonical.stream();
    let context_model = canonical.model().to_owned();
    let maximum_output_tokens = canonical.maximum_output_tokens();
    let dispatched = dispatch(&state, &auth, billing, input, Some(canonical)).await?;
    let context = AdapterContext {
        request_id: dispatched.request_id.to_string(),
        model: context_model,
        created_at: unix_seconds(),
        maximum_output_tokens,
    };
    if stream {
        stream_response(
            dispatched.response.body,
            StreamAdapter::new(surface, context),
            state.pilot,
            dispatched.sender,
        )
        .await
    } else {
        nonstream_response(
            dispatched.response.body,
            surface,
            &context,
            &state.pilot,
            dispatched.sender,
        )
        .await
    }
}

struct OpenedInput {
    headers: HeaderMap,
    plaintext: Vec<u8>,
    sender: Option<X25519PublicKey>,
    input_permit: OwnedSemaphorePermit,
}

async fn read_input(
    request: Request,
    pilot: &PilotHandle,
) -> Result<OpenedInput, InferenceHttpError> {
    let started = std::time::Instant::now();
    let result = read_input_unobserved(request, pilot).await;
    observe_stage(
        "parse",
        started.elapsed(),
        std::time::Duration::from_secs(2),
        if result.is_ok() { "success" } else { "failure" },
    );
    result
}

async fn read_input_unobserved(
    request: Request,
    pilot: &PilotHandle,
) -> Result<OpenedInput, InferenceHttpError> {
    let input_permit = pilot
        .try_reserve_input(INPUT_RESERVATION_BYTES)
        .map_err(|error| InferenceHttpError::capacity(error.to_string()))?;
    let (parts, body) = request.into_parts();
    if parts
        .headers
        .get(header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<usize>().ok())
        .is_some_and(|length| length > super::MAX_BODY_BYTES)
    {
        return Err(AdapterError::payload_too_large().into());
    }
    let bytes = to_bytes(body, super::MAX_BODY_BYTES)
        .await
        .map_err(|_| AdapterError::payload_too_large())?;
    let content_type = parts
        .headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok());
    let opened = open_transport_request(content_type, &bytes, pilot.keyring())?;
    Ok(OpenedInput {
        headers: parts.headers,
        plaintext: opened.plaintext().to_vec(),
        sender: opened.sender(),
        input_permit,
    })
}

struct Dispatched {
    response: PilotResponse,
    sender: Option<X25519PublicKey>,
    request_id: Uuid,
}

async fn dispatch(
    state: &FullSurfaceState,
    auth: &AuthContext,
    billing: BillingContext,
    mut input: OpenedInput,
    canonical: Option<CanonicalChatRequest>,
) -> Result<Dispatched, InferenceHttpError> {
    if !state.pilot.is_ready() {
        return Err(InferenceHttpError::unavailable(
            "private inference runtime is unavailable",
        ));
    }
    if let Some(canonical) = canonical {
        input.plaintext = canonical.into_body();
    }
    let request_id = durable_request_id(&input.headers, &auth.account_id)?;
    let prepare_started = std::time::Instant::now();
    let prepared = state
        .inference_control
        .prepare(auth, &input.plaintext)
        .await;
    observe_stage(
        "prepare",
        prepare_started.elapsed(),
        std::time::Duration::from_secs(3),
        if prepared.is_ok() {
            "success"
        } else {
            "failure"
        },
    );
    let prepared = prepared?;
    let parse_started = std::time::Instant::now();
    let parsed = parse_request_facts(
        &input.plaintext,
        &prepared.catalog.concrete_model,
        &prepared.catalog.public_model,
    );
    observe_stage(
        "parse",
        parse_started.elapsed(),
        std::time::Duration::from_millis(250),
        if parsed.is_ok() { "success" } else { "failure" },
    );
    let (model, _requested_model, output_mode, maximum_output_tokens, traits, demand) = parsed?;
    if maximum_output_tokens > prepared.catalog.maximum_output_tokens
        || demand.total_tokens().get() > prepared.catalog.maximum_context_tokens
    {
        return Err(InferenceHttpError::invalid(
            "request exceeds the active model token bounds",
        ));
    }
    let reserve_started = std::time::Instant::now();
    let response_permit = state
        .pilot
        .try_reserve_response()
        .map_err(|error| InferenceHttpError::capacity(error.to_string()));
    observe_stage(
        "reserve",
        reserve_started.elapsed(),
        std::time::Duration::from_millis(100),
        if response_permit.is_ok() {
            "success"
        } else {
            "failure"
        },
    );
    let response_permit = response_permit?;
    let (response_tx, response_rx) = oneshot::channel();
    let client_cancellation = CancellationToken::new();
    let mut cancellation_guard = CancellationGuard::new(client_cancellation.clone());
    let job = PilotRequestJob {
        identity: DurableRequestIdentity::from_request_id(request_id)
            .map_err(|_| InferenceHttpError::invalid("invalid request identity"))?,
        billing,
        controls: PilotRequestControls {
            billing: Some(prepared.billing),
            api_key_limit_micro_usd: prepared.api_key_limit_micro_usd,
            api_key_controlled: prepared.api_key_controlled,
            api_key_public_model: prepared.catalog.public_model.clone(),
            api_key_concrete_model: Arc::from(prepared.catalog.concrete_model.as_str()),
            required_provider_id: prepared.required_provider_id,
        },
        plaintext: input.plaintext,
        model,
        output_mode,
        maximum_output_tokens,
        traits,
        demand,
        input_permit: input.input_permit,
        response_permit,
        response: Some(response_tx),
        client_cancellation,
    };
    let start_started = std::time::Instant::now();
    let dispatched = state.pilot.request_dispatcher().try_dispatch(job);
    observe_stage(
        "start",
        start_started.elapsed(),
        std::time::Duration::from_millis(100),
        if dispatched.is_ok() {
            "success"
        } else {
            "failure"
        },
    );
    dispatched?;
    let ttft_started = std::time::Instant::now();
    let response = response_rx.await.map_err(|_| {
        InferenceHttpError::unavailable("request worker ended before source commitment")
    });
    let response_succeeded = response.as_ref().is_ok_and(Result::is_ok);
    observe_stage(
        "ttft",
        ttft_started.elapsed(),
        std::time::Duration::from_secs(30),
        if response_succeeded {
            "success"
        } else {
            "failure"
        },
    );
    let response = response??;
    cancellation_guard.disarm();
    Ok(Dispatched {
        response,
        sender: input.sender,
        request_id,
    })
}

fn durable_request_id(headers: &HeaderMap, account_id: &str) -> Result<Uuid, InferenceHttpError> {
    let Some(value) = headers.get("idempotency-key") else {
        return Ok(Uuid::new_v4());
    };
    let value = value
        .to_str()
        .ok()
        .filter(|value| {
            !value.is_empty()
                && value.len() <= 256
                && value.trim() == *value
                && !value.chars().any(char::is_control)
        })
        .ok_or_else(|| {
            InferenceHttpError::invalid(
                "Idempotency-Key must be 1..=256 visible bytes without surrounding whitespace",
            )
        })?;
    Ok(request_id_from_idempotency(account_id, value))
}

async fn nonstream_response(
    mut source: BytePipeReceiver<Vec<u8>>,
    surface: InferenceSurface,
    context: &AdapterContext,
    pilot: &PilotHandle,
    sender: Option<X25519PublicKey>,
) -> Result<Response<Body>, InferenceHttpError> {
    let mut exact = Vec::new();
    loop {
        let chunk_started = std::time::Instant::now();
        let chunk = source.recv().await;
        observe_stage(
            "chunk",
            chunk_started.elapsed(),
            std::time::Duration::from_secs(10),
            if chunk.is_ok() { "success" } else { "failure" },
        );
        match chunk {
            Ok(Some(chunk)) => {
                if exact.len().saturating_add(chunk.len()) > MAX_CONSUMER_RESPONSE_BYTES {
                    return Err(InferenceHttpError::upstream(
                        "provider response exceeded its finite limit",
                    ));
                }
                exact.extend_from_slice(&chunk);
            }
            Ok(None) => break,
            Err(_) => return Err(InferenceHttpError::upstream("provider response failed")),
        }
    }
    let exact = crate::http::response::parse_chat_completion_sse(&exact)
        .map_err(|_| InferenceHttpError::upstream("provider response was not valid chat output"))?;
    let adapted = match surface {
        InferenceSurface::Responses => adapt_responses_nonstream(&exact, context),
        InferenceSurface::Completions => adapt_completions_nonstream(&exact, context),
        InferenceSurface::AnthropicMessages => adapt_anthropic_nonstream(&exact, context),
    }?;
    let (body, content_type) = seal_nonstream(pilot, sender, adapted)?;
    response(body, content_type, pilot, sender.is_some())
}

async fn stream_response(
    mut source: BytePipeReceiver<Vec<u8>>,
    mut adapter: StreamAdapter,
    pilot: PilotHandle,
    sender: Option<X25519PublicKey>,
) -> Result<Response<Body>, InferenceHttpError> {
    let mut pending = VecDeque::new();
    loop {
        let chunk_started = std::time::Instant::now();
        let chunk = source.recv().await;
        observe_stage(
            "chunk",
            chunk_started.elapsed(),
            std::time::Duration::from_secs(10),
            if chunk.is_ok() { "success" } else { "failure" },
        );
        match chunk {
            Ok(Some(chunk)) => {
                pending.extend(adapter.push(&chunk)?);
                if !pending.is_empty() {
                    break;
                }
            }
            Ok(None) => {
                pending.extend(adapter.finish()?);
                break;
            }
            Err(_) => {
                return match adapter.fail(InferenceHttpError::adapter_upstream()) {
                    AdaptedStreamFailure::PreCommit(error) => Err(error.into()),
                    AdaptedStreamFailure::Committed(events) => {
                        pending.extend(events);
                        break;
                    }
                };
            }
        }
    }
    let state = AdaptedBody {
        source,
        adapter,
        pending,
        source_finished: false,
        pilot: pilot.clone(),
        sender,
    };
    let body = Body::from_stream(stream::unfold(state, |mut state| async move {
        loop {
            if let Some(event) = state.pending.pop_front() {
                return Some((state.encode_event(event).map(Bytes::from), state));
            }
            if state.source_finished {
                return None;
            }
            let chunk_started = std::time::Instant::now();
            let chunk = state.source.recv().await;
            observe_stage(
                "chunk",
                chunk_started.elapsed(),
                std::time::Duration::from_secs(10),
                if chunk.is_ok() { "success" } else { "failure" },
            );
            match chunk {
                Ok(Some(chunk)) => match state.adapter.push(&chunk) {
                    Ok(events) => state.pending.extend(events),
                    Err(error) => {
                        state.pending.extend(committed_failure(
                            state.adapter.fail(error),
                            state.adapter.surface(),
                        ));
                        state.source_finished = true;
                    }
                },
                Ok(None) => {
                    match state.adapter.finish() {
                        Ok(events) => state.pending.extend(events),
                        Err(error) => state.pending.extend(committed_failure(
                            state.adapter.fail(error),
                            state.adapter.surface(),
                        )),
                    }
                    state.source_finished = true;
                }
                Err(_) => {
                    let error = InferenceHttpError::adapter_upstream();
                    state.pending.extend(committed_failure(
                        state.adapter.fail(error),
                        state.adapter.surface(),
                    ));
                    state.source_finished = true;
                }
            }
        }
    }));
    response(body, "text/event-stream", &pilot, sender.is_some())
}

fn observe_stage(
    stage: &'static str,
    elapsed: std::time::Duration,
    budget: std::time::Duration,
    outcome: &'static str,
) {
    let tags = [
        Tag::new(TagKey::Stage, stage),
        Tag::new(TagKey::Outcome, outcome),
    ];
    datadog::histogram(
        Metric::HttpStageDurationMs,
        elapsed.as_secs_f64() * 1_000.0,
        &tags,
    );
    if elapsed > budget {
        datadog::counter(Metric::HttpStageBudgetExceeded, 1, &tags);
    }
}

struct AdaptedBody {
    source: BytePipeReceiver<Vec<u8>>,
    adapter: StreamAdapter,
    pending: VecDeque<Vec<u8>>,
    source_finished: bool,
    pilot: PilotHandle,
    sender: Option<X25519PublicKey>,
}

impl AdaptedBody {
    fn encode_event(&self, event: Vec<u8>) -> Result<Vec<u8>, io::Error> {
        let Some(sender) = self.sender else {
            return Ok(event);
        };
        let ciphertext = self
            .pilot
            .seal_to_sender(sender, &event)
            .map_err(|_| io::Error::other("response sealing failed"))?;
        let mut output = Vec::with_capacity(ciphertext.len() + 8);
        output.extend_from_slice(b"data: ");
        output.extend_from_slice(ciphertext.as_bytes());
        output.extend_from_slice(b"\n\n");
        Ok(output)
    }
}

enum StreamAdapter {
    Responses(ResponsesStreamAdapter),
    Completions(CompletionsStreamAdapter),
    Anthropic(AnthropicStreamAdapter),
}

impl StreamAdapter {
    fn new(surface: InferenceSurface, context: AdapterContext) -> Self {
        match surface {
            InferenceSurface::Responses => Self::Responses(ResponsesStreamAdapter::new(context)),
            InferenceSurface::Completions => {
                Self::Completions(CompletionsStreamAdapter::new(context))
            }
            InferenceSurface::AnthropicMessages => {
                Self::Anthropic(AnthropicStreamAdapter::new(context))
            }
        }
    }

    fn surface(&self) -> InferenceSurface {
        match self {
            Self::Responses(_) => InferenceSurface::Responses,
            Self::Completions(_) => InferenceSurface::Completions,
            Self::Anthropic(_) => InferenceSurface::AnthropicMessages,
        }
    }

    fn push(&mut self, bytes: &[u8]) -> Result<Vec<Vec<u8>>, AdapterError> {
        match self {
            Self::Responses(adapter) => adapter.push(bytes),
            Self::Completions(adapter) => adapter.push(bytes),
            Self::Anthropic(adapter) => adapter.push(bytes),
        }
    }

    fn finish(&mut self) -> Result<Vec<Vec<u8>>, AdapterError> {
        match self {
            Self::Responses(adapter) => adapter.finish_input(),
            Self::Completions(adapter) => adapter.finish_input(),
            Self::Anthropic(adapter) => adapter.finish_input(),
        }
    }

    fn fail(&mut self, error: AdapterError) -> AdaptedStreamFailure {
        match self {
            Self::Responses(adapter) => adapter.fail(error),
            Self::Completions(adapter) => adapter.fail(error),
            Self::Anthropic(adapter) => adapter.fail(error),
        }
    }
}

fn committed_failure(failure: AdaptedStreamFailure, surface: InferenceSurface) -> Vec<Vec<u8>> {
    match failure {
        AdaptedStreamFailure::Committed(events) => events,
        AdaptedStreamFailure::PreCommit(error) => {
            let bytes = match surface {
                InferenceSurface::AnthropicMessages => serde_json::to_vec(&error.anthropic_json()),
                InferenceSurface::Responses | InferenceSurface::Completions => {
                    serde_json::to_vec(&error.openai_json())
                }
            }
            .unwrap_or_else(|_| b"{\"error\":{\"message\":\"stream failed\"}}".to_vec());
            vec![bytes]
        }
    }
}

fn seal_nonstream(
    pilot: &PilotHandle,
    sender: Option<X25519PublicKey>,
    plaintext: Vec<u8>,
) -> Result<(Vec<u8>, &'static str), InferenceHttpError> {
    let Some(sender) = sender else {
        return Ok((plaintext, "application/json"));
    };
    let ciphertext = pilot
        .seal_to_sender(sender, &plaintext)
        .map_err(|_| InferenceHttpError::upstream("response sealing failed"))?;
    let body = serde_json::to_vec(&SealedResponse {
        kid: pilot.keyring().active().kid(),
        ciphertext: &ciphertext,
    })
    .map_err(|_| InferenceHttpError::upstream("response sealing failed"))?;
    Ok((body, SEALED_CONTENT_TYPE))
}

fn response(
    body: impl Into<Body>,
    content_type: &'static str,
    pilot: &PilotHandle,
    sealed: bool,
) -> Result<Response<Body>, InferenceHttpError> {
    let mut response = Response::new(body.into());
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    if sealed {
        response
            .headers_mut()
            .insert(X_EIGEN_SEALED, HeaderValue::from_static("true"));
        let key_id = HeaderValue::from_str(pilot.keyring().active().kid())
            .map_err(|_| InferenceHttpError::upstream("invalid response key identity"))?;
        response.headers_mut().insert(X_EIGEN_SEALED_KID, key_id);
    }
    Ok(response)
}

fn unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| i64::try_from(duration.as_secs()).ok())
        .unwrap_or_default()
}

struct CancellationGuard(Option<CancellationToken>);

impl CancellationGuard {
    fn new(token: CancellationToken) -> Self {
        Self(Some(token))
    }

    fn disarm(&mut self) {
        self.0 = None;
    }
}

impl Drop for CancellationGuard {
    fn drop(&mut self) {
        if let Some(token) = self.0.take() {
            token.cancel();
        }
    }
}

#[derive(Serialize)]
struct SealedResponse<'a> {
    kid: &'a str,
    ciphertext: &'a str,
}

#[derive(Debug)]
pub struct InferenceHttpError {
    status: StatusCode,
    code: &'static str,
    kind: &'static str,
    message: Cow<'static, str>,
    anthropic: bool,
}

impl InferenceHttpError {
    fn for_surface(mut self, surface: InferenceSurface) -> Self {
        self.anthropic = surface == InferenceSurface::AnthropicMessages;
        self
    }

    fn invalid(message: &'static str) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code: "invalid_request_error",
            kind: "invalid_request_error",
            message: Cow::Borrowed(message),
            anthropic: false,
        }
    }

    fn capacity(message: String) -> Self {
        Self {
            status: StatusCode::TOO_MANY_REQUESTS,
            code: "capacity_exhausted",
            kind: "rate_limit_error",
            message: Cow::Owned(message),
            anthropic: false,
        }
    }

    fn unavailable(message: &'static str) -> Self {
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            code: "service_unavailable",
            kind: "server_error",
            message: Cow::Borrowed(message),
            anthropic: false,
        }
    }

    fn upstream(message: &'static str) -> Self {
        Self {
            status: StatusCode::BAD_GATEWAY,
            code: "provider_error",
            kind: "server_error",
            message: Cow::Borrowed(message),
            anthropic: false,
        }
    }

    fn adapter_upstream() -> AdapterError {
        AdapterError::new(
            502,
            "provider_error",
            "server_error",
            Cow::Borrowed("provider response failed"),
            None,
        )
    }
}

impl From<AdapterError> for InferenceHttpError {
    fn from(error: AdapterError) -> Self {
        Self {
            status: StatusCode::from_u16(error.status())
                .unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
            code: error.code(),
            kind: error.kind(),
            message: Cow::Owned(error.message().to_owned()),
            anthropic: false,
        }
    }
}

impl From<FullSurfaceBuildError> for InferenceHttpError {
    fn from(error: FullSurfaceBuildError) -> Self {
        match error {
            FullSurfaceBuildError::ProviderCannotInfer => Self {
                status: StatusCode::FORBIDDEN,
                code: "forbidden",
                kind: "authentication_error",
                message: Cow::Borrowed("provider credentials cannot authorize inference"),
                anthropic: false,
            },
            _ => Self::unavailable("durable billing identity is unavailable"),
        }
    }
}

impl From<InferenceControlError> for InferenceHttpError {
    fn from(error: InferenceControlError) -> Self {
        match error {
            InferenceControlError::InvalidRequest => Self::invalid("invalid inference request"),
            InferenceControlError::CredentialChanged => Self {
                status: StatusCode::UNAUTHORIZED,
                code: "authentication_error",
                kind: "authentication_error",
                message: Cow::Borrowed("API key was revoked or changed"),
                anthropic: false,
            },
            InferenceControlError::ModelForbidden => Self {
                status: StatusCode::FORBIDDEN,
                code: "model_not_allowed",
                kind: "permission_error",
                message: Cow::Borrowed("API key does not allow the requested model"),
                anthropic: false,
            },
            InferenceControlError::RateLimited => {
                Self::capacity("API key rate limit exceeded".into())
            }
            InferenceControlError::CapabilityUnavailable => {
                Self::invalid("active model does not support the requested capability")
            }
            InferenceControlError::OwnedProviderUnavailable => {
                Self::unavailable("self-route-only key has no matching trusted owned provider")
            }
            InferenceControlError::Catalog(crate::db::catalog::CatalogError::NotFound) => Self {
                status: StatusCode::NOT_FOUND,
                code: "model_not_found",
                kind: "invalid_request_error",
                message: Cow::Borrowed("requested model is not available"),
                anthropic: false,
            },
            _ => Self::unavailable("dynamic inference controls are unavailable"),
        }
    }
}

impl From<PilotRequestError> for InferenceHttpError {
    fn from(error: PilotRequestError) -> Self {
        match error {
            PilotRequestError::InvalidRequest(_) => Self::invalid("invalid inference request"),
            PilotRequestError::ModelNotFound(_) => Self {
                status: StatusCode::NOT_FOUND,
                code: "model_not_found",
                kind: "invalid_request_error",
                message: Cow::Borrowed("requested model is not available"),
                anthropic: false,
            },
            PilotRequestError::Capacity => Self::capacity("inference fleet is at capacity".into()),
            PilotRequestError::PaymentRequired => Self {
                status: StatusCode::PAYMENT_REQUIRED,
                code: "insufficient_credit",
                kind: "billing_error",
                message: Cow::Borrowed("consumer account has insufficient credit"),
                anthropic: false,
            },
            PilotRequestError::Forbidden => Self {
                status: StatusCode::FORBIDDEN,
                code: "forbidden",
                kind: "permission_error",
                message: Cow::Borrowed("API key no longer authorizes this request"),
                anthropic: false,
            },
            PilotRequestError::Timeout => Self {
                status: StatusCode::GATEWAY_TIMEOUT,
                code: "request_timeout",
                kind: "server_error",
                message: Cow::Borrowed("inference request timed out"),
                anthropic: false,
            },
            PilotRequestError::Cancelled => Self {
                status: StatusCode::from_u16(499).expect("valid status"),
                code: "request_cancelled",
                kind: "server_error",
                message: Cow::Borrowed("inference request was cancelled"),
                anthropic: false,
            },
            PilotRequestError::Provider(_)
            | PilotRequestError::ProviderPricing(_)
            | PilotRequestError::Protocol(_) => Self::upstream("provider request failed"),
            PilotRequestError::Unavailable(_) => {
                Self::unavailable("private inference runtime is unavailable")
            }
            _ => Self {
                status: StatusCode::INTERNAL_SERVER_ERROR,
                code: "internal_error",
                kind: "server_error",
                message: Cow::Borrowed("internal inference error"),
                anthropic: false,
            },
        }
    }
}

impl From<crate::pilot::RequestDispatchError> for InferenceHttpError {
    fn from(error: crate::pilot::RequestDispatchError) -> Self {
        match error {
            crate::pilot::RequestDispatchError::Full => {
                Self::capacity("inference request queue is full".into())
            }
            crate::pilot::RequestDispatchError::Closed => {
                Self::unavailable("private inference runtime is unavailable")
            }
        }
    }
}

impl IntoResponse for InferenceHttpError {
    fn into_response(self) -> axum::response::Response {
        let body = if self.anthropic {
            serde_json::json!({
                "type": "error",
                "error": {"type": self.kind, "message": self.message}
            })
        } else {
            serde_json::json!({
                "error": {
                    "message": self.message,
                    "type": self.kind,
                    "param": serde_json::Value::Null,
                    "code": self.code,
                }
            })
        };
        (self.status, Json(body)).into_response()
    }
}

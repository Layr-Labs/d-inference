mod auth;
mod body;
mod error;
pub(crate) mod response;

use std::sync::Arc;

use axum::{
    Json, Router,
    extract::{Request, State, WebSocketUpgrade},
    http::{StatusCode, header::HeaderName},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::Serialize;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

use crate::pilot::{
    BillingContext, DurableRequestIdentity, PilotHandle, PilotRequestError, PilotRequestJob,
    PilotTelemetryEvent, parse_request_facts, request_id_from_idempotency,
};

use self::{
    auth::authenticate_consumer, body::read_consumer_input, error::ApiError,
    response::consumer_response,
};

#[derive(Clone)]
struct PilotHttpState {
    pilot: Option<PilotHandle>,
    admission: Option<crate::surface::operations::AdmissionGate>,
}

pub fn routes(pilot: Option<PilotHandle>) -> Router {
    routes_for_mode(pilot, PilotRouteMode::Isolated)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PilotRouteMode {
    Isolated,
    FullSurface,
}

pub fn routes_for_mode(pilot: Option<PilotHandle>, mode: PilotRouteMode) -> Router {
    routes_for_mode_with_admission(pilot, mode, None)
}

pub(crate) fn full_surface_routes(
    pilot: PilotHandle,
    admission: crate::surface::operations::AdmissionGate,
) -> Router {
    routes_for_mode_with_admission(Some(pilot), PilotRouteMode::FullSurface, Some(admission))
}

fn routes_for_mode_with_admission(
    pilot: Option<PilotHandle>,
    mode: PilotRouteMode,
    admission: Option<crate::surface::operations::AdmissionGate>,
) -> Router {
    match mode {
        PilotRouteMode::Isolated => Router::new()
            .route("/v1/encryption-key", get(encryption_key))
            .route("/v1/models", get(models))
            .route("/v1/chat/completions", post(chat_completions))
            .route("/ws/provider", get(provider_websocket))
            .with_state(PilotHttpState { pilot, admission }),
        PilotRouteMode::FullSurface => Router::new()
            .route("/v1/encryption-key", get(encryption_key))
            .route("/ws/provider", get(provider_websocket))
            .with_state(PilotHttpState { pilot, admission }),
    }
}

async fn encryption_key(
    State(state): State<PilotHttpState>,
) -> Result<Json<EncryptionKey>, ApiError> {
    let pilot = state.pilot.as_ref().ok_or_else(pilot_unavailable)?;
    let active = pilot.keyring().active();
    Ok(Json(EncryptionKey {
        kid: Arc::from(active.kid()),
        public_key: active.public_key().to_base64(),
        algorithm: "x25519-nacl-box",
    }))
}

async fn models(
    State(state): State<PilotHttpState>,
    request: Request,
) -> Result<Json<ModelList>, ApiError> {
    let pilot = state.pilot.as_ref().ok_or_else(pilot_unavailable)?;
    let _billing = authenticate_consumer(request.headers(), pilot)?;
    let data = pilot
        .catalog()
        .models()
        .map(|model| Model {
            id: Arc::from(model.id.as_str()),
            object: "model",
            created: 0,
            owned_by: "darkbloom",
        })
        .collect();
    Ok(Json(ModelList {
        object: "list",
        data,
    }))
}

async fn chat_completions(
    State(state): State<PilotHttpState>,
    request: Request,
) -> Result<Response, ApiError> {
    let pilot = state.pilot.ok_or_else(pilot_unavailable)?;
    let billing = authenticate_consumer(request.headers(), &pilot).inspect_err(|_| {
        pilot.telemetry().emit(PilotTelemetryEvent::RequestRejected);
    })?;
    if !pilot.is_ready() {
        return Err(pilot_unavailable());
    }
    let (parts, body) = request.into_parts();
    let request_id = durable_request_id(&parts.headers, &billing)?;
    let input = read_consumer_input(&parts.headers, body, &pilot).await?;
    let model = pilot
        .catalog()
        .models()
        .next()
        .expect("pilot catalog contains exactly one model");
    let alias = model
        .aliases
        .iter()
        .next()
        .map_or(model.id.as_str(), AsRef::as_ref);
    let (model, output_mode, maximum_output_tokens, traits, demand) =
        parse_request_facts(&input.plaintext, &model.id, alias)?;
    let response_permit = pilot.try_reserve_response().map_err(|error| {
        pilot.telemetry().emit(PilotTelemetryEvent::RequestRejected);
        ApiError::capacity(error.to_string())
    })?;
    let (response_tx, response_rx) = oneshot::channel();
    let client_cancellation = CancellationToken::new();
    let mut client_guard = ClientCancellationGuard::new(client_cancellation.clone());
    let job = PilotRequestJob {
        identity: DurableRequestIdentity::from_request_id(request_id).map_err(|error| {
            ApiError::new(
                StatusCode::BAD_REQUEST,
                "invalid_idempotency_key",
                "invalid_request_error",
                error.to_string(),
            )
        })?,
        billing,
        controls: crate::pilot::PilotRequestControls::default(),
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
    if let Err(error) = pilot.request_dispatcher().try_dispatch(job) {
        pilot.telemetry().emit(PilotTelemetryEvent::RequestRejected);
        return Err(ApiError::from(error));
    }
    let response = response_rx.await.map_err(|_| {
        ApiError::from(PilotRequestError::Unavailable(Arc::from(
            "pilot request worker ended before commitment",
        )))
    })??;
    client_guard.disarm();
    Ok(consumer_response(response, pilot, input.sender))
}

fn durable_request_id(
    headers: &axum::http::HeaderMap,
    billing: &BillingContext,
) -> Result<uuid::Uuid, ApiError> {
    static IDEMPOTENCY_KEY: HeaderName = HeaderName::from_static("idempotency-key");
    let Some(value) = headers.get(&IDEMPOTENCY_KEY) else {
        return Ok(uuid::Uuid::new_v4());
    };
    let value = value
        .to_str()
        .ok()
        .filter(|value| {
            !value.is_empty() && value.len() <= 256 && !value.chars().any(char::is_control)
        })
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::BAD_REQUEST,
                "invalid_idempotency_key",
                "invalid_request_error",
                "Idempotency-Key must be 1..=256 visible bytes",
            )
        })?;
    let scope = match billing {
        BillingContext::FreeSelfRoute => "self-route",
        BillingContext::Paid(context) => context.account_id.as_str(),
    };
    Ok(request_id_from_idempotency(scope, value))
}

async fn provider_websocket(
    State(state): State<PilotHttpState>,
    websocket: WebSocketUpgrade,
) -> Result<Response, ApiError> {
    let pilot = state.pilot.ok_or_else(pilot_unavailable)?;
    if !pilot.is_ready() {
        return Err(pilot_unavailable());
    }
    let acceptor = pilot.provider_acceptor();
    if acceptor.remaining_capacity() == 0 {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "provider_capacity_exhausted",
            "server_error",
            "pilot provider session owner is full",
        ));
    }
    let admission = state
        .admission
        .map(|gate| gate.enter(crate::surface::operations::AdmissionKind::Mutation))
        .transpose()
        .map_err(|_| ApiError::draining())?;
    Ok(websocket
        .on_upgrade(move |socket| async move {
            let result = match admission {
                Some(admission) => acceptor.try_accept_guarded(socket, admission),
                None => acceptor.try_accept(socket),
            };
            if let Err(error) = result {
                tracing::warn!(error = %error, "pilot provider connection rejected after upgrade");
            }
        })
        .into_response())
}

fn pilot_unavailable() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "pilot_unavailable",
        "server_error",
        "Rust private-inference pilot is unavailable",
    )
}

struct ClientCancellationGuard {
    cancellation: Option<CancellationToken>,
}

impl ClientCancellationGuard {
    fn new(cancellation: CancellationToken) -> Self {
        Self {
            cancellation: Some(cancellation),
        }
    }

    fn disarm(&mut self) {
        self.cancellation = None;
    }
}

impl Drop for ClientCancellationGuard {
    fn drop(&mut self) {
        if let Some(cancellation) = self.cancellation.take() {
            cancellation.cancel();
        }
    }
}

#[derive(Serialize)]
struct EncryptionKey {
    kid: Arc<str>,
    public_key: String,
    algorithm: &'static str,
}

#[derive(Serialize)]
struct ModelList {
    object: &'static str,
    data: Vec<Model>,
}

#[derive(Serialize)]
struct Model {
    id: Arc<str>,
    object: &'static str,
    created: u64,
    owned_by: &'static str,
}

#[cfg(test)]
mod tests;

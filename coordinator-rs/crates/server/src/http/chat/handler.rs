//! Chat ingress: auth, concurrency shed, bounded body collection, sealed
//! unwrap, and the request-task spawn (plan §14, §15.1).
//!
//! # Ingress ordering (plan §14: reject before large allocation)
//!
//! The handler consumes the raw request so IT controls the order — never an
//! extractor: (1) authenticate from headers, (2) acquire the global and
//! per-account concurrency permits, (3) only then collect the body, bounded
//! by [`MAX_BODY_BYTES`](crate::http::MAX_BODY_BYTES) and
//! [`BODY_READ_TIMEOUT`](crate::http::BODY_READ_TIMEOUT). A shed request
//! (401/429) therefore never buffers a byte of a 16 MiB body.

use std::sync::Arc;

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap};
use axum::response::{IntoResponse, Response};
use bytes::Bytes;
use tokio::sync::mpsc;

use crate::http::auth::authenticate;
use crate::http::errors::ApiError;
use crate::http::sealed::{self, SealedReply};
use crate::http::HttpState;
use crate::http::{BODY_READ_TIMEOUT, MAX_BODY_BYTES};
use crate::request_task::{self, ConsumerEvent};

use super::aggregate::non_streaming_response;
use super::request::prepare_request;
use super::stream::streaming_response;

/// Consumer-event channel capacity: drains continuously into the socket;
/// the per-attempt byte pipe upstream is the real 13.6 grace window.
const CONSUMER_CHANNEL_CAP: usize = 256;

pub(crate) async fn chat_completions(
    State(state): State<HttpState>,
    request: axum::extract::Request,
) -> Response {
    match handle(state, request).await {
        Ok(response) => response,
        Err(err) => err.into_response(),
    }
}

async fn handle(state: HttpState, request: axum::extract::Request) -> Result<Response, ApiError> {
    let (parts, raw_body) = request.into_parts();
    let headers = parts.headers;

    // Header-only auth, then concurrency shed — BEFORE any body byte is
    // buffered (plan §14; see the module docs on ingress ordering).
    let key = authenticate(&*state.app.keys, &headers).await?;
    let permits = state
        .limits
        .try_acquire(key.account)
        .ok_or(ApiError::Overloaded)?;

    let body = collect_body(&headers, raw_body).await?;

    // Sealed-transport unwrap (Go sender_encryption.go semantics).
    let (plain_body, seal_ctx): (Bytes, Option<Arc<SealedReply>>) = if sealed::is_sealed(&headers) {
        let (plaintext, reply) = sealed::open_request(&state.app.encryption, &body)?;
        (plaintext, Some(Arc::new(reply)))
    } else {
        (body, None)
    };

    let (consumer_tx, consumer_rx) = mpsc::channel::<ConsumerEvent>(CONSUMER_CHANNEL_CAP);
    let prepared = prepare_request(&state, &key, &plain_body, consumer_tx)?;
    let job = prepared.job;
    let public_model = prepared.public_model.clone();
    let stream = prepared.stream;

    let span = tracing::info_span!("request_task", job = %job, model = %public_model);
    let task = {
        let deps = state.task_deps.clone();
        let normalized = prepared.normalized;
        // Spawned on the supervisor's requests-phase tracker (plan §15.1
        // step 2): ordered shutdown cancels via `deps.shutdown` (already in
        // the task's select) and then WAITS for these tasks to reach their
        // durable disposition before workers and sessions stop.
        state.request_tracker.spawn(tracing::Instrument::instrument(
            request_task::run(deps, normalized),
            span,
        ))
    };

    if stream {
        streaming_response(
            state.clone(),
            task,
            consumer_rx,
            job,
            public_model.clone(),
            seal_ctx.clone(),
            permits,
        )
        .await
    } else {
        // Permits drop when aggregation completes (request ends here).
        let response = non_streaming_response(
            state.clone(),
            task,
            consumer_rx,
            job,
            public_model.clone(),
            seal_ctx.clone(),
        )
        .await;
        drop(permits);
        response
    }
}

/// Collects the request body under the plaintext cap and the read timeout
/// (a declared-oversize Content-Length is shed without reading at all).
async fn collect_body(headers: &HeaderMap, body: Body) -> Result<Bytes, ApiError> {
    let declared = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<usize>().ok());
    if declared.is_some_and(|len| len > MAX_BODY_BYTES) {
        return Err(ApiError::PayloadTooLarge);
    }
    match tokio::time::timeout(
        BODY_READ_TIMEOUT,
        axum::body::to_bytes(body, MAX_BODY_BYTES),
    )
    .await
    {
        Err(_elapsed) => Err(ApiError::BodyReadTimeout),
        Ok(Ok(bytes)) => Ok(bytes),
        Ok(Err(err)) if is_length_limit(&err) => Err(ApiError::PayloadTooLarge),
        Ok(Err(_)) => Err(ApiError::InvalidRequest(
            "failed to read request body".to_owned(),
        )),
    }
}

/// True when the collect error is the `Limited` body cap (413), as opposed
/// to a transport-level read failure (400).
fn is_length_limit(err: &axum::Error) -> bool {
    let mut source: Option<&(dyn std::error::Error + 'static)> = Some(err);
    while let Some(inner) = source {
        if inner.is::<http_body_util::LengthLimitError>() {
            return true;
        }
        source = inner.source();
    }
    false
}

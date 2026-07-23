use crate::api::{ErrorResponse, PlanRequest};
use crate::metrics::MetricsSnapshot;
use crate::planner::{PlanError, Planner, Readiness};
use crate::preload::{PreloadError, PreloadReport, PreloadRequest};
use crate::render::RenderError;
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper::header::{CONTENT_LENGTH, CONTENT_TYPE};
use hyper::{Method, Request, Response, StatusCode};
use serde::Serialize;
use std::time::Duration;

type ResponseBody = Full<Bytes>;

pub(super) async fn handle(
    request: Request<Incoming>,
    planner: Planner,
    max_body_bytes: usize,
    body_read_timeout: Duration,
    planning_timeout: Duration,
) -> Response<ResponseBody> {
    match (request.method(), request.uri().path()) {
        (&Method::GET, "/health") => health_response(&planner),
        (&Method::GET, "/ready") => ready_response(&planner),
        (&Method::GET, "/metrics") => encoded_response(StatusCode::OK, &planner.status()),
        (&Method::POST, "/v1/preload") => {
            handle_preload(request, planner, max_body_bytes, body_read_timeout).await
        }
        (&Method::POST, "/v1/plan") => {
            handle_plan(
                request,
                planner,
                max_body_bytes,
                body_read_timeout,
                planning_timeout,
            )
            .await
        }
        _ => error_response(StatusCode::NOT_FOUND, "not_found", "endpoint not found"),
    }
}

fn plan_timeout_response() -> Response<ResponseBody> {
    error_response(
        StatusCode::GATEWAY_TIMEOUT,
        "deadline_exceeded",
        "prompt planning deadline exceeded",
    )
}

async fn handle_preload(
    request: Request<Incoming>,
    planner: Planner,
    max_body_bytes: usize,
    body_read_timeout: Duration,
) -> Response<ResponseBody> {
    if content_length_exceeds(&request, max_body_bytes) {
        return body_too_large_response();
    }
    let bytes = match tokio::time::timeout(
        body_read_timeout,
        collect_bounded(request.into_body(), max_body_bytes),
    )
    .await
    {
        Ok(Ok(bytes)) => bytes,
        Ok(Err(error)) => return collect_error_response(error),
        Err(_) => {
            return error_response(
                StatusCode::REQUEST_TIMEOUT,
                "body_deadline_exceeded",
                "request body deadline exceeded",
            );
        }
    };
    let preload_request: PreloadRequest = match serde_json::from_slice(&bytes) {
        Ok(request) => request,
        Err(_) => {
            return error_response(
                StatusCode::BAD_REQUEST,
                "malformed_json",
                "request body is not a valid preload request",
            );
        }
    };
    match planner
        .preload_contracts(preload_request.prompt_contract_ids)
        .await
    {
        Ok(report) => {
            let metrics = planner.status().metrics;
            encoded_response(StatusCode::OK, &PreloadResponse { report, metrics })
        }
        Err(error) => preload_error_response(error),
    }
}

async fn handle_plan(
    request: Request<Incoming>,
    planner: Planner,
    max_body_bytes: usize,
    body_read_timeout: Duration,
    planning_timeout: Duration,
) -> Response<ResponseBody> {
    if content_length_exceeds(&request, max_body_bytes) {
        return body_too_large_response();
    }
    let bytes = match tokio::time::timeout(
        body_read_timeout,
        collect_bounded(request.into_body(), max_body_bytes),
    )
    .await
    {
        Ok(Ok(bytes)) => bytes,
        Ok(Err(error)) => return collect_error_response(error),
        Err(_) => {
            return error_response(
                StatusCode::REQUEST_TIMEOUT,
                "body_deadline_exceeded",
                "request body deadline exceeded",
            );
        }
    };
    let plan_request: PlanRequest = match serde_json::from_slice(&bytes) {
        Ok(request) => request,
        Err(_) => {
            return error_response(
                StatusCode::BAD_REQUEST,
                "malformed_json",
                "request body is not a valid plan request",
            );
        }
    };
    let started = std::time::Instant::now();
    match tokio::time::timeout(planning_timeout, planner.plan(plan_request)).await {
        Ok(Ok(plan)) => encoded_response(StatusCode::OK, &plan),
        Ok(Err(error)) => plan_error_response(error),
        Err(_) => {
            planner.record_timeout(started.elapsed());
            plan_timeout_response()
        }
    }
}

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
    ready: bool,
}

#[derive(Serialize)]
struct PreloadResponse {
    #[serde(flatten)]
    report: PreloadReport,
    metrics: MetricsSnapshot,
}

fn health_response(planner: &Planner) -> Response<ResponseBody> {
    let readiness = planner.readiness();
    encoded_response(
        StatusCode::OK,
        &HealthResponse {
            status: match readiness {
                Readiness::Starting => "starting",
                Readiness::Ready => "ok",
                Readiness::Degraded => "degraded",
            },
            ready: readiness == Readiness::Ready,
        },
    )
}

fn ready_response(planner: &Planner) -> Response<ResponseBody> {
    let ready = planner.readiness() == Readiness::Ready;
    encoded_response(
        if ready {
            StatusCode::OK
        } else {
            StatusCode::SERVICE_UNAVAILABLE
        },
        &HealthResponse {
            status: if ready { "ok" } else { "not_ready" },
            ready,
        },
    )
}

fn content_length_exceeds(request: &Request<Incoming>, max_body_bytes: usize) -> bool {
    request
        .headers()
        .get(CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<usize>().ok())
        .is_some_and(|length| length > max_body_bytes)
}

fn body_too_large_response() -> Response<ResponseBody> {
    error_response(
        StatusCode::PAYLOAD_TOO_LARGE,
        "body_too_large",
        "request body exceeded its bound",
    )
}

fn collect_error_response(error: CollectError) -> Response<ResponseBody> {
    match error {
        CollectError::TooLarge => body_too_large_response(),
        CollectError::Read => error_response(
            StatusCode::BAD_REQUEST,
            "malformed_body",
            "request body could not be read",
        ),
    }
}

enum CollectError {
    TooLarge,
    Read,
}

async fn collect_bounded(
    mut body: Incoming,
    max_body_bytes: usize,
) -> Result<Vec<u8>, CollectError> {
    let mut output = Vec::with_capacity(max_body_bytes.min(64 * 1024));
    while let Some(frame) = body.frame().await {
        let frame = frame.map_err(|_| CollectError::Read)?;
        let Ok(data) = frame.into_data() else {
            continue;
        };
        if output.len().saturating_add(data.len()) > max_body_bytes {
            return Err(CollectError::TooLarge);
        }
        output.extend_from_slice(&data);
    }
    Ok(output)
}

fn plan_error_response(error: PlanError) -> Response<ResponseBody> {
    match error {
        PlanError::NotReady => error_response(
            StatusCode::SERVICE_UNAVAILABLE,
            "not_ready",
            "prompt planner is not ready",
        ),
        PlanError::AtCapacity => error_response(
            StatusCode::SERVICE_UNAVAILABLE,
            "at_capacity",
            "prompt planner is at capacity",
        ),
        PlanError::TooManyTokens => error_response(
            StatusCode::PAYLOAD_TOO_LARGE,
            "prompt_too_large",
            "prompt token count exceeded its bound",
        ),
        PlanError::Contract => error_response(
            StatusCode::FAILED_DEPENDENCY,
            "contract_unavailable",
            "prompt contract is unavailable",
        ),
        PlanError::Worker => error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "worker_failure",
            "prompt planner worker failed",
        ),
        PlanError::Render(RenderError::DynamicTime) => error_response(
            StatusCode::UNPROCESSABLE_ENTITY,
            "dynamic_time",
            "prompt contract depends on provider-local time",
        ),
        PlanError::InvalidScope
        | PlanError::Endpoint
        | PlanError::Normalize
        | PlanError::Render(_)
        | PlanError::Tokenize
        | PlanError::BlockHash => error_response(
            StatusCode::UNPROCESSABLE_ENTITY,
            "planning_failed",
            "request could not be planned",
        ),
    }
}

fn preload_error_response(error: PreloadError) -> Response<ResponseBody> {
    match error {
        PreloadError::InvalidRequest => error_response(
            StatusCode::BAD_REQUEST,
            "invalid_preload",
            "preload request is invalid",
        ),
        PreloadError::TooManyContracts => error_response(
            StatusCode::BAD_REQUEST,
            "preload_too_large",
            "preload request exceeded its contract bound",
        ),
        PreloadError::AlreadyRunning => error_response(
            StatusCode::CONFLICT,
            "preload_in_progress",
            "a preload is already running",
        ),
        PreloadError::Worker => error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "preload_failed",
            "prompt contract preload failed",
        ),
    }
}

fn error_response(
    status: StatusCode,
    code: &'static str,
    message: &'static str,
) -> Response<ResponseBody> {
    let body = serde_json::to_vec(&ErrorResponse::new(code, message)).unwrap_or_else(|_| {
        br#"{"error":{"code":"internal_error","message":"internal error"}}"#.to_vec()
    });
    json_response(status, body)
}

fn json_response(status: StatusCode, body: Vec<u8>) -> Response<ResponseBody> {
    Response::builder()
        .status(status)
        .header(CONTENT_TYPE, "application/json")
        .body(Full::new(Bytes::from(body)))
        .expect("valid static HTTP response")
}

fn encoded_response(status: StatusCode, value: &impl Serialize) -> Response<ResponseBody> {
    match serde_json::to_vec(value) {
        Ok(body) => json_response(status, body),
        Err(_) => error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal_error",
            "response could not be encoded",
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn dynamic_time_is_a_distinct_cold_only_response() {
        let response = plan_error_response(PlanError::Render(RenderError::DynamicTime));
        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        let encoded = std::str::from_utf8(&body).unwrap();
        assert!(encoded.contains(r#""code":"dynamic_time""#));
    }
}

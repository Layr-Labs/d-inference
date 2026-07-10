//! Router middleware: request-id propagation plus the per-request tracing
//! span (plan §7.1).

use axum::http::{HeaderValue, Request};
use axum::middleware::Next;
use axum::response::Response;
use tracing::Instrument;
use uuid::Uuid;

/// Request-id propagation plus a per-request tracing span (plan §7.1
/// middleware). The job id gets its own span inside the chat handler.
pub(super) async fn request_id_middleware(
    request: Request<axum::body::Body>,
    next: Next,
) -> Response {
    let request_id = request
        .headers()
        .get("x-request-id")
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned)
        .unwrap_or_else(|| Uuid::new_v4().to_string());
    let span = tracing::info_span!(
        "http",
        request_id = %request_id,
        method = %request.method(),
        path = %request.uri().path(),
    );
    let mut response = next.run(request).instrument(span).await;
    if let Ok(value) = HeaderValue::from_str(&request_id) {
        response.headers_mut().insert("x-request-id", value);
    }
    response
}

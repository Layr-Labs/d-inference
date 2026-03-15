//! Local-only HTTP server for the DGInf provider.
//!
//! When running in local-only mode (`dginf-provider serve --local`), this
//! module provides an HTTP server that proxies OpenAI-compatible requests
//! to the local inference backend. This is useful for development and
//! testing without a coordinator.
//!
//! Endpoints:
//!   - GET /health — proxied to the backend's /health
//!   - GET /v1/models — proxied to the backend's /v1/models
//!   - POST /v1/chat/completions — proxied with request logging
//!
//! Streaming responses (SSE) are forwarded transparently using
//! axum's Body::from_stream.

use anyhow::Result;
use axum::{
    body::Body,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use std::sync::Arc;

/// Shared state for the local HTTP server.
#[derive(Clone)]
pub struct AppState {
    pub backend_url: String,
    pub client: reqwest::Client,
}

/// Create the axum router for local-only mode.
pub fn create_router(backend_url: String) -> Router {
    let state = Arc::new(AppState {
        backend_url,
        client: reqwest::Client::new(),
    });

    Router::new()
        .route("/health", get(health_handler))
        .route("/v1/models", get(models_handler))
        .route("/v1/chat/completions", post(chat_completions_handler))
        .with_state(state)
}

/// GET /health — proxy to backend health endpoint.
async fn health_handler(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let url = format!("{}/health", state.backend_url);
    tracing::debug!("Health check -> {url}");

    match state.client.get(&url).send().await {
        Ok(resp) if resp.status().is_success() => {
            (StatusCode::OK, "ok").into_response()
        }
        Ok(resp) => {
            let status = resp.status();
            tracing::warn!("Backend health check returned {status}");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                format!("backend unhealthy: {status}"),
            )
                .into_response()
        }
        Err(e) => {
            tracing::error!("Backend health check failed: {e}");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                format!("backend unreachable: {e}"),
            )
                .into_response()
        }
    }
}

/// GET /v1/models — proxy to backend models endpoint.
async fn models_handler(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let url = format!("{}/v1/models", state.backend_url);
    tracing::debug!("Models request -> {url}");

    match state.client.get(&url).send().await {
        Ok(resp) => proxy_response(resp).await,
        Err(e) => {
            tracing::error!("Failed to proxy models request: {e}");
            (
                StatusCode::BAD_GATEWAY,
                Json(serde_json::json!({"error": format!("backend error: {e}")})),
            )
                .into_response()
        }
    }
}

/// POST /v1/chat/completions — proxy to backend with request/response logging.
async fn chat_completions_handler(
    State(state): State<Arc<AppState>>,
    body: String,
) -> impl IntoResponse {
    let url = format!("{}/v1/chat/completions", state.backend_url);

    // Log the request (summary)
    if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&body) {
        let model = parsed.get("model").and_then(|v| v.as_str()).unwrap_or("unknown");
        let stream = parsed.get("stream").and_then(|v| v.as_bool()).unwrap_or(false);
        let msg_count = parsed
            .get("messages")
            .and_then(|v| v.as_array())
            .map(|a| a.len())
            .unwrap_or(0);
        tracing::info!(
            "Chat completion: model={model}, stream={stream}, messages={msg_count}"
        );
    }

    match state
        .client
        .post(&url)
        .header("content-type", "application/json")
        .body(body)
        .send()
        .await
    {
        Ok(resp) => {
            let is_stream = resp
                .headers()
                .get("content-type")
                .and_then(|v| v.to_str().ok())
                .map(|ct| ct.contains("text/event-stream"))
                .unwrap_or(false);

            if is_stream {
                proxy_streaming_response(resp).await
            } else {
                proxy_response(resp).await
            }
        }
        Err(e) => {
            tracing::error!("Failed to proxy chat completion: {e}");
            (
                StatusCode::BAD_GATEWAY,
                Json(serde_json::json!({"error": format!("backend error: {e}")})),
            )
                .into_response()
        }
    }
}

/// Proxy a non-streaming response from the backend.
async fn proxy_response(resp: reqwest::Response) -> Response {
    let status = StatusCode::from_u16(resp.status().as_u16()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);

    // Forward relevant headers
    let mut builder = Response::builder().status(status);
    if let Some(ct) = resp.headers().get("content-type") {
        builder = builder.header("content-type", ct.clone());
    }

    match resp.bytes().await {
        Ok(body) => builder.body(Body::from(body)).unwrap_or_else(|_| {
            Response::builder()
                .status(StatusCode::INTERNAL_SERVER_ERROR)
                .body(Body::from("proxy error"))
                .unwrap()
        }),
        Err(e) => Response::builder()
            .status(StatusCode::BAD_GATEWAY)
            .body(Body::from(format!("error reading backend response: {e}")))
            .unwrap(),
    }
}

/// Proxy a streaming (SSE) response from the backend.
async fn proxy_streaming_response(resp: reqwest::Response) -> Response {
    let status = StatusCode::from_u16(resp.status().as_u16()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);

    let stream = resp.bytes_stream();

    Response::builder()
        .status(status)
        .header("content-type", "text/event-stream")
        .header("cache-control", "no-cache")
        .header("connection", "keep-alive")
        .body(Body::from_stream(stream))
        .unwrap_or_else(|_| {
            Response::builder()
                .status(StatusCode::INTERNAL_SERVER_ERROR)
                .body(Body::from("proxy streaming error"))
                .unwrap()
        })
}

/// Start the local HTTP server.
pub async fn start_server(port: u16, backend_url: String) -> Result<()> {
    let app = create_router(backend_url);
    let addr = format!("0.0.0.0:{port}");

    tracing::info!("Local API server listening on {addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{Request, StatusCode},
    };
    use tower::ServiceExt;

    /// Start a mock backend returning fixed responses.
    async fn start_mock_backend() -> u16 {
        let app = Router::new()
            .route("/health", get(|| async { "ok" }))
            .route(
                "/v1/models",
                get(|| async {
                    Json(serde_json::json!({
                        "data": [{"id": "qwen3.5-9b", "object": "model"}]
                    }))
                }),
            )
            .route(
                "/v1/chat/completions",
                post(|body: String| async move {
                    let parsed: serde_json::Value = serde_json::from_str(&body).unwrap();
                    let is_stream = parsed
                        .get("stream")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);

                    if is_stream {
                        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n";
                        Response::builder()
                            .status(StatusCode::OK)
                            .header("content-type", "text/event-stream")
                            .body(Body::from(sse))
                            .unwrap()
                    } else {
                        Json(serde_json::json!({
                            "choices": [{"message": {"content": "Hello!"}}],
                            "usage": {"prompt_tokens": 5, "completion_tokens": 3}
                        }))
                        .into_response()
                    }
                }),
            );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        port
    }

    fn make_request(method: &str, uri: &str, body: Body) -> Request<Body> {
        Request::builder()
            .method(method)
            .uri(uri)
            .header("content-type", "application/json")
            .body(body)
            .unwrap()
    }

    fn get_request(uri: &str) -> Request<Body> {
        make_request("GET", uri, Body::empty())
    }

    #[tokio::test]
    async fn test_health_endpoint() {
        let backend_port = start_mock_backend().await;
        let app = create_router(format!("http://127.0.0.1:{backend_port}"));

        let response = app.oneshot(get_request("/health")).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_health_endpoint_backend_down() {
        let app = create_router("http://127.0.0.1:19998".to_string());

        let response = app.oneshot(get_request("/health")).await.unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    }

    #[tokio::test]
    async fn test_models_endpoint() {
        let backend_port = start_mock_backend().await;
        let app = create_router(format!("http://127.0.0.1:{backend_port}"));

        let response = app.oneshot(get_request("/v1/models")).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(json.get("data").is_some());
    }

    #[tokio::test]
    async fn test_chat_completions_non_streaming() {
        let backend_port = start_mock_backend().await;
        let app = create_router(format!("http://127.0.0.1:{backend_port}"));

        let body = serde_json::json!({
            "model": "qwen3.5-9b",
            "messages": [{"role": "user", "content": "hello"}],
            "stream": false
        });

        let req = make_request(
            "POST",
            "/v1/chat/completions",
            Body::from(serde_json::to_string(&body).unwrap()),
        );
        let response = app.oneshot(req).await.unwrap();

        assert_eq!(response.status(), StatusCode::OK);

        let resp_body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: serde_json::Value = serde_json::from_slice(&resp_body).unwrap();
        assert!(json.get("choices").is_some());
    }

    #[tokio::test]
    async fn test_chat_completions_streaming() {
        let backend_port = start_mock_backend().await;
        let app = create_router(format!("http://127.0.0.1:{backend_port}"));

        let body = serde_json::json!({
            "model": "qwen3.5-9b",
            "messages": [{"role": "user", "content": "hello"}],
            "stream": true
        });

        let req = make_request(
            "POST",
            "/v1/chat/completions",
            Body::from(serde_json::to_string(&body).unwrap()),
        );
        let response = app.oneshot(req).await.unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response
                .headers()
                .get("content-type")
                .unwrap()
                .to_str()
                .unwrap(),
            "text/event-stream"
        );

        let resp_body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let text = String::from_utf8_lossy(&resp_body);
        assert!(text.contains("data:"));
        assert!(text.contains("[DONE]"));
    }
}

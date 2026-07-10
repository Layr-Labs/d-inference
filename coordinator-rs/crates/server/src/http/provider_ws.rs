//! The provider WebSocket upgrade route, present only when the session
//! handler is wired (concurrent-module seam; see
//! [`ProviderConnectHandler`](super::ProviderConnectHandler)).

use axum::extract::{State, WebSocketUpgrade};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;

use super::config::ProviderConnectHandler;
use super::errors::ApiError;
use super::state::HttpState;

/// The provider WebSocket route, or `None` when the handler is not wired.
pub(super) fn wire_provider_route(
    handler: Option<ProviderConnectHandler>,
) -> Option<Router<HttpState>> {
    handler.as_ref()?;
    Some(Router::new().route("/v1/providers/connect", get(provider_connect)))
}

async fn provider_connect(State(state): State<HttpState>, upgrade: WebSocketUpgrade) -> Response {
    match state.provider_connect.clone() {
        Some(handler) => upgrade
            // Both caps must carry the same value: tungstenite's DEFAULT
            // frame cap is 16 MiB, which would reject a single-frame sealed
            // vision payload that the 32 MiB message cap allows.
            .max_message_size(state.provider_max_frame_bytes)
            .max_frame_size(state.provider_max_frame_bytes)
            .on_upgrade(move |socket| async move { handler(socket).await })
            .into_response(),
        None => ApiError::Internal("provider session component not wired").into_response(),
    }
}

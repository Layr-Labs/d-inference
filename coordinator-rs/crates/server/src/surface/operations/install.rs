use std::sync::Arc;

use axum::{
    extract::State,
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::IntoResponse,
};

use super::OperationsState;

const INSTALL_SCRIPT: &str = include_str!("../../../../../../coordinator/api/install.sh");
const COORDINATOR_PLACEHOLDER: &str = "__DARKBLOOM_COORD_URL__";

pub(super) async fn install_script(State(state): State<Arc<OperationsState>>) -> impl IntoResponse {
    let script = INSTALL_SCRIPT.replace(
        COORDINATOR_PLACEHOLDER,
        state
            .settings
            .public_base_url
            .as_str()
            .trim_end_matches('/'),
    );
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    (StatusCode::OK, headers, script)
}

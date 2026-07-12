use axum::{
    Json, Router,
    extract::{Request, State},
    http::{HeaderValue, Method, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::post,
};
use serde::Serialize;

use super::{
    FullSurfaceBuildError, FullSurfaceState, billing,
    billing::BillingError,
    billing_principal, durable_billing_context,
    identity::{AuthPrincipal, AuthRequirement, IdentityError},
    inference,
    operations::{self, AdmissionKind, OperationsPrincipal},
    routes,
};

pub fn router(state: FullSurfaceState) -> Router {
    let inference_routes = Router::new()
        .route("/v1/chat/completions", post(inference::chat))
        .route("/v1/responses", post(inference::responses))
        .route("/v1/completions", post(inference::completions))
        .route("/v1/messages", post(inference::messages))
        .with_state(state.clone());
    let routes = Router::new()
        .merge(crate::http::full_surface_routes(
            state.pilot.clone(),
            state.operations.admission_gate(),
        ))
        .merge(operations::router_with_state(state.operations.clone()))
        .merge(super::identity::router(state.identity.clone()))
        .merge(billing::router(state.billing.clone()))
        .merge(inference_routes)
        .fallback(unknown_route)
        .method_not_allowed_fallback(method_not_allowed);
    routes.layer(middleware::from_fn_with_state(state, shared_context))
}

/// Axum's `get` helper implicitly serves `HEAD`. The committed contract does
/// not: a known path with any undeclared method must receive the same stable
/// 405 response as every other unsupported method.
pub(crate) async fn enforce_registered_method(request: Request, next: Next) -> Response {
    let path = request.uri().path();
    if routes::is_registered_path(path)
        && routes::registered_route(request.method(), path).is_none()
    {
        return method_not_allowed().await.into_response();
    }
    next.run(request).await
}

async fn shared_context(
    State(state): State<FullSurfaceState>,
    mut request: Request,
    next: Next,
) -> Result<Response, SharedContextError> {
    let path = request.uri().path();
    let auth_class = shared_auth_class(request.method(), path);
    let admission_kind = admission_kind(&request, auth_class);
    let _admission = if path == "/v1/admin/drain" {
        None
    } else if let Some(kind) = admission_kind {
        match state.operations.admission_gate().enter(kind) {
            Ok(guard) => Some(guard),
            Err(_) => {
                return Ok(drain_rejection());
            }
        }
    } else {
        None
    };
    match auth_class {
        SharedAuth::None => {}
        SharedAuth::Required => {
            let context = state
                .identity
                .auth()
                .authenticate(request.headers(), AuthRequirement::PrivyOrApiKey)
                .await?;
            install_context(&mut request, context)?;
        }
        SharedAuth::OptionalPrivy => {
            if let Ok(context) = state
                .identity
                .auth()
                .authenticate(request.headers(), AuthRequirement::Privy)
                .await
            {
                install_context(&mut request, context)?;
            }
        }
        SharedAuth::OptionalAny => {
            let context = match state
                .identity
                .auth()
                .authenticate(request.headers(), AuthRequirement::PrivyOrApiKey)
                .await
            {
                Ok(context) => Some(context),
                Err(_) => state
                    .identity
                    .auth()
                    .authenticate(request.headers(), AuthRequirement::ProviderToken)
                    .await
                    .ok(),
            };
            if let Some(context) = context {
                install_context(&mut request, context)?;
            }
        }
    }
    Ok(next.run(request).await)
}

fn drain_rejection() -> Response {
    let mut response = (
        StatusCode::TOO_MANY_REQUESTS,
        Json(ErrorEnvelope::new(
            "rate_limit_exceeded",
            "rate_limit_exceeded",
            "draining rate limit exceeded — retry after 3s",
        )),
    )
        .into_response();
    response
        .headers_mut()
        .insert(header::RETRY_AFTER, HeaderValue::from_static("3"));
    response
}

fn admission_kind(request: &Request, auth: SharedAuth) -> Option<AdmissionKind> {
    let path = request.uri().path();
    if matches!(
        path,
        "/v1/chat/completions" | "/v1/responses" | "/v1/completions" | "/v1/messages"
    ) {
        return Some(AdmissionKind::Inference);
    }
    if path == "/ws/provider"
        || routes::is_registered_mutation(request.method(), path)
        || authenticated_get_may_provision(request, auth)
    {
        return Some(AdmissionKind::Mutation);
    }
    None
}

fn authenticated_get_may_provision(request: &Request, auth: SharedAuth) -> bool {
    if request.method() != Method::GET
        || !matches!(
            auth,
            SharedAuth::Required | SharedAuth::OptionalPrivy | SharedAuth::OptionalAny
        )
    {
        return false;
    }
    request
        .headers()
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .is_some_and(|token| token.starts_with("eyJ"))
}

fn install_context(
    request: &mut Request,
    context: super::identity::AuthContext,
) -> Result<(), SharedContextError> {
    if matches!(context.principal, AuthPrincipal::ProviderToken { .. }) {
        request
            .extensions_mut()
            .insert(OperationsPrincipal::new(false));
        request.extensions_mut().insert(context);
        return Ok(());
    }
    let billing_principal = billing_principal(&context)?;
    let billing_context = durable_billing_context(&context)?;
    let operations_principal = OperationsPrincipal::new(context.role.as_ref() == "admin");
    request.extensions_mut().insert(billing_principal);
    request.extensions_mut().insert(billing_context);
    request.extensions_mut().insert(operations_principal);
    request.extensions_mut().insert(context);
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SharedAuth {
    None,
    Required,
    OptionalPrivy,
    OptionalAny,
}

fn shared_auth_class(method: &Method, path: &str) -> SharedAuth {
    match routes::registered_route(method, path).map(|route| route.auth.as_str()) {
        Some("api_key_or_privy") => SharedAuth::Required,
        Some("admin_key_or_privy_admin") => SharedAuth::OptionalPrivy,
        Some("optional_provider_token_privy_api_key_or_anonymous") => SharedAuth::OptionalAny,
        _ => SharedAuth::None,
    }
}

async fn unknown_route() -> impl IntoResponse {
    (
        StatusCode::NOT_FOUND,
        Json(ErrorEnvelope::new(
            "not_found",
            "invalid_request_error",
            "requested endpoint was not found",
        )),
    )
}

async fn method_not_allowed() -> impl IntoResponse {
    (
        StatusCode::METHOD_NOT_ALLOWED,
        Json(ErrorEnvelope::new(
            "method_not_allowed",
            "invalid_request_error",
            "method is not allowed for this endpoint",
        )),
    )
}

#[derive(Serialize)]
struct ErrorEnvelope {
    error: ErrorBody,
}

impl ErrorEnvelope {
    fn new(code: &'static str, kind: &'static str, message: &'static str) -> Self {
        Self {
            error: ErrorBody {
                code,
                kind,
                message,
            },
        }
    }
}

#[derive(Serialize)]
struct ErrorBody {
    code: &'static str,
    #[serde(rename = "type")]
    kind: &'static str,
    message: &'static str,
}

#[derive(Debug)]
enum SharedContextError {
    Identity(IdentityError),
    Billing(BillingError),
    Durable(FullSurfaceBuildError),
}

impl From<IdentityError> for SharedContextError {
    fn from(error: IdentityError) -> Self {
        Self::Identity(error)
    }
}

impl From<BillingError> for SharedContextError {
    fn from(error: BillingError) -> Self {
        Self::Billing(error)
    }
}

impl From<FullSurfaceBuildError> for SharedContextError {
    fn from(error: FullSurfaceBuildError) -> Self {
        Self::Durable(error)
    }
}

impl IntoResponse for SharedContextError {
    fn into_response(self) -> Response {
        match self {
            Self::Identity(error) => error.into_response(),
            Self::Billing(error) => error.into_response(),
            Self::Durable(error) => {
                tracing::error!(error = %error, "authenticated durable context could not be built");
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    Json(ErrorEnvelope::new(
                        "billing_context_unavailable",
                        "server_error",
                        "authenticated billing context is unavailable",
                    )),
                )
                    .into_response()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use axum::{
        Router,
        body::{Body, to_bytes},
        http::{Method, Request, StatusCode},
        middleware,
        response::IntoResponse as _,
        routing::get,
    };
    use serde_json::Value;
    use tower::ServiceExt as _;

    use super::{
        SharedAuth, enforce_registered_method, method_not_allowed, shared_auth_class, unknown_route,
    };

    #[tokio::test]
    async fn contract_methods_reject_axums_implicit_head_without_masking_unknown_paths() {
        let app = Router::new()
            .route("/health", get(|| async { StatusCode::OK }))
            .fallback(unknown_route)
            .method_not_allowed_fallback(method_not_allowed)
            .layer(middleware::from_fn(enforce_registered_method));

        let known_head = call(&app, Method::HEAD, "/health").await;
        assert_eq!(known_head.status(), StatusCode::METHOD_NOT_ALLOWED);

        let known_put = call(&app, Method::PUT, "/health").await;
        assert_eq!(known_put.status(), StatusCode::METHOD_NOT_ALLOWED);
        let body = to_bytes(known_put.into_body(), 64 * 1024)
            .await
            .expect("405 body");
        let value: Value = serde_json::from_slice(&body).expect("405 JSON");
        assert_eq!(value["error"]["code"], "method_not_allowed");

        let unknown = call(&app, Method::HEAD, "/v1/not-a-contract-route").await;
        assert_eq!(unknown.status(), StatusCode::NOT_FOUND);
    }

    #[test]
    fn shared_auth_class_is_derived_from_every_registered_route() {
        for route in crate::surface::registered_routes() {
            if route.method == "ANY" {
                continue;
            }
            let method = Method::from_bytes(route.method.as_bytes()).expect("contract method");
            let expected = match route.auth.as_str() {
                "api_key_or_privy" => SharedAuth::Required,
                "admin_key_or_privy_admin" => SharedAuth::OptionalPrivy,
                "optional_provider_token_privy_api_key_or_anonymous" => SharedAuth::OptionalAny,
                _ => SharedAuth::None,
            };
            let path = representative_path(&route.path);
            assert_eq!(
                shared_auth_class(&method, &path),
                expected,
                "{} {}",
                route.method,
                route.path
            );
        }
    }

    fn representative_path(pattern: &str) -> String {
        if matches!(
            pattern,
            "/v1/models/catalog/manifest/" | "/v1/models/catalog/" | "/v1/admin/models/"
        ) {
            return format!("{pattern}fixture");
        }
        let mut path = pattern.to_owned();
        while let Some(start) = path.find('{') {
            let end = path[start..]
                .find('}')
                .map(|relative| start + relative)
                .expect("contract parameter closes");
            let wildcard = path[start..=end].contains("...");
            path.replace_range(
                start..=end,
                if wildcard { "fixture/child" } else { "fixture" },
            );
        }
        path
    }

    async fn call(app: &Router, method: Method, path: &str) -> axum::response::Response {
        app.clone()
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(path)
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("response")
            .into_response()
    }
}

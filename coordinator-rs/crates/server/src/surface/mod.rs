//! Production HTTP surface adapters grouped by domain.

pub mod billing;
mod config;
mod http;
pub mod identity;
pub mod inference;
pub mod operations;
mod routes;
mod runtime;

pub use config::{FullSurfaceConfig, FullSurfaceConfigError};
pub(crate) use http::enforce_registered_method;
pub use http::router;
pub use routes::{RegisteredRoute, registered_routes};
pub use runtime::{
    FullSurfaceBuildError, FullSurfaceState, billing_principal, durable_billing_context,
};

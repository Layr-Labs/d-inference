//! Objective 5 private-inference pilot composition.

mod config;
mod json_limits;
mod provider;
mod request;
mod runtime;
mod state;
mod telemetry;

pub use config::{
    INPUT_RESERVATION_BYTES, MAX_CONSUMER_BODY_BYTES, MAX_CONSUMER_RESPONSE_BYTES, PilotConfig,
    PilotConfigError, RESPONSE_RESERVATION_BYTES,
};
pub(crate) use json_limits::JsonStructureBudget;
pub use json_limits::{JsonStructureError, validate_json_structure};
pub use provider::{ProviderAcceptError, ProviderAcceptor};
pub use request::{
    PilotRequestError, PilotRequestJob, PilotResponse, RequestDispatchError, RequestDispatcher,
    parse_request_facts,
};
pub use runtime::{PilotHandle, PilotResourceError, PilotRuntime, PilotRuntimeBuildError};
pub use state::{RequestTable, SessionDirectory};
pub use telemetry::{PilotTelemetry, PilotTelemetryEvent};
